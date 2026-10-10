import AKitFoundation
import AKitHarnesses
import AKitMCP
import AKitModel
import AKitProjectSetup
import AKitSkills
import Foundation

/// `akit mcp state`, `akit mcp set`, `akit mcp connectors`: MCP servers off without deleting them,
/// in each harness's own setting (docs/design/harness-support.md, "MCP switches").
extension AKitCLI {
    static let mcpUsage = "Use: akit mcp state [NAME] | akit mcp set NAME --harness claude|pi (--off everywhere | --off project --project PATH... | --on [--project PATH...]) [--yes]"
        + " | akit mcp connectors on|off [--yes]"

    static func mcp(_ args: inout Arguments, yes: Bool, env: HarnessEnvironment, cwd: URL, projectsRoot: URL,
                    out: (String) -> Void, err: (String) -> Void) throws -> Int32 {
        let subcommand = args.positional()
        let harnessName = args.value("--harness"), offMode = args.value("--off"), turnOn = args.flag("--on")
        let projectPaths = args.values("--project")
        let name = args.positional()
        try args.finish()
        let installations = HarnessCatalog.detectAll(in: env)
        let projects = SkillScanner.projects(installations: installations, extraProjects: ProjectFinder.projects(inRoots: [projectsRoot]), in: env)
            + projectPaths.map { resolve($0, cwd: cwd, env: env) }
        let servers = MCPScanner.scan(installations: installations, projects: projects, in: env).servers
            .filter { server in MCPSwitches.harnesses.contains { server.usedBy.contains($0) } }

        switch subcommand {
        case "state":
            if harnessName != nil || offMode != nil || turnOn || !projectPaths.isEmpty || yes { throw Failure(message: mcpUsage) }
            let shown = name.map { name in servers.filter { $0.name == name } } ?? servers
            if let name, shown.isEmpty { throw Failure(message: "No MCP server named \(name) that Claude Code or Pi uses.") }
            out(mcpStatesText(shown, projects: projects, details: name != nil, env: env))
            return 0
        case "connectors":
            guard harnessName == nil, offMode == nil, !turnOn, projectPaths.isEmpty, let name, name == "on" || name == "off" else {
                throw Failure(message: mcpUsage)
            }
            let plan: MCPSwitches.Plan
            do { plan = try MCPSwitches.connectorsPlan(off: name == "off", in: env) } catch { throw Failure(message: error.message) }
            return try runMCPPlan(plan, yes: yes, env: env, out: out)
        case "set":
            break
        default:
            throw Failure(message: mcpUsage)
        }

        guard let name, let harnessName, (offMode != nil) != turnOn else { throw Failure(message: mcpUsage) }
        let harness: HarnessID
        switch harnessName {
        case "claude", "claude-code": harness = .claudeCode
        case "pi": harness = .pi
        default: throw Failure(message: "--harness is claude or pi.")
        }
        let families = projectPaths.map { path -> MCPSwitches.Family in
            let family = ProjectWorktrees.family(of: resolve(path, cwd: cwd, env: env), env: env)
            return MCPSwitches.Family(main: family.main, worktrees: family.worktrees)
        }
        let target: MCPSwitches.Target
        switch (offMode, turnOn) {
        case ("everywhere"?, false):
            if !families.isEmpty { throw Failure(message: "--off everywhere takes no --project.") }
            target = .everywhere
        case ("project"?, false):
            if families.isEmpty { throw Failure(message: "--off project needs --project PATH (one or more).") }
            target = .projects(families)
        case (nil, true):
            target = families.isEmpty ? .all : .projects(families)
        default:
            throw Failure(message: "--off is everywhere or project.")
        }

        // The entry the change is for: a project's own server when the project is named, else the user-level one.
        let candidates = servers.filter { $0.name == name && MCPSwitches.options(for: $0, harness: harness, in: env) != nil }
        guard !candidates.isEmpty else { throw Failure(message: "No MCP server named \(name) that \(harness.displayName) uses.") }
        let usable = candidates.filter { MCPSwitches.options(for: $0, harness: harness, in: env)?.unavailable == nil }
        guard !usable.isEmpty else {
            throw Failure(message: MCPSwitches.options(for: candidates[0], harness: harness, in: env)?.unavailable ?? "No switch for \(name).")
        }
        let mains = Set(families.map(\.main.path))
        let own = usable.filter { server in MCPSwitches.options(for: server, harness: harness, in: env)?.ownProject.map { mains.contains($0.standardizedFileURL.path) } == true }
        let shared = usable.filter { MCPSwitches.options(for: $0, harness: harness, in: env)?.ownProject == nil }
        guard let server = own.first ?? shared.first ?? (usable.count == 1 ? usable.first : nil) else {
            let places = usable.map { FileWalk.tilde($0.file, home: env.homeDirectory) }.joined(separator: ", ")
            throw Failure(message: "Several servers named \(name): \(places). Name the project with --project PATH.")
        }
        let plan: MCPSwitches.Plan
        do {
            plan = try MCPSwitches.plan(server, harness: harness, off: !turnOn, target: target, known: projects, in: env)
        } catch {
            throw Failure(message: error.message)
        }
        return try runMCPPlan(plan, yes: yes, env: env, out: out)
    }

