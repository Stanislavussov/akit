import Foundation

/// The last check before an insights commit from a work Mac. The brain is pushed to a personal
/// remote, so each commit kind has an allow-list for what it may push: the staged paths, the
/// commit message and the bytes of every staged file. Anything else and nothing is committed.
/// It also refuses when `machine.json` is broken or the brain has no git name and email of its
/// own (the global ones may be the work ones). Checked fail-closed: any git error refuses.
enum WorkFilter {
    struct Failure: Error, LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// What one kind of commit may contain.
    enum Kind: Equatable {
        /// The work machine file: only `insights/machines/<pseudonym>.json`, only counts of brain skills.
        case summary(pseudonym: String, brainSkills: Set<String>)
        /// `akit recommend apply` / `dismiss` of a layer skill: only `layers/<layer>/layer.yaml`, only
        /// that skill's mode or keep_auto line, and a message naming nothing but the skill and the layer.
        case layer(layer: String, skill: String, change: LayerPatch.Change)

        var name: String {
            switch self {
            case .summary: "usage summary"
            case .layer: "layer"
            }
        }

        var paths: Set<String> {
            switch self {
            case .summary(let pseudonym, _): [UsageSummary.machinePath(pseudonym)]
            case .layer(let layer, _, _): [LayerPatch.path(layer: layer)]
            }
        }

        var message: String {
            switch self {
            case .summary(let pseudonym, _): "Update usage summaries (\(pseudonym))"
            case .layer(let layer, let skill, let change): change.message(skill: skill, layer: layer)
            }
        }

        /// Throws when the bytes hold anything the kind doesn't allow. `head`: the file at HEAD.
        func check(path: String, data: Data, head: Data?) throws(Failure) {
            switch self {
            case .summary(let pseudonym, let brainSkills):
                try WorkFilter.checkSummary(data, pseudonym: pseudonym, brainSkills: brainSkills, path: path)
            case .layer(let layer, let skill, let change):
                guard path == LayerPatch.path(layer: layer), let head, let before = String(data: head, encoding: .utf8),
                      let after = String(data: data, encoding: .utf8) else {
                    throw Failure(message: "Refused a commit from this work Mac: \(path) is not the committed layer.yaml of \(layer).")
                }
                if let problem = LayerPatch.problem(before: before, after: after, skill: skill, layer: layer, change: change) {
                    throw Failure(message: "Refused a commit from this work Mac: \(path) changes more than \(skill)'s \(change.key) (\(problem)).")
                }
            }
        }

        /// Kinds that edit a committed file and are checked against it.
        var needsHead: Bool { if case .layer = self { true } else { false } }
    }

    /// Variables that would win over the brain's configured identity in a commit git makes.
    static let identityVariables = ["GIT_AUTHOR_NAME", "GIT_AUTHOR_EMAIL", "GIT_COMMITTER_NAME", "GIT_COMMITTER_EMAIL", "EMAIL"]

    /// The environment without `identityVariables`, so commits (also a sync's rebase) carry the brain's own identity.
    static func withoutIdentity(_ environment: [String: String]) -> [String: String] {
        environment.filter { !identityVariables.contains($0.key) }
    }

    /// Keeps a global `commit.gpgsign` (maybe with a work key) from signing the brain's commits.
    static let noSigning = ["-c", "commit.gpgsign=false"]

    /// Checks that don't need the files: a readable `machine.json`, the brain's own git name and
    /// email and nothing staged already (so a refusal can reset the index without touching the user's work).
    static func preflight(brain root: URL, machine: MachineProfile, env: HarnessEnvironment) async throws(Failure) {
        if let problem = machine.problem { throw Failure(message: "\(problem) Nothing is published from this Mac until then.") }
        try await requireOwnIdentity(brain: root, env: env)
        let staged = try await git(["diff", "--cached", "--name-only", "-z"], in: root, env: env)
        guard staged.isEmpty else {
            throw Failure(message: "The brain has staged changes; commit or unstage them first (nothing was committed).")
        }
    }

