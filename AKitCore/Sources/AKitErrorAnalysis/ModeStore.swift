import AKitBrain
import AKitFoundation
import Darwin
import Foundation

/// The list of modes and their exemplars (`docs/design/error-analysis.md`, "Modes" and
/// "Storage"). `~/.akit/lab/analysis/` is a local git repository with no remote that tracks
/// `modes/` only, so every change to the list is a commit and its history can be read back,
/// while notes and quotes outside `modes/` never enter it.
///
/// Every change runs under a file lock, so the app and `akit` can't interleave their writes.
/// The first use creates the repository and installs the seeds.
public struct ModeStore: Sendable {
    public struct Failure: Error, LocalizedError {
        public let message: String
        public var errorDescription: String? { message }
    }

    /// Exemplars per mode: they go into every matching call, so a few familiar ones are enough.
    public static let maxExemplars = 3

    let env: HarnessEnvironment
    let paths: AnalysisPaths

    public init(env: HarnessEnvironment) {
        self.env = env
        paths = AnalysisPaths(env: env)
    }

    // MARK: Reading

    /// Every mode, merged and rejected ones included, sorted by id.
    public func list() async throws -> [Mode] {
        try await locked { try await prepare() }
    }

    public func mode(_ id: String) async throws -> Mode? {
        try await list().first { $0.id == id }
    }

    /// Names of rejected modes, for prompts: the model isn't offered them again.
    public func rejectedNames() async throws -> [String] {
        try await list().filter { $0.status == .rejected }.map(\.name).sorted()
    }

    /// The mode a result for `id` counts for today, following merges.
    public func resolve(_ id: String) async throws -> String {
        Self.resolve(id, in: try await list())
    }

    /// Follows `mergedInto` until a mode that wasn't merged, so past results are recounted
    /// through merges. A cycle can't be made through `merge`, but a hand-edited file could
    /// hold one; the walk stops at the first repeat.
    public static func resolve(_ id: String, in modes: [Mode]) -> String {
        let byID = Dictionary(modes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var current = id
        var seen: Set<String> = [id]
        while let next = byID[current]?.mergedInto, seen.insert(next).inserted { current = next }
        return current
    }

    /// Exemplars of one mode, oldest first.
    public func exemplars(of modeID: String) throws -> [Exemplar] {
        let file = exemplarsFile(modeID)
        guard let data = try? Data(contentsOf: file) else { return [] }
        do { return try AnalysisJSON.decoder.decode([Exemplar].self, from: data) } catch {
            throw Failure(message: "\(file.path) can't be read: \(error.localizedDescription)")
        }
    }

    /// The newest commits of the modes repository: what changed in the list, and when.
    public func history(limit: Int = 50) async throws -> [(date: Date, message: String)] {
        try await locked {
            _ = try await prepare()
            let output = try await git(["log", "-n", String(max(limit, 1)), "--format=%at%x09%s"])
            return output.split(separator: "\n").compactMap { line in
                let parts = line.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
                guard parts.count == 2, let seconds = TimeInterval(parts[0]) else { return nil }
                return (Date(timeIntervalSince1970: seconds), String(parts[1]))
            }
        }
    }

    // MARK: Changing the list

    /// Adds a mode at version 1. An emergent mode starts as a candidate.
    @discardableResult
    public func create(_ mode: Mode) async throws -> Mode {
        try await change { modes in
            try Self.validate(new: mode, among: modes)
            var mode = mode
            mode.version = 1
            mode.mergedInto = nil
            if mode.origin == .emergent { mode.status = .candidate }
            if !mode.kind.takesFixes { mode.fix = nil }
            modes.append(mode)
            return (mode, "Add mode \(mode.id): \"\(mode.name)\"")
        }
    }

    /// A new name; the id stays, so results and exemplars keep pointing at the mode.
    @discardableResult
    public func rename(_ id: String, to name: String) async throws -> Mode {
        try await change { modes in
            let index = try Self.index(of: id, in: modes)
            let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { throw Failure(message: "A mode needs a name.") }
            let old = modes[index].name
            guard name != old else { return (modes[index], nil) }
            if let other = modes.first(where: { $0.id != id && $0.isCurrent && $0.name.lowercased() == name.lowercased() }) {
                throw Failure(message: "Mode \(other.id) is already called \"\(other.name)\".")
            }
            modes[index].name = name
            return (modes[index], "Rename mode \(id): \"\(old)\" → \"\(name)\"")
        }
    }

    /// Changes what the mode means. A change to the definition, the criteria or the kind
    /// bumps the version and invalidates the mode's test metrics (criteria drift); the fault
    /// layer only labels the mode and doesn't. nil leaves a field as it is.
    @discardableResult
    public func edit(_ id: String, definition: String? = nil, include: [String]? = nil, exclude: [String]? = nil,
                     kind: Mode.Kind? = nil, faultLayer: FaultLayer? = nil) async throws -> ModeChange {
        try await change { modes in
            let index = try Self.index(of: id, in: modes)
            var mode = modes[index]
            if let target = mode.mergedInto { throw Failure(message: "Mode \(id) was merged into \(target); edit that one.") }
            var changed: [String] = []
            if let definition, definition != mode.definition {
                guard !definition.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw Failure(message: "A mode needs a definition.")
                }
                mode.definition = definition
                changed.append("definition")
            }
            if let include, include != mode.include { mode.include = include; changed.append("include") }
            if let exclude, exclude != mode.exclude { mode.exclude = exclude; changed.append("exclude") }
            if let kind, kind != mode.kind {
                mode.kind = kind
                if !kind.takesFixes { mode.fix = nil; mode.fixAppliedAt = nil; mode.fixReason = nil }
                changed.append("kind")
            }
            var invalidations: [Invalidation] = []
            if !changed.isEmpty {
                mode.version += 1
                invalidations.append(Invalidation(modeID: id, version: mode.version, reason: "edited " + changed.joined(separator: ", ")))
            }
            if let faultLayer, faultLayer != mode.faultLayer { mode.faultLayer = faultLayer; changed.append("fault layer") }
            guard !changed.isEmpty else { return (ModeChange(modes: [mode], invalidations: []), nil) }
            modes[index] = mode
            return (ModeChange(modes: [mode], invalidations: invalidations),
                    "Edit mode \(id): \(changed.joined(separator: ", ")) (v\(mode.version))")
        }
    }

