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
        // An empty file is a layer with nothing in it yet.
        guard let root = node.map({ isNull($0) ? Node.Mapping([]) : $0.mapping }) ?? Node.Mapping([]) else {
            throw Failure(message: "layer.yaml must be a map (name, description, fields, …).")
        }

        var problems: [String] = []
        let folderName = folder.lastPathComponent
        let name = scalar(root["name"]) ?? folderName
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
            description: scalar(root["description"]) ?? "",
            requires: strings(root["requires"], "requires", &problems),
            conflicts: strings(root["conflicts"], "conflicts", &problems),
            fields: fields, skills: skills, files: files, folder: folder)
        return Parsed(layer: layer, problems: problems)
    }

    // MARK: - Entries

    private static func field(_ node: Node, _ problems: inout [String]) -> LayerField? {
        guard let map = node.mapping, let id = scalar(map["id"]), !id.isEmpty else {
            problems.append("A field has no id.")
            return nil
        }
        guard Condition.isIdentifier(id) else {
            problems.append("Field “\(id)”: an id may use only letters, digits, _ and -.")
            return nil
        }
        let kindText = scalar(map["type"]) ?? "text"
        guard let kind = LayerField.Kind(rawValue: kindText) else {
            problems.append("Field “\(id)”: unknown type “\(kindText)” (text, choice, bool or multi).")
            return nil
        }
        let options = strings(map["options"], "field “\(id)” options", &problems)
        if kind == .choice || kind == .multi, options.isEmpty {
            problems.append("Field “\(id)”: a \(kind.rawValue) field needs options.")
        }
        return LayerField(id: id, prompt: scalar(map["prompt"]) ?? id, kind: kind,
                          required: flag(map["required"], "Field “\(id)”: required", &problems),
                          defaultValue: map["default"].flatMap { isNull($0) ? nil : value($0, kind: kind, field: id, &problems) },
                          options: options)
    }

    private static func skill(_ node: Node, _ problems: inout [String]) -> LayerSkill? {
        // A bare name is a skill with the default mode.
        if let name = scalar(node), !name.isEmpty { return LayerSkill(name: name, mode: .auto, when: [], override: false) }
        guard let map = node.mapping, let name = scalar(map["name"]), !name.isEmpty else {
            problems.append("A skill has no name.")
            return nil
        }
        let modeText = scalar(map["mode"]) ?? "auto"
        guard let mode = LayerSkill.Mode(rawValue: modeText) else {
            problems.append("Skill “\(name)”: unknown mode “\(modeText)” (auto, manual or off).")
            return nil
        }
        return LayerSkill(name: name, mode: mode, when: conditions(map["when"], "skill “\(name)”", &problems),
                          override: flag(map["override"], "Skill “\(name)”: override", &problems))
    }

    private static func file(_ node: Node, _ problems: inout [String]) -> LayerFile? {
        guard let map = node.mapping, let template = scalar(map["template"]), !template.isEmpty else {
            problems.append("A file has no template.")
            return nil
        }
        let to = scalar(map["to"]) ?? template
        for path in [template, to] {
            let parts = path.split(separator: "/")
            if path.hasPrefix("/") || parts.contains("..") || parts.allSatisfy({ $0 == "." }) {
                problems.append("File “\(template)”: “\(path)” must be a relative file path inside the folder.")
                return nil
            }
        }
        return LayerFile(template: template, to: to, when: conditions(map["when"], "file “\(template)”", &problems),
                         override: flag(map["override"], "File “\(template)”: override", &problems))
    }

    private static func value(_ node: Node, kind: LayerField.Kind, field: String, _ problems: inout [String]) -> FieldValue? {
        switch kind {
        case .bool:
            if let flag = node.bool { return .bool(flag) }
        case .multi:
            if let items = node.sequence {
                let texts = items.compactMap(scalar)
                if texts.count == items.count { return .list(texts) }
            }
        case .text, .choice:
            if let value = scalar(node) { return .text(value) }
        }
        problems.append("Field “\(field)”: default doesn't fit type \(kind.rawValue).")
        return nil
    }

    private static func conditions(_ node: Node?, _ owner: String, _ problems: inout [String]) -> [Condition] {
        guard let node, !isNull(node) else { return [] }
        let items = node.sequence.map(Array.init) ?? [node]
        return items.compactMap { item in
            if let line = scalar(item), let condition = Condition(parsing: line) { return condition }
            var shown = scalar(item) ?? (try? Yams.serialize(node: item).trimmingCharacters(in: .whitespacesAndNewlines)) ?? "?"
            if shown.isEmpty { shown = item.tag.rawValue }  // `when: !flag` is a YAML tag, not "not flag"
            problems.append("\(owner.prefix(1).uppercased() + owner.dropFirst()): can't read when “\(shown)” (use field == value, field != value or field).")
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

    /// `key:`, `key: ~` or `key: null`: same as leaving the key out. A tagged
    /// scalar such as `!flag` is not null, even though its text is empty.
    private static func isNull(_ node: Node) -> Bool {
        guard let scalar = node.scalar, node.tag.rawValue == Tag.Name.null.rawValue else { return false }
        return NSNull.construct(from: scalar) != nil
    }

    /// The text of a scalar; nil for a missing key, null, a list or a map.
    private static func scalar(_ node: Node?) -> String? {
        guard let node, !isNull(node), let scalar = node.scalar else { return nil }
        return scalar.string
    }

    /// A missing or null flag is false; anything but true/false is a problem.
    private static func flag(_ node: Node?, _ owner: String, _ problems: inout [String]) -> Bool {
        guard let node, !isNull(node) else { return false }
        if node.scalar != nil, let flag = node.bool { return flag }
        problems.append("\(owner) must be true or false.")
        return false
    }

    private static func strings(_ node: Node?, _ key: String, _ problems: inout [String]) -> [String] {
        guard let node, !isNull(node) else { return [] }
        if let single = scalar(node) { return [single] }
        let items = list(node, key, &problems)
        let texts = items.compactMap(scalar)
        if texts.count != items.count { problems.append("“\(key)” must be a list of names.") }
        return texts
    }
}
