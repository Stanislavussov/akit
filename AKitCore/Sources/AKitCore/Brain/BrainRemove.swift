import Foundation

/// Removing things from the brain safely: folders go to the Trash, every removal is one
/// git commit, and nothing still in use is removed.
public enum BrainRemove {
    public struct Failure: Error, LocalizedError {
        public let message: String
        public var errorDescription: String? { message }
    }

    /// What removing a layer touches; shown before asking.
    public struct LayerImpact: Sendable {
        /// Layers that require it: removal is refused while there are any.
        public let requiredBy: [String]
        /// Projects whose saved answers use it; it is dropped from them.
        public let projects: [String]
    }

    /// `home` finds this Mac's local project store too (work Mac), besides the brain's.
    public static func layerImpact(_ name: String, in brain: Brain, home: URL) -> LayerImpact {
        LayerImpact(requiredBy: brain.layers.filter { $0.requires.contains(name) }.map(\.name),
                    projects: savedAnswers(brain: brain, home: home).filter { $0.answers.layers.contains(name) }.map(\.id))
    }

    /// Layers that list this skill: removal is refused while there are any.
    public static func skillUsers(_ name: String, in brain: Brain) -> [String] {
        brain.layers.filter { $0.skills.contains { $0.name == name } }.map(\.name)
    }

    /// Moves `layers/<name>` to the Trash, drops the layer from saved project answers and
    /// commits. Returns the projects to re-apply so its files leave them.
    @discardableResult
    public static func removeLayer(_ name: String, in brain: Brain, env: HarnessEnvironment,
                                   trash: (URL) throws -> URL? = SkillRemover.defaultTrash) async throws(Failure) -> [String] {
        guard let layer = brain.layers.first(where: { $0.name == name }) else { throw Failure(message: "No layer named \(name).") }
        guard name != "core" else { throw Failure(message: "The core layer can't be removed; remove skills from it instead.") }
        let impact = layerImpact(name, in: brain, home: env.homeDirectory)
        guard impact.requiredBy.isEmpty else {
            throw Failure(message: "\(name) is required by \(impact.requiredBy.joined(separator: ", ")). Remove it from their requires first.")
        }
        var paths = ["layers/\(name)"]
        for saved in savedAnswers(brain: brain, home: env.homeDirectory) where saved.answers.layers.contains(name) {
            var answers = saved.answers
            answers.layers.removeAll { $0 == name }
            do {
                try encode(answers).write(to: saved.file, options: .atomic)
            } catch {
                throw Failure(message: "Couldn't update \(saved.store.describe(id: saved.id))/answers.json: \(error.localizedDescription)")
            }
            // Only the brain's own store is committed; a work Mac's local answers stay out of git.
            if !saved.store.isLocal { paths.append("projects/\(saved.id)/answers.json") }
        }
        do {
            _ = try trash(layer.folder)
        } catch {
            throw Failure(message: "Couldn't move layers/\(name) to the Trash: \(error.localizedDescription)")
        }
        try await commit(paths, "Remove layer \(name)", in: brain.root, env: env)
        return impact.projects
    }

    /// Moves `skills/<name>` to the Trash and commits. Refused while a layer lists it.
    public static func removeSkill(_ name: String, in brain: Brain, env: HarnessEnvironment,
                                   trash: (URL) throws -> URL? = SkillRemover.defaultTrash) async throws(Failure) {
        guard let skill = brain.skills.first(where: { $0.name == name }) else { throw Failure(message: "No skill named \(name) in skills/.") }
        let users = skillUsers(name, in: brain)
        guard users.isEmpty else {
            throw Failure(message: "\(name) is used by \(users.joined(separator: ", ")). Remove it from \(users.count == 1 ? "that layer" : "those layers") first.")
        }
        do {
            _ = try trash(skill.folder)
        } catch {
            throw Failure(message: "Couldn't move skills/\(name) to the Trash: \(error.localizedDescription)")
        }
        try await commit(["skills/\(name)"], "Remove skill \(name)", in: brain.root, env: env)
    }

    /// The layer.yaml text without this skill's entry; nothing else changes.
    public static func layerWithoutSkill(_ skill: String, in layer: Layer) throws(Failure) -> (before: String, after: String) {
        guard let text = try? String(contentsOf: layer.manifest, encoding: .utf8) else {
            throw Failure(message: "Can't read layers/\(layer.name)/layer.yaml.")
        }
        let after = try dropSkill(skill, from: text)
        return (text, after)
    }