    /// Narrows or widens where the mode shows. No version bump: scope only filters reports.
    @discardableResult
    public func setScope(_ id: String, _ scope: Mode.Scope) async throws -> Mode {
        try await change { modes in
            let index = try Self.index(of: id, in: modes)
            let old = modes[index].scope
            guard scope != old else { return (modes[index], nil) }
            modes[index].scope = scope
            return (modes[index], "Set scope of mode \(id): \(old) → \(scope)")
        }
    }

    /// Merges `ids` into `target`: they get `mergedInto` and leave the current list, and the
    /// target's version is bumped. Returns the target first, then the merged modes.
    @discardableResult
    public func merge(_ ids: [String], into target: String) async throws -> ModeChange {
        try await change { modes in
            guard !ids.isEmpty else { throw Failure(message: "Pick the modes to merge into \(target).") }
            guard Set(ids).count == ids.count else { throw Failure(message: "A mode is listed twice in the merge.") }
            guard !ids.contains(target) else { throw Failure(message: "Mode \(target) can't be merged into itself.") }
            let targetIndex = try Self.index(of: target, in: modes)
            guard modes[targetIndex].isCurrent else {
                throw Failure(message: "Mode \(target) is merged or rejected; merge into a current mode.")
            }
            var merged: [Mode] = []
            for id in ids {
                let index = try Self.index(of: id, in: modes)
                if let other = modes[index].mergedInto { throw Failure(message: "Mode \(id) was already merged into \(other).") }
                modes[index].mergedInto = target
                merged.append(modes[index])
            }
            modes[targetIndex].version += 1
            let into = modes[targetIndex]
            let list = ids.joined(separator: ", ")
            return (ModeChange(modes: [into] + merged,
                               invalidations: [Invalidation(modeID: target, version: into.version, reason: "merged \(list) into it")]),
                    "Merge modes \(list) into \(target) (v\(into.version))")
        }
    }

