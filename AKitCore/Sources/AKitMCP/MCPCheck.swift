import AKitFoundation
import AKitModel
import Foundation

/// Does an MCP server connect? The harness that runs it answers (`docs/design/mcp-check.md`):
/// `claude mcp get NAME` / `claude mcp list` and `pi mcp list --json`, run in the folder a
/// session would start in and with the user's login-shell environment. AKit itself never
/// speaks MCP. Only the status lines or the JSON are read: `claude mcp get` also prints the
/// server's environment, which may hold secrets.
public enum MCPCheck {
    public static let harnesses: [HarnessID] = [.claudeCode, .pi]
    public static let timeout: TimeInterval = 90

    /// What to check: some servers of one harness, in one folder.
    public struct Request: Sendable, Hashable {
        public let harness: HarnessID
        /// The folder the harness starts in; it decides which project servers it sees.
        public let folder: URL
        public let names: [String]
        /// Variables each server needs from the environment (`MCPServer.variables`), by name.
        public let variables: [String: [String]]

        public init(harness: HarnessID, folder: URL, names: [String], variables: [String: [String]] = [:]) {
            self.harness = harness
            self.folder = folder
            self.names = names
            self.variables = variables
        }
    }

    /// The servers to check, grouped into one request per harness and folder. A project
    /// server runs in its project; a global one in `context` (the project the screen shows)
    /// or else the home folder.
    public static func requests(for servers: [MCPServer], harness only: HarnessID? = nil, context: URL?,
                                home: URL) -> [Request] {
        var groups: [String: (HarnessID, URL, [String], [String: [String]])] = [:]
        var order: [String] = []
        for server in servers {
            let folder: URL
            switch server.scope {
            case .project(let project): folder = project
            case .global: folder = context ?? home
            default: continue
            }
            for use in server.uses where harnesses.contains(use.harness) && (only == nil || use.harness == only) {
                let key = "\(use.harness.rawValue)|\(folder.standardizedFileURL.path)"
                if groups[key] == nil {
                    groups[key] = (use.harness, folder, [], [:])
                    order.append(key)
                }
                if !groups[key]!.2.contains(server.name) { groups[key]!.2.append(server.name) }
                groups[key]!.3[server.name, default: []] += server.variables.filter { !groups[key]!.3[server.name, default: []].contains($0) }
            }
        }
        return order.compactMap { groups[$0] }.map { Request(harness: $0.0, folder: $0.1, names: $0.2, variables: $0.3) }
    }

    /// Runs the requests one after the other (each starts the user's servers) and returns a
    /// result for every requested name, plus Pi's other servers in that folder.
    /// `shellTimeout`: how long the login shell may take to start (a busy Mac scans new programs).
    public static func run(_ requests: [Request], in env: HarnessEnvironment, shellTimeout: TimeInterval = 30,
                           now: @Sendable () -> Date = Date.init) async -> [MCPCheckResult] {
        guard !requests.isEmpty else { return [] }
        let shell = await LoginShell.variables(in: env, timeout: shellTimeout)
        var results: [MCPCheckResult] = []
        for request in requests {
            results += await run(request, shell: shell, in: env, now: now)
        }
        if let note = shell.note {
            for index in results.indices where results[index].state.isProblem {
                results[index].detail = [results[index].detail, note].compactMap { $0 }.joined(separator: "\n")
            }
        }
        return results
    }

