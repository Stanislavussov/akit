import Foundation

/// A JSON document as a value: for merging JSON files key by key (layers into `.mcp.json`
/// and `.claude/settings.json`). Objects are compared and printed with sorted keys.
public enum JSONValue: Hashable, Sendable {
    case object([String: JSONValue])
    case array([JSONValue])
    case string(String)
    /// The number as written in the JSON text (`1`, `2.50`, `1e21`): never rounded.
    case number(String)
    case bool(Bool)
    case null

    public struct ParseError: Error, LocalizedError {
        public let message: String
        public var errorDescription: String? { message }
    }

    /// Strict JSON (no comments, no trailing commas). Numbers keep their text, so a rewrite
    /// never rounds them; a key given twice in one object is an error (harnesses would take
    /// the last one, and a rewrite would silently keep only one).
    public static func parse(_ data: Data) throws(ParseError) -> JSONValue {
        var parser = Parser(bytes: Array(data))
        if parser.bytes.starts(with: [0xEF, 0xBB, 0xBF]) { parser.index = 3 }
        let value = try parser.value(depth: 0)
        parser.skipSpace()
        guard parser.index == parser.bytes.count else { throw parser.error("unexpected text after the end") }
        return value
    }

    private struct Parser {
        let bytes: [UInt8]
        var index = 0

        func error(_ message: String) -> ParseError { ParseError(message: "\(message) at byte \(index)") }

        mutating func skipSpace() {
            while index < bytes.count, [0x20, 0x09, 0x0A, 0x0D].contains(bytes[index]) { index += 1 }
        }

        mutating func expect(_ word: String) throws(ParseError) {
            let utf8 = Array(word.utf8)
            guard bytes[index...].starts(with: utf8) else { throw error("expected \(word)") }
            index += utf8.count
        }

        mutating func value(depth: Int) throws(ParseError) -> JSONValue {
            guard depth < 100 else { throw error("nested too deeply") }
            skipSpace()
            guard index < bytes.count else { throw error("unexpected end") }
            switch bytes[index] {
            case UInt8(ascii: "{"):
                index += 1
                var members: [String: JSONValue] = [:]
                skipSpace()
                if index < bytes.count, bytes[index] == UInt8(ascii: "}") { index += 1; return .object(members) }
                while true {
                    skipSpace()
                    guard index < bytes.count, bytes[index] == UInt8(ascii: "\"") else { throw error("expected a key") }
                    let key = try string()
                    // Swift compares strings by canonical equivalence, so "é" written precomposed
                    // (NFC) and decomposed (NFD) is one key here: such a file reads as having a key
                    // twice and is refused. Harnesses would see two keys; AKit never merges into it.
                    guard members[key] == nil else { throw error("the key \"\(key)\" appears twice") }
                    skipSpace()
                    try expect(":")
                    members[key] = try value(depth: depth + 1)
                    skipSpace()
                    guard index < bytes.count else { throw error("unexpected end") }
                    if bytes[index] == UInt8(ascii: ",") { index += 1; continue }
                    try expect("}")
                    return .object(members)
                }
            case UInt8(ascii: "["):
                index += 1
                var items: [JSONValue] = []
                skipSpace()
                if index < bytes.count, bytes[index] == UInt8(ascii: "]") { index += 1; return .array(items) }
                while true {
                    items.append(try value(depth: depth + 1))
                    skipSpace()
                    guard index < bytes.count else { throw error("unexpected end") }
                    if bytes[index] == UInt8(ascii: ",") { index += 1; continue }
                    try expect("]")
                    return .array(items)
                }
            case UInt8(ascii: "\""): return .string(try string())
            case UInt8(ascii: "t"): try expect("true"); return .bool(true)
            case UInt8(ascii: "f"): try expect("false"); return .bool(false)
            case UInt8(ascii: "n"): try expect("null"); return .null
            default: return .number(try number())
            }
        }

        /// `-? (0 | [1-9][0-9]*) (. [0-9]+)? ([eE] [+-]? [0-9]+)?`, kept as written.
        mutating func number() throws(ParseError) -> String {
            let start = index
            func digits() -> Int {
                let from = index
                while index < bytes.count, (0x30...0x39).contains(bytes[index]) { index += 1 }
                return index - from
            }
            if index < bytes.count, bytes[index] == UInt8(ascii: "-") { index += 1 }
            guard index < bytes.count, (0x30...0x39).contains(bytes[index]) else { throw error("unexpected character") }
            if bytes[index] == UInt8(ascii: "0") { index += 1 } else { _ = digits() }
            if index < bytes.count, bytes[index] == UInt8(ascii: ".") {
                index += 1
                guard digits() > 0 else { throw error("expected digits after the point") }
            }
            if index < bytes.count, bytes[index] == UInt8(ascii: "e") || bytes[index] == UInt8(ascii: "E") {
                index += 1
                if index < bytes.count, bytes[index] == UInt8(ascii: "+") || bytes[index] == UInt8(ascii: "-") { index += 1 }
                guard digits() > 0 else { throw error("expected digits in the exponent") }
            }
            return String(decoding: bytes[start..<index], as: UTF8.self)
        }

