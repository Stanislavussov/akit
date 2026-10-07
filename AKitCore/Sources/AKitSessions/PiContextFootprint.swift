import AKitFoundation
import AKitModel
import Foundation

extension PiSessions {
    /// The overview of a Pi session. Pi 1.0 and newer record the system prompt they send as a
    /// `system` message with named `sections`: `project_context` holds every AGENTS.md with its
    /// path, `skills` every listed skill with its SKILL.md, `tools` one line per declared tool.
    /// Tool schemas aren't recorded, so they stay in the rest of the first call. Older sessions
    /// have no system message: their footprint is nil.
    static func overview(of file: URL) throws -> SessionOverview {
        let data = try Data(contentsOf: file, options: .mappedIfSafe)
        var reader = PiFootprintReader()
        for entry in try JSONLines.objects(in: data) {
            reader.read(entry)
        }
        return SessionOverview(footprint: reader.footprint, tools: reader.outcomes)
    }
}

/// Reads a Pi session in order for `PiSessions.overview(of:)`.
struct PiFootprintReader {
    typealias Object = JSONLines.Object
    typealias Part = ContextFootprint.Part

    private var cwd: URL?
    private var sections: [String: String]?
    private var seenCalls = Set<String>()
    private var contexts: [Int] = []
    private var costs: [ContextFootprint.CallCost] = []
    private var toolCalls: [String: Int] = [:]
    /// Paths the model read, standardized: reading a listed SKILL.md is using the skill.
    private var readPaths: [String: Int] = [:]
    private var userSkillCalls: [String: Int] = [:]
    private var pending: [String: (name: String, readsSecret: Bool)] = [:]
    private var outcomeTools: [String: ToolOutcomes.Tool] = [:]

    mutating func read(_ entry: Object) {
        if entry["type"] as? String == "session", let path = entry["cwd"] as? String { cwd = URL(filePath: path) }
        guard entry["type"] as? String == "message", let message = entry["message"] as? Object else { return }
        switch message["role"] as? String {
        case "system":
            guard sections == nil, let given = message["sections"] as? Object else { return }
            sections = given.mapValues { value in (value as? String) ?? JSONLines.pretty(value) }
        case "user":
            if let skill = PiLogFormat.skillPrefixName(JSONLines.text(of: message["content"])) {
                userSkillCalls[skill, default: 0] += 1
            }
        case "assistant":
            if let usage = message["usage"] as? Object, let model = message["model"] as? String, !model.isEmpty {
                let id = message["responseId"] as? String ?? entry["id"] as? String ?? UUID().uuidString
                if seenCalls.insert(id).inserted {
                    let tokens = PiLogFormat.tokens(fromPiUsage: usage)
                    contexts.append(tokens.context)
                    let cost = usage["cost"] as? Object ?? [:]
                    func dollars(_ key: String) -> Double { (cost[key] as? NSNumber)?.doubleValue ?? 0 }
                    costs.append(.init(input: tokens.input, cacheRead: tokens.cacheRead, cacheWrite: tokens.cacheWrite,
                                       inputCost: dollars("input"), cacheReadCost: dollars("cacheRead"),
                                       cacheWriteCost: dollars("cacheWrite"), outputCost: dollars("output")))
                }
            }
            for block in message["content"] as? [Object] ?? [] where block["type"] as? String == "toolCall" {
                let name = block["name"] as? String ?? "tool"
                let arguments = block["arguments"] as? Object ?? [:]
                toolCalls[name, default: 0] += 1
                if let id = block["id"] as? String { pending[id] = (name, SecretFilter.readsSecretFile(arguments)) }
                if name == "read", let path = (arguments["path"] ?? arguments["file_path"]) as? String {
                    readPaths[standardized(path), default: 0] += 1
                }
            }
        case "toolResult":
            guard let id = message["toolCallId"] as? String, let call = pending.removeValue(forKey: id) else { return }
            let result = JSONLines.text(of: message["content"])
            record(call.name, ToolOutcomes.outcome(tool: call.name, result: result, isError: message["isError"] as? Bool == true),
                   example: call.readsSecret ? SecretFilter.hiddenOutput : result)
        default:
            break
        }
    }

    /// `~` and paths relative to the session's folder made absolute.
    private func standardized(_ path: String) -> String {
        let expanded = (path as NSString).expandingTildeInPath
        let url = expanded.hasPrefix("/") ? URL(filePath: expanded) : (cwd ?? URL(filePath: "/")).appending(path: expanded)
        return url.standardizedFileURL.path
    }