    static func run(_ request: Request, shell: LoginShell.Variables, in env: HarnessEnvironment,
                    now: @Sendable () -> Date) async -> [MCPCheckResult] {
        let folder = request.folder.standardizedFileURL
        let paths = (shell.values["PATH"] ?? "").split(separator: ":").map { URL(filePath: String($0), directoryHint: .isDirectory) }
        var lookup = env
        lookup.executableSearchPaths = paths + env.executableSearchPaths
        let program = request.harness == .pi ? "pi" : "claude"
        let date = now()
        func all(_ state: MCPCheckResult.State, _ detail: String) -> [MCPCheckResult] {
            request.names.map { MCPCheckResult(harness: request.harness, name: $0, folder: folder.path, state: state, detail: detail, checkedAt: date) }
        }
        guard let executable = lookup.findExecutable(program) else {
            return all(.failed, "AKit can't find the \(program) command, neither in your shell's PATH nor in the usual places.")
        }
        var variables = shell.values
        variables["PATH"] = lookup.pathForChildProcesses
        variables["HOME"] = env.homeDirectory.path

        let arguments: [String] = switch request.harness {
        case .pi: ["mcp", "list", "--json"]
        default: request.names.count == 1 ? ["mcp", "get", request.names[0]] : ["mcp", "list"]
        }
        guard let output = await ProcessRunner.run(executable, arguments: arguments, directory: folder, environment: variables,
                                                   timeout: timeout) else {
            return all(.failed, "\(program) couldn't be started in \(FileWalk.tilde(folder, home: env.homeDirectory)).")
        }
        if output.timedOut {
            return all(.timedOut, "Timed out after \(Int(timeout)) s; the first run of npx or uvx may download the package. Check again.")
        }
        var parsed: [MCPCheckResult]
        switch request.harness {
        case .pi:
            parsed = parsePiList(output.output, folder: folder.path, checkedAt: date)
                ?? all(.failed, "pi mcp list --json gave no answer AKit can read (exit status \(output.status)). Pi 0.99 or newer has it.")
        default:
            parsed = request.names.count == 1
                ? [parseClaudeGet(output.output, name: request.names[0], folder: folder.path, checkedAt: date)]
                : parseClaudeList(output.output, names: request.names, folder: folder.path, checkedAt: date)
        }
        let answered = Set(parsed.map(\.name))
        let untrusted = request.harness == .pi ? piUntrustedNote(output.output) : nil
        for name in request.names where !answered.contains(name) {
            parsed.append(untrusted != nil
                ? MCPCheckResult(harness: request.harness, name: name, folder: folder.path, state: .untrustedProject,
                                 detail: "Pi doesn't trust this project yet: start Pi there once.", checkedAt: date)
                : MCPCheckResult(harness: request.harness, name: name, folder: folder.path, state: .notFound,
                                 detail: "\(program) doesn't list this server in \(FileWalk.tilde(folder, home: env.homeDirectory)).", checkedAt: date))
        }
        // A server that didn't connect while a variable it needs is missing: name the variable.
        // Only a plain failure becomes Missing Variables; Pending Approval, Needs Sign-In and the
        // others keep their state (and their fix), with the variables named beside it.
        for index in parsed.indices where parsed[index].state.isProblem {
            let missing = (request.variables[parsed[index].name] ?? []).filter { (shell.values[$0] ?? "").isEmpty }
            guard !missing.isEmpty else { continue }
            parsed[index].missingVariables = missing
            if parsed[index].state == .failed || parsed[index].state == .timedOut { parsed[index].state = .missingVariables }
        }
        return parsed
    }

    // MARK: Claude Code

    /// `claude mcp get NAME`: the `Status:` and `Issue:` lines only.
    static func parseClaudeGet(_ output: String, name: String, folder: String, checkedAt: Date) -> MCPCheckResult {
        let lines = output.components(separatedBy: .newlines)
        func field(_ key: String) -> String? {
            lines.first { $0.trimmingCharacters(in: .whitespaces).hasPrefix(key + ":") }
                .map { String($0.trimmingCharacters(in: .whitespaces).dropFirst(key.count + 1)).trimmingCharacters(in: .whitespaces) }
        }
        var result = MCPCheckResult(harness: .claudeCode, name: name, folder: folder, state: .failed, checkedAt: checkedAt)
        if output.contains("No MCP server named") {
            result.state = .notFound
            result.detail = "Claude Code doesn't list this server here."
            return result
        }
        guard let status = field("Status") else {
            result.detail = "claude mcp get gave no status AKit can read."
            return result
        }
        (result.state, result.detail) = claudeState(status, issue: field("Issue"))
        return result
    }

