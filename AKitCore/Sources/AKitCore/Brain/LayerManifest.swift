import Foundation
import Yams

/// Reads `layer.yaml`. Anything that is wrong but not fatal becomes a problem
/// message instead of an error, so one typo doesn't hide the whole layer.
enum LayerManifest {
    struct Parsed {
        var layer: Layer
        var problems: [String]
    }

    struct Failure: Error {
        let message: String
    }

    static func parse(_ text: String, folder: URL) throws(Failure) -> Parsed {
        let node: Node?
        do {
            node = try Yams.compose(yaml: text)
        } catch {
            throw Failure(message: "layer.yaml is not valid YAML: \(error)")
        }
        guard let root = node?.mapping else {
            throw Failure(message: "layer.yaml must be a map (name, description, fields, …).")
        }

        var problems: [String] = []
        let folderName = folder.lastPathComponent
        let name = root["name"]?.string ?? folderName
        if name != folderName {
            problems.append("name “\(name)” differs from the folder “\(folderName)”; the folder name is used.")
        }
        let known: Set = ["name", "description", "requires", "conflicts", "fields", "skills", "files"]
        for key in root.keys.compactMap(\.string) where !known.contains(key) {
            problems.append("Unknown key “\(key)”.")
        }

        let fields = list(root["fields"], "fields", &problems).compactMap { field($0, &problems) }
        let skills = list(root["skills"], "skills", &problems).compactMap { skill($0, &problems) }
        let files = list(root["files"], "files", &problems).compactMap { file($0, &problems) }

        let layer = Layer(
            name: folderName,
            description: root["description"]?.string ?? "",
            requires: strings(root["requires"], "requires", &problems),
            conflicts: strings(root["conflicts"], "conflicts", &problems),
            fields: fields, skills: skills, files: files, folder: folder)
        return Parsed(layer: layer, problems: problems)
    }

    // MARK: - Entries

    private static func field(_ node: Node, _ problems: inout [String]) -> LayerField? {
        guard let map = node.mapping, let id = map["id"]?.string, !id.isEmpty else {
            problems.append("A field has no id.")
            return nil
        }
        let kindText = map["type"]?.string ?? "text"
        guard let kind = LayerField.Kind(rawValue: kindText) else {
            problems.append("Field “\(id)”: unknown type “\(kindText)” (text, choice, bool or multi).")
            return nil
        }
        let options = strings(map["options"], "field “\(id)” options", &problems)
        if kind == .choice || kind == .multi, options.isEmpty {
            problems.append("Field “\(id)”: a \(kind.rawValue) field needs options.")
        }
        return LayerField(id: id, prompt: map["prompt"]?.string ?? id, kind: kind,
                          required: map["required"]?.bool ?? false,
                          defaultValue: map["default"].flatMap { isNull($0) ? nil : value($0, kind: kind, field: id, &problems) },
                          options: options)
    }

    private static func skill(_ node: Node, _ problems: inout [String]) -> LayerSkill? {
        // A bare name is a skill with the default mode.
        if let name = node.string, node.mapping == nil { return LayerSkill(name: name, mode: .auto, when: [], override: false) }
        guard let map = node.mapping, let name = map["name"]?.string, !name.isEmpty else {
            problems.append("A skill has no name.")
            return nil
        }
        let modeText = map["mode"]?.string ?? "auto"
        guard let mode = LayerSkill.Mode(rawValue: modeText) else {
            problems.append("Skill “\(name)”: unknown mode “\(modeText)” (auto, manual or off).")
            return nil
        }
        return LayerSkill(name: name, mode: mode, when: conditions(map["when"], "skill “\(name)”", &problems),
                          override: map["override"]?.bool ?? false)
    }

    private static func file(_ node: Node, _ problems: inout [String]) -> LayerFile? {
        guard let map = node.mapping, let template = map["template"]?.string, !template.isEmpty else {
            problems.append("A file has no template.")
            return nil
        }
        let to = map["to"]?.string ?? template
        for path in [template, to] where path.hasPrefix("/") || path.split(separator: "/").contains("..") {
            problems.append("File “\(template)”: “\(path)” must be a relative path inside the folder.")
            return nil
        }
        return LayerFile(template: template, to: to, when: conditions(map["when"], "file “\(template)”", &problems),
                         override: map["override"]?.bool ?? false)
    }

    private static func value(_ node: Node, kind: LayerField.Kind, field: String, _ problems: inout [String]) -> FieldValue? {
        switch kind {
        case .bool:
            if let flag = node.bool { return .bool(flag) }
        case .multi:
            if let items = node.sequence { return .list(items.compactMap(\.string)) }
        case .text, .choice:
            if let text = node.string { return .text(text) }
        }
        problems.append("Field “\(field)”: default doesn't fit type \(kind.rawValue).")
        return nil
    }

    private static func conditions(_ node: Node?, _ owner: String, _ problems: inout [String]) -> [Condition] {
        guard let node, !isNull(node) else { return [] }
        let texts = node.sequence.map { $0.compactMap(\.string) } ?? node.string.map { [$0] } ?? []
        return texts.compactMap { text in
            if let condition = Condition(parsing: text) { return condition }
            problems.append("\(owner.prefix(1).uppercased() + owner.dropFirst()): can't read when “\(text)” (use field == value, field != value or field).")
            return nil
        }
    }

    // MARK: - Helpers

    private static func list(_ node: Node?, _ key: String, _ problems: inout [String]) -> [Node] {
        guard let node, !isNull(node) else { return [] }
        guard let items = node.sequence else {
            problems.append("“\(key)” must be a list.")
            return []
        }
        return Array(items)
    }

    /// `key:`, `key: ~` or `key: null`: same as leaving the key out.
    private static func isNull(_ node: Node) -> Bool {
        node.scalar.map { NSNull.construct(from: $0) != nil } ?? false
    }

    private static func strings(_ node: Node?, _ key: String, _ problems: inout [String]) -> [String] {
        guard let node, !isNull(node) else { return [] }
        if let single = node.scalar { return [single.string] }
        return list(node, key, &problems).compactMap(\.string)
    }
}