    /// Prints the plan's changes; with `--yes` writes them.
    static func runMCPPlan(_ plan: MCPSwitches.Plan, yes: Bool, env: HarnessEnvironment, out: (String) -> Void) throws -> Int32 {
        guard !plan.changesNothing else {
            out("\(plan.title): nothing to change, it is already so.")
            return 0
        }
        var lines = [plan.title + "."]
        for change in plan.changes {
            lines.append("\(change.creates ? "Creates" : "Changes") \(FileWalk.tilde(change.file, home: env.homeDirectory)):")
            lines += TextDiff.unified(change.diff)
        }
        lines += plan.notes
        guard yes else {
            out((lines + ["Run again with --yes to do it."]).joined(separator: "\n"))
            return 0
        }
        let backups: [URL]
        do { backups = try MCPSwitches.apply(plan, home: env.homeDirectory) } catch { throw Failure(message: error.message) }
        lines.append("Done." + (backups.isEmpty ? "" : " Backups: \(backups.map { FileWalk.tilde($0, home: env.homeDirectory) }.joined(separator: ", "))."))
        out(lines.joined(separator: "\n"))
        return 0
    }

    /// One line per server: name, file, state in each harness; with `details`, the folders.
    static func mcpStatesText(_ servers: [MCPServer], projects: [URL], details: Bool, env: HarnessEnvironment) -> String {
        let home = env.homeDirectory
        let statuses = MCPSwitches.statuses(of: servers, projects: projects, in: env)
        var lines: [String] = []
        let connectors: String = switch MCPSwitches.connectorsOff(in: env) {
        case true?: "Off"
        case false?: "On"
        case nil: "Unknown (Claude Code's settings can't be read)"
        }
        lines.append("claude.ai connectors (Claude Code): \(connectors)")
        for server in servers.sorted(by: { ($0.name, $0.file.path) < ($1.name, $1.file.path) }) {
            let parts = MCPSwitches.harnesses.compactMap { harness -> String? in
                guard let options = MCPSwitches.options(for: server, harness: harness, in: env) else { return nil }
                if options.unavailable != nil { return "\(harness.displayName): no switch" }
                guard let status = statuses[server.id]?[harness] else { return nil }
                if let unknown = status.unknown { return "\(harness.displayName): unknown (\(unknown))" }
                return "\(harness.displayName): \(status.title)"
            }
            lines.append("\(server.name)  \(parts.joined(separator: ", "))  \(FileWalk.tilde(server.file, home: home))")
            if details {
                for harness in MCPSwitches.harnesses {
                    for folder in statuses[server.id]?[harness]?.offIn ?? [] {
                        lines.append("  \(harness.displayName) off in \(FileWalk.tilde(URL(filePath: folder), home: home))")
                    }
                }
            }
        }
        return lines.joined(separator: "\n")
    }
}
