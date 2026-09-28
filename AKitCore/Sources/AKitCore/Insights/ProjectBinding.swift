import Foundation

/// How a session was tied to its project, most reliable first. Each method has a fixed confidence.
enum BindingMethod: String, CaseIterable, Codable {
    /// The SessionStart hook read the folder's repository while the folder existed.
    case hook
    /// The session's folder still exists.
    case live
    /// `git worktree list` in a known repository still lists the folder (deleted ones until pruned).
    case worktree
    /// A sibling candidate whose repository has the session's git branch.
    case branchConfirmed
    /// Same parent folder as a session bound to a worktree of the repository.
    case sibling
    /// A path template (built in for Orca and herdr, or in `~/.akit/insights.json`) names the
    /// repository: `{repo}` in the path is a deliberate statement, so medium like a git confirmation.
    case template
    /// No project.
    case none

    var confidence: Confidence? {
        switch self {
        case .hook, .live: .exact
        case .worktree: .high
        case .branchConfirmed, .template: .medium
        case .sibling: .low
        case .none: nil
        }
    }
}

enum Confidence: String, CaseIterable, Codable, Comparable {
    case exact, high, medium, low

    private var rank: Int {
        switch self {
        case .exact: 3
        case .high: 2
        case .medium: 1
        case .low: 0
        }
    }

    static func < (lhs: Confidence, rhs: Confidence) -> Bool { lhs.rank < rhs.rank }
}

/// The confidences that count as bound, for `stats`, `recommend` and the binding share.
/// Default: exact, high and medium (git-confirmed or a path template); unconfirmed siblings
/// (low) only with `--bindings exact,high,medium,low`.
struct BindingSet: Equatable {
    struct Failure: Error, LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static let `default` = BindingSet(confidences: [.exact, .high, .medium])

    let confidences: Set<Confidence>

    /// `--bindings LIST`; nil or missing gives the default set.
    static func parse(_ text: String?) throws -> BindingSet {
        guard let text else { return .default }
        var found: Set<Confidence> = []
        for name in text.split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces).lowercased() }) where !name.isEmpty {
            guard let confidence = Confidence(rawValue: name) else {
                throw Failure(message: "Unknown binding confidence “\(name)”. Use a list of exact, high, medium, low.")
            }
            found.insert(confidence)
        }
        guard !found.isEmpty else { throw Failure(message: "--bindings needs at least one of exact, high, medium, low.") }
        return BindingSet(confidences: found)
    }

    /// Most reliable first.
    var names: [String] { Confidence.allCases.filter(confidences.contains).map(\.rawValue) }

    /// `('exact', 'high')` for SQL `IN`: enum raw values only, never user text.
    var sqlList: String { "(" + names.map { "'\($0)'" }.joined(separator: ", ") + ")" }

    func contains(_ confidence: Confidence?) -> Bool { confidence.map(confidences.contains) ?? false }
}

/// A session folder's repository: the project id `ProjectSetup.projectID` would give it and the
/// main repository's git folder (`<repo>/.git`, shared by its worktrees), nil for a plain folder.
struct RepositoryMatch: Equatable {
    let projectID: String
    let repoPath: String?
}

/// "Path → repository or nothing". The seam for tool-specific resolvers (Orca, herdr, …):
/// each answers for one folder, with its fixed method.
protocol ProjectResolver {
    var method: BindingMethod { get }
    func repository(for path: String) -> RepositoryMatch?
}

/// Paths of one repository layout, compared after `canonical`.
enum BindingPaths {
    /// Standardized, without the `/private` of macOS's `/var`, `/tmp` and `/etc` links, so a path
    /// git prints and one a harness logged compare equal whether or not the folder still exists.
    static func canonical(_ path: String) -> String {
        var path = (path as NSString).standardizingPath
        for linked in ["/private/var", "/private/tmp", "/private/etc"] where path == linked || path.hasPrefix(linked + "/") {
            path.removeFirst("/private".count)
        }
        return path
    }

