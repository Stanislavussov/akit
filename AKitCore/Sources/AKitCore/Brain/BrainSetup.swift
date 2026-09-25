import Foundation

/// Creates a new brain repo: the folder layout from docs/design/layers.md, an
/// empty `core` layer, and a git repo with a first commit.
public enum BrainSetup {
    public struct Failure: Error, LocalizedError {
        public let message: String
        public var errorDescription: String? { message }
    }

    /// Files of a new brain, by path inside it.
    static let skeleton: [String: String] = [
        "README.md": """
            # Brain

            Skill library and harness layers for AKit. No harness reads this folder;
            AKit renders from it into projects and the home folder.

            ```
            skills/<name>/SKILL.md     skill library
            layers/<name>/layer.yaml   layers: fields, skills, files
            layers/<name>/templates/   files rendered into a project
            projects/<id>/             answers and lock per project (written by AKit)
            machines/<name>.yaml       harnesses and core layer per machine
            ```

            """,
        "layers/core/layer.yaml": """
            name: core
            description: Applied to the home folder on every machine. Keep it small; prefer manual skills.
            skills: []

            """,
        "skills/.gitkeep": "",
        "projects/.gitkeep": "",
        "machines/.gitkeep": "",
    ]

    /// Writes the skeleton into `root` (which must be missing or empty) and commits it.
    /// A failing git step leaves the files in place and says so.
    public static func create(at root: URL, env: HarnessEnvironment) async throws(Failure) {
        let fm = FileManager.default
        let existing = (try? fm.contentsOfDirectory(atPath: root.path)) ?? []
        guard existing.filter({ $0 != ".DS_Store" }).isEmpty else {
            throw Failure(message: "\(root.path) is not empty. Pick an empty or new folder.")
        }
        do {
            for (path, text) in skeleton {
                let file = root.appending(path: path)
                try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data(text.utf8).write(to: file, options: .withoutOverwriting)
            }
        } catch {
            throw Failure(message: "Couldn't create the brain in \(root.path): \(error.localizedDescription)")
        }

        guard let git = env.findExecutable("git") else {
            throw Failure(message: "The brain folder was created, but git was not found, so it is not a repo yet.")
        }
        var environment = env.variables
        environment["PATH"] = env.pathForChildProcesses
        for arguments in [["init", "--quiet", "--initial-branch=main"], ["add", "--all"], ["commit", "--quiet", "-m", "Create brain repo"]] {
            let result = await ProcessRunner.run(git, arguments: arguments, directory: root, environment: environment, timeout: 30)
            guard let result, result.succeeded else {
                let output = result?.output.trimmingCharacters(in: .whitespacesAndNewlines) ?? "git couldn't be started."
                throw Failure(message: "The brain folder was created, but git \(arguments[0]) failed: \(output)")
            }
        }
    }
}
