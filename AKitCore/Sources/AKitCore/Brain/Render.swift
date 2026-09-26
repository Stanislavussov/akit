import Foundation

/// Chosen layers and field values for one project.
public struct ProjectAnswers: Codable, Hashable, Sendable {
    /// Layers in the order they were picked; required layers are added by the render.
    public var layers: [String]
    public var values: [String: FieldValue]
    /// Harnesses rendered for: `claude`, `pi`, `opencode`, `codex`.
    public var targets: [String]

    public init(layers: [String] = [], values: [String: FieldValue] = [:], targets: [String] = []) {
        self.layers = layers
        self.values = values
        self.targets = targets
    }

    /// Target names used in `when: target == …`.
    public static let knownTargets = ["claude", "pi", "opencode", "codex"]
}

extension FieldValue: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let flag = try? container.decode(Bool.self) {
            self = .bool(flag)
        } else if let items = try? container.decode([String].self) {
            self = .list(items)
        } else {
            self = .text(try container.decode(String.self))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .text(let text): try container.encode(text)
        case .bool(let flag): try container.encode(flag)
        case .list(let items): try container.encode(items)
        }
    }
}

/// Turns layers + answers into harness files for a project. Pure: reads the brain,
/// never the project.
public enum Render {
    /// One file (or link) in the project, by path relative to the project folder.
    public struct Output: Hashable, Sendable {
        public enum Content: Hashable, Sendable {
            case data(Data)
            /// A symlink with this relative destination.
            case link(String)
        }

        public let path: String
        public let content: Content
        /// Layers the file comes from (a glued AGENTS.md has several).
        public let layers: [String]

        public var text: String? {
            if case .data(let data) = content { return String(data: data, encoding: .utf8) }
            return nil
        }
    }

    public struct Result: Sendable {
        /// Layers in render order: required ones first, then the selection order.
        public let layers: [String]
        public let outputs: [Output]
        /// Things that stop the render (missing required field, clashing files, …).
        public let errors: [String]
        /// Things worth a look that don't stop it (unknown `{{field}}` in a template).
        public let warnings: [String]
    }

    public static let skillsFolder = ".agents/skills"

    public static func render(_ answers: ProjectAnswers, brain: Brain, projectName: String) -> Result {
        var errors: [String] = []
        var warnings: [String] = []
        let byName = Dictionary(brain.layers.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })

        // 1. Layers: required ones before the layers that need them, then selection order.
        var order: [String] = []
        var visiting: Set<String> = []  // a requires cycle is reported by the brain checks; don't loop
        func visit(_ name: String, from parent: String?) {
            guard !order.contains(name), !visiting.contains(name) else { return }
            guard let layer = byName[name] else {
                errors.append(parent.map { "Layer “\($0)” requires “\(name)”, which is not in the brain." }
                              ?? "Layer “\(name)” is not in the brain.")
                return
            }
            visiting.insert(name)
            for required in layer.requires { visit(required, from: name) }
            visiting.remove(name)
            order.append(name)
        }
        for name in answers.layers { visit(name, from: nil) }
        let layers = order.compactMap { byName[$0] }
        for layer in layers {
            for other in layer.conflicts where order.contains(other) {
                errors.append("“\(layer.name)” can't be used together with “\(other)”.")
            }
        }

        // 2. Values: answers, then defaults; built-ins last so they can't be overridden.
        var values: [String: FieldValue] = [:]
        for layer in layers {
            for field in layer.fields {
                // An unanswered field is empty (false, no items), so {{field}} and `when` still know it.
                values[field.id] = answers.values[field.id] ?? field.defaultValue
                    ?? (field.kind == .bool ? .bool(false) : field.kind == .multi ? .list([]) : .text(""))
                if field.required, !isSet(values[field.id]) {
                    errors.append("“\(field.prompt)” (\(field.id)) is required by \(layer.name).")
                }
            }
        }
        values["project_name"] = .text(projectName)
        values["target"] = .list(answers.targets)

        // 3. Skills.
        var outputs: [Output] = []
        var skillOwner: [String: (layer: String, override: Bool)] = [:]
        var skills: [(skill: LayerSkill, layer: String)] = []
        for layer in layers {
            for skill in layer.skills where skill.mode != .off && matches(skill.when, values) {
                if let owner = skillOwner[skill.name] {
                    guard skill.override else {
                        errors.append("Skill “\(skill.name)” comes from both \(owner.layer) and \(layer.name). Set override: true in the layer that should win.")
                        continue
                    }
                    skills.removeAll { $0.skill.name == skill.name }
                }
                skillOwner[skill.name] = (layer.name, skill.override)
                skills.append((skill, layer.name))
            }
        }
        for (skill, layer) in skills {
            guard let source = brain.skills.first(where: { $0.name == skill.name }) else {
                errors.append("Skill “\(skill.name)” (layer \(layer)) is not in the brain's skills/.")
                continue
            }
            let files = BrainImport.copyable(source.folder).files
            for (relative, url) in files.sorted(by: { $0.key < $1.key }) {
                guard var data = try? Data(contentsOf: url) else {
                    errors.append("Couldn't read skills/\(skill.name)/\(relative).")
                    continue
                }
                if let text = String(data: data, encoding: .utf8) {
                    var rendered = substitute(text, values).text
                    if relative == "SKILL.md", skill.mode == .manual {
                        guard let manual = manualOnly(rendered) else {
                            errors.append("skills/\(skill.name)/SKILL.md has no --- header, so it can't be made manual.")
                            continue
                        }
                        rendered = manual
                    }
                    data = Data(rendered.utf8)
                }
                outputs.append(Output(path: "\(skillsFolder)/\(skill.name)/\(relative)", content: .data(data), layers: [layer]))
            }
        }

