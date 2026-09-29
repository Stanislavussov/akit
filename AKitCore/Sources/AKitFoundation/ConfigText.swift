import Foundation

/// Small readers for config formats Foundation doesn't know.
public enum ConfigText {
    /// JSON with `//` and `/* */` comments and trailing commas (OpenCode's `.jsonc`) → plain JSON.
    public static func stripJSONC(_ text: String) -> String {
        var out = ""
        var chars = Array(normalized(text))
        var index = 0
        var inString = false
        while index < chars.count {
            let char = chars[index]
            let next = index + 1 < chars.count ? chars[index + 1] : nil
            if inString {
                out.append(char)
                if char == "\\", let next { out.append(next); index += 2; continue }
                if char == "\"" { inString = false }
                index += 1
            } else if char == "\"" {
                inString = true
                out.append(char)
                index += 1
            } else if char == "/", next == "/" {
                while index < chars.count, chars[index] != "\n" { index += 1 }
            } else if char == "/", next == "*" {
                index += 2
                while index + 1 < chars.count, !(chars[index] == "*" && chars[index + 1] == "/") { index += 1 }
                index += 2
            } else {
                out.append(char)
                index += 1
            }
        }
        // Trailing commas: `,` followed only by whitespace before `}` or `]` (outside strings).
        chars = Array(out)
        out = ""
        inString = false
        for (i, char) in chars.enumerated() {
            if inString {
                if char == "\"" {
                    var backslashes = 0
                    var j = i - 1
                    while j >= 0, chars[j] == "\\" { backslashes += 1; j -= 1 }
                    if backslashes % 2 == 0 { inString = false }
                }
            } else if char == "\"" {
                inString = true
            } else if char == "," {
                var j = i + 1
                while j < chars.count, chars[j].isWhitespace { j += 1 }
                if j < chars.count, chars[j] == "}" || chars[j] == "]" { continue }
            }
            out.append(char)
        }
        return out
    }

    /// `\r\n` is one Character in Swift and would never equal `\n`; also drops a BOM.
    public static func normalized(_ text: String) -> String {
        var text = text.replacingOccurrences(of: "\r\n", with: "\n")
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        return text
    }

    public static func jsonObject(_ data: Data, jsonc: Bool) throws -> [String: Any] {
        var data = data
        if jsonc, let text = String(data: data, encoding: .utf8) { data = Data(stripJSONC(text).utf8) }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ConfigTextError("the top level is not an object")
        }
        return object
    }
}

public struct ConfigTextError: Error, LocalizedError {
    let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

/// Enough TOML for Codex's `config.toml`: tables, dotted keys, strings, numbers,
/// booleans, arrays and inline tables. Arrays of tables (`[[x]]`) are skipped:
/// MCP servers never use them.
public struct MiniTOML {
    private let chars: [Character]
    private var index = 0
    /// Nesting of arrays and inline tables; deep input would overflow the stack.
    private var depth = 0
    static let maxDepth = 64

    public static func parse(_ text: String) throws -> [String: Any] {
        var parser = MiniTOML(chars: Array(ConfigText.normalized(text)))
        return try parser.document()
    }

    private init(chars: [Character]) { self.chars = chars }

    private var current: Character? { index < chars.count ? chars[index] : nil }
    private var line: Int { chars[..<min(index, chars.count)].filter { $0 == "\n" }.count + 1 }

    private func error(_ message: String) -> ConfigTextError { ConfigTextError("line \(line): \(message)") }

    private mutating func document() throws -> [String: Any] {
        var root: [String: Any] = [:]
        var table: [String]? = []
        while true {
            skipBlank(newlines: true)
            guard let char = current else { return root }
            if char == "[" {
                if index + 1 < chars.count, chars[index + 1] == "[" {
                    index += 2
                    _ = try keyPath()
                    try expect("]"); try expect("]")
                    table = nil // content of arrays of tables is ignored
                } else {
                    index += 1
                    let path = try keyPath()
                    try expect("]")
                    Self.ensureTable(path[...], in: &root)
                    table = path
                }
            } else {
                let path = try keyPath()
                try expect("=")
                skipBlank(newlines: false)
                let value = try self.value()
                if let table { Self.set(value, at: (table + path)[...], in: &root) }
            }
            skipBlank(newlines: false)
            if let char = current, char != "\n", char != "\r" { throw error("unexpected \"\(char)\"") }
        }
    }

    private mutating func keyPath() throws -> [String] {
        var parts: [String] = []
        repeat {
            skipBlank(newlines: false)
            if current == "." { index += 1; skipBlank(newlines: false) }
            switch current {
            case "\"": parts.append(try basicString())
            case "'": parts.append(try literalString())
            default:
                var key = ""
                while let char = current, char.isLetter || char.isNumber || char == "_" || char == "-" {
                    key.append(char); index += 1
                }
                if key.isEmpty { throw error("key expected") }
                parts.append(key)
            }
            skipBlank(newlines: false)
            if parts.count > Self.maxDepth { throw error("key is too long") }
        } while current == "."
        return parts
    }

