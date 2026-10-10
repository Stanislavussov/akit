import AKitFoundation
import AKitMCP
import AKitModel
import Foundation

/// MCP switches with the project's git around them (docs/design/harness-support.md, "MCP
/// switches"): a Pi `.pi/mcp.json` AKit writes stays out of git through a line in AKit's MCP
/// block of `<git common dir>/info/exclude` (one exclude file covers every worktree), unless git
/// tracks the file there. A tracked one is changed only when asked (the preview says so), never
/// by a background sync. Projects are expanded to their worktrees here (`ProjectWorktrees.family`).
public enum MCPProjectSwitch {
    /// The project and its worktrees, for a folder AKit knows (a worktree stands for its project).
    public static func family(of folder: URL, env: HarnessEnvironment) -> MCPSwitches.Family {
        let family = ProjectWorktrees.family(of: folder, env: env)
        return MCPSwitches.Family(main: family.main, worktrees: family.worktrees)
    }

    /// Where a change applies, before worktrees are known.
    public enum Target: Sendable {
        case everywhere
        case projects([URL])
        /// Everywhere and in every folder where it is off (On only).
        case all
    }

    public static func plan(_ server: MCPServer, harness: HarnessID, off: Bool, target: Target, includeUnmanaged: Bool = false,
                            known: [URL], in env: HarnessEnvironment) throws(MCPSwitches.Failure) -> MCPSwitches.Plan {
        let inner: MCPSwitches.Target
        switch target {
        case .everywhere:
            inner = .everywhere
        case .projects(let folders):
            inner = .projects(folders.map { family(of: $0, env: env) })
        case .all:
            // Pi: every folder where it is off and every remembered project, each with its worktrees,
            // so overrides in worktrees go too.
            var mains: [String] = []
            if harness == .pi {
                let status = MCPSwitches.statuses(of: [server], projects: known, in: env)[server.id]?[harness]
                mains = (status?.offIn ?? []) + MCPSwitches.intents(home: env.homeDirectory)
                    .filter { $0.harness == harness.rawValue && $0.server == server.name }.map(\.project)
            }
            var seen = Set<String>()
            let families = mains.compactMap { path -> MCPSwitches.Family? in
                let family = family(of: URL(filePath: path, directoryHint: .isDirectory), env: env)
                return seen.insert(family.main.path).inserted ? family : nil
            }
            inner = .all(extra: families)
        }
        var plan = try MCPSwitches.plan(server, harness: harness, off: off, target: inner, includeUnmanaged: includeUnmanaged, known: known, in: env)
        guard harness == .pi, off, !plan.piFolders.isEmpty else { return plan }
        let git = gitFacts(plan.piFolders, env: env)
        plan.excludes = git.excludes
        if !git.excludes.isEmpty {
            plan.notes.insert("Keeps .pi/mcp.json out of git: adds it to AKit's MCP block in \(git.excludes.keys.map { FileWalk.tilde($0, home: env.homeDirectory) }.sorted().joined(separator: ", ")).", at: 0)
        }
        if !git.tracked.isEmpty {
            plan.notes.insert("Modifies a tracked file in \(git.tracked.count) \(git.tracked.count == 1 ? "worktree" : "worktrees") (git shows the change): \(git.tracked.map { FileWalk.tilde(URL(filePath: $0), home: env.homeDirectory) }.joined(separator: ", ")).", at: 0)
        }
        if !git.unknown.isEmpty {
            plan.notes.insert("Git couldn't say whether .pi/mcp.json is tracked in \(git.unknown.map { FileWalk.tilde(URL(filePath: $0), home: env.homeDirectory) }.joined(separator: ", ")); AKit adds no exclude line there.", at: 0)
        }
        return plan
    }

    /// Adds the exclude lines first (so git never lists the file), then writes the settings.
    @discardableResult
    public static func apply(_ plan: MCPSwitches.Plan, home: URL) throws(MCPSwitches.Failure) -> [URL] {
        for (file, units) in plan.excludes.sorted(by: { $0.key.path < $1.key.path }) {
            if let problem = addExcludes(units, to: file) { throw MCPSwitches.Failure(problem) }
        }
        return try MCPSwitches.apply(plan, home: home)
    }