    /// Removes a skill from a layer's `skills:` list and commits.
    public static func removeSkill(_ skill: String, fromLayer name: String, in brain: Brain, env: HarnessEnvironment) async throws(Failure) {
        guard let layer = brain.layers.first(where: { $0.name == name }) else { throw Failure(message: "No layer named \(name).") }
        let edit = try layerWithoutSkill(skill, in: layer)
        do {
            try Data(edit.after.utf8).write(to: layer.manifest, options: .atomic)
        } catch {
            throw Failure(message: "Couldn't write layers/\(name)/layer.yaml: \(error.localizedDescription)")
        }
        try await commit(["layers/\(name)/layer.yaml"], "Remove skill \(skill) from layer \(name)", in: brain.root, env: env)
    }

    /// Removes the skill's item (a bare `- name` or a `- name: x` block) from the top-level
    /// `skills:` list, then checks that only that entry went away.
    static func dropSkill(_ skill: String, from text: String) throws(Failure) -> String {
        let newline = text.contains("\r\n") ? "\r\n" : "\n"
        var lines = text.components(separatedBy: newline)
        guard LayerEditor.block("skills", in: lines) != nil else {
            throw Failure(message: "The layer has no skills list.")
        }
        guard let found = LayerEditor.skillItem(skill, in: lines) else {
            throw Failure(message: "\(skill) is not in the layer's skills list (or the list is written on one line; edit it by hand).")
        }
        lines.removeSubrange(found.item)
        if found.starts.count == 1 { lines[found.list.key] = "skills: []" }  // it was the only item
        let result = lines.joined(separator: newline)

        let folder = URL(filePath: "/layer")
        guard let old = try? LayerManifest.parse(text, folder: folder).layer,
              let new = try? LayerManifest.parse(result, folder: folder).layer,
              new.skills == old.skills.filter({ $0.name != skill }), new.fields == old.fields, new.files == old.files,
              new.requires == old.requires, new.conflicts == old.conflicts, new.description == old.description else {
            throw Failure(message: "AKit couldn't remove \(skill) from layer.yaml safely. Edit it by hand.")
        }
        return result
    }

    // MARK: - Projects

    /// Removes a project's (or the home folder's) record from its store: `<store>/<id>` to
    /// the Trash, committed when the store is the brain's. Its rendered files are left to
    /// `akit remove project`, which first applies an empty render.
    public static func forgetProject(_ id: String, in store: ProjectStore, env: HarnessEnvironment,
                                     trash: (URL) throws -> URL? = SkillRemover.defaultTrash) async throws(Failure) {
        let folder = store.folder(id: id)
        guard FileManager.default.fileExists(atPath: folder.path) else { throw Failure(message: "Nothing is saved for \(id).") }
        do {
            _ = try trash(folder)
        } catch {
            throw Failure(message: "Couldn't move \(store.describe(id: id)) to the Trash: \(error.localizedDescription)")
        }
        if let brainRoot = store.brain {
            try await commit(["projects/\(id)"], "Forget \(id)", in: brainRoot, env: env)
        }
    }

    // MARK: - Helpers

    struct Saved {
        let id: String
        let file: URL
        let answers: ProjectAnswers
        let store: ProjectStore
    }

    /// Saved answers in the brain and in this Mac's local store.
    static func savedAnswers(brain: Brain, home: URL) -> [Saved] {
        savedAnswers(in: .brain(brain.root)) + savedAnswers(in: .local(home: home))
    }

    /// Every `**/answers.json` in a store.
    static func savedAnswers(in store: ProjectStore) -> [Saved] {
        let base = store.root.standardizedFileURL
        guard let walker = FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil) else { return [] }
        var found: [Saved] = []
        for case let url as URL in walker where url.lastPathComponent == "answers.json" {
            guard let data = try? Data(contentsOf: url), let answers = try? JSONDecoder().decode(ProjectAnswers.self, from: data) else { continue }
            let id = String(url.deletingLastPathComponent().standardizedFileURL.path.dropFirst(base.path.count + 1))
            found.append(Saved(id: id, file: url, answers: answers, store: store))
        }
        return found.sorted { $0.id < $1.id }
    }

    private static func encode(_ answers: ProjectAnswers) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(answers)
    }

    /// Stages these paths (removals included) and commits only them, if the brain is a git repo.
    static func commit(_ paths: [String], _ message: String, in root: URL, env: HarnessEnvironment) async throws(Failure) {
        guard FileManager.default.fileExists(atPath: root.appending(path: ".git").path) else { return }
        guard let git = env.findExecutable("git") else { throw Failure(message: "Done, but git was not found, so nothing was committed.") }
        let environment = env.variables.merging(["PATH": env.pathForChildProcesses]) { $1 }
        for arguments in [["add", "--all", "--"] + paths, ["commit", "--quiet", "-m", message, "--"] + paths] {
            let result = await ProcessRunner.run(git, arguments: arguments, directory: root, environment: environment, timeout: 30)
            guard let result, result.succeeded else {
                throw Failure(message: "Done, but git \(arguments[0]) failed: \(result?.output.trimmingCharacters(in: .whitespacesAndNewlines) ?? "couldn't start")")
            }
        }
    }
}
