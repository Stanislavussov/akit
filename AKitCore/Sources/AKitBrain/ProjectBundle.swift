import AKitFoundation
import AKitModel
import Foundation

/// Chosen layers and field values for one project.
public struct ProjectAnswers: Codable, Hashable, Sendable {
    /// A brain skill for this project only, or a new mode for one a layer brings
    /// (`off` takes it out of this project).
    public struct Skill: Codable, Hashable, Sendable {
        public var name: String
        public var mode: LayerSkill.Mode

        public init(name: String, mode: LayerSkill.Mode) {
            self.name = name
            self.mode = mode
        }
    }

    /// Layers in the order they were picked; required layers are added by the render.
    public var layers: [String]
    public var values: [String: FieldValue]
    /// Harnesses rendered for: `claude`, `pi`, `opencode`, `codex`.
    public var targets: [String]
    /// This project's own skills from the brain, after the layers' skills.
    public var skills: [Skill]

    public init(layers: [String] = [], values: [String: FieldValue] = [:], targets: [String] = [], skills: [Skill] = []) {
        self.layers = layers
        self.values = values
        self.targets = targets
        self.skills = skills
    }

    private enum CodingKeys: String, CodingKey { case layers, values, targets, skills }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        layers = try container.decode([String].self, forKey: .layers)
        values = try container.decode([String: FieldValue].self, forKey: .values)
        targets = try container.decode([String].self, forKey: .targets)
        // Answers saved before project skills existed have none.
        skills = try container.decodeIfPresent([Skill].self, forKey: .skills) ?? []
    }

    /// Target names used in `when: target == …`.
    public static let knownTargets = ["claude", "pi", "opencode", "codex"]

    /// The target name for a harness (`claude` for Claude Code); nil if layers can't target it.
    public static func target(for harness: HarnessID) -> String? {
        let name = harness == .claudeCode ? "claude" : harness.rawValue
        return knownTargets.contains(name) ? name : nil
    }
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

/// Layers + answers resolved for one project, without any harness file layout: the
/// layers in order, the template outputs and skills with fields filled in. `Render`
/// turns it into files. Pure: reads the brain, never the project.
public struct ProjectBundle: Sendable {
    /// A template output of one layer, before Markdown files are glued.
    public struct File: Hashable, Sendable {
        public let layer: String
        /// Path relative to the project folder.
        public let to: String
        public let data: Data
        public let override: Bool
    }

    /// A skill the project gets, with where it comes from (a layer or `projectSource`).
    public struct Skill: Hashable, Sendable {
        public let name: String
        public let mode: LayerSkill.Mode
        public let source: String
        /// The skill folder's files by relative path, fields filled in the Markdown ones.
        /// Empty when the skill is not in the brain (see `errors`).
        public let files: [String: Data]
    }

    /// Where skills land in the project: lock paths, brain links, project skills and
    /// recommendations all read it.
    public static let skillsFolder = ".agents/skills"
    /// What `RenderedFile.layers` says for a skill the project picked itself (not a layer
    /// name: layer names have no spaces).
    public static let projectSource = "this project"

    public let projectName: String
    public let targets: [String]
    /// Layers in render order: required ones first, then the selection order.
    public let layers: [String]
    /// Template outputs in layer order.
    public let files: [File]
    /// The skills in order (`off` ones left out).
    public let skills: [Skill]
    /// Things that stop the render (missing required field, unknown layer, clash, …).
    public let errors: [String]
    /// Things worth a look that don't stop it (unknown `{{field}}` in a template).
    public let warnings: [String]