    /// Replaces a mode by narrower ones. The new modes start at version 1 with the old one's
    /// origin; the old one is kept, rejected with "split into …", and its version is bumped.
    /// Returns the new modes, then the old one.
    @discardableResult
    public func split(_ id: String, into parts: [Mode]) async throws -> ModeChange {
        try await change { modes in
            let index = try Self.index(of: id, in: modes)
            guard modes[index].isCurrent else { throw Failure(message: "Mode \(id) is merged or rejected; it can't be split.") }
            guard parts.count >= 2 else { throw Failure(message: "Split \(id) into at least two modes.") }
            var created: [Mode] = []
            for part in parts {
                try Self.validate(new: part, among: modes + created)
                var mode = part
                mode.version = 1
                mode.mergedInto = nil
                mode.origin = modes[index].origin
                if mode.status == .rejected { mode.status = .candidate }
                if !mode.kind.takesFixes { mode.fix = nil }
                created.append(mode)
            }
            let list = created.map(\.id).joined(separator: ", ")
            modes[index].status = .rejected
            modes[index].rejectedReason = "split into \(list)"
            modes[index].version += 1
            modes += created
            let old = modes[index]
            return (ModeChange(modes: created + [old],
                               invalidations: [Invalidation(modeID: id, version: old.version, reason: "split into \(list)")]),
                    "Split mode \(id) into \(list)")
        }
    }

    /// Keeps the mode with the reason, so the model isn't offered it again.
    @discardableResult
    public func reject(_ id: String, reason: String) async throws -> Mode {
        try await change { modes in
            let index = try Self.index(of: id, in: modes)
            let reason = reason.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !reason.isEmpty else { throw Failure(message: "Say why mode \(id) is rejected; the reason keeps the model from proposing it again.") }
            guard modes[index].status != .rejected else { throw Failure(message: "Mode \(id) is already rejected.") }
            modes[index].status = .rejected
            modes[index].rejectedReason = reason
            return (modes[index], "Reject mode \(id): \(reason)")
        }
    }

    /// Takes a rejection back: a confirmed mode is active again, a seed inactive, anything
    /// else a candidate.
    @discardableResult
    public func restore(_ id: String) async throws -> Mode {
        try await change { modes in
            let index = try Self.index(of: id, in: modes)
            guard modes[index].status == .rejected else { throw Failure(message: "Mode \(id) isn't rejected.") }
            let mode = modes[index]
            modes[index].status = mode.confirmedAt != nil ? .active : mode.origin.isSeed ? .seedInactive : .candidate
            modes[index].rejectedReason = nil
            return (modes[index], "Restore mode \(id)")
        }
    }

    /// The user confirms a candidate or a seed: it becomes active.
    @discardableResult
    public func confirm(_ id: String, at date: Date = .now) async throws -> Mode {
        try await change { modes in
            let index = try Self.index(of: id, in: modes)
            if let target = modes[index].mergedInto { throw Failure(message: "Mode \(id) was merged into \(target).") }
            switch modes[index].status {
            case .candidate, .seedInactive: break
            case .active: throw Failure(message: "Mode \(id) is already active.")
            case .rejected: throw Failure(message: "Mode \(id) is rejected; restore it first.")
            }
            modes[index].status = .active
            modes[index].confirmedAt = date
            return (modes[index], "Confirm mode \(id)")
        }
    }

    /// Records that a batch run matched a note to the mode (through merges). An inactive seed
    /// with matches from two different batch runs becomes active; ad-hoc matches never come
    /// here. The same run twice counts once.
    @discardableResult
    public func recordBatchMatch(_ id: String, runID: String) async throws -> Mode {
        try await change { modes in
            let resolved = Self.resolve(id, in: modes)
            let index = try Self.index(of: resolved, in: modes)
            guard !modes[index].batchMatches.contains(runID) else { return (modes[index], nil) }
            modes[index].batchMatches.append(runID)
            var message = "Record batch match of mode \(resolved) in run \(runID)"
            if modes[index].status == .seedInactive, Set(modes[index].batchMatches).count >= 2 {
                modes[index].status = .active
                message += "; seed activated"
            }
            return (modes[index], message)
        }
    }

    /// Moves the mode's fix along: open → draft → applied(T) → confirmed / didn't help /
    /// rejected (with a reason). Failure and efficiency modes only. `date` is T for `applied`.
    @discardableResult
    public func setFix(_ id: String, _ status: Mode.FixStatus, reason: String? = nil, at date: Date = .now) async throws -> Mode {
        try await change { modes in
            let index = try Self.index(of: id, in: modes)
            guard modes[index].kind.takesFixes else {
                throw Failure(message: "Mode \(id) is a success mode; fixes apply to failure and efficiency modes.")
            }
            let reason = reason?.trimmingCharacters(in: .whitespacesAndNewlines)
            if status == .rejected, reason?.isEmpty ?? true { throw Failure(message: "Say why the fix for \(id) is rejected.") }
            modes[index].fix = status
            switch status {
            case .open, .draft: modes[index].fixAppliedAt = nil
            case .applied: modes[index].fixAppliedAt = date
            case .confirmed, .didntHelp, .rejected: break
            }
            modes[index].fixReason = status == .rejected ? reason : nil
            return (modes[index], "Set fix of mode \(id): \(status.title)")
        }
    }