    /// `path` equals `folder` or lies inside it.
    static func isInside(_ path: String, _ folder: String) -> Bool {
        path == folder || path.hasPrefix(folder == "/" ? "/" : folder + "/")
    }

    /// The checkout that owns a common git dir: `<repo>` for `<repo>/.git`, the folder itself for a bare repository.
    static func mainFolder(ofCommonDir commonDir: String) -> String {
        (commonDir as NSString).lastPathComponent == ".git" ? (commonDir as NSString).deletingLastPathComponent : commonDir
    }

    /// The project id of the repository with this common git dir: its `origin` remote, else the
    /// `local/…` id of its main folder, as `ProjectSetup.projectID` gives it.
    static func projectID(commonDir: String, projectsRoot: String) -> String {
        if let remote = RecordSession.small(commonDir + "/config").flatMap(RecordSession.originURL).flatMap(ProjectSetup.normalizedRemote) {
            return remote
        }
        return ProjectSetup.localID(path: canonical(mainFolder(ofCommonDir: commonDir)), projectsRoot: projectsRoot)
    }
}

// MARK: - Resolvers

/// The session's folder still exists: its repository, read from `.git` files like
/// `RecordSession` does (no git process), else the folder itself when it lies under the
/// projects root. Answers are cached per folder for one run.
final class LiveFolderResolver: ProjectResolver {
    let method = BindingMethod.live
    private let projectsRoot: String
    private var cache: [String: RepositoryMatch?] = [:]

    init(projectsRoot: String) { self.projectsRoot = projectsRoot }

    func repository(for path: String) -> RepositoryMatch? {
        if let cached = cache[path] { return cached }
        let found = resolve(path)
        cache[path] = found
        return found
    }

    private func resolve(_ path: String) -> RepositoryMatch? {
        var isFolder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isFolder), isFolder.boolValue else { return nil }
        if let repository = RecordSession.repository(containing: path) {
            let common = BindingPaths.canonical(repository.commonDir)
            let id = repository.remoteID
                ?? ProjectSetup.localID(path: BindingPaths.mainFolder(ofCommonDir: common), projectsRoot: projectsRoot)
            return RepositoryMatch(projectID: id, repoPath: common)
        }
        // A folder without git is a project only inside the projects root (not ~, not /tmp).
        let folder = BindingPaths.canonical(path)
        guard folder.hasPrefix(projectsRoot + "/") else { return nil }
        return RepositoryMatch(projectID: ProjectSetup.localID(path: folder, projectsRoot: projectsRoot), repoPath: nil)
    }
}

/// Folders `git worktree list --porcelain` printed in known repositories, deleted ones included
/// until git prunes them. A folder inside a listed worktree belongs to that repository; the
/// deepest listed folder wins.
struct WorktreeListResolver: ProjectResolver {
    let method = BindingMethod.worktree
    /// Folders never taken as a worktree: the home folder, the projects root and everything above them.
    let excluded: [String]
    private(set) var worktrees: [String: RepositoryMatch] = [:]

    init(excluded: [String]) { self.excluded = excluded }

    mutating func add(porcelain: String, repository: RepositoryMatch) {
        for path in Self.paths(inPorcelain: porcelain) {
            let folder = BindingPaths.canonical(path)
            guard !excluded.contains(where: { BindingPaths.isInside($0, folder) }) else { continue }
            worktrees[folder] = repository
        }
    }

    /// `worktree <path>` lines; `prunable` and other attribute lines don't matter here.
    static func paths(inPorcelain text: String) -> [String] {
        text.split(whereSeparator: \.isNewline).compactMap { line in
            line.hasPrefix("worktree /") ? String(line.dropFirst("worktree ".count)) : nil
        }
    }

    func repository(for path: String) -> RepositoryMatch? {
        let folder = BindingPaths.canonical(path)
        return worktrees.filter { BindingPaths.isInside(folder, $0.key) }.max { $0.key.count < $1.key.count }?.value
    }
}

