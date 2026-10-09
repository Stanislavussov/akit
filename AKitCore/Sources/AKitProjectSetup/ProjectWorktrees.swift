import AKitBrain
import AKitFoundation
import Foundation

/// The git worktrees of a local-only project (layers.md, "Local-only files and git worktrees"):
/// git checks out only tracked files, so each unit of AKit's `info/exclude` block becomes, in
/// every other worktree, a symbolic link to the same path in the main checkout. The block is
/// the list of units. AKit only creates links where nothing is, and removes only links that
/// point into the main checkout; never a file or a folder.
public enum ProjectWorktrees {
    public struct Link: Hashable, Sendable {
        public enum State: String, Hashable, Sendable {
            /// The link to the main checkout is there.
            case linked
            /// Nothing at the path: sync creates the link.
            case missing
            /// Something else is at the path (the branch has its own file or skill, another
            /// link, a file in the way of a parent folder): left alone.
            case conflict
            /// A link into the main checkout whose path is no longer a unit: sync removes it.
            case stale
        }

        /// The path in the worktree, the same as in the main checkout (`.agents/skills/tdd`).
        public let path: String
        public let state: State
    }

    public struct Worktree: Hashable, Sendable, Identifiable {
        public var id: String { folder.path }
        public let folder: URL
        /// `main`; nil for a detached HEAD.
        public let branch: String?
        /// Every unit's state, then the stale links.
        public let links: [Link]

        /// Units a sync would link.
        public var lacks: [String] { links.filter { $0.state == .missing }.map(\.path) }
        public var conflicts: [String] { links.filter { $0.state == .conflict }.map(\.path) }
        public var stale: [String] { links.filter { $0.state == .stale }.map(\.path) }
        /// A sync would change something here.
        public var needsSync: Bool { links.contains { $0.state == .missing || $0.state == .stale } }
    }

    public struct Status: Hashable, Sendable {
        /// The main checkout, as git names it.
        public let main: URL
        /// The units of AKit's block that exist in the main checkout.
        public let units: [String]
        /// The other worktrees whose folder exists (not bare, not prunable).
        public let worktrees: [Worktree]

        public var needsSync: Bool { worktrees.contains(where: \.needsSync) }
    }

    public struct Outcome: Hashable, Sendable {
        /// Links made and removed, as `<worktree folder>/<path>`.
        public var created: [String] = []
        public var removed: [String] = []
        /// Paths left alone because something else is there.
        public var conflicts: [String] = []
        /// What went wrong (a link that couldn't be made, git didn't run).
        public var problems: [String] = []

        public var changed: Bool { !created.isEmpty || !removed.isEmpty }
    }

    // MARK: - Status

    /// The worktrees of the project whose main checkout is `project`, and what each lacks.
    /// nil when `project` is not the top of a main checkout, or AKit's block is broken. Only
    /// reads: one `git worktree list`, and none when the repository has no other worktree.
    public static func status(of project: URL, env: HarnessEnvironment) -> Status? {
        status(of: project, dropped: [], env: env)
    }

    /// `dropped`: units an Apply just took out of the block; their links count as stale too.
    static func status(of project: URL, dropped: [String], env: HarnessEnvironment) -> Status? {
        guard let checkout = GitCheckout.at(project), !checkout.isLinkedWorktree,
              !LocalOnly.blockIsBroken(in: checkout.excludeFile) else { return nil }
        let main = URL(filePath: realPath(project.standardizedFileURL.path), directoryHint: .isDirectory)
        let units = (LocalOnly.blockUnits(in: checkout.excludeFile) ?? []).filter { exists(main.path + "/" + $0) }
        let mainSpellings = Set([main.path, project.standardizedFileURL.path])
        let worktrees = linkedWorktrees(of: checkout, main: mainSpellings, env: env).map { tree in
            Worktree(folder: tree.folder, branch: tree.branch,
                     links: links(in: tree.folder.path, units: units, dropped: dropped, main: mainSpellings))
        }
        return Status(main: main, units: units, worktrees: worktrees)
    }

    // MARK: - Sync

    /// Creates the missing links in every worktree and removes the stale ones (and those of
    /// `dropped` units). Parent folders are made as real folders.
    public static func sync(_ project: URL, env: HarnessEnvironment) -> Outcome {
        sync(project, dropped: [], env: env)
    }

    static func sync(_ project: URL, dropped: [String], env: HarnessEnvironment) -> Outcome {
        var outcome = Outcome()
        guard let status = status(of: project, dropped: dropped, env: env) else { return outcome }
        let fm = FileManager.default
        for tree in status.worktrees {
            for link in tree.links {
                let path = tree.folder.path + "/" + link.path
                switch link.state {
                case .linked:
                    continue
                case .conflict:
                    outcome.conflicts.append(path)
                case .stale:
                    // Checked again right before: only a link into the main checkout goes.
                    guard let destination = try? fm.destinationOfSymbolicLink(atPath: path),
                          inside(destination, linkFolder: (path as NSString).deletingLastPathComponent,
                                 main: [status.main.path, project.standardizedFileURL.path]) != nil else { continue }
                    do {
                        try fm.removeItem(atPath: path)
                        outcome.removed.append(path)
                    } catch {
                        outcome.problems.append("Couldn't remove the link \(path): \(error.localizedDescription)")
                    }
                case .missing:
                    do {
                        try makeParents(of: link.path, in: tree.folder.path)
                        try fm.createSymbolicLink(atPath: path, withDestinationPath: status.main.path + "/" + link.path)
                        outcome.created.append(path)
                    } catch {
                        outcome.problems.append("Couldn't link \(path): \(error.localizedDescription)")
                    }
                }
            }
        }
        return outcome
    }

