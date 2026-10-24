import AKitFoundation
import AKitModel
import Foundation

/// Fixes for a failed connection check (`docs/design/mcp-check.md`): approving a project's
/// `.mcp.json` server for Claude Code, and signing in to an OAuth server.
public enum MCPApprove {
    /// Approving `name` in `project`: the name added to `enabledMcpjsonServers` of the project's
    /// `.claude/settings.local.json`, where Claude Code 2.1.310 keeps the answer of its own
    /// approval question (older answers in `~/.claude.json` move there by Claude itself). The
    /// file may hold secrets: the preview shows only this one key, nothing else of the file.
    public struct Plan: Sendable {
        public let name: String
        public let change: SettingsFile.Change
        public let notes: [String]
    }

    public static func file(in project: URL) -> URL { project.appending(path: ".claude/settings.local.json") }

    public static func plan(_ name: String, project: URL, env: HarnessEnvironment) throws(SettingsFile.Failure) -> Plan {
        let home = env.homeDirectory
        let file = file(in: project)
        let current = try SettingsFile.read(file, home: home)?.value
        var names: [JSONValue] = []
        switch current?.value(at: ["enabledMcpjsonServers"]) {
        case nil: break
        case .array(let items)?: names = items
        default:
            throw SettingsFile.Failure("enabledMcpjsonServers in \(FileWalk.tilde(file, home: home)) isn't a list; fix it by hand first.")
        }
        if names.contains(.string(name)) {
            throw SettingsFile.Failure("“\(name)” is already approved in \(FileWalk.tilde(file, home: home)).")
        }
        names.append(.string(name))
        let change = try SettingsFile.change(file, edits: [.set(["enabledMcpjsonServers"], .array(names))], home: home)
        var notes = ["Claude Code reads this answer from \(FileWalk.tilde(file, home: home)); only this key is shown and changed."]
        if !isTrusted(project, home: home) {
            notes.insert("Claude Code doesn't trust this folder yet: the answer counts once you start claude there and trust it.", at: 0)
        }
        if isTracked(file, in: project, env: env) {
            notes.insert("Git tracks this file: Claude Code ignores approvals in a tracked settings.local.json, and git will show the change.", at: 0)
        }
        return Plan(name: name, change: change, notes: notes)
    }

    /// Writes the plan (backup first, refused when the key changed since the preview).
    public static func apply(_ plan: Plan, home: URL) throws(SettingsFile.Failure) -> URL? {
        try SettingsFile.apply(plan.change, home: home)
    }

    /// Claude Code reads a project's settings only once the folder is trusted (its entry's
    /// `hasTrustDialogAccepted` in `~/.claude.json`, keyed like the switches).
    static func isTrusted(_ project: URL, home: URL) -> Bool {
        guard let state = try? SettingsFile.read(home.appending(path: ".claude.json"), home: home)?.value else { return false }
        return state.value(at: ["projects", MCPSwitches.claudeProjectKey(project), "hasTrustDialogAccepted"]) == .bool(true)
    }

    static func isTracked(_ file: URL, in project: URL, env: HarnessEnvironment) -> Bool {
        guard let git = env.findExecutable("git") ?? Optional(URL(filePath: "/usr/bin/git")),
              FileManager.default.isExecutableFile(atPath: git.path) else { return false }
        let result = ProcessRunner.runAndWait(git, arguments: ["ls-files", "--error-unmatch", ".claude/settings.local.json"],
                                              directory: project, environment: env.gitVariables, timeout: 10)
        return result?.succeeded == true
    }

    /// `claude mcp login NAME` / `pi mcp login NAME` in `folder`, with the login shell's
    /// environment: the harness opens the browser and waits. nil when it worked, else the
    /// harness's answer, masked.
    public static func signIn(_ name: String, harness: HarnessID, folder: URL, in env: HarnessEnvironment,
                              timeout: TimeInterval = 300) async -> String? {
        let shell = await LoginShell.variables(in: env)
        var lookup = env
        lookup.executableSearchPaths = (shell.values["PATH"] ?? "").split(separator: ":")
            .map { URL(filePath: String($0), directoryHint: .isDirectory) } + env.executableSearchPaths
        let program = harness == .pi ? "pi" : "claude"
        guard let executable = lookup.findExecutable(program) else { return "AKit can't find the \(program) command." }
        var variables = shell.values
        variables["PATH"] = lookup.pathForChildProcesses
        variables["HOME"] = env.homeDirectory.path
        var arguments = ["mcp", "login", name]
        if harness == .pi { arguments += ["--timeout", String(Int(timeout))] }
        guard let result = await ProcessRunner.run(executable, arguments: arguments, directory: folder, environment: variables,
                                                   timeout: timeout + 10) else {
            return "\(program) couldn't be started."
        }
        if result.timedOut { return "The sign-in didn't finish within \(Int(timeout / 60)) minutes." }
        guard result.succeeded else {
            let text = MCPCheck.masked(result.output)
            return "\(program) mcp login failed" + (text.isEmpty ? "." : ": \(String(text.suffix(600)))")
        }
        return nil
    }
}
