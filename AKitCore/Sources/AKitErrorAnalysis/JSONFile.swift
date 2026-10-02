import AKitLab
import Foundation

/// The analysis folder's JSON files are written by the app, by `akit` in a terminal tab and
/// by two batch workers at once. Every write, and every read-modify-write, happens under an
/// exclusive `flock` on `<file>.lock`, so no writer saves over another's change with a stale
/// copy. The lock is held only around file work, never across a model call.
enum JSONFile {
    struct Failure: Error, LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static func read<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        (try? Data(contentsOf: url)).flatMap { try? AnalysisJSON.decoder.decode(T.self, from: $0) }
    }

    static func locked<R>(_ url: URL, _ body: () throws -> R) throws -> R {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        return try FileLock.locked(url.appendingPathExtension("lock"), body)
    }

    static func write<T: Encodable>(_ value: T, to url: URL) throws {
        try locked(url) { try AnalysisJSON.encoder.encode(value).write(to: url, options: .atomic) }
    }

    /// Reads the file (or `empty` when there is none), lets `change` edit it, writes it back.
    @discardableResult
    static func update<T: Codable, R>(_ url: URL, empty: @autoclosure () -> T, _ change: (inout T) throws -> R) throws -> R {
        try locked(url) {
            // A file that exists but can't be read is never replaced with an empty one: it may
            // hold the test-once records, splits or reservations.
            var value: T
            if FileManager.default.fileExists(atPath: url.path) {
                guard let read = read(T.self, from: url) else {
                    throw Failure(message: "\(url.path) can't be read; fix or move it before AKit changes it.")
                }
                value = read
            } else {
                value = empty()
            }
            let result = try change(&value)
            try AnalysisJSON.encoder.encode(value).write(to: url, options: .atomic)
            return result
        }
    }
}
