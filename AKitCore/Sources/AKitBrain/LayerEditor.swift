import AKitFoundation
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
        if let problem = await BrainGit.commitProblem(brain: brain.root, env: env) { throw Failure(message: problem) }
        let layer = try find(name, in: brain)
        let missing = names.filter { skill in !brain.skills.contains { $0.name == skill } }
        guard missing.isEmpty else { throw Failure(message: "Not in the brain's skills/: \(missing.joined(separator: ", ")).") }
        let text = try read(layer)
        try write(addingSkills(names, mode: mode, to: text), to: layer.manifest, name)
        try await commit(["layers/\(name)/layer.yaml"], "Add \(names.joined(separator: ", ")) to layer \(name)", in: brain, env: env)
    }

    /// The layer.yaml text with this skill added in `mode`, for a preview; nothing else changes.
    public static func layerWithSkill(_ skill: String, mode: LayerSkill.Mode, in layer: Layer) throws(Failure) -> (before: String, after: String) {
        let text = try read(layer)
        return (text, try addingSkills([skill], mode: mode, to: text))
    }

    /// The layer.yaml text with this skill's mode set, for a preview; nothing else changes.
    public static func layerWithMode(_ mode: LayerSkill.Mode, ofSkill skill: String, in layer: Layer) throws(Failure) -> (before: String, after: String) {
        let text = try read(layer)
        return (text, try settingMode(mode, of: skill, in: text))
    }

    /// Sets how the layer brings one of its skills, and commits.
    public static func setMode(_ mode: LayerSkill.Mode, ofSkill skill: String, inLayer name: String,
                               in brain: Brain, env: HarnessEnvironment) async throws(Failure) {
        if let problem = await BrainGit.commitProblem(brain: brain.root, env: env) { throw Failure(message: problem) }
        let layer = try find(name, in: brain)
        let text = try read(layer)
        let after = try settingMode(mode, of: skill, in: text)
        guard after != text else { return }
        try write(after, to: layer.manifest, name)
        try await commit(["layers/\(name)/layer.yaml"], "Make \(skill) \(mode.rawValue) in layer \(name)", in: brain, env: env)
    }

    /// The layer.yaml text with these skills' mode set, for a preview; nothing else changes.
    public static func layerWithMode(_ mode: LayerSkill.Mode, ofSkills skills: [String], in layer: Layer) throws(Failure) -> (before: String, after: String) {
        let text = try read(layer)
        var after = text
        for skill in skills { after = try settingMode(mode, of: skill, in: after) }
        return (text, after)
    }

    /// Sets how each layer brings the listed skills (layer name → skill names), and commits all
    /// the layer files in one commit.
    public static func setModes(_ mode: LayerSkill.Mode, ofSkills skills: [String: [String]],
                                in brain: Brain, env: HarnessEnvironment) async throws(Failure) {
        if let problem = await BrainGit.commitProblem(brain: brain.root, env: env) { throw Failure(message: problem) }
        var changed: [(name: String, layer: Layer, text: String)] = []
        for name in skills.keys.sorted() {
            let layer = try find(name, in: brain)
            let edit = try layerWithMode(mode, ofSkills: skills[name] ?? [], in: layer)
            if edit.after != edit.before { changed.append((name, layer, edit.after)) }
        }
        guard !changed.isEmpty else { return }
        for item in changed { try write(item.text, to: item.layer.manifest, item.name) }
        let names = skills.filter { key, _ in changed.contains { $0.name == key } }.values.flatMap { $0 }.sorted()
        let what = names.count == 1 ? names[0] : "\(names.count) skills"
        try await commit(changed.map { "layers/\($0.name)/layer.yaml" },
                         "Make \(what) \(mode.rawValue) in layer\(changed.count == 1 ? "" : "s") \(changed.map(\.name).joined(separator: ", "))",
                         in: brain, env: env)
    }

    /// Adds `piece` at the end of the layer's AGENTS.md section and commits, read from disk now
    /// (not from `brain`'s scan): nothing else in the layer changes. The template's own bytes
    /// stay; only blank lines at its end give way to one blank line before the piece, which takes
    /// the template's line ending. Refused when the section's text is no longer `expected` (the
    /// trimmed text a preview showed), or when the layer's only AGENTS.md entry has a `when:`.
    /// A layer without an AGENTS.md entry gets `templates/AGENTS.md` and its `files:` entry.
    public static func appendToAgentsSection(_ piece: String, inLayer name: String, expected: String,
                                             in brain: Brain, env: HarnessEnvironment) async throws(Failure) {
        if let problem = await BrainGit.commitProblem(brain: brain.root, env: env) { throw Failure(message: problem) }
        guard let fresh = Brain.load(from: brain.root) else { throw Failure(message: "The brain at \(brain.root.path) can't be read.") }
        let layer = try find(name, in: fresh)
        guard details(of: layer).agentsSection == expected else {
            throw Failure(message: "The \(name) layer's AGENTS.md text changed since the preview. Look at the preview again.")
        }
        let piece = piece.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let file = agentsFile(of: layer) else {
            if layer.files.contains(where: { $0.to == "AGENTS.md" }) {
                throw Failure(message: "The \(name) layer sends its AGENTS.md text only under a when: condition. Edit the layer by hand.")
            }
            var created = details(of: layer)
            created.agentsSection = piece
            try await update(name, to: created, in: fresh, env: env)
            return
        }
        let url = layer.templates.appending(path: file.template)
        let raw = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        let newline = raw.contains("\r\n") ? "\r\n" : "\n"
        var lines = raw.unicodeScalars.split(separator: "\n", omittingEmptySubsequences: false).map { String(String.UnicodeScalarView($0)) }
        while let last = lines.last, last.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { lines.removeLast() }
        // The last line's own \r goes: `newline` below ends it again.
        if let last = lines.last, last.hasSuffix("\r") { lines[lines.count - 1] = String(last.dropLast()) }
        let kept = lines.joined(separator: "\n")
        let added = piece.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\n", with: newline)
        let text = (kept.isEmpty ? "" : kept + newline + newline) + added + newline
        try write(text, to: url, name)
        try await commit(["layers/\(name)/templates/\(file.template)"], "Add a section to layer \(name)'s AGENTS.md", in: fresh, env: env)
    }

    /// Writes the description, requires and AGENTS.md section, and commits them together.
    public static func update(_ name: String, to details: Details, in brain: Brain, env: HarnessEnvironment) async throws(Failure) {
        if let problem = await BrainGit.commitProblem(brain: brain.root, env: env) { throw Failure(message: problem) }
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

    /// One template of a layer and its `files:` entry, before and after an edit, for a preview.
    public struct FileEdit: Equatable, Sendable {
        public let layer: String
        public let template: String
        public let layerBefore: String
        public let layerAfter: String
        /// nil: the template file isn't there yet.
        public let templateBefore: String?
        public let templateAfter: String

        public var changesLayer: Bool { layerBefore != layerAfter }
        public var changesTemplate: Bool { templateBefore != templateAfter }
        /// Nothing to write: the entry is listed and the template has this text.
        public var isEmpty: Bool { !changesLayer && !changesTemplate }

        /// Both files' changed lines with 3 lines of context, each under its path in the brain.
        public var diff: String {
            var parts: [[String]] = []
            if changesLayer {
                parts.append(["--- layers/\(layer)/layer.yaml"] + TextDiff.unified(TextDiff.lines(from: layerBefore, to: layerAfter)))
            }
            if changesTemplate {
                parts.append(["--- layers/\(layer)/templates/\(template)" + (templateBefore == nil ? " (new)" : "")]
                             + TextDiff.unified(TextDiff.lines(from: templateBefore ?? "", to: templateAfter)))
            }
            return parts.map { $0.joined(separator: "\n") }.joined(separator: "\n")
        }
    }

    /// What setting `templates/<template>` to `text` does, read from disk now: when `files:`
    /// already lists that template (whatever its `to:` and `when:`), only the template text
    /// changes; otherwise the entry `template → path` with `when` is added too.
    public static func fileEdit(template: String, to path: String, when conditions: [Condition], text: String,
                                in layer: Layer) throws(Failure) -> FileEdit {
        let parts = template.split(separator: "/")
        guard !template.hasPrefix("/"), !parts.isEmpty, !parts.contains("..") else {
            throw Failure(message: "“\(template)” must be a file path inside the layer's templates/.")
        }
        let before = try read(layer)
        let after = try snapshot(before).files.contains { $0.template == template } ? before
            : try addingFile(template: template, to: path, when: conditions, in: before)
        let current = try? String(contentsOf: layer.templates.appending(path: template), encoding: .utf8)
        return FileEdit(layer: layer.name, template: template, layerBefore: before, layerAfter: after,
                        templateBefore: current, templateAfter: text)
    }

    /// Writes what `edit` previewed (the template first: layer.yaml must never list a file that
    /// isn't there) and commits both in one brain commit. Refused when the files changed since
    /// the preview; nothing is written when the edit is empty.
    public static func apply(_ edit: FileEdit, to path: String, when conditions: [Condition], message: String,
                             in brain: Brain, env: HarnessEnvironment) async throws(Failure) {
        if let problem = await BrainGit.commitProblem(brain: brain.root, env: env) { throw Failure(message: problem) }
        guard let fresh = Brain.load(from: brain.root) else { throw Failure(message: "The brain at \(brain.root.path) can't be read.") }
        let layer = try find(edit.layer, in: fresh)
        guard try fileEdit(template: edit.template, to: path, when: conditions, text: edit.templateAfter, in: layer) == edit else {
            throw Failure(message: "layers/\(edit.layer)/layer.yaml or templates/\(edit.template) changed since the preview. Look at the preview again.")
        }
        guard !edit.isEmpty else { return }
        var paths: [String] = []
        if edit.changesTemplate {
            let url = layer.templates.appending(path: edit.template)
            do {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data(edit.templateAfter.utf8).write(to: url, options: .atomic)
            } catch {
                throw Failure(message: "Couldn't write layers/\(edit.layer)/templates/\(edit.template): \(error.localizedDescription)")
            }
            paths.append("layers/\(edit.layer)/templates/\(edit.template)")
        }
        if edit.changesLayer {
            try write(edit.layerAfter, to: layer.manifest, edit.layer)
            paths.insert("layers/\(edit.layer)/layer.yaml", at: 0)
        }
        try await commit(paths, message, in: fresh, env: env)
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
        try addingFile(template: LayerWriter.agentsTemplate, to: "AGENTS.md", when: [], in: text,
                       refusal: "AKit couldn't add the AGENTS.md section to layer.yaml safely. Add it by hand.")
    }

    /// Lists `templates/<template> → <path>` in `files:`, with its `when:` conditions (one inline,
    /// more as a flow list); read back like every other edit.
    static func addingFile(template: String, to path: String, when conditions: [Condition], in text: String,
                           refusal: String? = nil) throws(Failure) -> String {
        let before = try snapshot(text)
        let quotedTemplate = try scalar(template), quotedPath = try scalar(path)
        let quoted = try conditions.map { condition throws(Failure) in try scalar(condition.description) }
        let when = quoted.isEmpty ? [] : ["when: " + (quoted.count == 1 ? quoted[0] : "[\(quoted.joined(separator: ", "))]")]
        let result = try appending({ indent in
            ["\(indent)- template: \(quotedTemplate)", "\(indent)  to: \(quotedPath)"] + when.map { "\(indent)  \($0)" }
        }, toList: "files", in: text)
        var expected = before
        expected.files.append(LayerFile(template: template, to: ProjectBundle.normalizedPath(path), when: conditions, override: false))
        try verify(result, expected, refusal ?? "AKit couldn't add \(template) to layer.yaml safely. Add it by hand.")
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