/// Worktree folders of agent workspaces: the built-in ones (Orca, herdr) plus
/// `"pathTemplates": ["~/.tool/trees/{repo}/*"]` in `~/.akit/insights.json`. A folder matching a
/// template belongs to the one known repository named `{repo}` (its folder name or the last part
/// of its remote id). `*` is any one folder name; deeper folders match too.
struct PathTemplateResolver: ProjectResolver {
    static let builtIn = ["~/orca/workspaces/{repo}/*", "~/.herdr/worktrees/{repo}/*"]

    let method = BindingMethod.template
    /// Each template's path components, `~` expanded.
    let templates: [[String]]
    /// Known repositories by lowercased name.
    let repositories: [String: [RepositoryMatch]]

    init(templates: [String], home: String, repositories: [RepositoryMatch]) {
        self.templates = templates.compactMap { template in
            let expanded = template.hasPrefix("~/") ? home + template.dropFirst(1) : template
            guard expanded.hasPrefix("/") else { return nil }
            let parts = BindingPaths.canonical(expanded).split(separator: "/").map(String.init)
            return parts.filter { $0 == "{repo}" }.count == 1 ? parts : nil
        }
        var byName: [String: [RepositoryMatch]] = [:]
        for repository in repositories {
            guard let common = repository.repoPath else { continue }
            let folder = (BindingPaths.mainFolder(ofCommonDir: common) as NSString).lastPathComponent.lowercased()
            let remote = repository.projectID.hasPrefix("local/") ? nil : repository.projectID.split(separator: "/").last.map(String.init)
            for name in Set([folder, remote].compactMap { $0 }) { byName[name, default: []].append(repository) }
        }
        self.repositories = byName
    }

    func repository(for path: String) -> RepositoryMatch? {
        let parts = BindingPaths.canonical(path).split(separator: "/").map(String.init)
        for template in templates where parts.count >= template.count {
            var name: String?
            let matches = zip(template, parts).allSatisfy { pattern, part in
                if pattern == "{repo}" { name = part.lowercased(); return true }
                return pattern == "*" || pattern == part
            }
            if matches, let name, let found = ProjectBinder.unique(repositories[name] ?? []) { return found }
        }
        return nil
    }
}

/// A folder next to worktrees of one repository (`<root>/<repo>/<branch>`) probably is one
/// too. Only sessions bound exact or high to a folder outside their repository's main
/// checkout count, and never parents like the home folder or the projects root, where
/// neighbours are different repositories.
struct SiblingResolver: ProjectResolver {
    let method = BindingMethod.sibling
    let parents: [String: [RepositoryMatch]]

    /// `bound`: session folders with their exact or high repository.
    init(bound: [(cwd: String, repository: RepositoryMatch)], excluded: [String]) {
        var parents: [String: [RepositoryMatch]] = [:]
        for (cwd, repository) in bound {
            guard let common = repository.repoPath else { continue }
            let folder = BindingPaths.canonical(cwd)
            guard !BindingPaths.isInside(folder, BindingPaths.mainFolder(ofCommonDir: common)) else { continue }
            let parent = (folder as NSString).deletingLastPathComponent
            guard parent != folder, !excluded.contains(where: { BindingPaths.isInside($0, parent) }) else { continue }
            parents[parent, default: []].append(repository)
        }
        self.parents = parents
    }

    func repository(for path: String) -> RepositoryMatch? {
        let folder = BindingPaths.canonical(path)
        return ProjectBinder.unique(parents[(folder as NSString).deletingLastPathComponent] ?? [])
    }
}