    /// The brain's own `user.email` and `user.name` (in its `.git/config`), checked fail-closed with
    /// git: without them a commit would carry the global ones, maybe the work ones.
    static func requireOwnIdentity(brain root: URL, env: HarnessEnvironment) async throws(Failure) {
        for (key, what) in [("user.email", "email"), ("user.name", "name")] {
            let value = try await git(["config", "--local", "--get", key], in: root, env: env,
                                      failure: "The brain has no git \(what) of its own, so a commit would carry the global one (maybe the work \(what))")
            guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw Failure(message: "The brain's git \(what) is empty. Set one: git -C \(root.path) config \(key) <personal \(what)>")
            }
        }
    }

    /// Writes the files, stages them, checks paths, message and bytes, and commits with the
    /// brain's own identity and without hooks. On any failure the index is reset, the files are
    /// put back as they were and nothing is committed. Returns false when nothing changed.
    @discardableResult
    static func commit(_ kind: Kind, files: [String: Data], message: String, brain root: URL, machine: MachineProfile,
                       env: HarnessEnvironment) async throws(Failure) -> Bool {
        try await preflight(brain: root, machine: machine, env: env)
        guard Set(files.keys) == kind.paths, message == kind.message else {
            throw Failure(message: "Refused a commit from this work Mac: it held other paths or another message than a \(kind.name) commit may.")
        }
        let fm = FileManager.default
        var before: [String: Data?] = [:]
        for path in files.keys { before[path] = try? Data(contentsOf: root.appending(path: path)) }
        func undo() async {
            _ = try? await git(["reset", "--quiet"], in: root, env: env)
            for (path, data) in before {
                let url = root.appending(path: path)
                if let data { try? data.write(to: url, options: .atomic) } else { try? fm.removeItem(at: url) }
            }
        }
        do {
            for (path, data) in files {
                let url = root.appending(path: path)
                try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: url, options: .atomic)
            }
        } catch {
            await undo()
            throw Failure(message: "Couldn't write \(files.keys.sorted().joined(separator: ", ")): \(error.localizedDescription)")
        }
        do throws(Failure) {
            try await git(["add", "--"] + files.keys.sorted(), in: root, env: env)
            let staged = Set(records(try await git(["-c", "core.quotePath=false", "diff", "--cached", "--name-only", "--no-renames", "-z"],
                                                   in: root, env: env)))
            if staged.isEmpty { return false }
            guard staged == kind.paths else {
                throw Failure(message: "Refused a commit from this work Mac: staged \(staged.sorted().joined(separator: ", ")), allowed only \(kind.paths.sorted().joined(separator: ", ")).")
            }
            for path in staged.sorted() {
                // The bytes git would commit: the staged blob, not the file on disk.
                let blob = try await git(["show", ":\(path)"], in: root, env: env)
                let head = kind.needsHead ? Data(try await git(["show", "HEAD:\(path)"], in: root, env: env).utf8) : nil
                try kind.check(path: path, data: Data(blob.utf8), head: head)
            }
            // No hooks (they could add files or change the message); the brain's own identity, not the
            // environment's; never signed with a global key; only the checked paths.
            let paths = staged.sorted()
            var checked: [String: String] = [:]
            for path in paths { checked[path] = try await git(["rev-parse", ":\(path)"], in: root, env: env) }
            try await git(["-c", "core.hooksPath=/dev/null"] + noSigning + ["commit", "--quiet", "--no-verify", "-m", message, "--"] + paths,
                          in: root, env: env, identityFromConfig: true)
            // A path in the commit takes the file as it is on disk: it must still be the checked bytes.
            let committed = Set(records(try await git(["diff-tree", "--no-commit-id", "--name-only", "--no-renames", "-r", "-z", "HEAD"],
                                                      in: root, env: env)))
            var same = committed == staged
            for path in paths where same { same = try await git(["rev-parse", "HEAD:\(path)"], in: root, env: env) == checked[path] }
            guard same else {
                _ = try? await git(["reset", "--quiet", "--soft", "HEAD~1"], in: root, env: env)
                throw Failure(message: "Refused a commit from this work Mac: \(paths.joined(separator: ", ")) changed while it was checked.")
            }
            return true
        } catch {
            await undo()
            throw error
        }
    }

    /// The work machine file: exactly the allowed keys and value types; skills only from the brain.
    static func checkSummary(_ data: Data, pseudonym: String, brainSkills: Set<String>, path: String) throws(Failure) {
        func refuse(_ why: String) -> Failure { Failure(message: "Refused a commit from this work Mac: \(path) \(why).") }
        guard path == UsageSummary.machinePath(pseudonym) else { throw refuse("is not this Mac's summary") }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw refuse("is not a JSON object") }
        guard Set(object.keys).isSubset(of: ["version", "machine", "updated", "days"]) else {
            throw refuse("has other fields than version, machine, updated and days")
        }
        struct Shape: Decodable {
            let version: Int
            let machine: String
            let updated: String
            let days: [String: [String: [String: [Int]]]]
        }
        guard let shape = try? JSONDecoder().decode(Shape.self, from: data) else { throw refuse("doesn't have the summary's shape") }
        guard shape.version == UsageSummary.version, shape.machine == pseudonym else { throw refuse("names another machine or version") }
        guard ISO8601DateFormatter().date(from: shape.updated) != nil else { throw refuse("has an update time that isn't a date") }
        for (day, fields) in shape.days {
            guard day.count == 10, DescriptionWindow.day(day, calendar: Calendar(identifier: .gregorian)) != nil,
                  day.allSatisfy({ $0.isNumber || $0 == "-" }) else { throw refuse("has a day that isn't yyyy-MM-dd") }
            guard Set(fields.keys) == ["skills"], let skills = fields["skills"] else { throw refuse("has other day fields than skills") }
            for (skill, counts) in skills {
                guard brainSkills.contains(skill) else { throw refuse("names a skill that isn't in the brain") }
                guard counts.count == 3, counts.allSatisfy({ $0 >= 0 }) else { throw refuse("has counts that aren't three whole numbers") }
            }
        }
    }

    // MARK: - git

    private static func records(_ output: String) -> [String] {
        output.split(separator: "\0").map(String.init).filter { !$0.isEmpty }
    }

    /// Runs git in the brain. `identityFromConfig` drops the author and committer variables, so
    /// the commit carries the brain's configured identity. Output is stdout and stderr combined.
    @discardableResult
    private static func git(_ arguments: [String], in root: URL, env: HarnessEnvironment, failure: String? = nil,
                            identityFromConfig: Bool = false) async throws(Failure) -> String {
        guard let git = env.findExecutable("git") else { throw Failure(message: "git was not found, so nothing was committed.") }
        var environment = env.variables.merging(["PATH": env.pathForChildProcesses, "GIT_TERMINAL_PROMPT": "0"]) { $1 }
        if identityFromConfig { environment = withoutIdentity(environment) }
        let result = await ProcessRunner.run(git, arguments: ["-C", root.path] + arguments, directory: root,
                                             environment: environment, timeout: 30)
        guard let result, result.succeeded else {
            let output = result.map { $0.timedOut ? "timed out" : $0.output.trimmingCharacters(in: .whitespacesAndNewlines) } ?? "couldn't start git"
            throw Failure(message: "\(failure ?? "git \(arguments.first { !$0.hasPrefix("-") } ?? "") failed") (\(output)). Nothing was committed.")
        }
        return result.output
    }
}