        mutating func string() throws(ParseError) -> String {
            index += 1  // the opening quote
            var scalars = String.UnicodeScalarView()
            var run = index  // start of plain bytes not yet copied
            func flush(_ end: Int) throws(ParseError) {
                guard let text = String(bytes: bytes[run..<end], encoding: .utf8) else { throw error("invalid UTF-8") }
                scalars.append(contentsOf: text.unicodeScalars)
            }
            while true {
                guard index < bytes.count else { throw error("unterminated string") }
                let byte = bytes[index]
                if byte == UInt8(ascii: "\"") {
                    try flush(index)
                    index += 1
                    return String(scalars)
                }
                guard byte >= 0x20 else { throw error("control character in a string") }
                guard byte == UInt8(ascii: "\\") else { index += 1; continue }
                try flush(index)
                index += 1
                guard index < bytes.count else { throw error("unterminated string") }
                let escape = bytes[index]
                index += 1
                switch escape {
                case UInt8(ascii: "\""): scalars.append("\"")
                case UInt8(ascii: "\\"): scalars.append("\\")
                case UInt8(ascii: "/"): scalars.append("/")
                case UInt8(ascii: "b"): scalars.append("\u{08}")
                case UInt8(ascii: "f"): scalars.append("\u{0C}")
                case UInt8(ascii: "n"): scalars.append("\n")
                case UInt8(ascii: "r"): scalars.append("\r")
                case UInt8(ascii: "t"): scalars.append("\t")
                case UInt8(ascii: "u"):
                    var code = try hex4()
                    if (0xD800...0xDBFF).contains(code) {
                        // A surrogate pair: \uD83D\uDE00.
                        guard bytes[index...].starts(with: [UInt8(ascii: "\\"), UInt8(ascii: "u")]) else { throw error("lone surrogate") }
                        index += 2
                        let low = try hex4()
                        guard (0xDC00...0xDFFF).contains(low) else { throw error("lone surrogate") }
                        code = 0x10000 + ((code - 0xD800) << 10) + (low - 0xDC00)
                    }
                    guard let scalar = Unicode.Scalar(code) else { throw error("lone surrogate") }
                    scalars.append(scalar)
                default: throw error("unknown escape")
                }
                run = index
            }
        }

        mutating func hex4() throws(ParseError) -> UInt32 {
            // Exactly four hex digits: UInt32(_:radix:) alone would also take a sign.
            guard index + 4 <= bytes.count, bytes[index..<index + 4].allSatisfy({ ($0 >= 0x30 && $0 <= 0x39) || ($0 | 0x20 >= 0x61 && $0 | 0x20 <= 0x66) }),
                  let code = UInt32(String(decoding: bytes[index..<index + 4], as: UTF8.self), radix: 16)
            else { throw error("expected 4 hex digits") }
            index += 4
            return code
        }
    }

    // MARK: - Printing

    /// Two-space indent, `"key": value`, sorted keys and a trailing newline: the form AKit
    /// writes merged files in.
    public var pretty: String {
        var out = ""
        print(into: &out, indent: "", pretty: true)
        return out + "\n"
    }

    /// One line, sorted keys: for hashing a value.
    public var compact: String {
        var out = ""
        print(into: &out, indent: "", pretty: false)
        return out
    }

    private func print(into out: inout String, indent: String, pretty: Bool) {
        switch self {
        case .object(let members):
            guard !members.isEmpty else { out += "{}"; return }
            let inner = indent + "  "
            out += "{"
            for (index, key) in members.keys.sorted().enumerated() {
                if index > 0 { out += "," }
                if pretty { out += "\n" + inner }
                out += Self.quoted(key) + (pretty ? ": " : ":")
                members[key]!.print(into: &out, indent: inner, pretty: pretty)
            }
            out += pretty ? "\n" + indent + "}" : "}"
        case .array(let items):
            guard !items.isEmpty else { out += "[]"; return }
            let inner = indent + "  "
            out += "["
            for (index, item) in items.enumerated() {
                if index > 0 { out += "," }
                if pretty { out += "\n" + inner }
                item.print(into: &out, indent: inner, pretty: pretty)
            }
            out += pretty ? "\n" + indent + "]" : "]"
        case .string(let text): out += Self.quoted(text)
        case .number(let text): out += text
        case .bool(let flag): out += flag ? "true" : "false"
        case .null: out += "null"
        }
    }