    private mutating func record(_ tool: String, _ outcome: ToolOutcomes.Outcome, example: String = "") {
        var entry = outcomeTools[tool] ?? ToolOutcomes.Tool(name: tool)
        entry.counts[outcome, default: 0] += 1
        if outcome != .ok, entry.examples[outcome] == nil, let line = FootprintReader.firstLine(example) {
            entry.examples[outcome] = String(SecretFilter.masked(line).prefix(200))
        }
        outcomeTools[tool] = entry
    }

    var outcomes: ToolOutcomes {
        var reader = self
        for call in pending.values { reader.record(call.name, .noResult) }
        return ToolOutcomes(tools: Array(reader.outcomeTools.values))
    }

    var footprint: ContextFootprint? {
        guard let sections else { return nil }
        var parts: [Part] = []
        var servers = MCPServers()
        for (key, text) in sections where !text.isEmpty {
            switch key {
            case "project_context": parts += projectContext(text)
            case "skills": parts += skills(text)
            case "tools": parts += tools(text, servers: &servers)
            default:
                parts.append(Part(group: .systemPrompt, name: Self.title(of: key), source: "Pi", tokens: TokenEstimate.tokens(text),
                                  use: .always, text: text))
            }
        }
        parts += servers.parts(calls: toolCalls)
        return ContextFootprint(harness: .pi, parts: parts, callContexts: contexts,
                                restNote: "Pi doesn't record the tool schemas it declares; they are in this part.", callCosts: costs)
    }

    static func title(of key: String) -> String {
        switch key {
        case "preamble": "Preamble"
        case "rules": "Pi's guidelines"
        case "docs": "Pi documentation pointers"
        case "cwd": "Working directory"
        default: key.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    /// Each `<project_instructions path="…">` is a rules file; the wrapping stays system prompt.
    private func projectContext(_ text: String) -> [Part] {
        var parts: [Part] = []
        var rest = text
        for match in text.matches(of: /<project_instructions path="([^"]*)">\n?(.*?)<\/project_instructions>/.dotMatchesNewlines()) {
            let path = String(match.1), body = String(match.2)
            parts.append(Part(group: .rules, name: URL(filePath: path).lastPathComponent, source: path,
                              tokens: TokenEstimate.tokens(String(match.0)), use: .always, text: body))
            rest = rest.replacingOccurrences(of: String(match.0), with: "")
        }
        return parts + wrapping("Project context wrapping", rest)
    }

    /// Each `<skill>` with its name, description and SKILL.md location.
    private func skills(_ text: String) -> [Part] {
        var parts: [Part] = []
        var rest = text
        for match in text.matches(of: /<skill>.*?<\/skill>/.dotMatchesNewlines()) {
            let block = String(match.0)
            guard let name = ClaudeLogFormat.tag("name", in: block) else { continue }
            let location = ClaudeLogFormat.tag("location", in: block)
            let calls = location.map { readPaths[standardized($0)] ?? 0 } ?? 0
            let userCalls = userSkillCalls[name] ?? 0
            let detail = calls == 0 && userCalls > 0
                ? "Only you ran it (/skill:\(name) ×\(userCalls)); the model never needed its description." : nil
            parts.append(Part(group: .skills, name: name, source: location, tokens: TokenEstimate.tokens(block),
                              use: calls > 0 ? .used : .unused, calls: calls, detail: detail, text: block))
            rest = rest.replacingOccurrences(of: block, with: "")
        }
        return parts + wrapping("Skills introduction", rest)
    }

    /// One `- name: description` line per declared tool; `mcp__server__tool` lines go to their server.
    private func tools(_ text: String, servers: inout MCPServers) -> [Part] {
        var parts: [Part] = []
        var rest: [String] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            guard line.hasPrefix("- "), let colon = line.firstIndex(of: ":") else {
                rest.append(line)
                continue
            }
            let name = String(line[line.index(line.startIndex, offsetBy: 2)..<colon]).trimmingCharacters(in: .whitespaces)
            if let server = MCPServers.server(ofTool: name) {
                servers.add(server, tool: name, text: line)
                continue
            }
            let calls = toolCalls[name] ?? 0
            let builtIn = Self.builtInTools.contains(name)
            parts.append(Part(group: .tools, name: name, source: builtIn ? "Built into Pi" : "An extension",
                              tokens: TokenEstimate.tokens(line), use: calls > 0 ? .used : .unused, calls: calls,
                              detail: "Its line in the system prompt; the schema Pi declares with it isn't recorded.", text: line))
        }
        return parts + wrapping("Tools introduction", rest.joined(separator: "\n"))
    }

    private func wrapping(_ name: String, _ text: String) -> [Part] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        return [Part(group: .systemPrompt, name: name, source: "Pi", tokens: TokenEstimate.tokens(trimmed), use: .always, text: trimmed)]
    }

    static let builtInTools: Set<String> = ["read", "bash", "powershell", "edit", "write", "grep", "find", "ls", "codemode", "tool_search"]
}