    // MARK: - Pieces

    struct Listed {
        let folder: URL
        let branch: String?
    }

    /// `git worktree list --porcelain -z` in the main checkout, without the main one, bare ones,
    /// prunable ones and folders that are gone. No git run when the repository has no
    /// `worktrees` folder.
    static func linkedWorktrees(of checkout: GitCheckout, main: Set<String>, env: HarnessEnvironment) -> [Listed] {
        let records = checkout.commonDir.appending(path: "worktrees").path
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: records), !names.isEmpty else { return [] }
        let git = env.findExecutable("git") ?? URL(filePath: "/usr/bin/git")
        guard let result = ProcessRunner.runAndWait(git, arguments: ["-C", checkout.folder.path, "worktree", "list", "--porcelain", "-z"],
                                                    environment: env.gitVariables, timeout: 15),
              result.succeeded else { return [] }
        var listed: [Listed] = []
        var folder: String?, branch: String?, skip = false
        func close() {
            if let folder, !skip, !main.contains(folder), !main.contains(realPath(folder)), FileWalk.isDirectory(URL(filePath: folder)) {
                listed.append(Listed(folder: URL(filePath: folder, directoryHint: .isDirectory), branch: branch))
            }
            folder = nil
            branch = nil
            skip = false
        }
        for item in result.output.split(separator: "\0", omittingEmptySubsequences: false).map(String.init) {
            if item.hasPrefix("worktree ") {
                close()
                folder = String(item.dropFirst("worktree ".count))
            } else if item.hasPrefix("branch ") {
                let ref = item.dropFirst("branch ".count)
                branch = ref.hasPrefix("refs/heads/") ? String(ref.dropFirst("refs/heads/".count)) : String(ref)
            } else if item == "bare" || item == "prunable" || item.hasPrefix("prunable ") {
                skip = true
            }
        }
        close()
        // The first record is the main checkout, whatever its spelling.
        return listed.filter { realPath($0.folder.path) != realPath(checkout.folder.path) }
    }

    /// Each unit's state in one worktree, then its stale links: a link into the main checkout
    /// at the same path, in `.agents/skills`, at `.claude/skills`, or at a dropped unit.
    static func links(in tree: String, units: [String], dropped: [String], main: Set<String>) -> [Link] {
        let fm = FileManager.default
        var links = units.map { unit in Link(path: unit, state: state(of: unit, in: tree, main: main)) }
        let unitSet = Set(units)
        var candidates = Set(dropped + [".claude/skills"])
        let skills = tree + "/" + ProjectBundle.skillsFolder
        if isRealFolder(tree + "/.agents"), isRealFolder(skills) {
            for name in (try? fm.contentsOfDirectory(atPath: skills)) ?? [] { candidates.insert(ProjectBundle.skillsFolder + "/" + name) }
        }
        for path in candidates.subtracting(unitSet).sorted() where !path.split(separator: "/").contains("..") {
            let full = tree + "/" + path
            guard let destination = try? fm.destinationOfSymbolicLink(atPath: full),
                  inside(destination, linkFolder: (full as NSString).deletingLastPathComponent, main: main) == path else { continue }
            links.append(Link(path: path, state: .stale))
        }
        return links
    }

    static func state(of unit: String, in tree: String, main: Set<String>) -> Link.State {
        let path = tree + "/" + unit
        if let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: path) {
            return inside(destination, linkFolder: (path as NSString).deletingLastPathComponent, main: main) == unit ? .linked : .conflict
        }
        if exists(path) { return .conflict }
        // Every parent that is there must be a real folder (not a link out of the worktree).
        var parent = tree
        for component in unit.split(separator: "/").dropLast() {
            parent += "/" + component
            if exists(parent), !isRealFolder(parent) { return .conflict }
        }
        return .missing
    }

    /// A link's destination as a path inside the main checkout (`.agents/skills/tdd`); nil when
    /// it points elsewhere.
    static func inside(_ destination: String, linkFolder: String, main: Set<String>) -> String? {
        let absolute = destination.hasPrefix("/") ? destination : linkFolder + "/" + destination
        let path = (absolute as NSString).standardizingPath
        for base in main.flatMap({ [$0, ($0 as NSString).standardizingPath] }) where path.hasPrefix(base + "/") {
            return String(path.dropFirst(base.count + 1))
        }
        return nil
    }

    private static func makeParents(of unit: String, in tree: String) throws {
        var parent = tree
        for component in unit.split(separator: "/").dropLast() {
            parent += "/" + component
            if !exists(parent) { try FileManager.default.createDirectory(atPath: parent, withIntermediateDirectories: false) }
        }
    }

    /// Something is at the path, a broken link included.
    private static func exists(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0
    }

    private static func isRealFolder(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0 && info.st_mode & S_IFMT == S_IFDIR
    }

    /// The path with links resolved (`/var` → `/private/var`), as git prints worktree folders.
    static func realPath(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}