    /// `claude mcp list`: one line per server, `NAME: COMMAND-OR-URL - STATUS[ — ISSUE]`. A
    /// line belongs to the longest name it starts with; other lines are left out.
    static func parseClaudeList(_ output: String, names: [String], folder: String, checkedAt: Date) -> [MCPCheckResult] {
        let byLength = names.sorted { $0.count > $1.count }
        var results: [MCPCheckResult] = []
        for line in output.components(separatedBy: .newlines) {
            guard let name = byLength.first(where: { line.hasPrefix($0 + ": ") }), !results.contains(where: { $0.name == name }),
                  let status = claudeStatusPart(line) else { continue }
            var issue: String?
            var text = status
            if let dash = status.range(of: " — ") {
                issue = String(status[dash.upperBound...])
                text = String(status[..<dash.lowerBound])
            }
            var result = MCPCheckResult(harness: .claudeCode, name: name, folder: folder, state: .failed, checkedAt: checkedAt)
            (result.state, result.detail) = claudeState(text, issue: issue)
            results.append(result)
        }
        return results
    }

    private static let statusMarks: [Character] = ["✔", "✓", "✘", "✗", "!", "⏸", "-"]

    /// The status: the text after the last ` - ` that starts one (a mark and a word), searched
    /// only before the issue (` — `), whose text may hold such a piece too.
    static func claudeStatusPart(_ line: String) -> String? {
        let issueStart = line.range(of: " — ")?.lowerBound ?? line.endIndex
        var search = issueStart
        while let range = line.range(of: " - ", options: .backwards, range: line.startIndex..<search) {
            let rest = line[range.upperBound...]
            if let first = rest.first, statusMarks.contains(first), rest.dropFirst().first == " " { return String(rest) }
            search = range.lowerBound
        }
        return nil
    }

    /// Claude Code's status words (2.1.310: `mcp list` and `mcp get` use the same ones).
    static func claudeState(_ status: String, issue: String?) -> (MCPCheckResult.State, String?) {
        let text = status.drop { statusMarks.contains($0) || $0 == " " }
        let issue = issue.map(masked)
        if text.hasPrefix("Connected") {
            return text.contains("tools fetch failed")
                ? (.failed, ["Connected, but its list of tools failed.", issue].compactMap { $0 }.joined(separator: " "))
                : (.connected, nil)
        }
        if text.hasPrefix("Needs authentication") { return (.needsSignIn, nil) }
        if text.hasPrefix("Pending approval") { return (.pendingApproval, "Claude Code asks whether to use this .mcp.json server.") }
        if text.lowercased().contains("disabled") { return (.off, masked(String(text))) }
        if text.hasPrefix("Not configured") { return (.failed, "Not configured: the entry has no URL or command.") }
        return (.failed, [masked(String(text)), issue].compactMap { $0 }.joined(separator: ": "))
    }

    // MARK: Pi

    /// `pi mcp list --json` (Pi 0.99+); nil when the output holds no such JSON.
    static func parsePiList(_ output: String, folder: String, checkedAt: Date) -> [MCPCheckResult]? {
        guard let object = piJSON(output), let servers = object["servers"] as? [[String: Any]] else { return nil }
        return servers.compactMap { report in
            guard let name = report["name"] as? String else { return nil }
            var result = MCPCheckResult(harness: .pi, name: name, folder: folder, state: .failed, checkedAt: checkedAt)
            let error = (report["error"] as? String).map(masked)
            switch (report["enabled"] as? Bool ?? true, report["state"] as? String ?? "") {
            case (false, _), (_, "disabled"): result.state = .off
            case (_, "connected"): result.state = .connected
            case (_, "needs-auth"): result.state = .needsSignIn
            case (_, "connecting"): result.detail = "Still connecting when Pi stopped waiting."
            default: result.detail = error ?? "Pi couldn't connect."
            }
            if result.state == .connected || result.state == .off {
                result.tools = report["tools"] as? [String]
                result.exposure = report["exposure"] as? String
                result.toolExposure = report["toolExposure"] as? [String: String]
            }
            return result
        }
    }

