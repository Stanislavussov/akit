import Foundation
import os

/// The Meetings log: each line goes to the macOS log (subsystem `dev.ussov.meetings`, so
/// `log show --predicate 'subsystem == "dev.ussov.meetings"'` finds it) and to
/// `~/Library/Logs/Meetings/meetings.log` (Settings → Show Log, Copy Log). It never holds the key,
/// a request body, audio or transcript text: only what happened, sizes, codes and times.
public enum MeetingsLog {
    public enum Area: String, Sendable { case recorder, mixer, openrouter, processor, key, store, ui, ask, local, pi }

    public static var file: URL {
        // Tests never write into the real home.
        if isTest { return FileManager.default.temporaryDirectory.appending(path: "meetings-test-log/meetings.log") }
        return userHome.appending(path: "Library/Logs/Meetings/meetings.log")
    }

    static let isTest: Bool = {
        let name = ProcessInfo.processInfo.processName.lowercased()
        return name.contains("xctest") || name.contains("swiftpm-testing") || NSClassFromString("XCTestCase") != nil
            || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }()
    static let maxBytes = 5_000_000
    private static let lock = NSLock()
    nonisolated(unsafe) private static let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    public static func info(_ area: Area, _ message: String) { write(area, "info", message) }
    public static func error(_ area: Area, _ message: String) { write(area, "error", message) }

    static func write(_ area: Area, _ level: String, _ message: String) {
        let logger = Logger(subsystem: "dev.ussov.meetings", category: area.rawValue)
        if level == "error" { logger.error("\(message, privacy: .public)") } else { logger.info("\(message, privacy: .public)") }
        let line = "\(formatter.string(from: Date())) [\(level)] \(area.rawValue): \(message)\n"
        lock.withLock {
            let url = file
            let fm = FileManager.default
            try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            // One old file is kept beside the new one.
            if let size = (try? fm.attributesOfItem(atPath: url.path))?[.size] as? Int, size > maxBytes {
                let old = url.deletingPathExtension().appendingPathExtension("1.log")
                try? fm.removeItem(at: old)
                try? fm.moveItem(at: url, to: old)
            }
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write(Data(line.utf8))
                try? handle.close()
            } else {
                try? Data(line.utf8).write(to: url)
            }
        }
    }

    /// The last `lines` lines, for Copy Log.
    public static func tail(_ lines: Int = 400) -> String {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return "" }
        return text.split(separator: "\n", omittingEmptySubsequences: false).suffix(lines).joined(separator: "\n")
    }
}
