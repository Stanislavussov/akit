import Foundation

/// Changes one member of a JSON file's text and keeps every other byte: key order, spacing,
/// other keys. For files a harness owns and may rewrite itself (`~/.claude/settings.json`),
/// where a full rewrite with sorted keys would be a needless diff.
public enum JSONTextEdit {
    public struct Failure: Error, LocalizedError {
        public let message: String
        public var errorDescription: String? { message }
    }

    /// Sets `value` at the key path. Missing objects on the way are made; a value on the way
    /// that is not an object is refused. A new member goes after the object's last member,
    /// with the same indentation.
    public static func setting(_ value: JSONValue, at path: [String], in text: String) throws(Failure) -> String {
        guard !path.isEmpty else { throw Failure(message: "No key to set.") }
        let scanner = try Scanner(text)
        var bytes = scanner.bytes
        try set(value, path: path[...], objectAt: scanner.root, scanner: scanner, into: &bytes)
        return String(decoding: bytes, as: UTF8.self)
    }

    /// Removes the member at the key path; the text is returned unchanged when it is not there.
    public static func removing(at path: [String], in text: String) throws(Failure) -> String {
        guard !path.isEmpty else { throw Failure(message: "No key to remove.") }
        let scanner = try Scanner(text)
        var open = scanner.root
        for key in path.dropLast() {
            guard let member = scanner.members(ofObjectAt: open).members.first(where: { Self.same($0.key, key) }),
                  scanner.bytes[member.valueStart] == UInt8(ascii: "{") else { return text }
            open = member.valueStart
        }
        let (members, close) = scanner.members(ofObjectAt: open)
        guard let index = members.firstIndex(where: { Self.same($0.key, path.last!) }) else { return text }
        var bytes = scanner.bytes
        let range: Range<Int>
        if members.count == 1 {
            range = (open + 1)..<close
        } else if index < members.count - 1 {
            range = members[index].keyStart..<members[index + 1].keyStart
        } else {
            range = members[index - 1].valueEnd..<members[index].valueEnd
        }
        bytes.removeSubrange(range)
        return String(decoding: bytes, as: UTF8.self)
    }

    // MARK: - Setting

    private static func set(_ value: JSONValue, path: ArraySlice<String>, objectAt open: Int, scanner: Scanner,
                            into bytes: inout [UInt8]) throws(Failure) {
        let key = path.first!
        let (members, close) = scanner.members(ofObjectAt: open)
        if let member = members.first(where: { Self.same($0.key, key) }) {
            if path.count > 1 {
                guard scanner.bytes[member.valueStart] == UInt8(ascii: "{") else {
                    throw Failure(message: "“\(key)” is not an object; AKit won't replace it.")
                }
                try set(value, path: path.dropFirst(), objectAt: member.valueStart, scanner: scanner, into: &bytes)
                return
            }
            let old = scanner.bytes[member.valueStart..<member.valueEnd]
            let inline = !old.contains(UInt8(ascii: "\n"))
            let indent = scanner.indent(ofLineAt: member.keyStart)
            bytes.replaceSubrange(member.valueStart..<member.valueEnd,
                                  with: Array(render(value, indent: indent, inline: inline, newline: scanner.newline).utf8))
            return
        }
        // The rest of the path becomes nested objects around the value.
        var wrapped = value
        for inner in path.dropFirst().reversed() { wrapped = .object([inner: wrapped]) }
        let quotedKey = JSONValue.string(key).compact
        if let last = members.last {
            if let indent = scanner.leadingIndent(at: last.keyStart) {
                let text = "," + scanner.newline + indent + quotedKey + ": " + render(wrapped, indent: indent, inline: false, newline: scanner.newline)
                bytes.insert(contentsOf: Array(text.utf8), at: last.valueEnd)
            } else {
                let text = ", " + quotedKey + ": " + render(wrapped, indent: "", inline: true)
                bytes.insert(contentsOf: Array(text.utf8), at: last.valueEnd)
            }
        } else {
            let outer = scanner.indent(ofLineAt: open)
            let inner = outer + scanner.indentUnit
            let newline = scanner.newline
            let text = "{" + newline + inner + quotedKey + ": " + render(wrapped, indent: inner, inline: false, newline: newline) + newline + outer + "}"
            bytes.replaceSubrange(open...close, with: Array(text.utf8))
        }
    }

    /// Keys are compared by their Unicode scalars, as harnesses compare them (Swift's `==` treats
    /// precomposed and decomposed letters as equal).
    static func same(_ a: String, _ b: String) -> Bool { a.unicodeScalars.elementsEqual(b.unicodeScalars) }

    /// The value as AKit writes it at this indentation; `inline`: on one line (`["a", "b"]`).
    private static func render(_ value: JSONValue, indent: String, inline: Bool, newline: String = "\n") -> String {
        if inline {
            if case .array(let items) = value { return "[" + items.map(\.compact).joined(separator: ", ") + "]" }
            return value.compact
        }
        return String(value.pretty.dropLast()).replacingOccurrences(of: "\n", with: newline + indent)
    }

