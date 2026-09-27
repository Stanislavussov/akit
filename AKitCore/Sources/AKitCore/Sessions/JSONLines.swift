import CryptoKit
import Foundation

/// Reading JSONL session files: one JSON object per line. Broken lines are skipped,
/// so a file that is being written right now still loads.
enum JSONLines {
    typealias Object = [String: Any]

    /// Every line decoded. Throws CancellationError when the surrounding task is cancelled,
    /// so leaving a large session early stops the work.
    static func objects(in data: Data, where keep: (Data) -> Bool = { _ in true }) throws -> [Object] {
        var result: [Object] = []
        for (index, line) in data.split(separator: UInt8(ascii: "\n")).enumerated() {
            if index % 256 == 0 { try Task.checkCancellation() }
            if keep(line), let object = decode(line) { result.append(object) }
        }
        return result
    }

    /// Cheap byte search before decoding: skips lines that can't be what we look for.
    static func contains(_ line: Data, _ needle: Data) -> Bool {
        line.range(of: needle) != nil
    }

    static func decode(_ line: Data) -> Object? {
        try? JSONSerialization.jsonObject(with: line) as? Object
    }

    /// Complete lines from the start of the file, read in chunks until `stop` returns
    /// true or `limit` bytes were read. Returns whether `stop` was satisfied.
    @discardableResult
    static func scanHead(of url: URL, limit: Int = 4 << 20, chunk: Int = 256 << 10,
                         _ visit: (Object) -> Bool) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        var pending = Data()
        var total = 0
        while total < limit, let data = try? handle.read(upToCount: chunk), !data.isEmpty {
            total += data.count
            pending.append(data)
            // Keep the unfinished last line for the next chunk.
            guard let lastNewline = pending.lastIndex(of: UInt8(ascii: "\n")) else { continue }
            let complete = pending[..<lastNewline]
            pending = Data(pending[pending.index(after: lastNewline)...])
            for line in complete.split(separator: UInt8(ascii: "\n")) {
                if let object = decode(line), visit(object) { return true }
            }
        }
        if let object = decode(pending), visit(object) { return true }
        return false
    }

    /// Complete lines from byte `offset` on, each with the offset it starts at. Stops after
    /// the last complete line, so a line being written is read next time, or after the first
    /// line that ends past `deadline` (`stopped`). Returns the offset after the last line read
    /// and its `tailHash` (nil when no complete line was read).
    static func lines(of url: URL, from offset: UInt64, chunk: Int = 1 << 20, until deadline: Date? = nil,
                      _ visit: (Data, UInt64) throws -> Void) throws -> (offset: UInt64, tailHash: String?, stopped: Bool) {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        // Only what the file holds now: a log still being written is read on the next run.
        let end = try handle.seekToEnd()
        guard end > offset else { return (offset, nil, false) }
        try handle.seek(toOffset: offset)
        // `pending[lineStart...]` is the unfinished line; `searched` is where the newline search
        // stopped, so a long line is scanned once, and read bytes are dropped only once they are
        // most of the buffer: a line spanning many chunks costs linear time.
        var pending = Data()
        var lineStart = 0, searched = 0
        var consumed = offset
        var remaining = end - offset
        var lastTail: Data?
        while remaining > 0, let data = try handle.read(upToCount: Int(min(UInt64(chunk), remaining))), !data.isEmpty {
            remaining -= UInt64(data.count)
            pending.append(data)
            var lastLine: Range<Int>?
            var stopped = false
            while let newline = pending[searched...].firstIndex(of: UInt8(ascii: "\n")) {
                let line = pending[lineStart..<newline]
                if !line.isEmpty { try autoreleasepool { try visit(Data(line), consumed) } }
                lastLine = lineStart..<newline
                consumed += UInt64(newline - lineStart + 1)
                lineStart = newline + 1
                searched = lineStart
                if let deadline, Date() >= deadline {
                    stopped = true
                    break
                }
            }
            // An owned copy: a slice kept across `append` would copy the whole buffer each time.
            if let lastLine { lastTail = Data(pending[lastLine].suffix(tailBytes)) }
            if stopped {
                let more = remaining > 0 || pending[lineStart...].contains(UInt8(ascii: "\n"))
                return (consumed, lastTail.map(hash), more)
            }
            searched = pending.endIndex
            if lineStart > pending.count / 2 {
                pending = Data(pending[lineStart...])
                searched -= lineStart
                lineStart = 0
            }
        }
        return (consumed, lastTail.map(hash), false)
    }

    /// How much of a line's end `tailHash` covers.
    static let tailBytes = 64 << 10

    /// SHA-256 of the last `tailBytes` of the line that ends right before `offset` (its newline
    /// is byte `offset - 1`); the whole line when it is shorter, which is also the hash stored
    /// before this bound existed. `whole` tells which. nil at the start of the file or when that
    /// byte isn't a line end. Reads at most `tailBytes + 2` bytes, however long the line is.
    static func tailHash(of url: URL, endingAt offset: UInt64) -> (hash: String, whole: Bool)? {
        guard offset > 0, let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        // The newline before a line of exactly `tailBytes` still fits.
        let window = UInt64(tailBytes) + 2
        let start = offset > window ? offset - window : 0
        guard (try? handle.seek(toOffset: start)) != nil,
              let data = try? handle.read(upToCount: Int(offset - start)), UInt64(data.count) == offset - start,
              data.last == UInt8(ascii: "\n") else { return nil }
        let body = data.dropLast()
        if let newline = body.lastIndex(of: UInt8(ascii: "\n")) {
            return (hash(body[body.index(after: newline)...]), true)
        }
        return (hash(body.suffix(tailBytes)), start == 0 && body.count <= tailBytes)
    }

    /// SHA-256 of the whole line that ends right before `offset`: the `tail_hash` stored before
    /// it was bounded to `tailBytes`. Only asked for lines longer than that, to accept those
    /// stored hashes once. nil past `maxBytes`.
    static func wholeLineHash(of url: URL, endingAt offset: UInt64, maxBytes: UInt64 = 64 << 20) -> String? {
        guard offset > 0, let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var window: UInt64 = 64 << 10
        while true {
            let start = offset > window ? offset - window : 0
            guard (try? handle.seek(toOffset: start)) != nil,
                  let data = try? handle.read(upToCount: Int(offset - start)), UInt64(data.count) == offset - start,
                  data.last == UInt8(ascii: "\n") else { return nil }
            let body = data.dropLast()
            if let newline = body.lastIndex(of: UInt8(ascii: "\n")) {
                return hash(body[body.index(after: newline)...])
            }
            if start == 0 { return hash(body) }
            guard window < maxBytes else { return nil }
            window *= 4
        }
    }

    static func hash(_ data: some DataProtocol) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Complete lines from the last `bytes` of the file. If the last line alone is longer,
    /// the window grows (up to `maxBytes`) until at least one complete line fits.
    static func tail(of url: URL, bytes: Int = 256 << 10, maxBytes: Int = 16 << 20) -> [Object] {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return [] }
        var window = UInt64(bytes)
        while !Task.isCancelled {
            let start = size > window ? size - window : 0
            guard (try? handle.seek(toOffset: start)) != nil, var data = try? handle.readToEnd() else { return [] }
            if start > 0 {
                // Drop the cut-off first line (all of it when the window has no line break).
                if let firstNewline = data.firstIndex(of: UInt8(ascii: "\n")) {
                    data = Data(data[data.index(after: firstNewline)...])
                } else {
                    data = Data()
                }
            }
            let objects = (try? objects(in: data)) ?? []
            if !objects.isEmpty || start == 0 || window >= UInt64(maxBytes) { return objects }
            window *= 4
        }
        return []
    }

    static func date(_ value: Any?) -> Date? {
        guard let text = value as? String else {
            // Pi stores Unix milliseconds inside messages.
            if let ms = value as? Double { return Date(timeIntervalSince1970: ms / 1000) }
            return nil
        }
        return (try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(text))
            ?? (try? Date.ISO8601FormatStyle().parse(text))
    }

    /// Text blocks of a message `content`: a plain string or `[{type: "text", text}]`.
    static func text(of content: Any?) -> String {
        if let text = content as? String { return text }
        guard let blocks = content as? [Object] else { return "" }
        return blocks.compactMap { block -> String? in
            switch block["type"] as? String {
            case "text": block["text"] as? String
            case "image": "[image]"
            default: nil
            }
        }.joined(separator: "\n")
    }

    /// Stable, readable JSON for tool inputs.
    static func pretty(_ value: Any?) -> String {
        guard let value, JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value,
                                                     options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        else { return value.map { "\($0)" } ?? "" }
        return String(decoding: data, as: UTF8.self)
    }

    /// First line of a prompt, short enough for a list row.
    static func titleLine(_ text: String, limit: Int = 120) -> String {
        let line = text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty } ?? ""
        return line.count > limit ? String(line.prefix(limit)) + "…" : line
    }

    /// Summaries of many files, read in parallel. Order is kept.
    static func summaries(of files: [URL], _ read: @Sendable (URL) -> SessionSummary?) -> [SessionSummary] {
        let results = ResultBox(count: files.count)
        DispatchQueue.concurrentPerform(iterations: files.count) { index in
            results.set(index, read(files[index]))
        }
        return results.values.compactMap { $0 }
    }

    static func fileInfo(_ url: URL) -> (modified: Date, size: Int) {
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        return (values?.contentModificationDate ?? .distantPast, values?.fileSize ?? 0)
    }
}

/// Slots written from `concurrentPerform`, one per index, under a lock.
private final class ResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var slots: [SessionSummary?]

    init(count: Int) { slots = Array(repeating: nil, count: count) }

    func set(_ index: Int, _ value: SessionSummary?) {
        lock.withLock { slots[index] = value }
    }

    var values: [SessionSummary?] { lock.withLock { slots } }
}
