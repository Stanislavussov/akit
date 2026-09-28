import Foundation

/// Writes this Mac's usage summaries (`UsageSummary`) and commits them to the brain, once and
/// only when a count changed. Run by `akit insights publish` and `akit sync` (import, publish,
/// then pull and push), never by the hourly import. A work Mac commits only its pseudonym's
/// machine file, through `WorkFilter`; its project summaries stay in the local store.
enum SummaryPublisher {
    struct Failure: Error, LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    struct Outcome: Equatable {
        /// The machine file's key: the pseudonym on a work Mac, else the id.
        var key: String
        var isWork: Bool
        var message: String
        /// Brain paths written or removed (to be, on a dry run).
        var changed: [String] = []
        /// Brain paths in the commit; empty when nothing was committed.
        var committed: [String] = []
        /// Files outside the brain written or removed: a work Mac's project summaries.
        var local: [String] = []
        var dryRun = false
        /// Said to the user after the result, e.g. a step left for the next publish.
        var notes: [String] = []
    }

    static func publish(env: HarnessEnvironment, brain: Brain, database: IndexDatabase, hostName: String, hardware: String?,
                        dryRun: Bool = false, bindings: BindingSet = .default, now: Date = Date(),
                        calendar: Calendar = .current) async throws(Failure) -> Outcome {
        let home = env.homeDirectory, root = brain.root, fm = FileManager.default
        var profile = MachineProfile.load(home: home)
        if let problem = profile.problem { throw Failure(message: "\(problem) Nothing was published.") }
        let own = UsageSummary.ownKeys(database)
        let before = profile
        // Never saved while machine.json is broken (refused above).
        if profile.identify(hardware: hardware, own: own, now: now), !dryRun {
            do {
                try profile.save(home: home)
            } catch {
                throw Failure(message: "Couldn't save \(MachineProfile.file(home: home).path): \(error.localizedDescription)")
            }
        }
        guard let id = profile.id, let key = profile.summaryKey else { throw Failure(message: "This Mac has no summary key yet.") }
        var host = hostName
        if host.hasSuffix(".local") { host.removeLast(".local".count) }
        let name = profile.name ?? host
        var outcome = Outcome(key: key, isWork: profile.isWork, message: "Update usage summaries (\(profile.isWork ? key : name))",
                              dryRun: dryRun)
        if profile.isWork {
            do {
                try await WorkFilter.preflight(brain: root, machine: profile, env: env)
            } catch {
                throw Failure(message: error.message)
            }
        }

        // What changes: brain files by path, local files by URL, removals.
        var brainWrites: [String: Data] = [:]
        var localWrites: [URL: Data] = [:]
        var removals: [URL] = []
        let machinePath = UsageSummary.machinePath(key)
        let store = ProjectStore.current(brain: root, home: home, machine: profile)
        do {
            let existing = UsageSummary.read(root.appending(path: machinePath))
            if let file = try UsageSummary.machineFile(database, profile: profile, name: name, brainSkills: Set(brain.skills.map(\.name)),
                                                       existing: existing, now: now, calendar: calendar),
               existing != nil || !file.days.isEmpty || file.descHashes?.isEmpty == false,  // nothing to say yet
               !file.sameContent(as: existing) {
                brainWrites[machinePath] = UsageSummary.encode(file)
            }
            let projects = Set(try UsageSummary.boundProjects(database, bindings: bindings))
                .union(UsageSummary.projectsWithFile(of: id, in: store))
            for project in projects.sorted() {
                let url = UsageSummary.projectURL(project, key: id, in: store)
                let old = UsageSummary.read(url)
                guard let file = try UsageSummary.projectFile(database, project: project, profile: profile, existing: old,
                                                              bindings: bindings, now: now, calendar: calendar) else { continue }
                if file.days.isEmpty {
                    if fm.fileExists(atPath: url.path) { removals.append(url) }
                } else if !file.sameContent(as: old) {
                    if store.isLocal { localWrites[url] = UsageSummary.encode(file) }
                    else { brainWrites["projects/\(project)/usage/\(id).json"] = UsageSummary.encode(file) }
                }
            }
        } catch {
            throw Failure(message: "Couldn't read the session index: \(error.localizedDescription)")
        }
        // A personal Mac whose id changed: its files under older ids leave in the same commit,
        // so other Macs never count those days twice. Only ids this hardware published: a clone's
        // copied index also lists the original Mac's, whose files stay.
        var stalePaths: [String] = []
        if !profile.isWork {
            for old in own.published(by: profile.hardwareHash, cloned: profile.idSince != nil).ids where old != id {
                if fm.fileExists(atPath: root.appending(path: UsageSummary.machinePath(old)).path) {
                    stalePaths.append(UsageSummary.machinePath(old))
                }
                stalePaths += UsageSummary.projectsWithFile(of: old, in: .brain(root)).map { "projects/\($0)/usage/\(old).json" }
            }
        }
        removals += stalePaths.map { root.appending(path: $0) }

        let rootPath = root.standardizedFileURL.path + "/"
        func brainPath(_ url: URL) -> String? {
            let path = url.standardizedFileURL.path
            return path.hasPrefix(rootPath) ? String(path.dropFirst(rootPath.count)) : nil
        }
        outcome.changed = (brainWrites.keys + removals.compactMap(brainPath)).sorted()
        outcome.local = (localWrites.keys + removals.filter { brainPath($0) == nil }).map(\.path).sorted()
        if dryRun { return placeholders(outcome, id: id, pseudonym: profile.pseudonym, before: before, own: own) }

        do {
            for (url, data) in localWrites {
                try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: url, options: .atomic)
            }
            for url in removals where brainPath(url) == nil { try fm.removeItem(at: url) }
        } catch {
            throw Failure(message: "Couldn't write the project summaries on this Mac: \(error.localizedDescription)")
        }