/// A low candidate becomes `branchConfirmed` when its repository knows the Claude session's
/// git branch: a local branch (loose, packed or with a reflog) or a remote-tracking one, read
/// from the files (`git rev-parse --verify` only for a reftable repository). The
/// main checkout's branch, `main`, `master` and `HEAD` confirm nothing (every repository has them).
enum BranchConfirmation {
    /// The branch can confirm this repository at all.
    static func isTelling(_ branch: String, commonDir: String) -> Bool {
        let parts = branch.split(separator: "/", omittingEmptySubsequences: false)
        guard !branch.isEmpty, branch.count <= 255, !branch.hasPrefix("-"), !["HEAD", "main", "master"].contains(branch),
              !parts.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }),
              !branch.contains(where: { $0.isNewline || $0 == "\0" || $0 == " " }) else { return false }
        let head = RecordSession.small(commonDir + "/HEAD")?.trimmingCharacters(in: .whitespacesAndNewlines)
        return head != "ref: refs/heads/" + branch
    }

    /// From the repository's files: no git process.
    static func knows(_ branch: String, commonDir: String) -> Bool {
        let fm = FileManager.default
        for path in ["refs/heads/", "logs/refs/heads/"] where fm.fileExists(atPath: commonDir + "/" + path + branch) {
            return true
        }
        let remotes = commonDir + "/refs/remotes"
        for remote in (try? fm.contentsOfDirectory(atPath: remotes)) ?? [] where fm.fileExists(atPath: "\(remotes)/\(remote)/\(branch)") {
            return true
        }
        guard let packed = RecordSession.small(commonDir + "/packed-refs", limit: 16 << 20) else { return false }
        return packed.split(whereSeparator: \.isNewline).contains { line in
            guard let space = line.firstIndex(of: " ") else { return false }
            let ref = line[line.index(after: space)...]
            if ref == "refs/heads/" + branch { return true }
            // refs/remotes/<remote>/<branch>
            guard ref.hasPrefix("refs/remotes/") else { return false }
            let rest = ref.dropFirst("refs/remotes/".count)
            return rest.split(separator: "/", maxSplits: 1).last.map { String($0) == branch } ?? false
        }
    }
}

// MARK: - Binder

/// Binds sessions to projects after the facts of an import (`bindings`, local only). Resolvers
/// in order, each with a fixed confidence: the session's hook event (exact), its folder when it
/// still exists (exact), `git worktree list` in known repositories (high), then a path template
/// (medium) and sibling candidates (low, raised to `branchConfirmed`, medium, when the candidate
/// knows the session's git branch); otherwise no project.
///
/// Decided again only: sessions without a binding, bound none or low, bound by an older
/// resolver, or with a hook event and another method. A new decision never lowers a
/// binding's confidence (a folder deleted since keeps its live binding).
///
/// Git costs at most `gitBudget` seconds per run (`callTimeout` per call, both cut to an
/// optional deadline). Sessions that wait for a worktree list not read yet stay as they are,
/// and the next run goes on with the repositories this one didn't reach.
struct ProjectBinder {
    /// Bump when a resolver decides differently; every binding is decided again (never lower).
    static let resolverVersion = 2
    static let gitBudget: TimeInterval = 10
    static let callTimeout: TimeInterval = 5
    /// `meta` key: the first repository whose worktree list the last run didn't reach.
    static let cursorKey = "bindingWorktreeCursor"

    struct Report: Equatable {
        /// Bindings added or changed.
        var changed = 0
        /// Sessions left for the next run (deadline or git budget).
        var pending = 0
    }

    let env: HarnessEnvironment
    /// Canonical path of the projects root (`local/…` ids are relative to it).
    let projectsRoot: String
    var run: CommandRunner
    var gitBudget = Self.gitBudget
    var callTimeout = Self.callTimeout
    /// Measures git time and the deadline; replaced in tests.
    var clock: () -> Date = { Date() }

    init(env: HarnessEnvironment, projectsRoot: URL, run: CommandRunner? = nil) {
        self.env = env
        self.projectsRoot = BindingPaths.canonical(projectsRoot.path)
        self.run = run ?? CaptureInstaller.liveRunner(env)
    }

    /// One distinct project among `candidates`, else nil (ambiguous or empty).
    static func unique(_ candidates: [RepositoryMatch]) -> RepositoryMatch? {
        guard let first = candidates.first, candidates.allSatisfy({ $0.projectID == first.projectID }) else { return nil }
        return first
    }

    private struct Session {
        let key: String
        let harness: String
        let nativeID: String
        let cwd: String?
        let branch: String?
        let old: (projectID: String?, method: String, confidence: Confidence?)?
    }

