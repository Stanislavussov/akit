import CoreFoundation
import Foundation

/// A JSON document as a value: for merging JSON files key by key (layers into `.mcp.json`
/// and `.claude/settings.json`). Objects are compared and printed with sorted keys.
public enum JSONValue: Hashable, Sendable {
    case object([String: JSONValue])
    case array([JSONValue])
    case string(String)
    /// The number as JSON text (`1`, `2.5`, `1e+21`), so integers stay integers.
    case number(String)
    case bool(Bool)
    case null

    public struct ParseError: Error, LocalizedError {
        public let message: String
        public var errorDescription: String? { message }
    }

    /// Strict JSON (no comments, no trailing commas).
    public static func parse(_ data: Data) throws(ParseError) -> JSONValue {
        do {
            return try value(JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]))
        } catch let error as ParseError {
            throw error
        } catch {
            let reason = (error as NSError).userInfo[NSDebugDescriptionErrorKey] as? String ?? error.localizedDescription
            throw ParseError(message: reason)
        }
    }

    private static func value(_ any: Any) throws -> JSONValue {
        switch any {
        case let object as [String: Any]: return .object(try object.mapValues(value))
        case let array as [Any]: return .array(try array.map(value))
        case let text as String: return .string(text)
        case is NSNull: return .null
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return .bool(number.boolValue) }
            guard CFNumberIsFloatType(number) else { return .number(number.stringValue) }
            let double = number.doubleValue
            // 1.0 is printed as 1, like JSON.stringify.
            if double == double.rounded(), abs(double) < 1e15 { return .number(String(Int64(double))) }
            return .number("\(double)")
        default: throw ParseError(message: "unexpected value \(type(of: any))")
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

    /// Removes the value at a key path; objects on the way that become empty go too (never
    /// the top level).
    public mutating func remove(at path: [String]) {
        guard let first = path.first, case .object(var members) = self, var child = members[first] else { return }
        if path.count == 1 {
            members[first] = nil
        } else {
            child.remove(at: Array(path.dropFirst()))
            members[first] = child == .object([:]) ? nil : child
        }
        self = .object(members)
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

    /// Keys whose values may be secrets (MCP server `env` and `headers`, settings `env`).
    public static let secretKeys: Set<String> = ["env", "headers"]
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
            guard leaf.path.contains(where: { Self.secretKeys.contains($0) }) else { return false }
            switch leaf.value {
            case .string(let text): return !Self.isVariableReference(text)
            case .array(let items): return !items.isEmpty
            default: return true
            }
        }.map(\.path)
    }

    /// For showing: every leaf under an `env` or `headers` key that is not a `${NAME}`
    /// reference becomes `••••`.
    public var masked: JSONValue {
        var copy = self
        for path in secretLeaves { copy.set(.string(Self.mask), at: path) }
        return copy
    }
}
