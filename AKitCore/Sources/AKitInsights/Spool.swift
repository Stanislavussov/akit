import Darwin
import Foundation

/// The hand-off from hooks (and `apply`) to the importer: daily files
/// `~/.akit/index/spool/YYYY-MM-DD.jsonl` (UTC day at the time of writing), one JSON object
/// per line. A writer opens with `O_APPEND`, writes the whole line in one `write(2)` and
/// closes; no lock is shared with anyone. The kernel appends each such write at the end of
/// the file as one piece, so parallel sessions never interleave their lines. That holds on
/// a local APFS home only; homes on NFS or SMB are not supported.
///
/// The importer reads each day file like a log (offset in the fact transaction) and deletes
/// it once fully read, two days old and without lines it didn't understand.
public enum Spool {
    /// Version of the line format (`"v"`); lines of a newer version are left for a newer akit.
    public static let lineVersion = 1
    /// Line kinds this akit writes and reads. An older akit counts a kind it doesn't know (as
    /// `mark` before spool parser 2) in `sources.unknown_lines` and keeps the file for a newer one.
    static let kinds: Set<String> = ["session_start", "apply", "mark", "rating"]
    /// Lines longer than this drop their longest fields (`transcript`, `cwd`) first.
    static let maxLine = 4096

    /// Appends one line to today's file. Never throws and never prints: a hook must not
    /// break or slow down a harness, and an apply must not fail over it. Returns whether the
    /// whole line was written (for `akit stats mark`; hooks ignore it).
    @discardableResult
    public static func append(_ object: [String: Any], home: URL, now: Date = Date()) -> Bool {
        guard let line = line(object) else { return false }
        let folder = InsightsPaths(home: home).spool
        let path = folder.appending(path: fileName(for: now)).path
        var fd = open(path, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC, 0o600)
        if fd < 0, errno == ENOENT {
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                     attributes: [.posixPermissions: 0o700])
            fd = open(path, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC, 0o600)
        }
        guard fd >= 0 else { return false }
        defer { close(fd) }
        // One write for the whole line; retried (a few times) only when a signal interrupted it
        // before anything was written.
        return line.withUnsafeBytes { bytes in
            for _ in 0..<8 {
                let written = write(fd, bytes.baseAddress, bytes.count)
                if written >= 0 { return written == bytes.count }
                if errno != EINTR { return false }
            }
            return false
        }
    }

    /// The line with its newline; without `transcript` and `cwd` when it would be too long.
    /// A line still longer (an apply of a huge layer set) is written anyway, in one write.
    static func line(_ object: [String: Any]) -> Data? {
        func encode(_ value: [String: Any]) -> Data? {
            guard JSONSerialization.isValidJSONObject(value),
                  var data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes])
            else { return nil }
            data.append(UInt8(ascii: "\n"))
            return data
        }
        guard let data = encode(object) else { return nil }
        guard data.count > maxLine else { return data }
        var shorter = object
        shorter["transcript"] = nil
        shorter["cwd"] = nil
        return encode(shorter)
    }

    /// `2026-09-27.jsonl` for any time on that UTC day.
    static func fileName(for date: Date) -> String {
        day(of: date) + ".jsonl"
    }

    static func day(of date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    /// The UTC start of the day a spool file is named after; nil for any other name.
    static func dayStart(ofFile name: String) -> Date? {
        guard name.hasSuffix(".jsonl") else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: String(name.dropLast(".jsonl".count)))
    }

    /// Unix milliseconds, the `ts` of every spool line.
    public static func milliseconds(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1000).rounded(.down))
    }
}

// MARK: - Marks

extension Spool {
    public struct MarkFailure: Error, LocalizedError {
        public let message: String
        public var errorDescription: String? { message }
    }

    public static let maxNoteLength = 500

    /// A change made by hand (`akit stats mark`, the Insights screen's Add Mark…): one spool line
    /// the next import turns into a before/after anchor at `date`. Returns the note as written.
    @discardableResult
    public static func mark(_ note: String, at date: Date, home: URL, now: Date = Date()) throws(MarkFailure) -> String {
        let text = note.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw MarkFailure(message: "The note is empty.") }
        guard text.count <= maxNoteLength else { throw MarkFailure(message: "The note is longer than \(maxNoteLength) characters.") }
        guard date <= now else { throw MarkFailure(message: "The time is in the future.") }
        guard append(["v": lineVersion, "kind": "mark", "note": text, "ts": milliseconds(date)], home: home, now: now) else {
            throw MarkFailure(message: "Couldn't write the mark into \(InsightsPaths(home: home).spool.path); nothing was marked.")
        }
        return text
    }
}