    static func piUntrustedNote(_ output: String) -> String? {
        piJSON(output)?["note"] as? String
    }

    /// The JSON object with `servers` in the output: tried from each line that starts with `{`
    /// (a login shell or a warning may print before it).
    private static func piJSON(_ output: String) -> [String: Any]? {
        guard let end = output.range(of: "}", options: .backwards)?.upperBound else { return nil }
        var starts = output.hasPrefix("{") ? [output.startIndex] : []
        var from = output.startIndex
        while let range = output.range(of: "\n{", range: from..<output.endIndex) {
            starts.append(output.index(after: range.lowerBound))
            from = range.upperBound
        }
        for start in starts where start < end {
            if let object = (try? JSONSerialization.jsonObject(with: Data(output[start..<end].utf8))) as? [String: Any],
               object["servers"] != nil { return object }
        }
        return nil
    }

    /// Error text from a harness may quote a command line or a URL with a token in it.
    static func masked(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return String(SecretFilter.masked(trimmed).prefix(2000))
    }
}

/// The result of one check of one server.
public struct MCPCheckResult: Codable, Sendable, Hashable, Identifiable {
    public enum State: String, Codable, Sendable {
        case connected, failed, needsSignIn, pendingApproval, untrustedProject, off, missingVariables, timedOut, notFound

        public var title: String {
            switch self {
            case .connected: "Connected"
            case .failed: "Failed"
            case .needsSignIn: "Needs Sign-In"
            case .pendingApproval: "Pending Approval"
            case .untrustedProject: "Untrusted Project"
            case .off: "Off"
            case .missingVariables: "Missing Variables"
            case .timedOut: "Timed Out"
            case .notFound: "Not Found"
            }
        }

        /// A state the user has to act on (Off is a choice, not a problem).
        public var isProblem: Bool { self != .connected && self != .off }
    }

    public let harness: String
    public let name: String
    /// The folder the harness ran in.
    public let folder: String
    public var state: State
    /// The harness's error, masked; or why AKit couldn't tell.
    public var detail: String?
    public var missingVariables: [String]
    /// Pi only: the server's tools, its exposure and the tools with another exposure.
    public var tools: [String]?
    public var exposure: String?
    public var toolExposure: [String: String]?
    public let checkedAt: Date

    public var id: String { MCPCheckResult.key(harness: harness, name: name, folder: folder) }
    public var harnessID: HarnessID { harness == HarnessID.pi.rawValue ? .pi : .claudeCode }

    public static func key(harness: String, name: String, folder: String) -> String { "\(harness)|\(folder)|\(name)" }

    public init(harness: HarnessID, name: String, folder: String, state: State, detail: String? = nil,
                missingVariables: [String] = [], checkedAt: Date) {
        self.harness = harness.rawValue
        self.name = name
        self.folder = folder
        self.state = state
        self.detail = detail
        self.missingVariables = missingVariables
        self.checkedAt = checkedAt
    }
}

/// The last result of each check, kept in `~/.akit/mcp-checks.json` until the next one.
/// Safe to delete: it holds no secrets (masked errors and tool names only).
public enum MCPCheckStore {
    static func file(_ home: URL) -> URL { home.appending(path: ".akit/mcp-checks.json") }

    private struct Saved: Codable { var results: [MCPCheckResult] }

    public static func load(home: URL) -> [String: MCPCheckResult] {
        guard let data = try? Data(contentsOf: file(home)), let saved = try? decoder.decode(Saved.self, from: data) else { return [:] }
        return Dictionary(saved.results.map { ($0.id, $0) }, uniquingKeysWith: { $1 })
    }

    /// Replaces the stored results of the same server, harness and folder.
    public static func save(_ results: [MCPCheckResult], home: URL) throws {
        var all = load(home: home)
        for result in results { all[result.id] = result }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        let url = file(home)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(Saved(results: all.values.sorted { $0.id < $1.id })).write(to: url, options: .atomic)
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