        if profile.isWork {
            if let data = brainWrites[machinePath] {
                do {
                    if try await WorkFilter.commit(.summary(pseudonym: key, brainSkills: Set(brain.skills.map(\.name))),
                                                   files: [machinePath: data], message: outcome.message, brain: root,
                                                   machine: profile, env: env) {
                        outcome.committed = [machinePath]
                    }
                } catch {
                    throw Failure(message: error.message)
                }
            }
        } else {
            do {
                for (path, data) in brainWrites {
                    let url = root.appending(path: path)
                    try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try data.write(to: url, options: .atomic)
                }
                for url in removals where brainPath(url) != nil { try fm.removeItem(at: url) }
            } catch {
                throw Failure(message: "Couldn't write the summaries into the brain: \(error.localizedDescription)")
            }
            if fm.fileExists(atPath: root.appending(path: ".git").path) {
                // Own key files git sees as changed, also ones a failed earlier publish left uncommitted.
                let specs = [machinePath, ":(glob)projects/**/usage/\(id).json"] + stalePaths
                let status = try await git(["-c", "core.quotePath=false", "status", "--porcelain", "-z", "--no-renames",
                                            "--untracked-files=all", "--"] + specs, in: root, env: env)
                // "XY path" entries; anything else (a warning on stderr) is not a path.
                let paths = status.split(separator: "\0").filter { $0.count > 3 && Array($0)[2] == " " }
                    .map { String($0.dropFirst(3)) }.sorted()
                if !paths.isEmpty {
                    try await git(["add", "--all", "--"] + paths, in: root, env: env)
                    try await git(["commit", "--quiet", "-m", outcome.message, "--"] + paths, in: root, env: env)
                    outcome.committed = paths
                }
            }
        }
        // A running import (launchd) may hold the index for a while: then the keys are remembered next time.
        do {
            if let lock = try ImportLock.acquire(InsightsPaths(env: env).lock) {
                try withExtendedLifetime(lock) {
                    try UsageSummary.remember(id: id, pseudonym: profile.isWork ? key : nil, hardware: profile.hardwareHash,
                                              since: profile.idSince, in: database)
                }
            } else {
                outcome.notes.append("An import is running, so this Mac's keys are remembered in the index on the next publish.")
            }
        } catch {
            throw Failure(message: "Published, but couldn't remember this Mac's keys in the index: \(error.localizedDescription)")
        }
        return outcome
    }

    static let newID = "<new id>"
    static let newPseudonym = "<new pseudonym>"

    /// A dry run saves nothing, so an id or pseudonym it had to make up is random and differs from
    /// the one the real publish makes: shown as `<new id>` / `<new pseudonym>` instead.
    private static func placeholders(_ outcome: Outcome, id: String, pseudonym: String?, before: MachineProfile,
                                     own: MachineProfile.OwnKeys) -> Outcome {
        var replacements: [(String, String)] = []
        if id != before.id, !own.ids.contains(id) { replacements.append((id, newID)) }
        if let pseudonym, pseudonym != before.pseudonym, !own.pseudonyms.contains(pseudonym) {
            replacements.append((pseudonym, newPseudonym))
        }
        guard !replacements.isEmpty else { return outcome }
        func mask(_ text: String) -> String { replacements.reduce(text) { $0.replacingOccurrences(of: $1.0, with: $1.1) } }
        var masked = outcome
        masked.key = mask(outcome.key)
        masked.message = mask(outcome.message)
        masked.changed = outcome.changed.map(mask)
        masked.local = outcome.local.map(mask)
        return masked
    }

    @discardableResult
    private static func git(_ arguments: [String], in root: URL, env: HarnessEnvironment) async throws(Failure) -> String {
        guard let git = env.findExecutable("git") else { throw Failure(message: "Written, but git was not found, so nothing was committed.") }
        let environment = env.variables.merging(["PATH": env.pathForChildProcesses, "GIT_TERMINAL_PROMPT": "0"]) { $1 }
        let result = await ProcessRunner.run(git, arguments: arguments, directory: root, environment: environment, timeout: 30)
        guard let result, result.succeeded else {
            let output = result.map { $0.timedOut ? "timed out" : $0.output.trimmingCharacters(in: .whitespacesAndNewlines) } ?? "couldn't start git"
            throw Failure(message: "Written, but git \(arguments.first { !$0.hasPrefix("-") && !$0.contains("=") } ?? "") failed: \(output)")
        }
        return result.output
    }
}
