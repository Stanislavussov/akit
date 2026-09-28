import Foundation

/// Changes an existing layer from the Brain screen: adds skills, sets a skill's mode, and
/// edits the description, requires and the AGENTS.md section. Each edit touches only the
/// lines it has to (comments and the rest of layer.yaml stay), is read back before it is
/// written, and is committed.
public enum LayerEditor {
    public struct Failure: Error, LocalizedError {
        public let message: String
        public var errorDescription: String? { message }
    }

    /// What the Edit Layer sheet changes.
    public struct Details: Equatable, Sendable {
        public var description: String
        public var requires: [String]
        /// This layer's section of the project's AGENTS.md; empty = the layer adds nothing there.
        public var agentsSection: String

        public init(description: String = "", requires: [String] = [], agentsSection: String = "") {
            self.description = description
            self.requires = requires
            self.agentsSection = agentsSection
        }
    }

    /// The template that holds the layer's AGENTS.md section: its first file that always
    /// goes to AGENTS.md. Sections under a `when:` are edited by hand.
    public static func agentsFile(of layer: Layer) -> LayerFile? {
        layer.files.first { $0.to == "AGENTS.md" && $0.when.isEmpty }
    }

    public static func details(of layer: Layer) -> Details {
        let section = agentsFile(of: layer).flatMap {
            try? String(contentsOf: layer.templates.appending(path: $0.template), encoding: .utf8)
        } ?? ""
        return Details(description: layer.description, requires: layer.requires,
                       agentsSection: section.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Layers this one may require: every other layer that doesn't already need it.
    public static func requirable(by name: String, in brain: Brain) -> [String] {
        brain.layers.map(\.name).filter { $0 != name && !needs($0, name, in: brain) }
    }

    /// `layer` requires `target`, directly or through other layers.
    static func needs(_ layer: String, _ target: String, in brain: Brain) -> Bool {
        var seen: Set<String> = [], stack = [layer]
        while let next = stack.popLast() {
            guard seen.insert(next).inserted else { continue }
            let requires = brain.layers.first { $0.name == next }?.requires ?? []
            if requires.contains(target) { return true }
            stack += requires
        }
        return false
    }

    // MARK: - Edits

    /// Lists brain skills in the layer with one mode, and commits.
    public static func addSkills(_ names: [String], mode: LayerSkill.Mode, toLayer name: String,
                                 in brain: Brain, env: HarnessEnvironment) async throws(Failure) {
        let layer = try find(name, in: brain)
        let missing = names.filter { skill in !brain.skills.contains { $0.name == skill } }
        guard missing.isEmpty else { throw Failure(message: "Not in the brain's skills/: \(missing.joined(separator: ", ")).") }
        let text = try read(layer)
        try write(addingSkills(names, mode: mode, to: text), to: layer.manifest, name)
        try await commit(["layers/\(name)/layer.yaml"], "Add \(names.joined(separator: ", ")) to layer \(name)", in: brain, env: env)
    }

    /// Sets how the layer brings one of its skills, and commits.
    public static func setMode(_ mode: LayerSkill.Mode, ofSkill skill: String, inLayer name: String,
                               in brain: Brain, env: HarnessEnvironment) async throws(Failure) {
        let layer = try find(name, in: brain)
        let text = try read(layer)
        let after = try settingMode(mode, of: skill, in: text)
        guard after != text else { return }
        try write(after, to: layer.manifest, name)
        try await commit(["layers/\(name)/layer.yaml"], "Make \(skill) \(mode.rawValue) in layer \(name)", in: brain, env: env)
    }

    /// Writes the description, requires and AGENTS.md section, and commits them together.
    public static func update(_ name: String, to details: Details, in brain: Brain, env: HarnessEnvironment) async throws(Failure) {
        let layer = try find(name, in: brain)
        let text = try read(layer)
        // Only new names are checked: one already listed must not block other edits.
        let listed = try snapshot(text).requires, allowed = requirable(by: name, in: brain)
        for required in details.requires where !listed.contains(required) && !allowed.contains(required) {
            throw Failure(message: "\(name) can't require \(required): it is not a layer, or it already needs \(name).")
        }
        var after = try settingDetails(description: details.description, requires: details.requires, in: text)

        // The AGENTS.md section: its template, or a new templates/AGENTS.md listed in files.
        let section = details.agentsSection.trimmingCharacters(in: .whitespacesAndNewlines)
        var template: (path: String, text: String)?
        if section != self.details(of: layer).agentsSection {
            let content = section.isEmpty ? "" : section + "\n"
            if let file = agentsFile(of: layer) {
                template = (file.template, content)
            } else if !section.isEmpty {
                let path = LayerWriter.agentsTemplate
                guard !FileManager.default.fileExists(atPath: layer.templates.appending(path: path).path) else {
                    throw Failure(message: "layers/\(name)/templates/\(path) exists, but layer.yaml doesn't send it to AGENTS.md. Edit the layer by hand.")
                }
                after = try addingAgentsFile(to: after)
                template = (path, content)
            }
        }
        guard after != text || template != nil else { return }

        // The template first: layer.yaml must never list a file that isn't there.
        var paths: [String] = []
        if let template {
            let url = layer.templates.appending(path: template.path)
            do {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data(template.text.utf8).write(to: url, options: .atomic)
            } catch {
                throw Failure(message: "Couldn't write layers/\(name)/templates/\(template.path): \(error.localizedDescription)")
            }
            paths.append("layers/\(name)/templates/\(template.path)")
        }
        if after != text {
            try write(after, to: layer.manifest, name)
            paths.insert("layers/\(name)/layer.yaml", at: 0)
        }
        try await commit(paths, "Edit layer \(name)", in: brain, env: env)
    }

    // MARK: - layer.yaml text

    /// Adds `- name: x / mode: m` entries to the top-level `skills:` list.
    static func addingSkills(_ names: [String], mode: LayerSkill.Mode, to text: String) throws(Failure) -> String {
        guard !names.isEmpty else { return text }
        let before = try snapshot(text)
        if let listed = names.first(where: { name in before.skills.contains { $0.name == name } }) {
            throw Failure(message: "\(listed) is already in the layer.")
        }
        guard Set(names).count == names.count else { throw Failure(message: "A skill is named twice.") }
        let quoted = try names.map(scalar)
        let result = try appending({ indent in quoted.flatMap { ["\(indent)- name: \($0)", "\(indent)  mode: \(mode.rawValue)"] } },
                                   toList: "skills", in: text)
        var expected = before
        expected.skills += names.map { LayerSkill(name: $0, mode: mode, when: [], override: false, keepAuto: false) }
        try verify(result, expected, "AKit couldn't add skills to layer.yaml safely. Add them by hand.")
        return result
    }

    /// Sets `mode:` in one skill's item; a bare `- name` item becomes `- name: x / mode: m`.
    static func settingMode(_ mode: LayerSkill.Mode, of skill: String, in text: String) throws(Failure) -> String {
        let before = try snapshot(text)
        guard let current = before.skills.first(where: { $0.name == skill }) else {
            throw Failure(message: "\(skill) is not in the layer's skills list.")
        }
        guard current.mode != mode else { return text }
        let newline = text.contains("\r\n") ? "\r\n" : "\n"
        var lines = text.components(separatedBy: newline)
        guard let item = skillItem(skill, in: lines)?.item else {
            throw Failure(message: "The layer's skills list is written on one line. Change the mode by hand.")
        }
        let dash = lines[item.lowerBound]
        let indent = String(dash.prefix { $0 == " " })
        let content = dash.dropFirst(indent.count + 1)  // after "-"
        let keyIndent = indent + " " + String(content.prefix { $0 == " " })
        let entry = content.trimmingCharacters(in: .whitespaces)

        if !(entry.components(separatedBy: " #").first ?? "").contains(":") {
            // A bare name.
            lines.replaceSubrange(item.lowerBound..<(item.lowerBound + 1),
                                  with: ["\(indent)- name: \(try scalar(skill))", "\(keyIndent)mode: \(mode.rawValue)"])
        } else if entry.hasPrefix("mode:") {
            lines[item.lowerBound] = "\(indent)-\(content.prefix { $0 == " " })mode: \(mode.rawValue)"
        } else if let line = item.dropFirst().first(where: { lines[$0].hasPrefix(keyIndent + "mode:") }) {
            lines[line] = "\(keyIndent)mode: \(mode.rawValue)"
        } else {
            lines.insert("\(keyIndent)mode: \(mode.rawValue)", at: item.lowerBound + 1)
        }
        let result = lines.joined(separator: newline)

        var expected = before
        expected.skills = before.skills.map { $0.name == skill ? LayerSkill(name: skill, mode: mode, when: $0.when, override: $0.override,
                                                                         keepAuto: $0.keepAuto) : $0 }
        try verify(result, expected, "AKit couldn't change the mode of \(skill) in layer.yaml safely. Edit it by hand.")
        return result
    }

    /// Replaces `description:` and `requires:` when they differ; an empty value removes the key.
    static func settingDetails(description: String, requires: [String], in text: String) throws(Failure) -> String {
        let before = try snapshot(text)
        let description = oneLine(description)
        let newline = text.contains("\r\n") ? "\r\n" : "\n"
        var lines = text.components(separatedBy: newline)
        do {
            // A folded or literal description reads with newlines; unchanged text stays as written.
            if description != oneLine(before.description) {
                let value = try LayerWriter.scalar(description)
                lines = replacing("description", with: description.isEmpty ? [] : "description: \(value)".components(separatedBy: "\n"), in: lines)
            }
            if requires != before.requires {
                let names = try requires.map { name throws(LayerWriter.Failure) in try LayerWriter.scalar(name) }
                lines = replacing("requires", with: requires.isEmpty ? [] : ["requires: [\(names.joined(separator: ", "))]"], in: lines)
            }
        } catch {
            throw Failure(message: error.message)
        }
        let result = lines.joined(separator: newline)

        var expected = before
        if description != oneLine(before.description) { expected.description = description }
        expected.requires = requires
        try verify(result, expected, "AKit couldn't change the description or requires in layer.yaml safely. Edit it by hand.")
        return result
    }

    /// A description as the one-line form writes it.
    public static func oneLine(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline).joined(separator: " ").trimmingCharacters(in: .whitespaces)
    }

    /// One YAML scalar, quoted when needed.
    private static func scalar(_ text: String) throws(Failure) -> String {
        do {
            return try LayerWriter.scalar(text)
        } catch {
            throw Failure(message: error.message)
        }
    }

    /// Lists `templates/AGENTS.md → AGENTS.md` in `files:`.
    static func addingAgentsFile(to text: String) throws(Failure) -> String {
        let before = try snapshot(text)
        let path = LayerWriter.agentsTemplate
        let result = try appending({ indent in ["\(indent)- template: \(path)", "\(indent)  to: AGENTS.md"] }, toList: "files", in: text)
        var expected = before
        expected.files.append(LayerFile(template: path, to: "AGENTS.md", when: [], override: false))
        try verify(result, expected, "AKit couldn't add the AGENTS.md section to layer.yaml safely. Add it by hand.")
        return result
    }

    // MARK: - Lines

    /// The top-level `key:` line and the end of the lines that belong to it (indented or
    /// list lines), trailing blank lines left out.
    static func block(_ key: String, in lines: [String]) -> (key: Int, end: Int)? {
        guard let start = lines.firstIndex(where: { $0.hasPrefix("\(key):") }) else { return nil }
        var end = start + 1
        while end < lines.count, lines[end].isEmpty || lines[end].first == " " || lines[end].first == "-" { end += 1 }
        while end > start + 1, lines[end - 1].trimmingCharacters(in: .whitespaces).isEmpty { end -= 1 }
        return (start, end)
    }

    /// One skill's item (a bare `- name` or a `- name: x` block) in the top-level `skills:`
    /// block list, with the list and the first line of every item.
    static func skillItem(_ skill: String, in lines: [String]) -> (list: (key: Int, end: Int), starts: [Int], item: Range<Int>)? {
        guard let list = block("skills", in: lines) else { return nil }
        // Item starts: lines whose first non-space character is "-" at the list's indent.
        let items = (list.key + 1..<list.end).filter { lines[$0].trimmingCharacters(in: .whitespaces).hasPrefix("-") }
        let indent = items.first.map { lines[$0].prefix { $0 == " " }.count } ?? 0
        let starts = items.filter { lines[$0].prefix { $0 == " " }.count == indent }
        func name(_ line: String) -> String {
            var item = line.trimmingCharacters(in: .whitespaces).dropFirst().trimmingCharacters(in: .whitespaces)
            if item.hasPrefix("name:") { item = item.dropFirst(5).trimmingCharacters(in: .whitespaces) }
            if let comment = item.range(of: " #") { item = String(item[..<comment.lowerBound]) }
            return item.trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
        }
        guard let start = starts.first(where: { index in
            // "- name: x" on the dash line, or "- mode: …" first and "name: x" below it.
            let itemEnd = starts.first { $0 > index } ?? list.end
            return (index..<itemEnd).contains { i in
                (i == index && name(lines[i]) == skill) || lines[i].trimmingCharacters(in: .whitespaces) == "name: \(skill)"
            }
        }) else { return nil }
        var end = starts.first { $0 > start } ?? list.end
        while end > start + 1, lines[end - 1].trimmingCharacters(in: .whitespaces).isEmpty { end -= 1 }
        return (list, starts, start..<end)
    }

    /// Appends items to the top-level block list `key:`, with the indent its items use;
    /// adds the key at the end when it is missing or empty.
    static func appending(_ entries: (String) -> [String], toList key: String, in text: String) throws(Failure) -> String {
        let newline = text.contains("\r\n") ? "\r\n" : "\n"
        var lines = text.isEmpty ? [] : text.components(separatedBy: newline)
        if lines.last == "" { lines.removeLast() }

        if let list = block(key, in: lines) {
            var rest = lines[list.key].dropFirst(key.count + 1).trimmingCharacters(in: .whitespaces)
            if let comment = rest.range(of: " #") ?? (rest.hasPrefix("#") ? rest.range(of: "#") : nil) {
                rest = rest[..<comment.lowerBound].trimmingCharacters(in: .whitespaces)
            }
            guard ["", "[]", "~", "null"].contains(rest) else {
                throw Failure(message: "The layer's “\(key):” line has “\(rest)” after it. Write it as a block list (one “- …” per line) and try again.")
            }
            let firstItem = lines[(list.key + 1)..<list.end].first { $0.trimmingCharacters(in: .whitespaces).hasPrefix("-") }
            let indent = firstItem.map { String($0.prefix { $0 == " " }) } ?? "  "
            if rest != "" { lines[list.key] = "\(key):" }
            lines.insert(contentsOf: entries(indent), at: list.end)
        } else {
            lines += ["\(key):"] + entries("  ")
        }
        return lines.joined(separator: newline) + newline
    }

    /// Top-level keys in the order AKit writes them; a missing key goes after the ones before it.
    private static let order = ["name", "description", "requires", "conflicts", "fields", "skills", "files"]

    private static func replacing(_ key: String, with new: [String], in lines: [String]) -> [String] {
        var lines = lines
        if let found = block(key, in: lines) {
            lines.replaceSubrange(found.key..<found.end, with: new)
        } else if !new.isEmpty {
            let earlier = order.prefix { $0 != key }
            let at = earlier.compactMap { block($0, in: lines)?.end }.max() ?? 0
            lines.insert(contentsOf: new, at: at)
        }
        return lines
    }

    // MARK: - Checks

    /// Everything a layer.yaml says, to compare an edit with what it should have done.
    struct Snapshot: Equatable {
        var description: String
        var requires: [String]
        var conflicts: [String]
        var fields: [LayerField]
        var skills: [LayerSkill]
        var files: [LayerFile]
    }

    static func snapshot(_ text: String) throws(Failure) -> Snapshot {
        guard let layer = try? LayerManifest.parse(text, folder: URL(filePath: "/layer")).layer else {
            throw Failure(message: "layer.yaml is not valid YAML. Fix it by hand first.")
        }
        return Snapshot(description: layer.description, requires: layer.requires, conflicts: layer.conflicts,
                        fields: layer.fields, skills: layer.skills, files: layer.files)
    }

    private static func verify(_ result: String, _ expected: Snapshot, _ message: String) throws(Failure) {
        guard (try? snapshot(result)) == expected else { throw Failure(message: message) }
    }

    // MARK: - Files

    private static func find(_ name: String, in brain: Brain) throws(Failure) -> Layer {
        guard let layer = brain.layers.first(where: { $0.name == name }) else { throw Failure(message: "No layer named \(name).") }
        return layer
    }

    /// From the file itself, not the last scan: it may have been edited since.
    private static func read(_ layer: Layer) throws(Failure) -> String {
        guard let text = try? String(contentsOf: layer.manifest, encoding: .utf8) else {
            throw Failure(message: "Can't read layers/\(layer.name)/layer.yaml.")
        }
        return text
    }

    private static func write(_ text: String, to file: URL, _ name: String) throws(Failure) {
        do {
            try Data(text.utf8).write(to: file, options: .atomic)
        } catch {
            throw Failure(message: "Couldn't write layers/\(name)/layer.yaml: \(error.localizedDescription)")
        }
    }

    private static func commit(_ paths: [String], _ message: String, in brain: Brain, env: HarnessEnvironment) async throws(Failure) {
        do {
            try await BrainRemove.commit(paths, message, in: brain.root, env: env)
        } catch {
            throw Failure(message: error.message)
        }
    }
}