    /// Gives the worktrees of remembered projects (all, or the one whose main checkout is `only`)
    /// the Pi entries they lack. Skips a worktree where git tracks `.pi/mcp.json` (or can't tell)
    /// and says so; adds the exclude line before writing. One sync at a time is the caller's job.
    public static func syncWorktrees(only: URL? = nil, env: HarnessEnvironment) -> (added: [String], problems: [String]) {
        let intents = MCPSwitches.intents(home: env.homeDirectory).filter { $0.harness == HarnessID.pi.rawValue }
        var added: [String] = [], problems: [String] = []
        var families: [String: MCPSwitches.Family] = [:]
        for intent in intents where only == nil || only!.standardizedFileURL.path == intent.project {
            let family = families[intent.project] ?? family(of: URL(filePath: intent.project, directoryHint: .isDirectory), env: env)
            families[intent.project] = family
            guard !family.worktrees.isEmpty else { continue }
            do {
                var plan = try MCPSwitches.worktreePlan(intent.server, worktrees: family.worktrees, in: env)
                guard !plan.piFolders.isEmpty else { continue }
                let git = gitFacts(plan.piFolders, env: env)
                let blocked = git.tracked + git.unknown
                if !blocked.isEmpty {
                    problems.append("\(intent.server) (Pi): .pi/mcp.json is tracked by git (or git couldn't tell) in \(blocked.map { FileWalk.tilde(URL(filePath: $0), home: env.homeDirectory) }.joined(separator: ", ")); AKit doesn't change it on its own. Use Off in Project… there.")
                    plan = try MCPSwitches.worktreePlan(intent.server, worktrees: family.worktrees.filter { !blocked.contains($0.standardizedFileURL.path) }, in: env)
                    guard !plan.piFolders.isEmpty else { continue }
                }
                plan.excludes = gitFacts(plan.piFolders, env: env).excludes
                try apply(plan, home: env.homeDirectory)
                added.append("\(intent.server) off for Pi in \(plan.piFolders.map(\.lastPathComponent).joined(separator: ", ")) (worktrees of \(family.main.lastPathComponent))")
            } catch {
                problems.append("\(intent.server) (Pi) in the worktrees of \(family.main.lastPathComponent): \(error.message)")
            }
        }
        return (added, problems)
    }

    // MARK: - Git

    /// For each folder whose `.pi/mcp.json` AKit writes: the exclude line it needs (the file is
    /// missing or untracked), or that git tracks it, or that git couldn't tell (no git: nothing).
    static func gitFacts(_ folders: [URL], env: HarnessEnvironment) -> (excludes: [URL: [String]], tracked: [String], unknown: [String]) {
        var excludes: [URL: [String]] = [:], tracked: [String] = [], unknown: [String] = []
        for folder in folders {
            guard let checkout = GitCheckout.containing(folder),
                  let top = FileWalk.realPath(checkout.folder), let inside = FileWalk.realPath(folder) else { continue }
            let relative = inside == top ? "" : String(inside.dropFirst(top.count + 1)) + "/"
            let unit = relative + ".pi/mcp.json"
            guard LocalOnly.isSafe(unit) else { continue }
            switch LocalOnly.tracked([unit], in: checkout.folder, env: env) {
            case nil: unknown.append(folder.standardizedFileURL.path)
            case let set? where set.contains(unit): tracked.append(folder.standardizedFileURL.path)
            default:
                if LocalOnly.blockUnits(in: checkout.excludeFile, markers: .mcp)?.contains(unit) != true {
                    excludes[checkout.excludeFile, default: []].append(unit)
                }
            }
        }
        return (excludes.mapValues { Array(Set($0)).sorted() }, tracked, unknown)
    }

    /// Adds units to AKit's MCP block of an exclude file (keeping those already there).
    static func addExcludes(_ units: [String], to file: URL) -> String? {
        if case .lines(let lines) = LocalOnly.contents(of: file), case .broken? = LocalOnly.block(in: lines, markers: .mcp) {
            return "\(file.path) has a broken AKit MCP block; AKit left it alone. Delete the lines from \(LocalOnly.Markers.mcp.start) to \(LocalOnly.Markers.mcp.end) by hand."
        }
        let current = LocalOnly.blockUnits(in: file, markers: .mcp) ?? []
        let all = Array(Set(current + units)).sorted()
        guard all != current.sorted() else { return nil }
        return LocalOnly.write(units: all, to: file, markers: .mcp)
    }
}
