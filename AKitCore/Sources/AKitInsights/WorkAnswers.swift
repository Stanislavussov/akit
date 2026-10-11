import AKitBrain
import AKitFoundation
import Foundation

/// Move to Project from a work Mac into a personal project that is not on it: the one exception
/// to "work Macs commit no project data" (layers.md, "Work machines"). Only a skill entry goes
/// into the brain's existing `projects/<id>/answers.json`, through `WorkFilter` (the brain's own
/// identity, no hooks, the bytes checked), so the project's own Mac renders the skill.
public enum WorkAnswers {
    public struct Failure: Error, LocalizedError {
        public let message: String
        public var errorDescription: String? { message }
    }

    /// Adds `skill` (in `mode`) to the brain's answers of `project` and commits only that file.
    public static func addSkill(_ skill: String, mode: LayerSkill.Mode, to project: String, brain root: URL, env: HarnessEnvironment)
        async throws(Failure) {
        try await change(skill, mode: mode, project: project, brain: root, env: env)
    }

    /// Move to Global: takes `skill`'s entry out of the brain's answers of `project` and commits only that file.
    public static func removeSkill(_ skill: String, from project: String, brain root: URL, env: HarnessEnvironment) async throws(Failure) {
        try await change(skill, mode: nil, project: project, brain: root, env: env)
    }

    /// `mode` nil: take the entry out.
    static func change(_ skill: String, mode: LayerSkill.Mode?, project: String, brain root: URL, env: HarnessEnvironment)
        async throws(Failure) {
        let file = root.appending(path: "projects/\(project)/answers.json")
        guard let data = try? Data(contentsOf: file), var answers = try? JSONDecoder().decode(ProjectAnswers.self, from: data) else {
            throw Failure(message: "The brain has no answers of \(project) to \(mode == nil ? "take \(skill) out of" : "add \(skill) to").")
        }
        answers.skills.removeAll { $0.name == skill }
        if let mode { answers.skills.append(.init(name: skill, mode: mode)) }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        do {
            let kind = WorkFilter.Kind.answers(project: project, skill: skill, mode: mode)
            try await WorkFilter.commit(kind, files: ["projects/\(project)/answers.json": try encoder.encode(answers)], message: kind.message,
                                        brain: root, machine: MachineProfile.load(home: env.homeDirectory), env: env)
        } catch let refused as WorkFilter.Failure {
            throw Failure(message: refused.message)
        } catch {
            throw Failure(message: "Couldn't write the answers of \(project): \(error.localizedDescription)")
        }
    }
}
