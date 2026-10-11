import AKitBrain
import AKitFoundation
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
        /// Move to Project into a personal project from a work Mac: only `projects/<id>/answers.json`
        /// of a project the brain already has, only one skill entry added (or its mode changed).
        /// `mode` nil: Move to Global, only that skill's entry taken out (it must be there).
        case answers(project: String, skill: String, mode: LayerSkill.Mode?)

        var name: String {
            switch self {
            case .summary: "usage summary"
            case .layer: "layer"
            case .answers: "project answers"
            }
        }

        var paths: Set<String> {
            switch self {
            case .summary(let pseudonym, _): [UsageSummary.machinePath(pseudonym)]
            case .layer(let layer, _, _): [LayerPatch.path(layer: layer)]
            case .answers(let project, _, _): ["projects/\(project)/answers.json"]
            }
        }

        var message: String {
            switch self {
            case .summary(let pseudonym, _): "Update usage summaries (\(pseudonym))"
            case .layer(let layer, let skill, let change): change.message(skill: skill, layer: layer)
            case .answers(let project, let skill, let mode):
                mode == nil ? "Remove skill \(skill) from \(project)'s answers" : "Add skill \(skill) to \(project)'s answers"
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
            case .answers(let project, let skill, let mode):
                let decoder = JSONDecoder()
                guard UsageSummary.isSafeProjectID(project), path == "projects/\(project)/answers.json", let head,
                      let before = try? decoder.decode(ProjectAnswers.self, from: head),
                      let after = try? decoder.decode(ProjectAnswers.self, from: data) else {
                    throw Failure(message: "Refused a commit from this work Mac: \(path) is not the committed answers of \(project).")
                }
                var expected = before
                expected.skills.removeAll { $0.name == skill }
                if let mode {
                    expected.skills.append(.init(name: skill, mode: mode))
                } else if expected.skills.count == before.skills.count {
                    throw Failure(message: "Refused a commit from this work Mac: \(path) has no \(skill) skill entry to take out.")
                }
                // Nothing but the one skill entry; no field the decoder doesn't know.
                let keys = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]).map { Set($0.keys) } ?? []
                guard after == expected, keys.isSubset(of: ["layers", "values", "targets", "skills", "localOnly"]) else {
                    throw Failure(message: "Refused a commit from this work Mac: \(path) changes more than the \(skill) skill entry.")
                }
            }
        }

        /// Kinds that edit a committed file and are checked against it.
        var needsHead: Bool {
            switch self {
            case .layer, .answers: true
            case .summary: false
            }
        }
    }

    /// Checks that don't need the files: a readable `machine.json`, the brain's own git name and
    /// email and nothing staged already (so a refusal can reset the index without touching the user's work).
    static func preflight(brain root: URL, machine: MachineProfile, env: HarnessEnvironment) async throws(Failure) {
        if let problem = machine.problem { throw Failure(message: "\(problem) Nothing is published from this Mac until then.") }
        do {
            try await BrainGit.requireOwnIdentity(brain: root, env: env)
        } catch {
            throw Failure(message: error.message)
        }
        let staged = try await git(["diff", "--cached", "--name-only", "-z"], in: root, env: env)
        guard staged.isEmpty else {
            throw Failure(message: "The brain has staged changes; commit or unstage them first (nothing was committed).")
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
            try await git(["-c", "core.hooksPath=/dev/null"] + BrainGit.noSigning + ["commit", "--quiet", "--no-verify", "-m", message, "--"] + paths,
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
        struct Day: Decodable {
            let skills: [String: [Int]]
            let described: [String: Int]?
        }
        struct Shape: Decodable {
            let version: Int
            let machine: String
            let updated: String
            let days: [String: Day]
        }
        guard let shape = try? JSONDecoder().decode(Shape.self, from: data) else { throw refuse("doesn't have the summary's shape") }
        guard shape.version == UsageSummary.version, shape.machine == pseudonym else { throw refuse("names another machine or version") }
        guard ISO8601DateFormatter().date(from: shape.updated) != nil else { throw refuse("has an update time that isn't a date") }
        // The decoder ignores unknown keys: the day fields are checked on the raw object too.
        let rawDays = object["days"] as? [String: Any] ?? [:]
        for (day, fields) in shape.days {
            guard day.count == 10, DescriptionWindow.day(day, calendar: Calendar(identifier: .gregorian)) != nil,
                  day.allSatisfy({ $0.isNumber || $0 == "-" }) else { throw refuse("has a day that isn't yyyy-MM-dd") }
            guard let raw = rawDays[day] as? [String: Any], raw["skills"] != nil,
                  Set(raw.keys).isSubset(of: ["skills", "described"]) else { throw refuse("has other day fields than skills and described") }
            for (skill, counts) in fields.skills {
                guard brainSkills.contains(skill) else { throw refuse("names a skill that isn't in the brain") }
                guard counts.count == 3, counts.allSatisfy({ $0 >= 0 }) else { throw refuse("has counts that aren't three whole numbers") }
            }
            for (skill, count) in fields.described ?? [:] {
                guard brainSkills.contains(skill) else { throw refuse("names a skill that isn't in the brain") }
                guard count >= 0 else { throw refuse("has a described count that isn't a whole number") }
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
    private static func git(_ arguments: [String], in root: URL, env: HarnessEnvironment,
                            identityFromConfig: Bool = false) async throws(Failure) -> String {
        guard let git = env.findExecutable("git") else { throw Failure(message: "git was not found, so nothing was committed.") }
        var environment = env.gitVariables
        if identityFromConfig { environment = BrainGit.withoutIdentity(environment) }
        let result = await ProcessRunner.run(git, arguments: ["-C", root.path] + arguments, directory: root,
                                             environment: environment, timeout: 30)
        guard let result, result.succeeded else {
            let output = result.map(\.failureText) ?? "couldn't start git"
            throw Failure(message: "git \(arguments.first { !$0.hasPrefix("-") } ?? "") failed (\(output)). Nothing was committed.")
        }
        return result.output
    }
}
