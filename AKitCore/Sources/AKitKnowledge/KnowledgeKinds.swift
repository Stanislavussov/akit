import Foundation
import Yams

/// The kinds of notes a base knows and the fields each one has (K24): data in `<base>/kb.yaml`,
/// never a list in code. The user adds, renames and removes kinds; a base without the file reads
/// the defaults. A note with a kind the file doesn't name still works (lint hints at it, 4.1).
///
/// ```yaml
/// kinds:
///   service:
///     fields: [repo, files, owner]
///     color: blue      # optional, for maps
///     shape: rectangle # optional, for maps
/// ```
///
/// AKit writes this file whole (it is AKit's own file, not a note), in the order the kinds are
/// listed. A file with keys AKit doesn't know is never rewritten, so nothing in it is lost.
public struct KnowledgeKinds: Sendable, Equatable {
    public typealias Failure = KnowledgeBase.Failure

    public struct Kind: Codable, Sendable, Equatable {
        public var name: String
        public var fields: [String]
        public var color: String?
        public var shape: String?

        public init(name: String, fields: [String] = [], color: String? = nil, shape: String? = nil) {
            self.name = name
            self.fields = fields
            self.color = color
            self.shape = shape
        }

        private enum CodingKeys: String, CodingKey { case name, fields, color, shape }