    private struct Decision {
        let session: Session
        let repository: RepositoryMatch?
        let method: BindingMethod
    }

    /// Git calls within the run's budget.
    private final class Git {
        let binder: ProjectBinder
        let executable: URL?
        let deadline: Date?
        var spent: TimeInterval = 0
        /// A call was skipped for lack of time.
        private(set) var exhausted = false

        init(binder: ProjectBinder, deadline: Date?) {
            self.binder = binder
            executable = binder.env.findExecutable("git")
            self.deadline = deadline
        }

        /// nil when git is missing, couldn't start or there's no time left.
        func run(_ arguments: [String], in folder: String) async -> ProcessRunner.Result? {
            guard let executable else { return nil }
            var left = binder.gitBudget - spent
            if let deadline { left = min(left, deadline.timeIntervalSince(binder.clock())) }
            guard left > 0 else {
                exhausted = true
                return nil
            }
            let start = binder.clock()
            let result = await binder.run(executable, arguments, URL(filePath: folder, directoryHint: .isDirectory),
                                          min(binder.callTimeout, left))
            spent += max(0, binder.clock().timeIntervalSince(start))
            return result
        }
    }

    func bind(database: IndexDatabase, now: Date = Date(), deadline: Date? = nil) async throws -> Report {
        let sessions = try database.rows("""
            SELECT s.key, s.harness, s.native_id, s.cwd, s.git_branch, b.project_id, b.method, b.confidence
            FROM sessions s LEFT JOIN bindings b ON b.session_key = s.key
            WHERE b.session_key IS NULL OR b.method = 'none' OR b.confidence = 'low' OR b.resolver_version < ?
              OR (b.method != 'hook' AND EXISTS(SELECT 1 FROM hook_events h WHERE h.session_id = s.native_id
                  AND h.harness = s.harness AND (h.remote_id IS NOT NULL OR h.common_dir IS NOT NULL)))
            ORDER BY s.started DESC
            """, Self.resolverVersion).compactMap { row -> Session? in
                guard let key = row[0].text, let harness = row[1].text, let native = row[2].text else { return nil }
                return Session(key: key, harness: harness, nativeID: native, cwd: row[3].text, branch: row[4].text,
                               old: row[6].text.map { (row[5].text, $0, row[7].text.flatMap(Confidence.init)) })
            }
        var report = Report()
        guard !sessions.isEmpty else { return report }
        let home = BindingPaths.canonical(env.homeDirectory.path)
        let excluded = [home, projectsRoot]
        let git = Git(binder: self, deadline: deadline)
        var decisions: [Decision] = []

        // Hook events and live folders: no git.
        let live = LiveFolderResolver(projectsRoot: projectsRoot)
        var waiting: [Session] = []
        for (index, session) in sessions.enumerated() {
            if let deadline, clock() >= deadline {
                report.pending += sessions.count - index
                break
            }
            if let hook = try hookRepository(session, database: database) {
                decisions.append(Decision(session: session, repository: hook, method: .hook))
            } else if let cwd = session.cwd, cwd.hasPrefix("/") {
                // A folder left over without its repository (a removed worktree that kept tool
                // files) goes on to the worktree lists, templates and siblings like a deleted one.
                if FileManager.default.fileExists(atPath: cwd), let found = live.repository(for: cwd) {
                    decisions.append(Decision(session: session, repository: found, method: .live))
                } else {
                    waiting.append(session)
                }
            } else {
                decisions.append(Decision(session: session, repository: nil, method: .none))
            }
        }

        // Deleted folders (and ones without a repository): worktree lists of known repositories,
        // then template and sibling candidates.
        var cursor: String?
        if !waiting.isEmpty {
            let repositories = try knownRepositories(database, decided: decisions)
            var worktrees = WorktreeListResolver(excluded: excluded)
            let stored = try database.value("SELECT value FROM meta WHERE key = ?", Self.cursorKey)?.text
            let ordered = repositories.keys.sorted()
            // Start where the last run stopped, then wrap around.
            let start = stored.flatMap { stored in ordered.firstIndex { $0 >= stored } } ?? 0
            var complete = true
            for path in ordered[start...] + ordered[..<start] {
                guard let repository = repositories[path] else { continue }
                let result = await git.run(["worktree", "list", "--porcelain"], in: BindingPaths.mainFolder(ofCommonDir: path))
                if git.exhausted {
                    complete = false
                    cursor = path
                    break
                }
                if let result, result.succeeded { worktrees.add(porcelain: result.output, repository: repository) }
            }
            let bound = try boundFolders(database, decided: decisions)
            let siblings = SiblingResolver(bound: bound, excluded: excluded)
            let templates = PathTemplateResolver(templates: Self.pathTemplates(env: env), home: home, repositories: Array(repositories.values))
            for session in waiting {
                guard let cwd = session.cwd else { continue }
                if let found = worktrees.repository(for: cwd) {
                    decisions.append(Decision(session: session, repository: found, method: .worktree))
                } else if !complete {
                    report.pending += 1
                } else {
                    decisions.append(try await candidate(session, cwd: cwd, resolvers: [templates, siblings], git: git))
                }
            }
        }

        try database.transaction {
            for decision in decisions where try write(decision, database: database, now: now) { report.changed += 1 }
            if let cursor {
                try database.run("INSERT INTO meta(key, value) VALUES(?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                                 Self.cursorKey, cursor)
            } else if !waiting.isEmpty {
                try database.run("DELETE FROM meta WHERE key = ?", Self.cursorKey)
            }
        }
        return report
    }

    /// The first hook event of the session that saw a repository: its remote id, else the
    /// `local/…` id of the repository's main folder.
    private func hookRepository(_ session: Session, database: IndexDatabase) throws -> RepositoryMatch? {
        guard let row = try database.rows("""
            SELECT remote_id, common_dir FROM hook_events WHERE harness = ? AND session_id = ?
              AND (remote_id IS NOT NULL OR common_dir IS NOT NULL) ORDER BY ts LIMIT 1
            """, session.harness, session.nativeID).first else { return nil }
        let common = row[1].text.map(BindingPaths.canonical)
        guard let id = row[0].text
            ?? common.map({ ProjectSetup.localID(path: BindingPaths.mainFolder(ofCommonDir: $0), projectsRoot: projectsRoot) }) else { return nil }
        return RepositoryMatch(projectID: id, repoPath: common)
    }

    /// Repositories whose worktrees may hold deleted folders, by common git dir: from hook
    /// events, exact/high/medium bindings (earlier and this run's) and git repositories directly
    /// under the projects root. Only ones that still exist.
    private func knownRepositories(_ database: IndexDatabase, decided: [Decision]) throws -> [String: RepositoryMatch] {
        var paths = Set(try database.rows("SELECT DISTINCT common_dir FROM hook_events WHERE common_dir IS NOT NULL").compactMap { $0[0].text })
        paths.formUnion(try database.rows("""
            SELECT DISTINCT repo_path FROM bindings WHERE repo_path IS NOT NULL AND confidence IN ('exact', 'high', 'medium')
            """).compactMap { $0[0].text })
        paths.formUnion(decided.compactMap { $0.repository?.repoPath })
        for child in SkillScanner.children(of: URL(filePath: projectsRoot, directoryHint: .isDirectory))
        where FileManager.default.fileExists(atPath: child.appending(path: ".git").path) {
            if let repository = RecordSession.repository(containing: child.path) { paths.insert(repository.commonDir) }
        }
        var found: [String: RepositoryMatch] = [:]
        for path in Set(paths.map(BindingPaths.canonical)) where SkillScanner.isDirectory(URL(filePath: path)) {
            found[path] = RepositoryMatch(projectID: BindingPaths.projectID(commonDir: path, projectsRoot: projectsRoot), repoPath: path)
        }
        return found
    }

    /// Session folders bound exact or high to a repository, for siblings.
    private func boundFolders(_ database: IndexDatabase, decided: [Decision]) throws -> [(cwd: String, repository: RepositoryMatch)] {
        let decidedKeys = Set(decided.map(\.session.key))
        var bound = try database.rows("""
            SELECT s.key, s.cwd, b.project_id, b.repo_path FROM bindings b JOIN sessions s ON s.key = b.session_key
            WHERE b.confidence IN ('exact', 'high') AND b.repo_path IS NOT NULL AND s.cwd IS NOT NULL AND b.project_id IS NOT NULL
            """).compactMap { row -> (cwd: String, repository: RepositoryMatch)? in
                guard let key = row[0].text, !decidedKeys.contains(key), let cwd = row[1].text, let id = row[2].text else { return nil }
                return (cwd, RepositoryMatch(projectID: id, repoPath: row[3].text))
            }
        for decision in decided where decision.method.confidence.map({ $0 >= .high }) == true {
            if let cwd = decision.session.cwd, let repository = decision.repository { bound.append((cwd, repository)) }
        }
        return bound
    }

    /// The built-in templates plus `pathTemplates` of `~/.akit/insights.json`.
    static func pathTemplates(env: HarnessEnvironment) -> [String] {
        guard let data = try? Data(contentsOf: InsightsPaths(env: env).settings),
              let settings = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return PathTemplateResolver.builtIn }
        return PathTemplateResolver.builtIn + (settings["pathTemplates"] as? [String] ?? [])
    }