    // MARK: - Scanning

    struct Member {
        let key: String
        let keyStart: Int
        let valueStart: Int
        let valueEnd: Int
    }

    /// Finds members in text that `JSONValue.parse` already accepted, so it trusts the syntax.
    struct Scanner {
        let bytes: [UInt8]
        /// The `{` of the top-level object.
        let root: Int

        init(_ text: String) throws(Failure) {
            bytes = Array(text.utf8)
            let value: JSONValue
            do {
                value = try JSONValue.parse(Data(bytes))
            } catch {
                throw Failure(message: "The file is not valid JSON (\(error.message)).")
            }
            guard case .object = value else { throw Failure(message: "The file is not a JSON object.") }
            var index = bytes.starts(with: [0xEF, 0xBB, 0xBF]) ? 3 : 0
            while index < bytes.count, Self.isSpace(bytes[index]) { index += 1 }
            root = index
        }

        static func isSpace(_ byte: UInt8) -> Bool { [0x20, 0x09, 0x0A, 0x0D].contains(byte) }

        func skipSpace(_ start: Int) -> Int {
            var index = start
            while index < bytes.count, Self.isSpace(bytes[index]) { index += 1 }
            return index
        }

        /// The index just after the value that starts at `start`.
        func valueEnd(_ start: Int) -> Int {
            var index = start
            switch bytes[index] {
            case UInt8(ascii: "\""):
                return stringEnd(index)
            case UInt8(ascii: "{"), UInt8(ascii: "["):
                var depth = 0
                while index < bytes.count {
                    switch bytes[index] {
                    case UInt8(ascii: "\""): index = stringEnd(index); continue
                    case UInt8(ascii: "{"), UInt8(ascii: "["): depth += 1
                    case UInt8(ascii: "}"), UInt8(ascii: "]"):
                        depth -= 1
                        if depth == 0 { return index + 1 }
                    default: break
                    }
                    index += 1
                }
                return index
            default:
                while index < bytes.count, !Self.isSpace(bytes[index]),
                      ![UInt8(ascii: ","), UInt8(ascii: "}"), UInt8(ascii: "]")].contains(bytes[index]) { index += 1 }
                return index
            }
        }

        /// The index just after the closing quote of the string that starts at `start`.
        func stringEnd(_ start: Int) -> Int {
            var index = start + 1
            while index < bytes.count {
                if bytes[index] == UInt8(ascii: "\\") { index += 2; continue }
                if bytes[index] == UInt8(ascii: "\"") { return index + 1 }
                index += 1
            }
            return index
        }

        /// The members of the object whose `{` is at `open`, and the index of its `}`.
        func members(ofObjectAt open: Int) -> (members: [Member], close: Int) {
            var result: [Member] = []
            var index = skipSpace(open + 1)
            while index < bytes.count, bytes[index] != UInt8(ascii: "}") {
                let keyStart = index
                let keyEnd = stringEnd(index)
                var key = ""
                if case .string(let text)? = try? JSONValue.parse(Data(bytes[keyStart..<keyEnd])) { key = text }
                index = skipSpace(keyEnd) + 1  // the colon
                let valueStart = skipSpace(index)
                let end = valueEnd(valueStart)
                result.append(Member(key: key, keyStart: keyStart, valueStart: valueStart, valueEnd: end))
                index = skipSpace(end)
                if index < bytes.count, bytes[index] == UInt8(ascii: ",") { index = skipSpace(index + 1) }
            }
            return (result, index)
        }

        /// The spaces and tabs before `index` when nothing else is on its line before it; nil for
        /// a member that shares its line with something else (`{"a": 1, …`).
        func leadingIndent(at index: Int) -> String? {
            var start = index
            while start > 0, bytes[start - 1] != UInt8(ascii: "\n") { start -= 1 }
            guard start > 0 else { return nil }
            let prefix = bytes[start..<index]
            return prefix.allSatisfy({ $0 == 0x20 || $0 == 0x09 }) ? String(decoding: prefix, as: UTF8.self) : nil
        }

        /// The indentation of the line that holds `index`.
        func indent(ofLineAt index: Int) -> String {
            var start = index
            while start > 0, bytes[start - 1] != UInt8(ascii: "\n") { start -= 1 }
            var end = start
            while end < bytes.count, bytes[end] == 0x20 || bytes[end] == 0x09 { end += 1 }
            return String(decoding: bytes[start..<end], as: UTF8.self)
        }

        /// The file's line ending: `\r\n` when it uses it, else `\n`.
        var newline: String {
            guard let first = bytes.firstIndex(of: UInt8(ascii: "\n")) else { return "\n" }
            return first > 0 && bytes[first - 1] == UInt8(ascii: "\r") ? "\r\n" : "\n"
        }

        /// One level of indentation: the top-level object's first indented member, else two spaces.
        var indentUnit: String {
            for member in members(ofObjectAt: root).members {
                if let indent = leadingIndent(at: member.keyStart), !indent.isEmpty { return indent }
            }
            return "  "
        }
    }
}