        // color and shape are null when unset, so every kind has the same keys.
        public func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(name, forKey: .name)
            try container.encode(fields, forKey: .fields)
            try container.encode(color, forKey: .color)
            try container.encode(shape, forKey: .shape)
        }
    }

    public static let fileName = "kb.yaml"

    /// What `kb init` writes and what a base without `kb.yaml` reads.
    public static let defaults = KnowledgeKinds(kinds: [
        Kind(name: "service", fields: ["repo", "path", "files", "owner"]),
        Kind(name: "flow", fields: ["owner"]),
        Kind(name: "team", fields: ["members", "channel"]),
        Kind(name: "database", fields: ["repo", "owner"]),
        Kind(name: "queue", fields: ["owner"]),
        Kind(name: "external", fields: ["url", "owner"]),
        Kind(name: "folder", fields: ["path", "owner"]),
    ])

    public var kinds: [Kind]
    /// Keys of the file AKit doesn't know (`kinds.service.icon`, `version`): such a file is read
    /// but never rewritten.
    public private(set) var unknownKeys: [String] = []

    public init(kinds: [Kind]) { self.kinds = kinds }

    public var names: [String] { kinds.map(\.name) }

    public func kind(_ name: String) -> Kind? { kinds.first { $0.name == name } }

    // MARK: - Read and write

    /// The base's `kb.yaml`; the defaults when it doesn't exist.
    public static func load(base: URL) throws(Failure) -> KnowledgeKinds {
        let file = base.appending(path: fileName)
        guard FileManager.default.fileExists(atPath: file.path) else { return defaults }
        guard let data = try? Data(contentsOf: file), let text = String(data: data, encoding: .utf8) else {
            throw Failure(message: "Can't read \(file.path) as UTF-8 text.")
        }
        return try parse(text)
    }

    /// Reads a `kb.yaml` text. Kinds keep the file's order.
    public static func parse(_ text: String) throws(Failure) -> KnowledgeKinds {
        let root: Node?
        do { root = try Yams.compose(yaml: text) } catch {
            throw Failure(message: "\(fileName) is not valid YAML: \(error)")
        }
        guard let root else { return KnowledgeKinds(kinds: []) }
        guard let top = root.mapping else { throw Failure(message: "\(fileName) must be a map with a kinds: key.") }
        var result = KnowledgeKinds(kinds: [])
        for (key, value) in top {
            let name = key.string ?? ""
            guard name == "kinds" else {
                result.unknownKeys.append(name)
                continue
            }
            if value.scalar?.string.isEmpty == true || value.null != nil { continue }
            guard let kinds = value.mapping else { throw Failure(message: "kinds: in \(fileName) must be a map of kind names.") }
            for (kindKey, kindValue) in kinds {
                guard let kindName = kindKey.string, validName(kindName) else {
                    throw Failure(message: "“\(kindKey.string ?? "")” in \(fileName) can't name a kind: one word, like service.")
                }
                var kind = Kind(name: kindName)
                if let fields = kindValue.mapping {
                    for (field, setting) in fields {
                        switch field.string {
                        case "fields":
                            if let list = setting.sequence {
                                kind.fields = list.compactMap(\.string)
                            } else if let one = setting.string, !one.isEmpty {
                                kind.fields = [one]
                            }
                        case "color": kind.color = setting.string
                        case "shape": kind.shape = setting.string
                        default: result.unknownKeys.append("kinds.\(kindName).\(field.string ?? "")")
                        }
                    }
                } else if kindValue.null == nil, kindValue.scalar?.string.isEmpty != true {
                    throw Failure(message: "kinds.\(kindName) in \(fileName) must be a map (fields:, color:, shape:).")
                }
                result.kinds.append(kind)
            }
        }
        return result
    }

    /// The file's text: the kinds in order, each with its fields.
    public var text: String {
        var lines = ["# The kinds of notes in this base and the fields of each (akit kb kinds, Kinds… in AKit).", "kinds:"]
        for kind in kinds {
            lines.append("  \(kind.name):")
            lines.append("    fields: [" + kind.fields.map(Self.scalar).joined(separator: ", ") + "]")
            if let color = kind.color { lines.append("    color: \(Self.scalar(color))") }
            if let shape = kind.shape { lines.append("    shape: \(Self.scalar(shape))") }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Writes `kb.yaml` atomically; refused when the file has keys AKit doesn't know.
    public func write(base: URL) throws(Failure) {
        if !unknownKeys.isEmpty {
            throw Failure(message: "\(Self.fileName) has keys AKit doesn't know (\(unknownKeys.joined(separator: ", "))), so AKit doesn't rewrite it. Edit it by hand.")
        }
        do { try Data(text.utf8).write(to: base.appending(path: Self.fileName), options: .atomic) } catch {
            throw Failure(message: "Couldn't write \(Self.fileName): \(error.localizedDescription)")
        }
    }

    // MARK: - Changes

    /// A new kind at the end.
    public func adding(_ name: String, fields: [String]) throws(Failure) -> KnowledgeKinds {
        guard Self.validName(name) else { throw Failure(message: "“\(name)” can't be a kind: one word, like service, flow or team.") }
        guard kind(name) == nil else { throw Failure(message: "The kind \(name) exists already.") }
        var copy = self
        copy.kinds.append(Kind(name: name, fields: try Self.checked(fields)))
        return copy
    }

    /// The kind's fields replaced.
    public func settingFields(of name: String, to fields: [String]) throws(Failure) -> KnowledgeKinds {
        guard let index = kinds.firstIndex(where: { $0.name == name }) else { throw missing(name) }
        var copy = self
        copy.kinds[index].fields = try Self.checked(fields)
        return copy
    }

    public func removing(_ name: String) throws(Failure) -> KnowledgeKinds {
        guard kind(name) != nil else { throw missing(name) }
        var copy = self
        copy.kinds.removeAll { $0.name == name }
        return copy
    }

    public func renaming(_ old: String, to new: String) throws(Failure) -> KnowledgeKinds {
        guard let index = kinds.firstIndex(where: { $0.name == old }) else { throw missing(old) }
        guard Self.validName(new) else { throw Failure(message: "“\(new)” can't be a kind: one word, like service, flow or team.") }
        guard old == new || kind(new) == nil else { throw Failure(message: "The kind \(new) exists already.") }
        var copy = self
        copy.kinds[index].name = new
        return copy
    }

    private func missing(_ name: String) -> Failure {
        Failure(message: "No kind \(name) in \(Self.fileName). Kinds: \(names.joined(separator: ", ")).")
    }

    /// A kind name: one word without spaces, `:`, `#`, quotes or brackets.
    public static func validName(_ name: String) -> Bool {
        !name.isEmpty && name.count <= 64 && !name.hasPrefix("-")
            && !name.contains { $0.isWhitespace || ":#\"'[]{},&*!|>%@`".contains($0) }
    }

    /// Field names are frontmatter keys; duplicates dropped, order kept.
    static func checked(_ fields: [String]) throws(Failure) -> [String] {
        var seen: [String] = []
        for field in fields.map({ $0.trimmingCharacters(in: .whitespaces) }) where !field.isEmpty && !seen.contains(field) {
            guard KnowledgeNote.validKey(field) else {
                throw Failure(message: "“\(field)” can't be a field: letters, digits, _, - and . (like repo or owner).")
            }
            seen.append(field)
        }
        return seen
    }

    /// A plain YAML scalar, double-quoted when it would read as something else.
    static func scalar(_ value: String) -> String { KnowledgeNote.PropertyValue.scalar(value) }
}