    private static func quoted(_ text: String) -> String {
        var out = "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            case _ where scalar.value < 0x20: out += String(format: "\\u%04x", scalar.value)
            default: out.unicodeScalars.append(scalar)
            }
        }
        return out + "\""
    }

    // MARK: - Key paths

    /// Every leaf with its key path. Arrays, strings, numbers, booleans and null are leaves;
    /// an empty object adds nothing.
    public var leaves: [(path: [String], value: JSONValue)] {
        guard case .object(let members) = self else { return [([], self)] }
        return members.keys.sorted().flatMap { key in
            if case .object = members[key]! {
                return members[key]!.leaves.map { (path: [key] + $0.path, value: $0.value) }
            }
            return [(path: [key], value: members[key]!)]
        }
    }

    /// The value at a key path; nil when a key is missing or a value on the way is not an object.
    public func value(at path: [String]) -> JSONValue? {
        guard let first = path.first else { return self }
        guard case .object(let members) = self, let child = members[first] else { return nil }
        return child.value(at: Array(path.dropFirst()))
    }

    /// Sets the value at a key path, making objects on the way (a non-object on the way is replaced).
    public mutating func set(_ value: JSONValue, at path: [String]) {
        guard let first = path.first else { self = value; return }
        var members: [String: JSONValue] = if case .object(let existing) = self { existing } else { [:] }
        var child = members[first] ?? .object([:])
        if path.count > 1, !child.isObject { child = .object([:]) }
        child.set(value, at: Array(path.dropFirst()))
        members[first] = child
        self = .object(members)
    }

    private var isObject: Bool {
        if case .object = self { return true }
        return false
    }

    /// Removes the value at a key path. Objects on the way stay, even when they become empty.
    public mutating func remove(at path: [String]) {
        guard let first = path.first, case .object(var members) = self, var child = members[first] else { return }
        if path.count == 1 {
            members[first] = nil
        } else {
            child.remove(at: Array(path.dropFirst()))
            members[first] = child
        }
        self = .object(members)
    }

    /// Key paths of every object inside this one (not the top level), outermost first.
    public var objectPaths: [[String]] {
        guard case .object(let members) = self else { return [] }
        return members.keys.sorted().flatMap { key -> [[String]] in
            guard case .object = members[key]! else { return [] }
            return [[key]] + members[key]!.objectPaths.map { [key] + $0 }
        }
    }

    /// The same document with `transform` applied to every string value (never to keys).
    public func mappingStrings(_ transform: (String) -> String) -> JSONValue {
        switch self {
        case .object(let members): .object(members.mapValues { $0.mappingStrings(transform) })
        case .array(let items): .array(items.map { $0.mappingStrings(transform) })
        case .string(let text): .string(transform(text))
        default: self
        }
    }

    /// RFC 6901 pointer for a key path: `/mcpServers/github/command`.
    public static func pointer(_ path: [String]) -> String {
        path.map { "/" + $0.replacingOccurrences(of: "~", with: "~0").replacingOccurrences(of: "/", with: "~1") }.joined()
    }

    /// The key path of a pointer made by `pointer(_:)`.
    public static func path(pointer: String) -> [String] {
        guard pointer.hasPrefix("/") else { return [] }
        return pointer.dropFirst().split(separator: "/", omittingEmptySubsequences: false)
            .map { $0.replacingOccurrences(of: "~1", with: "/").replacingOccurrences(of: "~0", with: "~") }
    }

    /// A key path for people: `mcpServers.github.command`.
    public static func display(_ path: [String]) -> String { path.joined(separator: ".") }

    // MARK: - Secrets

    /// Keys whose values may be secrets (MCP server `env` and `headers`, settings `env`),
    /// in any letter case.
    public static let secretKeys: Set<String> = ["env", "headers"]

    static func isSecretKey(_ key: String) -> Bool { secretKeys.contains(key.lowercased()) }
    public static let mask = "••••"

    /// A whole-string `${NAME}` reference: the harness fills it from the environment.
    public static func isVariableReference(_ text: String) -> Bool {
        guard text.hasPrefix("${"), text.hasSuffix("}"), text.count > 3 else { return false }
        let name = text.dropFirst(2).dropLast()
        guard let first = name.first, first.isASCII, first.isLetter || first == "_" else { return false }
        return name.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") }
    }

    /// Key paths of the values at or under an `env` or `headers` key that are not `${NAME}`
    /// references (an empty list holds nothing).
    public var secretLeaves: [[String]] {
        leaves.filter { leaf in
            guard leaf.path.contains(where: Self.isSecretKey) else { return false }
            switch leaf.value {
            case .string(let text): return !Self.isVariableReference(text)
            case .array(let items): return !items.isEmpty
            default: return true
            }
        }.map(\.path)
    }

    /// For showing: every value under an `env` or `headers` key that is not a `${NAME}`
    /// reference becomes `••••`, also inside lists of objects.
    public var masked: JSONValue { masked(secret: false) }

    private func masked(secret: Bool) -> JSONValue {
        switch self {
        case .object(let members):
            return .object(Dictionary(uniqueKeysWithValues: members.map { key, value in
                (key, value.masked(secret: secret || Self.isSecretKey(key)))
            }))
        case .array(let items):
            // A list right under env or headers is a value (args, tokens); deeper lists may hold objects.
            if secret, !items.isEmpty, !items.contains(where: \.isObject) { return .string(Self.mask) }
            return .array(items.map { $0.masked(secret: secret) })
        case .string(let text):
            return secret && !Self.isVariableReference(text) ? .string(Self.mask) : self
        case .number, .bool, .null:
            return secret ? .string(Self.mask) : self
        }
    }
}
