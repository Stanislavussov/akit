import AKitBrain
import AKitFoundation
import AKitHarnesses
import AKitModel
import AKitProjectSetup
import AKitSkills
import Foundation

/// `akit doctor` and the app's Help → Copy Diagnostics (machine-setup.md): a read-only report
/// of what AKit sees on this Mac and what is wrong. A line starting with `!` is a problem, with
/// what to do. Never a secret: no auth files, tokens, MCP env or header values, or
/// `settings.local.json` are read, a remote shows only as its `host/owner/repo`, and the whole
/// text goes through `SecretFilter.masked` last.
public enum Doctor {
    public struct Input: Sendable {
        public var env: HarnessEnvironment
        public var brainRoot: URL
        /// The projects folders setting (the first one gives ids of projects without a remote).
        public var projectRoots: [URL]
        /// The running app's bundle; nil (the command line): `~/Applications/AKit.app`.
        public var appBundle: URL?
        /// Project id → folder on this Mac, when the caller knows them (the app's Brain screen);
        /// nil: found here from the harnesses' known projects and the projects folders.
        public var projectFolders: [String: URL]?

        public init(env: HarnessEnvironment, brainRoot: URL, projectRoots: [URL], appBundle: URL? = nil,
                    projectFolders: [String: URL]? = nil) {
            self.env = env
            self.brainRoot = brainRoot
            self.projectRoots = projectRoots
            self.appBundle = appBundle
            self.projectFolders = projectFolders
        }
    }