    // MARK: Exemplars

    /// Adds an exemplar. A session in a test set never becomes one (pass the keys of every
    /// session in a validation test split), and a mode keeps at most `maxExemplars`.
    @discardableResult
    public func addExemplar(_ exemplar: Exemplar, testSessions: Set<String>) async throws -> [Exemplar] {
        try await change { modes in
            _ = try Self.index(of: exemplar.modeID, in: modes)
            guard !testSessions.contains(exemplar.sessionKey) else {
                throw Failure(message: "Session \(exemplar.sessionKey) is in a test set; it can't be an exemplar, or the test would leak through matching.")
            }
            var list = try exemplars(of: exemplar.modeID)
            if list.contains(where: { $0.sessionKey == exemplar.sessionKey && $0.step == exemplar.step }) { return (list, nil) }
            guard list.count < Self.maxExemplars else {
                throw Failure(message: "Mode \(exemplar.modeID) already has \(Self.maxExemplars) exemplars; remove one first.")
            }
            list.append(exemplar)
            try write(list, of: exemplar.modeID)
            return (list, "Add exemplar to mode \(exemplar.modeID): \(exemplar.sessionKey) #\(exemplar.step)")
        }
    }

    @discardableResult
    public func removeExemplar(_ exemplar: Exemplar) async throws -> [Exemplar] {
        try await change { _ in
            var list = try exemplars(of: exemplar.modeID)
            guard let index = list.firstIndex(where: { $0.sessionKey == exemplar.sessionKey && $0.step == exemplar.step }) else {
                throw Failure(message: "Mode \(exemplar.modeID) has no exemplar from \(exemplar.sessionKey) #\(exemplar.step).")
            }
            list.remove(at: index)
            try write(list, of: exemplar.modeID)
            return (list, "Remove exemplar from mode \(exemplar.modeID): \(exemplar.sessionKey) #\(exemplar.step)")
        }
    }

    // MARK: Files and git

    /// Reads the list under the lock, lets `work` change it, then writes and commits when
    /// `work` returns a commit message (nil = nothing changed).
    private func change<T>(_ work: (inout [Mode]) throws -> (T, String?)) async throws -> T {
        try await locked {
            var modes = try await prepare()
            let (result, message) = try work(&modes)
            if let message {
                try write(modes)
                try await commit(message)
            }
            return result
        }
    }

    /// The repository and the seeds, on first use; then the list as it is on disk.
    private func prepare() async throws -> [Mode] {
        if !FileManager.default.fileExists(atPath: paths.folder.appending(path: ".git").path) {
            try await createRepository()
        }
        var modes = try load()
        // Modes are never deleted, so a seed the user rejected, merged or split stays in the
        // list and is never added again.
        let known = Set(modes.map(\.id))
        let missing = Self.seeds.filter { !known.contains($0.id) }
        if !missing.isEmpty {
            let now = Date.now
            modes += missing.map { seed in
                var seed = seed
                seed.createdAt = now
                return seed
            }
            try write(modes)
            try await commit("Add seed modes")
        }
        return modes.sorted { $0.id < $1.id }
    }

    /// `git init` with an identity of its own (never the global one) and a `.gitignore`
    /// that lets only `modes/` in.
    private func createRepository() async throws {
        try FileManager.default.createDirectory(at: paths.modes, withIntermediateDirectories: true)
        try Data("/*\n!/modes/\n!/.gitignore\n".utf8).write(to: paths.folder.appending(path: ".gitignore"), options: .atomic)
        _ = try await git(["init", "-q"])
        _ = try await git(["config", "--local", "user.name", "AKit"])
        _ = try await git(["config", "--local", "user.email", "akit@localhost"])
        _ = try await git(["config", "--local", "commit.gpgsign", "false"])
        try await commit("Start the modes repository")
    }

    private func load() throws -> [Mode] {
        guard let data = try? Data(contentsOf: paths.modesFile) else { return [] }
        do { return try AnalysisJSON.decoder.decode([Mode].self, from: data) } catch {
            throw Failure(message: "\(paths.modesFile.path) can't be read: \(error.localizedDescription)")
        }
    }

