import AKitFoundation
import Foundation
import Yams

/// Creates a new layer in the brain from the New Layer form: `layers/<name>/layer.yaml`
/// plus an optional `templates/AGENTS.md` section, then commits it.
public enum LayerWriter {
    public struct Draft: Sendable {
        public var name: String
        public var description: String
        public var requires: [String]
        public var skills: [(name: String, mode: LayerSkill.Mode)]
        /// This layer's section of the project's AGENTS.md; empty = no file.
        public var agentsSection: String

        public init(name: String = "", description: String = "", requires: [String] = [],
                    skills: [(name: String, mode: LayerSkill.Mode)] = [], agentsSection: String = "") {
            self.name = name
            self.description = description
            self.requires = requires
            self.skills = skills
            self.agentsSection = agentsSection
        }
    }

    public struct Failure: Error, LocalizedError {
        public let message: String
        public var errorDescription: String? { message }
    }

    /// Why the name can't be used, or nil.
    public static func nameProblem(_ name: String, in brain: Brain) -> String? {
        if name.isEmpty { return "Give the layer a name." }
        guard name.allSatisfy({ ($0.isLowercase && $0.isASCII) || $0.isNumber || $0 == "-" }), name.first?.isLetter == true else {
            return "Use lowercase letters, digits and -, starting with a letter."
        }
        if brain.layers.contains(where: { $0.name == name })
            || FileManager.default.fileExists(atPath: brain.root.appending(path: "layers/\(name)").path) {
            return "A layer named \(name) already exists."
        }
        return nil
    }

    static let agentsTemplate = "AGENTS.md"

    /// The layer.yaml text for a draft.
    static func manifest(_ draft: Draft) throws(Failure) -> String {
        var lines = ["name: \(try scalar(draft.name))"]
        let description = draft.description.trimmingCharacters(in: .whitespacesAndNewlines)
        if !description.isEmpty { lines.append("description: \(try scalar(description))") }
        if !draft.requires.isEmpty {
            lines.append("requires: [\(try draft.requires.map { name throws(Failure) in try scalar(name) }.joined(separator: ", "))]")
        }
        if !draft.skills.isEmpty {
            lines.append("skills:")
            for skill in draft.skills {
                lines += ["  - name: \(try scalar(skill.name))", "    mode: \(skill.mode.rawValue)"]
            }
        }
        if !draft.agentsSection.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lines += ["files:", "  - template: \(agentsTemplate)", "    to: AGENTS.md"]
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// One YAML scalar, quoted by Yams when needed (`a: b`, `#x`, `yes`, …).
    public static func scalar(_ text: String) throws(Failure) -> String {
        do {
            return try Yams.serialize(node: Node(text)).trimmingCharacters(in: .newlines)
        } catch {
            throw Failure(message: "Couldn't write “\(text)” into layer.yaml.")
        }
    }

    /// Writes the layer and commits it (when the brain is a git repo). Returns the layer folder.
    @discardableResult
    public static func create(_ draft: Draft, in brain: Brain, env: HarnessEnvironment) async throws(Failure) -> URL {
        if let problem = nameProblem(draft.name, in: brain) { throw Failure(message: problem) }
        let text = try manifest(draft)
        // Read it back the way the brain will, so a bad layer is never written.
        guard let parsed = try? LayerManifest.parse(text, folder: URL(filePath: "/\(draft.name)")), parsed.problems.isEmpty else {
            throw Failure(message: "The layer would not read back cleanly; nothing was written.")
        }
        let fm = FileManager.default
        let folder = brain.root.appending(path: "layers/\(draft.name)")
        do {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data(text.utf8).write(to: folder.appending(path: "layer.yaml"), options: .withoutOverwriting)
            let section = draft.agentsSection.trimmingCharacters(in: .whitespacesAndNewlines)
            if !section.isEmpty {
                let templates = folder.appending(path: "templates")
                try fm.createDirectory(at: templates, withIntermediateDirectories: true)
                try Data((section + "\n").utf8).write(to: templates.appending(path: agentsTemplate), options: .withoutOverwriting)
            }
        } catch {
            try? fm.removeItem(at: folder)
            throw Failure(message: "Couldn't create layers/\(draft.name): \(error.localizedDescription)")
        }

        guard fm.fileExists(atPath: brain.root.appending(path: ".git").path), let git = env.findExecutable("git") else { return folder }
        let environment = env.variables.merging(["PATH": env.pathForChildProcesses]) { $1 }
        let path = "layers/\(draft.name)"
        for arguments in [["add", "--", path], ["commit", "--quiet", "-m", "Add layer \(draft.name)", "--", path]] {
            let result = await ProcessRunner.run(git, arguments: arguments, directory: brain.root, environment: environment, timeout: 30)
            guard let result, result.succeeded else {
                throw Failure(message: "The layer was created, but git \(arguments[0]) failed: \(result?.output.trimmingCharacters(in: .whitespacesAndNewlines) ?? "couldn't start")")
            }
        }
        return folder
    }
}