    /// The whole report, plain text. Only reads; runs git and the harnesses' `--version`.
    public static func report(_ input: Input) async -> String {
        let env = input.env
        let home = env.homeDirectory
        // Git names folders with links resolved (`/private/var/…`), so both spellings of home count.
        let homes = Set([home.standardizedFileURL.path, FileWalk.realPath(home) ?? home.path])
        func tilde(_ url: URL) -> String {
            let path = url.standardizedFileURL.path
            for base in homes where path.hasPrefix(base + "/") { return "~" + path.dropFirst(base.count) }
            return path
        }
        var lines = ["AKit doctor (lines starting with ! are problems, with what to do)"]

        // AKit
        lines += ["", "AKit"]
        let app = input.appBundle ?? home.appending(path: "Applications/AKit.app")
        if FileManager.default.fileExists(atPath: app.path) {
            lines.append("  app: \(tilde(app))\(buildText(app, home: home).map { ", \($0)" } ?? "")")
        } else {
            lines.append("! app: \(tilde(app)) is missing; install it with make install in the AKit source folder.")
        }
        let command = home.appending(path: ".local/bin/akit")
        lines.append(FileManager.default.isExecutableFile(atPath: command.path) ? "  command: \(tilde(command))"
                     : "! command: \(tilde(command)) is missing; install it with make install-cli in the AKit source folder.")

        // This Mac
        let machine = MachineProfile.load(home: home)
        let store = ProjectStore.current(brain: input.brainRoot, home: home, machine: machine)
        lines += ["", "This Mac"]
        lines.append("  \(machine.isWork ? "work" : "personal") Mac\(machine.homeName.map { " (home record name: \($0))" } ?? "")")
        if let problem = machine.problem { lines.append("! \(problem)") }
        lines.append("  project records: \(store.isLocal ? "on this Mac only, " : "in the brain, ")\(tilde(store.root))")

        // Brain
        lines += ["", "Brain"]
        let brain = Brain.load(from: input.brainRoot)
        if let brain {
            lines.append("  \(tilde(brain.root)): \(brain.layers.count) layers, \(brain.skills.count) skills")
            if FileManager.default.fileExists(atPath: brain.root.appending(path: ".git").path) {
                let remote = await ProjectRecords.projectID(for: brain.root, projectsRoot: brain.root, env: env)
                lines.append("  git repo; remote: \(remote.hasPrefix("local/") ? "none" : remote)")
                if let status = await BrainSync.status(of: brain.root, env: env, fetch: false) {
                    if status.hasRemote { lines.append("  ahead \(status.ahead), behind \(status.behind) (as of the last fetch)") }
                    if !status.changed.isEmpty { lines.append("  \(status.changed.count) uncommitted path\(status.changed.count == 1 ? "" : "s")") }
                    if let problem = status.problem { lines.append("! \(problem)") }
                }
            } else {
                lines.append("! not a git repo: changes can't be synced between Macs; run git init there or create the brain again (akit init).")
            }
            for problem in brain.problems {
                lines.append("! \(problem.layer.map { "layers/\($0): " } ?? "")\(problem.message) (akit check lists them)")
            }
        } else {
            lines.append("! no brain at \(tilde(input.brainRoot)): create one (akit init, or akit setup on a new Mac) or set its folder in Settings.")
        }

        // Tools
        lines += ["", "Tools"]
        let custom = (try? CustomHarnessStore.load(in: env)) ?? []
        let adapters = HarnessCatalog.allAdapters(custom: custom)
        let installations = HarnessCatalog.detectAll(in: env, adapters: adapters)
        let versions = await withTaskGroup(of: (Int, String?).self) { group in
            for (index, installation) in installations.enumerated() {
                group.addTask {
                    guard let executable = installation.executableURL else { return (index, nil) }
                    return (index, await VersionProbe.version(of: executable, in: env))
                }
            }
            var found: [Int: String] = [:]
            for await (index, version) in group { found[index] = version }
            return found
        }
        if installations.isEmpty { lines.append("! no harness found (Claude Code, Pi, Codex, OpenCode); install one, then refresh AKit.") }
        for (index, installation) in installations.enumerated() {
            var parts = ["config \(tilde(installation.configRoot))"]
            if let executable = installation.executableURL { parts.append("\(tilde(executable))\(versions[index].map { " \($0)" } ?? "")") }
            lines.append("  \(installation.displayName): \(parts.joined(separator: ", "))")
        }
        let missing = adapters.filter { adapter in !installations.contains { $0.id == adapter.id } }.map(\.displayName)
        if !missing.isEmpty { lines.append("  not found: \(missing.joined(separator: ", "))") }
        let piDir = env.variables["PI_CODING_AGENT_DIR"].flatMap { $0.isEmpty ? nil : $0 }
        lines.append("  PI_CODING_AGENT_DIR: \(piDir ?? "not set")")

        // Project folders
        lines += ["", "Project folders"]
        for root in input.projectRoots {
            lines.append(FileWalk.isDirectory(root) ? "  \(tilde(root))" : "! \(tilde(root)) doesn't exist; change the projects folders in Settings.")
        }
        if input.projectRoots.isEmpty { lines.append("! no projects folder set; add one in Settings.") }
        let found = SkillScanner.projects(installations: installations, extraProjects: ProjectFinder.projects(inRoots: input.projectRoots),
                                          adapters: adapters, in: env)
        lines.append("  \(found.count) project\(found.count == 1 ? "" : "s") found (projects folders and the harnesses' known projects)")

        // Projects
        lines += ["", "Projects"]
        let projects = (brain?.addingProjects(from: store).projects ?? []).filter { !$0.isHome }
        if projects.isEmpty { lines.append("  none set up") }
        if !projects.isEmpty {
            let folders: [String: URL]
            if let known = input.projectFolders {
                folders = known
            } else {
                folders = await projectFolders(found, projectsRoot: input.projectRoots.first ?? home.appending(path: "Projects"), env: env)
            }
            for project in projects {
                lines += projectLines(project, folder: folders[project.id], store: store, env: env, tilde: tilde)
            }
        }

        // Logs
        lines += ["", "Logs"]
        let reports = crashReports(in: home.appending(path: "Library/Logs/DiagnosticReports"))
        lines.append(reports.isEmpty ? "  no AKit crash reports"
                     : "  crash reports (newest first): \(reports.prefix(3).map { "\($0.name) (\(day($0.date)))" }.joined(separator: ", "))")
        let backups = home.appending(path: ".akit/backups")
        if FileWalk.isDirectory(backups) {
            lines.append("  backups: \(tilde(backups)), \(ByteCountFormatter.string(fromByteCount: size(of: backups), countStyle: .file))")
        }
        return SecretFilter.masked(lines.joined(separator: "\n"))
    }

    // MARK: - Pieces

    /// "2026.10.09 + 3, master @ abc1234, built from ~/Projects/akit" from the bundle's BuildInfo.plist.
    static func buildText(_ app: URL, home: URL) -> String? {
        guard let info = NSDictionary(contentsOf: app.appending(path: "Contents/Resources/BuildInfo.plist")) as? [String: Any] else { return nil }
        func value(_ key: String) -> String? { (info[key] as? String).flatMap { $0.isEmpty ? nil : $0 } }
        var parts: [String] = []
        let dirty = value("AKitGitDirty") == "yes" ? "*" : ""
        if let tag = value("AKitVersionTag") {
            let since = value("AKitCommitsSinceTag").flatMap(Int.init) ?? 0
            parts.append("version \(tag.hasPrefix("v") ? String(tag.dropFirst()) : tag)\(since > 0 ? " + \(since)" : "")\(dirty)")
        }
        let revision = [value("AKitGitBranch"), value("AKitGitCommit").map { "@ \($0)\(dirty)" }].compactMap(\.self)
        if !revision.isEmpty { parts.append(revision.joined(separator: " ")) }
        if let source = value("AKitSourcePath") { parts.append("built from \(FileWalk.tilde(URL(filePath: source), home: home))") }
        if let date = value("AKitBuildDate") { parts.append("on \(date)") }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }

    /// Project id → folder: the main checkout among folders with the same id. At most
    /// `parallel` git runs at a time.
    static func projectFolders(_ folders: [URL], projectsRoot: URL, env: HarnessEnvironment, parallel: Int = 8) async -> [String: URL] {
        var found: [String: [URL]] = [:]
        await withTaskGroup(of: (String, URL).self) { group in
            var next = folders.makeIterator()
            func addNext() {
                guard let folder = next.next() else { return }
                group.addTask { (await ProjectRecords.projectID(for: folder, projectsRoot: projectsRoot, env: env), folder) }
            }
            for _ in 0..<max(parallel, 1) { addNext() }
            for await (id, folder) in group {
                found[id, default: []].append(folder)
                addNext()
            }
        }
        return found.compactMapValues { GitCheckout.preferred($0) }
    }

    /// One project: its folder, local only or committed, AKit's exclude block, its worktrees.
    static func projectLines(_ project: Brain.Project, folder: URL?, store: ProjectStore, env: HarnessEnvironment,
                             tilde: (URL) -> String) -> [String] {
        guard let folder else { return ["  \(project.id): not on this Mac"] }
        let localOnly = project.answers.isLocalOnly(store: store)
        var parts = [tilde(folder), localOnly ? "local only" : "committed"]
        var problems: [String] = []
        let checkout = GitCheckout.at(folder)
        let block = checkout.flatMap { $0.isLinkedWorktree ? nil : LocalOnly.blockUnits(in: $0.excludeFile) }
        if let checkout, !checkout.isLinkedWorktree, let problem = LocalOnly.problem(in: checkout.excludeFile) {
            // `akit apply` can't fix a broken block: the problem names the fix by hand.
            parts.append("exclude block: can't be used")
            problems.append("! \(project.id): \(problem)")
        } else if let checkout, !checkout.isLinkedWorktree {
            parts.append(block.map { "exclude block: \($0.count) line\($0.count == 1 ? "" : "s")" } ?? "no exclude block")
            if localOnly, let lock = ProjectRecords.savedLock(id: project.id, in: store),
               let expected = LocalOnly.expectedUnits(of: folder, lock: lock, env: env), Set(expected) != Set(block ?? []) {
                problems.append("! \(project.id): AKit's block in .git/info/exclude doesn't match the files AKit wrote; run akit apply \(tilde(folder)).")
            }
            if !localOnly, block != nil {
                problems.append("! \(project.id): committed, but AKit's block is still in .git/info/exclude; run akit apply \(tilde(folder)).")
            }
            if let status = ProjectWorktrees.status(of: folder, env: env), !status.worktrees.isEmpty {
                parts.append("\(status.worktrees.count) worktree\(status.worktrees.count == 1 ? "" : "s")")
                for tree in status.worktrees where tree.needsSync {
                    let what = (tree.lacks.isEmpty ? [] : ["lacks \(tree.lacks.joined(separator: ", "))"])
                        + (tree.stale.isEmpty ? [] : ["stale links \(tree.stale.joined(separator: ", "))"])
                    problems.append("! worktree \(tilde(tree.folder)) \(what.joined(separator: "; ")); run akit worktrees sync \(tilde(folder)).")
                }
            }
        } else if checkout?.isLinkedWorktree == true {
            problems.append("! \(project.id): \(tilde(folder)) is a git worktree, not the main checkout.")
        } else if localOnly {
            parts.append("not a git repo")
        }
        return ["  \(project.id): \(parts.joined(separator: " · "))"] + problems
    }

    struct CrashReport {
        let name: String
        let date: Date
    }

    /// AKit's crash reports (`AKit-…`, `akit-…`), newest first.
    static func crashReports(in folder: URL) -> [CrashReport] {
        FileWalk.children(of: folder).compactMap { url -> CrashReport? in
            let name = url.lastPathComponent
            guard name.lowercased().hasPrefix("akit") else { return nil }
            let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            return CrashReport(name: name, date: date)
        }.sorted { $0.date > $1.date }
    }

    /// Total size of the files in a folder (bounded walk).
    static func size(of folder: URL) -> Int64 {
        guard let walk = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]) else { return 0 }
        var total: Int64 = 0
        var count = 0
        for case let url as URL in walk {
            count += 1
            if count > 200_000 { break }
            guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]), values.isRegularFile == true else { continue }
            total += Int64(values.fileSize ?? 0)
        }
        return total
    }

    /// `2026-10-09` in local time.
    static func day(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}