    private func write(_ modes: [Mode]) throws {
        try FileManager.default.createDirectory(at: paths.modes, withIntermediateDirectories: true)
        try AnalysisJSON.encoder.encode(modes.sorted { $0.id < $1.id }).write(to: paths.modesFile, options: .atomic)
    }

    private func exemplarsFile(_ modeID: String) -> URL {
        paths.exemplars.appending(path: AnalysisPaths.fileName(modeID) + ".json")
    }

    /// An empty list removes the file.
    private func write(_ exemplars: [Exemplar], of modeID: String) throws {
        let file = exemplarsFile(modeID)
        guard !exemplars.isEmpty else {
            try? FileManager.default.removeItem(at: file)
            return
        }
        try FileManager.default.createDirectory(at: paths.exemplars, withIntermediateDirectories: true)
        try AnalysisJSON.encoder.encode(exemplars).write(to: file, options: .atomic)
    }

    /// Stages `modes/` and commits it, unless nothing changed.
    private func commit(_ message: String) async throws {
        _ = try await git(["add", "-A", "--", "modes", ".gitignore"])
        guard try await git(["diff", "--cached", "--quiet"], allowedStatuses: [0, 1]).status == 1 else { return }
        // No hooks and no signing from a global config: these are AKit's own commits.
        _ = try await git(BrainGit.noSigning + ["-c", "core.hooksPath=/dev/null", "commit", "-q", "-m", message])
    }

    /// Git in the analysis folder, without the caller's identity or repository variables
    /// (a `GIT_DIR` from a hook would point the commands at another repository).
    @discardableResult
    private func git(_ arguments: [String]) async throws -> String {
        try await git(arguments, allowedStatuses: [0]).output
    }

    private func git(_ arguments: [String], allowedStatuses: Set<Int32>) async throws -> ProcessRunner.Result {
        guard let executable = env.findExecutable("git") else {
            throw Failure(message: "git was not found, so the modes list can't be versioned.")
        }
        let variables = BrainGit.withoutIdentity(env.gitVariables).filter { !$0.key.hasPrefix("GIT_") || $0.key == "GIT_TERMINAL_PROMPT" }
        let result = await ProcessRunner.run(executable, arguments: ["-C", paths.folder.path] + arguments, directory: paths.folder,
                                             environment: variables, timeout: 30)
        guard let result, result.exitedNormally, !result.timedOut, allowedStatuses.contains(result.status) else {
            let detail = result.map(\.failureText) ?? "couldn't start git"
            throw Failure(message: "git \(arguments.first { !$0.hasPrefix("-") } ?? "") failed in \(paths.folder.path): \(detail)")
        }
        return result
    }

    /// An exclusive `flock` on `.modes.lock` next to `modes/` (ignored by the repository).
    /// Waiting sleeps instead of blocking a thread.
    private func locked<T>(_ work: () async throws -> T) async throws -> T {
        try FileManager.default.createDirectory(at: paths.folder, withIntermediateDirectories: true)
        let file = paths.folder.appending(path: ".modes.lock")
        let descriptor = open(file.path, O_CREAT | O_RDWR | O_CLOEXEC, 0o644)
        guard descriptor >= 0 else { throw Failure(message: "Can't open \(file.path).") }
        defer { close(descriptor) }
        while flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
            guard errno == EWOULDBLOCK || errno == EINTR else { throw Failure(message: "Can't lock \(file.path).") }
            try await Task.sleep(for: .milliseconds(50))
        }
        defer { flock(descriptor, LOCK_UN) }
        return try await work()
    }

    // MARK: Checks

    private static func index(of id: String, in modes: [Mode]) throws -> Int {
        guard let index = modes.firstIndex(where: { $0.id == id }) else { throw Failure(message: "There is no mode \(id).") }
        return index
    }

    /// A slug id that no mode has (rejected and merged ones included), a name and a definition.
    private static func validate(new mode: Mode, among modes: [Mode]) throws {
        guard mode.id.wholeMatch(of: /[a-z0-9]+(-[a-z0-9]+)*/) != nil else {
            throw Failure(message: "Mode id \"\(mode.id)\" isn't a slug: lowercase letters and digits joined by dashes.")
        }
        guard !modes.contains(where: { $0.id == mode.id }) else { throw Failure(message: "There is already a mode \(mode.id).") }
        guard !mode.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw Failure(message: "A mode needs a name.") }
        guard !mode.definition.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw Failure(message: "Mode \(mode.id) needs a definition.")
        }
    }
}
