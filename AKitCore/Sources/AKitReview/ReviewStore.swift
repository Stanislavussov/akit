import AKitLab
import Foundation

/// JSON files of a run folder, written under a `flock` (the app and `akit review` in a terminal
/// may write the same run).
public enum ReviewJSON {
    public struct Failure: Error, LocalizedError {
        public let message: String
        public var errorDescription: String? { message }
    }

    public static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    public static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    public static func read<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        (try? Data(contentsOf: url)).flatMap { try? decoder.decode(T.self, from: $0) }
    }

    public static func write<T: Encodable>(_ value: T, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileLock.locked(url.appendingPathExtension("lock")) { try encoder.encode(value).write(to: url, options: .atomic) }
    }

    /// Reads (or starts from `empty`), changes, writes back, all under the lock. A file that
    /// exists but can't be read is never replaced.
    @discardableResult
    public static func update<T: Codable, R>(_ url: URL, empty: @autoclosure () -> T, _ change: (inout T) throws -> R) throws -> R {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        return try FileLock.locked(url.appendingPathExtension("lock")) {
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
            try encoder.encode(value).write(to: url, options: .atomic)
            return result
        }
    }
}

/// Glob patterns of path instructions: `**` crosses folders, `*` and `?` don't.
enum ReviewGlob {
    static func matches(_ pattern: String, _ path: String) -> Bool {
        var regex = "^"
        var characters = Array(pattern)
        if characters.first == "/" { characters.removeFirst() }
        var i = 0
        while i < characters.count {
            let c = characters[i]
            if c == "*", i + 1 < characters.count, characters[i + 1] == "*" {
                if i + 2 < characters.count, characters[i + 2] == "/" {
                    regex += "(?:.*/)?"
                    i += 3
                } else {
                    regex += ".*"
                    i += 2
                }
                continue
            }
            switch c {
            case "*": regex += "[^/]*"
            case "?": regex += "[^/]"
            default: regex += NSRegularExpression.escapedPattern(for: String(c))
            }
            i += 1
        }
        regex += "$"
        return path.range(of: regex, options: .regularExpression) != nil
    }
}