    private mutating func value() throws -> Any {
        let nested = current == "[" || current == "{"
        if nested {
            depth += 1
            guard depth <= Self.maxDepth else { throw error("nested too deep") }
        }
        defer { if nested { depth -= 1 } }
        switch current {
        case "\"": return try basicString()
        case "'": return try literalString()
        case "[":
            index += 1
            var items: [Any] = []
            while true {
                skipBlank(newlines: true)
                if current == "]" { index += 1; return items }
                items.append(try value())
                skipBlank(newlines: true)
                if current == "," { index += 1; continue }
                if current == "]" { index += 1; return items }
                throw error("\",\" or \"]\" expected in array")
            }
        case "{":
            index += 1
            var table: [String: Any] = [:]
            skipBlank(newlines: false)
            if current == "}" { index += 1; return table }
            while true {
                let path = try keyPath()
                try expect("=")
                skipBlank(newlines: false)
                Self.set(try value(), at: path[...], in: &table)
                skipBlank(newlines: false)
                if current == "," { index += 1; continue }
                if current == "}" { index += 1; return table }
                throw error("\",\" or \"}\" expected in inline table")
            }
        default:
            var token = ""
            while let char = current, !",]}#\n\r".contains(char) { token.append(char); index += 1 }
            token = token.trimmingCharacters(in: .whitespaces)
            if token == "true" { return true }
            if token == "false" { return false }
            if let number = Int(token.replacingOccurrences(of: "_", with: "")) { return number }
            if let number = Double(token.replacingOccurrences(of: "_", with: "")) { return number }
            if token.isEmpty { throw error("value expected") }
            return token // dates and times stay text
        }
    }

    private mutating func basicString() throws -> String {
        let multiline = starts(with: "\"\"\"")
        index += multiline ? 3 : 1
        if multiline, current == "\n" { index += 1 }
        var result = ""
        while let char = current {
            if multiline ? starts(with: "\"\"\"") : char == "\"" {
                index += multiline ? 3 : 1
                return result
            }
            if !multiline, char == "\n" { break }
            index += 1
            guard char == "\\" else { result.append(char); continue }
            guard let escaped = current else { break }
            index += 1
            switch escaped {
            case "n": result.append("\n")
            case "t": result.append("\t")
            case "r": result.append("\r")
            case "\"": result.append("\"")
            case "\\": result.append("\\")
            case "u", "U":
                let length = escaped == "u" ? 4 : 8
                let hex = String(chars[index..<min(index + length, chars.count)])
                index += length
                if let code = UInt32(hex, radix: 16), let scalar = Unicode.Scalar(code) { result.append(Character(scalar)) }
            case "\n" where multiline:
                while let next = current, next.isWhitespace { index += 1 }
            default: result.append(escaped)
            }
        }
        throw error("unterminated string")
    }

    private mutating func literalString() throws -> String {
        let multiline = starts(with: "'''")
        index += multiline ? 3 : 1
        if multiline, current == "\n" { index += 1 }
        var result = ""
        while let char = current {
            if multiline ? starts(with: "'''") : char == "'" {
                index += multiline ? 3 : 1
                return result
            }
            if !multiline, char == "\n" { break }
            result.append(char)
            index += 1
        }
        throw error("unterminated string")
    }

    private func starts(with text: String) -> Bool {
        let expected = Array(text)
        guard index + expected.count <= chars.count else { return false }
        return Array(chars[index..<index + expected.count]) == expected
    }

    private mutating func expect(_ char: Character) throws {
        skipBlank(newlines: false)
        guard current == char else { throw error("\"\(char)\" expected") }
        index += 1
    }

    /// Spaces, tabs, comments and (optionally) line breaks.
    private mutating func skipBlank(newlines: Bool) {
        while let char = current {
            if char == " " || char == "\t" || (newlines && (char == "\n" || char == "\r")) {
                index += 1
            } else if char == "#" {
                while let next = current, next != "\n" { index += 1 }
            } else {
                return
            }
        }
    }

    private static func ensureTable(_ path: ArraySlice<String>, in dict: inout [String: Any]) {
        guard let first = path.first else { return }
        var child = dict[first] as? [String: Any] ?? [:]
        ensureTable(path.dropFirst(), in: &child)
        dict[first] = child
    }

    private static func set(_ value: Any, at path: ArraySlice<String>, in dict: inout [String: Any]) {
        guard let first = path.first else { return }
        if path.count == 1 { dict[first] = value; return }
        var child = dict[first] as? [String: Any] ?? [:]
        set(value, at: path.dropFirst(), in: &child)
        dict[first] = child
    }
}
