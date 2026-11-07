import AKitFoundation
import Foundation

/// AKit's own skills (`/akit`, `/akit-context`) in a brain made before they existed or changed.
/// `akit init` writes them into a new brain only; this adds a missing one, lists it in the core
/// layer, or brings the brain's copy up to this AKit's template, in one commit.
public enum BuiltInSkills {
    /// A skill AKit ships, with the mode a new brain gives it in core.
    public struct Template: Sendable {
        public let name: String
        public let mode: LayerSkill.Mode
        public let text: String
    }

    public static let templates: [Template] = [
        Template(name: "akit", mode: .manual, text: AKitSkill.text),
        Template(name: "akit-context", mode: .auto, text: AKitContextSkill.text),
    ]

    public struct Item: Identifiable, Hashable, Sendable {
        public enum State: Hashable, Sendable {
            /// No `skills/<name>/SKILL.md` in the brain.
            case missing
            /// The brain's SKILL.md differs from this AKit's template.
            case outdated
            /// The brain's SKILL.md is the template.
            case current
        }

        public var id: String { name }
        public let name: String
        public let state: State
        /// Listed in the core layer.
        public let inCore: Bool
        /// The mode core gives it (its entry, or the template's mode when not listed).
        public let mode: LayerSkill.Mode
        /// The brain's SKILL.md now (nil when missing) and the template.
        public let before: String?
        public let template: String

        public var needsWork: Bool { state != .current || !inCore }
    }

    public struct Plan: Sendable {
        public let brainRoot: URL
        public let items: [Item]
        /// `layers/core/layer.yaml` as read for this plan.
        public let layerBefore: String

        public var needsWork: Bool { items.contains(where: \.needsWork) }
    }

    public struct Failure: Error, LocalizedError {
        public let message: String
        public var errorDescription: String? { message }
    }

    static let layerPath = "layers/core/layer.yaml"
    static func skillPath(_ name: String) -> String { "skills/\(name)/SKILL.md" }

    /// Reads the brain: where each of AKit's skills stands. Only reads.
    public static func plan(brain root: URL) throws(Failure) -> Plan {
        guard let layerText = try? String(contentsOf: root.appending(path: layerPath), encoding: .utf8) else {
            throw Failure(message: "The brain has no \(layerPath).")
        }
        let listed = Brain.load(from: root)?.layers.first { $0.name == "core" }?.skills ?? []
        let items = templates.map { template in
            let before = try? String(contentsOf: root.appending(path: skillPath(template.name)), encoding: .utf8)
            let entry = listed.first { $0.name == template.name }
            let state: Item.State = before == nil ? .missing : same(before!, template.text) ? .current : .outdated
            return Item(name: template.name, state: state, inCore: entry != nil, mode: entry?.mode ?? template.mode,
                        before: before, template: template.text)
        }
        return Plan(brainRoot: root, items: items, layerBefore: layerText)
    }

    /// The core layer after listing the chosen skills that are not listed yet, each in `modes[name]`
    /// (else the template's mode).
    public static func layerAfter(_ plan: Plan, names: [String], modes: [String: LayerSkill.Mode] = [:]) throws(Failure) -> String {
        var text = plan.layerBefore
        for item in plan.items where names.contains(item.name) && !item.inCore {
            do {
                text = try LayerEditor.addingSkills([item.name], mode: modes[item.name] ?? item.mode, to: text)
            } catch {
                throw Failure(message: "\(layerPath): \(error.message)")
            }
        }
        return text
    }

    /// Writes the chosen skills' templates and lists them in core, then commits those paths only.
    /// Refused when a file changed since the plan or holds uncommitted changes. Returns the commit
    /// message, or nil when nothing changed.
    @discardableResult
    public static func apply(_ plan: Plan, names: [String], modes: [String: LayerSkill.Mode] = [:],
                             env: HarnessEnvironment) async throws(Failure) -> String? {
        let root = plan.brainRoot
        if let problem = await BrainGit.commitProblem(brain: root, env: env) { throw Failure(message: problem) }
        let chosen = plan.items.filter { names.contains($0.name) && $0.needsWork }
        guard !chosen.isEmpty else { return nil }
        let layerAfter = try layerAfter(plan, names: names, modes: modes)
        let writes = chosen.filter { $0.state != .current }
        let paths = writes.map { skillPath($0.name) } + (layerAfter != plan.layerBefore ? [layerPath] : [])

        // Nothing changed since the preview.
        let fresh = try self.plan(brain: root)
        guard fresh.layerBefore == plan.layerBefore,
              chosen.allSatisfy({ item in fresh.items.first { $0.name == item.name }?.before == item.before }) else {
            throw Failure(message: "The brain changed since the preview. Open it again.")
        }
        if let dirty = await uncommitted(paths, in: root, env: env), !dirty.isEmpty {
            throw Failure(message: "The brain has uncommitted changes in \(dirty.joined(separator: ", ")). Commit or discard them first.")
        }

        let fm = FileManager.default
        do {
            for item in writes {
                let file = root.appending(path: skillPath(item.name))
                try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data(item.template.utf8).write(to: file, options: .atomic)
            }
            if layerAfter != plan.layerBefore {
                try Data(layerAfter.utf8).write(to: root.appending(path: layerPath), options: .atomic)
            }
        } catch {
            throw Failure(message: "Couldn't write the brain: \(error.localizedDescription)")
        }
        let added = chosen.filter { $0.state == .missing || !$0.inCore }.map(\.name)
        let updated = chosen.filter { $0.state == .outdated }.map(\.name)
        let message = [added.isEmpty ? nil : "Add \(added.joined(separator: ", ")) to core",
                       updated.isEmpty ? nil : "Update \(updated.joined(separator: ", "))"]
            .compactMap { $0 }.joined(separator: "; ") + " from AKit's templates"
        do {
            try await BrainRemove.commit(paths, message, in: root, env: env)
        } catch {
            throw Failure(message: error.message)
        }
        return message
    }

    /// The same text, line endings and trailing blank lines aside.
    static func same(_ a: String, _ b: String) -> Bool {
        func clean(_ t: String) -> String {
            t.replacingOccurrences(of: "\r\n", with: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return clean(a) == clean(b)
    }

    /// Paths among `paths` with uncommitted changes; nil when the brain is not a git repo.
    private static func uncommitted(_ paths: [String], in root: URL, env: HarnessEnvironment) async -> [String]? {
        guard !paths.isEmpty, FileManager.default.fileExists(atPath: root.appending(path: ".git").path),
              let git = env.findExecutable("git") else { return nil }
        var environment = env.variables
        environment["PATH"] = env.pathForChildProcesses
        let result = await ProcessRunner.run(git, arguments: ["status", "--porcelain", "--"] + paths, directory: root,
                                             environment: environment, timeout: 30)
        guard let result, result.succeeded else { return nil }
        return result.output.split(separator: "\n").map { String($0.dropFirst(3)) }
    }
}