    /// A template match (medium) first; else a sibling candidate: medium when its repository
    /// knows the session's branch, else low; no candidate is no project.
    private func candidate(_ session: Session, cwd: String, resolvers: [any ProjectResolver], git: Git) async throws -> Decision {
        let candidates = resolvers.compactMap { resolver in resolver.repository(for: cwd).map { (resolver.method, $0) } }
        if let (method, repository) = candidates.first(where: { $0.0 == .template }) {
            return Decision(session: session, repository: repository, method: method)
        }
        if let branch = session.branch {
            for (_, repository) in candidates {
                guard let common = repository.repoPath, BranchConfirmation.isTelling(branch, commonDir: common) else { continue }
                var known = BranchConfirmation.knows(branch, commonDir: common)
                // Refs the files don't show: only git reads a reftable.
                if !known, FileManager.default.fileExists(atPath: common + "/reftable") {
                    let result = await git.run(["rev-parse", "--verify", "--quiet", "refs/heads/" + branch],
                                               in: BindingPaths.mainFolder(ofCommonDir: common))
                    known = result?.succeeded == true
                }
                if known { return Decision(session: session, repository: repository, method: .branchConfirmed) }
            }
        }
        guard let (method, repository) = candidates.first else { return Decision(session: session, repository: nil, method: .none) }
        return Decision(session: session, repository: repository, method: method)
    }

    /// Stores one decision unless it would lower the binding's confidence (then only the
    /// resolver version moves on). Returns whether the binding changed.
    private func write(_ decision: Decision, database: IndexDatabase, now: Date) throws -> Bool {
        let session = decision.session, confidence = decision.method.confidence
        if let kept = session.old?.confidence, confidence.map({ $0 < kept }) ?? true {
            try database.run("UPDATE bindings SET resolver_version = ? WHERE session_key = ?", Self.resolverVersion, session.key)
            return false
        }
        try database.run("""
            INSERT INTO bindings(session_key, project_id, method, confidence, repo_path, decided_at, resolver_version)
            VALUES(?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(session_key) DO UPDATE SET project_id = excluded.project_id, method = excluded.method,
              confidence = excluded.confidence, repo_path = excluded.repo_path, decided_at = excluded.decided_at,
              resolver_version = excluded.resolver_version
            """, session.key, decision.repository?.projectID, decision.method.rawValue, confidence?.rawValue,
            decision.repository?.repoPath, now.timeIntervalSince1970, Self.resolverVersion)
        return session.old.map { $0.projectID != decision.repository?.projectID || $0.method != decision.method.rawValue } ?? true
    }
}
