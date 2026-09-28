import Foundation

/// A composable piece of harness setup: `brain/layers/<name>/layer.yaml` plus its
/// `templates/` folder. See docs/design/layers.md.
public struct Layer: Identifiable, Hashable, Sendable {
    /// The folder name. It is the layer's identity; `name:` in the manifest must match.
    public var id: String { name }
    public let name: String
    public let description: String
    /// Rendered after these layers; they must be selected too.
    public let requires: [String]
    /// Cannot be selected together with these.
    public let conflicts: [String]
    public let fields: [LayerField]
    public let skills: [LayerSkill]
    public let files: [LayerFile]
    /// `brain/layers/<name>`.
    public let folder: URL

    public var manifest: URL { folder.appending(path: "layer.yaml") }
    public var templates: URL { folder.appending(path: "templates") }
}

/// A question the project form asks. Never holds secrets.
public struct LayerField: Identifiable, Hashable, Sendable {
    public enum Kind: String, Hashable, Sendable, CaseIterable {
        case text, choice, bool, multi
    }

    public let id: String
    public let prompt: String
    public let kind: Kind
    public let required: Bool
    public let defaultValue: FieldValue?
    /// Only for `choice` and `multi`.
    public let options: [String]
}

/// A field value as it is written in `layer.yaml` or in the answers.
public enum FieldValue: Hashable, Sendable {
    case text(String)
    case bool(Bool)
    case list([String])

    public var display: String {
        switch self {
        case .text(let text): text
        case .bool(let flag): flag ? "true" : "false"
        case .list(let items): items.joined(separator: ", ")
        }
    }
}

/// How a layer brings a skill from `brain/skills/`.
public struct LayerSkill: Hashable, Sendable {
    public enum Mode: String, Codable, Hashable, Sendable, CaseIterable {
        /// Description in the agent's context; the agent may invoke it.
        case auto
        /// Runs only on an explicit `/name` (`disable-model-invocation: true`).
        case manual
        /// Not rendered.
        case off
    }

    public let name: String
    public let mode: Mode
    public let when: [Condition]
    public let override: Bool
}

/// A template rendered into the project.
public struct LayerFile: Hashable, Sendable {
    /// Path inside the layer's `templates/`.
    public let template: String
    /// Path inside the project.
    public let to: String
    public let when: [Condition]
    public let override: Bool
}

/// One `when:` entry: `field == value`, `field != value` or a bare field name
/// (true when the field is set).
public struct Condition: Hashable, Sendable, CustomStringConvertible {
    public enum Test: Hashable, Sendable {
        case isSet
        case equals(String)
        case notEquals(String)
    }

    public let field: String
    public let test: Test

    public init(field: String, test: Test) {
        self.field = field
        self.test = test
    }

    /// nil when the text is not one of the three forms.
    public init?(parsing text: String) {
        let text = text.trimmingCharacters(in: .whitespaces)
        // Split at the first operator; a quoted value may contain one itself.
        let found = [("!=", Test.notEquals), ("==", Test.equals)]
            .compactMap { op, make in text.range(of: op).map { (range: $0, make: make) } }
            .min { $0.range.lowerBound < $1.range.lowerBound }
        guard let found else {
            guard Self.isIdentifier(text) else { return nil }
            self.init(field: text, test: .isSet)
            return
        }
        let field = text[..<found.range.lowerBound].trimmingCharacters(in: .whitespaces)
        var value = text[found.range.upperBound...].trimmingCharacters(in: .whitespaces)
        if value.count >= 2, let quote = value.first, quote == "\"" || quote == "'", value.last == quote {
            value = String(value.dropFirst().dropLast())
        } else if value.contains("==") || value.contains("!=") {
            return nil
        }
        guard Self.isIdentifier(field), !value.isEmpty else { return nil }
        self.init(field: field, test: found.make(value))
    }

    public var description: String {
        switch test {
        case .isSet: field
        case .equals(let value): "\(field) == \(value)"
        case .notEquals(let value): "\(field) != \(value)"
        }
    }

    static func isIdentifier(_ text: String) -> Bool {
        guard let first = text.first, first.isLetter || first == "_" else { return false }
        return text.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }
    }
}