        // 4. Files from templates. Markdown targets are glued in layer order; other
        //    files from two layers clash unless the later one overrides.
        var pieces: [String: [(layer: String, data: Data, override: Bool)]] = [:]
        var targetsInOrder: [String] = []
        for layer in layers {
            for file in layer.files where matches(file.when, values) {
                let url = layer.templates.appending(path: file.template)
                guard let data = try? Data(contentsOf: url) else {
                    errors.append("Template “\(file.template)” of \(layer.name) can't be read.")
                    continue
                }
                var rendered = data
                if let text = String(data: data, encoding: .utf8) {
                    let result = substitute(text, values)
                    for name in result.unknown {
                        warnings.append("\(layer.name)/\(file.template) uses {{\(name)}}, which is not a field; it is left as is.")
                    }
                    rendered = Data(result.text.utf8)
                }
                if pieces[file.to] == nil { targetsInOrder.append(file.to) }
                pieces[file.to, default: []].append((layer.name, rendered, file.override))
            }
        }
        for path in targetsInOrder {
            let parts = pieces[path] ?? []
            if isMarkdown(path) {
                let texts = parts.map { String(decoding: $0.data, as: UTF8.self).trimmingCharacters(in: .newlines) }
                outputs.append(Output(path: path, content: .data(Data((texts.joined(separator: "\n\n") + "\n").utf8)),
                                      layers: parts.map(\.layer)))
            } else if let last = parts.last {
                if parts.count > 1, !last.override {
                    errors.append("\(path) comes from \(parts.map(\.layer).joined(separator: " and ")). Set override: true in the layer that should win.")
                }
                outputs.append(Output(path: path, content: .data(last.data), layers: [last.layer]))
            }
        }

        // 5. Claude reads CLAUDE.md and .claude/skills; point them at the shared files.
        let paths = Set(outputs.map(\.path))
        if answers.targets.contains("claude") {
            if paths.contains("AGENTS.md"), !paths.contains("CLAUDE.md") {
                outputs.append(Output(path: "CLAUDE.md", content: .data(Data("@AGENTS.md\n".utf8)), layers: []))
            }
            if !skills.isEmpty {
                if paths.contains(where: { $0.hasPrefix(".claude/skills/") }) {
                    errors.append("A layer writes into .claude/skills, so it can't link to .agents/skills.")
                } else {
                    outputs.append(Output(path: ".claude/skills", content: .link("../.agents/skills"), layers: []))
                }
            }
        }

        return Result(layers: order, outputs: outputs.sorted { $0.path < $1.path }, errors: errors, warnings: warnings)
    }

    // MARK: - Pieces

    /// `when` entries all hold. A list value (multi field, `target`) matches when it contains the value.
    static func matches(_ conditions: [Condition], _ values: [String: FieldValue]) -> Bool {
        conditions.allSatisfy { condition in
            let value = values[condition.field]
            switch condition.test {
            case .isSet: return isSet(value)
            case .equals(let expected): return equals(value, expected)
            case .notEquals(let expected): return !equals(value, expected)
            }
        }
    }

    private static func equals(_ value: FieldValue?, _ expected: String) -> Bool {
        switch value {
        case .text(let text): text == expected
        case .bool(let flag): (flag ? "true" : "false") == expected.lowercased()
        case .list(let items): items.contains(expected)
        case nil: false
        }
    }

    static func isSet(_ value: FieldValue?) -> Bool {
        switch value {
        case .text(let text): !text.trimmingCharacters(in: .whitespaces).isEmpty
        case .bool(let flag): flag
        case .list(let items): !items.isEmpty
        case nil: false
        }
    }

    /// Replaces `{{field}}` (spaces inside allowed) for known fields. Unknown names are
    /// left untouched, so `{{…}}` meant for other tools survives.
    static func substitute(_ text: String, _ values: [String: FieldValue]) -> (text: String, unknown: [String]) {
        var result = ""
        var unknown: [String] = []
        var rest = Substring(text)
        while let open = rest.range(of: "{{") {
            result += rest[..<open.lowerBound]
            guard let close = rest[open.upperBound...].range(of: "}}") else {
                rest = rest[open.lowerBound...]
                break
            }
            let name = rest[open.upperBound..<close.lowerBound].trimmingCharacters(in: .whitespaces)
            if let value = values[name] {
                result += value.display
            } else {
                if Condition.isIdentifier(name), !unknown.contains(name) { unknown.append(name) }
                result += rest[open.lowerBound..<close.upperBound]
            }
            rest = rest[close.upperBound...]
        }
        return (result + rest, unknown)
    }

    /// SKILL.md with `disable-model-invocation: true` in its header; nil without a header.
    static func manualOnly(_ text: String) -> String? {
        let newline = text.contains("\r\n") ? "\r\n" : "\n"
        var lines = text.components(separatedBy: newline)
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---",
              let end = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }) else { return nil }
        let key = "disable-model-invocation:"
        if let existing = lines[1..<end].firstIndex(where: { $0.hasPrefix(key) }) {
            lines[existing] = "\(key) true"
        } else {
            lines.insert("\(key) true", at: end)
        }
        return lines.joined(separator: newline)
    }

    private static func isMarkdown(_ path: String) -> Bool { path.lowercased().hasSuffix(".md") }
}