    public static func resolve(_ answers: ProjectAnswers, brain: Brain, projectName: String) -> ProjectBundle {
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
        var skillOwner: [String: (layer: String, override: Bool)] = [:]
        var skills: [(skill: LayerSkill, layer: String)] = []
        // The same skill from two layers: the one with override: true wins (its mode too,
        // so `mode: off` + override removes a skill an earlier layer brings).
        for layer in layers {
            for skill in layer.skills where matches(skill.when, values) {
                if let owner = skillOwner[skill.name] {
                    guard skill.override || owner.override else {
                        errors.append("Skill “\(skill.name)” comes from both \(owner.layer) and \(layer.name). Set override: true in the layer that should win.")
                        continue
                    }
                    if owner.override && !skill.override { continue }
                    skills.removeAll { $0.skill.name == skill.name }
                }
                skillOwner[skill.name] = (layer.name, skill.override)
                if skill.mode != .off { skills.append((skill, layer.name)) }
            }
        }
        // This project's own choices come last and win over the layers' modes.
        for chosen in answers.skills {
            let index = skills.firstIndex { $0.skill.name == chosen.name }
            if let index { skills.remove(at: index) }
            if chosen.mode != .off {
                let skill = LayerSkill(name: chosen.name, mode: chosen.mode, when: [], override: false, keepAuto: false)
                skills.insert((skill, projectSource), at: index ?? skills.endIndex)
            }
        }
        var resolved: [Skill] = []
        for (skill, layer) in skills {
            var files: [String: Data] = [:]
            if let source = brain.skills.first(where: { $0.name == skill.name }) {
                for (relative, url) in BrainImport.copyable(source.folder).files.sorted(by: { $0.key < $1.key }) {
                    guard var data = try? Data(contentsOf: url) else {
                        errors.append("Couldn't read skills/\(skill.name)/\(relative).")
                        continue
                    }
                    // Fields only in Markdown: a skill's scripts may use {{…}} for other tools.
                    if relative.lowercased().hasSuffix(".md"), let text = String(data: data, encoding: .utf8) {
                        data = Data(substitute(text, values).text.utf8)
                    }
                    files[relative] = data
                }
            } else {
                errors.append("Skill “\(skill.name)” (\(layer == projectSource ? layer : "layer \(layer)")) is not in the brain's skills/.")
            }
            resolved.append(Skill(name: skill.name, mode: skill.mode, source: layer, files: files))
        }

        // 4. Files from templates whose `when` holds.
        var files: [File] = []
        for layer in layers {
            for file in layer.files where matches(file.when, values) {
                let url = layer.templates.appending(path: file.template)
                guard let data = try? Data(contentsOf: url) else {
                    errors.append("Template “\(file.template)” of \(layer.name) can't be read.")
                    continue
                }
                var rendered = data
                if isJSON(file.to) {
                    // Merged key by key into the project's file: parsed first, fields filled only
                    // inside string values, so a value can't break the JSON.
                    let name = "\(layer.name)/\(file.template)"
                    if (file.to as NSString).lastPathComponent.lowercased() == "settings.local.json" {
                        errors.append("\(name) targets \(file.to), the project's private settings; layers can't write it.")
                        continue
                    }
                    let tree: JSONValue
                    do {
                        tree = try JSONValue.parse(data)
                    } catch {
                        errors.append("\(name) is not valid JSON: \(error.message)")
                        continue
                    }
                    guard case .object = tree else {
                        errors.append("\(name) must be a JSON object ({ … }); it is merged into \(file.to) key by key.")
                        continue
                    }
                    var unknown: [String] = []
                    let filled = tree.mappingStrings { text in
                        let result = substitute(text, values)
                        unknown += result.unknown
                        return result.text
                    }
                    for name in unknown.reduce(into: [String](), { if !$0.contains($1) { $0.append($1) } }) {
                        warnings.append("\(layer.name)/\(file.template) uses {{\(name)}}, which is not a field; it is left as is.")
                    }
                    // Secrets never live in the brain: env and headers hold only ${VAR} references.
                    let secrets = filled.secretLeaves
                    for path in secrets {
                        errors.append("\(name): \(JSONValue.display(path)) holds a value. Under env and headers a layer may bring only a ${NAME} reference; the value comes from the environment.")
                    }
                    guard secrets.isEmpty else { continue }
                    files.append(File(layer: layer.name, to: file.to, data: Data(filled.pretty.utf8), override: file.override))
                    continue
                }
                if let text = String(data: data, encoding: .utf8) {
                    let result = substitute(text, values)
                    for name in result.unknown {
                        warnings.append("\(layer.name)/\(file.template) uses {{\(name)}}, which is not a field; it is left as is.")
                    }
                    rendered = Data(result.text.utf8)
                }
                files.append(File(layer: layer.name, to: file.to, data: rendered, override: file.override))
            }
        }

        return ProjectBundle(projectName: projectName, targets: answers.targets, layers: order, files: files,
                             skills: resolved, errors: errors, warnings: warnings)
    }

    /// The answers without an `off` for a skill no picked layer brings: it takes nothing out,
    /// and would stay behind as "off" after its layer is gone.
    public static func pruned(_ answers: ProjectAnswers, brain: Brain, projectName: String) -> ProjectAnswers {
        guard answers.skills.contains(where: { $0.mode == .off }) else { return answers }
        var layersOnly = answers
        layersOnly.skills = []
        let brought = Set(resolve(layersOnly, brain: brain, projectName: projectName).skills.map(\.name))
        var pruned = answers
        pruned.skills.removeAll { $0.mode == .off && !brought.contains($0.name) }
        return pruned
    }

    // MARK: - Pieces

    /// A template target merged key by key into the project's file instead of written whole.
    public static func isJSON(_ path: String) -> Bool { path.lowercased().hasSuffix(".json") }

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
}

/// One file (or link) in the project, by path relative to the project folder.
public struct RenderedFile: Hashable, Sendable {
    public enum Content: Hashable, Sendable {
        case data(Data)
        /// A symlink with this relative destination.
        case link(String)
    }

    public let path: String
    public let content: Content
    /// Layers the file comes from (a glued AGENTS.md has several).
    public let layers: [String]
    /// A JSON file of the layers' keys, merged key by key into the project's file (never
    /// written whole; see `ProjectSetup`).
    public let mergesJSON: Bool

    public init(path: String, content: Content, layers: [String], mergesJSON: Bool = false) {
        self.path = path
        self.content = content
        self.layers = layers
        self.mergesJSON = mergesJSON
    }

    public var text: String? {
        if case .data(let data) = content { return String(data: data, encoding: .utf8) }
        return nil
    }
}

/// What a render gives back: the files for the project and what went into them.
public struct RenderResult: Sendable {
    /// A skill the render brings, with where it comes from (a layer or `ProjectBundle.projectSource`).
    public struct Skill: Hashable, Sendable {
        public let name: String
        public let mode: LayerSkill.Mode
        public let source: String

        public init(name: String, mode: LayerSkill.Mode, source: String) {
            self.name = name
            self.mode = mode
            self.source = source
        }
    }

    /// Layers in render order: required ones first, then the selection order.
    public let layers: [String]
    public let outputs: [RenderedFile]
    /// Things that stop the render (missing required field, clashing files, …).
    public let errors: [String]
    /// Things worth a look that don't stop it (unknown `{{field}}` in a template).
    public let warnings: [String]
    /// The skills rendered, in order (`off` ones left out).
    public let skills: [Skill]

    public init(layers: [String], outputs: [RenderedFile], errors: [String], warnings: [String], skills: [Skill] = []) {
        self.layers = layers
        self.outputs = outputs
        self.errors = errors
        self.warnings = warnings
        self.skills = skills
    }
}
