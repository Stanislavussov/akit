import AKitFoundation
import AKitModel
import Foundation

/// What happened in one session, at a glance: where its context went and how its tool calls ended.
public struct SessionOverview: Codable, Sendable, Hashable {
    /// nil = the session has no recorded system prompt (older Claude Code versions).
    public var footprint: ContextFootprint?
    public var tools: ToolOutcomes

    public init(footprint: ContextFootprint?, tools: ToolOutcomes) {
        self.footprint = footprint
        self.tools = tools
    }

    /// Claude Code sessions only; nil for other harnesses.
    public static func read(_ session: SessionSummary) throws -> SessionOverview? {
        guard session.harness == .claudeCode else { return nil }
        return try ClaudeSessions.overview(of: session.file)
    }
}

extension ClaudeSessions {
    /// The overview of a Claude Code session's main conversation. The context footprint (see
    /// `ContextFootprint`) comes from the `prompt_snapshot` (system prompt, tools), the
    /// attachments before the first answer (rules files, skill and subagent listings, MCP
    /// instructions, deferred tools, hook context) and what the conversation called.
    static func overview(of file: URL) throws -> SessionOverview {
        let data = try Data(contentsOf: file, options: .mappedIfSafe)
        let markers = ["\"type\":\"attachment\"", "\"type\":\"assistant\"", "command-name>", "\"tool_result\""].map { Data($0.utf8) }
        var reader = FootprintReader()
        for entry in try JSONLines.objects(in: data, where: { line in markers.contains { JSONLines.contains(line, $0) } })
        where !ClaudeLogFormat.isSidechain(entry) {
            reader.read(entry)
        }
        return SessionOverview(footprint: reader.footprint, tools: reader.outcomes)
    }

    static func footprint(of file: URL) throws -> ContextFootprint? {
        try overview(of: file).footprint
    }
}

/// Reads a Claude Code session in order for `ClaudeSessions.footprint(of:)`.
struct FootprintReader {
    typealias Object = JSONLines.Object
    typealias Part = ContextFootprint.Part

    private var sections: [String]?
    private var tools: [PromptTool] = []
    private var beforeFirstAnswer = true
    /// Attachments sent with the first call.
    private var attachments: [Object] = []
    private var seenCalls = Set<String>()
    private var contexts: [Int] = []
    private var toolCalls: [String: Int] = [:]
    private var skillCalls: [String: Int] = [:]
    private var agentCalls: [String: Int] = [:]
    /// Tool use id → tool name, until its result comes.
    private var pending: [String: String] = [:]
    private var outcomeTools: [String: ToolOutcomes.Tool] = [:]

    mutating func read(_ entry: Object) {
        switch entry["type"] as? String {
        case "attachment":
            guard let attachment = entry["attachment"] as? Object else { return }
            if attachment["type"] as? String == "prompt_snapshot" {
                let prompt = attachment["systemPrompt"]
                sections = ((prompt as? [String]) ?? (prompt as? String).map { [$0] }) ?? sections
                let listed = PromptTool.list(attachment["tools"])
                if !listed.isEmpty { tools = listed }
            } else if beforeFirstAnswer {
                attachments.append(attachment)
            }
        case "assistant":
            guard let message = entry["message"] as? Object else { return }
            beforeFirstAnswer = false
            if let usage = message["usage"] as? Object, message["model"] as? String != "<synthetic>" {
                let id = message["id"] as? String ?? entry["requestId"] as? String ?? UUID().uuidString
                if seenCalls.insert(id).inserted { contexts.append(ClaudeLogFormat.tokens(fromClaudeUsage: usage).context) }
            }
            for block in message["content"] as? [Object] ?? [] where block["type"] as? String == "tool_use" {
                let name = block["name"] as? String ?? ""
                let input = block["input"] as? Object ?? [:]
                toolCalls[name, default: 0] += 1
                if let id = block["id"] as? String { pending[id] = name }
                if name == "Skill", let skill = input["skill"] as? String { skillCalls[skill, default: 0] += 1 }
                if name == "Agent" || name == "Task" {
                    agentCalls[input["subagent_type"] as? String ?? "general-purpose", default: 0] += 1
                }
            }
        case "user":
            guard let message = entry["message"] as? Object else { return }
            for block in message["content"] as? [Object] ?? [] where block["type"] as? String == "tool_result" {
                guard let id = block["tool_use_id"] as? String, let name = pending.removeValue(forKey: id) else { continue }
                let result = JSONLines.text(of: block["content"])
                let outcome = ToolOutcomes.outcome(tool: name, result: result, isError: block["is_error"] as? Bool == true)
                record(name, outcome, example: result)
            }
            guard entry["isMeta"] as? Bool != true else { return }
            let text = JSONLines.text(of: message["content"])
            if let command = ClaudeLogFormat.tag("command-name", in: text), command.hasPrefix("/"), command.count > 1 {
                skillCalls[String(command.dropFirst()), default: 0] += 1
            }
        default:
            break
        }
    }

    private mutating func record(_ tool: String, _ outcome: ToolOutcomes.Outcome, example: String = "") {
        var entry = outcomeTools[tool] ?? ToolOutcomes.Tool(name: tool)
        entry.counts[outcome, default: 0] += 1
        if outcome != .ok, entry.examples[outcome] == nil {
            if let line = Self.firstLine(example) { entry.examples[outcome] = SecretFilter.masked(String(line.prefix(200))) }
        }
        outcomeTools[tool] = entry
    }

    /// The first line that says something; `Exit code 1` alone gets the line after it.
    static func firstLine(_ text: String) -> String? {
        let lines = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard let first = lines.first else { return nil }
        if first.wholeMatch(of: /Exit code \d+/) != nil, lines.count > 1 { return "\(first): \(lines[1])" }
        return first
    }

    /// Calls without a result count as `noResult`.
    var outcomes: ToolOutcomes {
        var reader = self
        for name in pending.values { reader.record(name, .noResult) }
        return ToolOutcomes(tools: Array(reader.outcomeTools.values))
    }

    var footprint: ContextFootprint? {
        guard let sections else { return nil }
        var parts: [Part] = []
        var servers = MCPServers()

        for section in sections {
            parts.append(Part(group: .systemPrompt, name: Self.title(of: section), tokens: TokenEstimate.tokens(section), use: .always))
        }
        for tool in tools {
            let text = tool.name + tool.description + Self.compact(tool.schema)
            if let server = MCPServers.server(ofTool: tool.name) {
                servers.add(server, tool: tool.name, text: text)
            } else {
                parts.append(toolPart(tool.name, text: text))
            }
        }
        for attachment in attachments {
            parts += self.parts(of: attachment, servers: &servers)
        }
        parts += servers.parts(calls: toolCalls)
        return ContextFootprint(harness: .claudeCode, parts: Self.merged(parts), callContexts: contexts)
    }

    private func toolPart(_ name: String, text: String) -> Part {
        let calls = toolCalls[name] ?? 0
        return Part(group: .tools, name: name, tokens: TokenEstimate.tokens(text), use: calls > 0 ? .used : .unused, calls: calls)
    }

    private func parts(of attachment: Object, servers: inout MCPServers) -> [Part] {
        switch attachment["type"] as? String {
        case "instructions":
            return (attachment["files"] as? [Object] ?? []).compactMap { file in
                guard let text = file["content"] as? String else { return nil }
                let path = file["path"] as? String
                let name = path.map { URL(filePath: $0).lastPathComponent } ?? "Instructions"
                let kind = (file["type"] as? String).map { " · \($0)" } ?? ""
                return Part(group: .rules, name: name + kind, source: path, tokens: TokenEstimate.tokens(text), use: .always)
            }
        case "skill_listing":
            return ClaudeLogFormat.listedSkills(attachment).map { skill in
                let calls = skillCalls.filter { Self.sameSkill($0.key, skill.name) }.values.reduce(0, +)
                let plugin = skill.name.split(separator: ":").first.map(String.init)
                return Part(group: .skills, name: skill.name, source: skill.name.contains(":") ? plugin.map { "plugin \($0)" } : nil,
                            tokens: TokenEstimate.tokens(skill.line), use: calls > 0 ? .used : .unused, calls: calls)
            }
        case "agent_listing_delta":
            let lines = attachment["addedLines"] as? [String] ?? []
            return (attachment["addedTypes"] as? [String] ?? []).map { type in
                let line = lines.first { $0.hasPrefix("- \(type):") || $0 == "- \(type)" } ?? type
                let calls = agentCalls[type] ?? 0
                return Part(group: .subagents, name: type, tokens: TokenEstimate.tokens(line), use: calls > 0 ? .used : .unused, calls: calls)
            }
        case "mcp_instructions_delta":
            let names = attachment["addedNames"] as? [String] ?? []
            for block in attachment["addedBlocks"] as? [String] ?? [] {
                let name = names.first { block.hasPrefix("## \($0)") } ?? names.first ?? "MCP"
                servers.add(name, instructions: block)
            }
            return []
        case "deferred_tools_delta":
            let names = attachment["addedNames"] as? [String] ?? []
            let lines = attachment["addedLines"] as? [String] ?? names
            var parts: [Part] = []
            for (index, name) in names.enumerated() {
                let line = index < lines.count ? lines[index] : name
                if let server = MCPServers.server(ofTool: name) {
                    servers.add(server, tool: name, text: line)
                } else {
                    var part = toolPart(name, text: line)
                    part.detail = "Deferred: only the name is sent until the model loads the tool."
                    parts.append(part)
                }
            }
            return parts
        case "deferred_tools_record":
            return (attachment["entries"] as? [Object] ?? []).compactMap { entry in
                guard let name = entry["name"] as? String else { return nil }
                let text = name + (entry["description"] as? String ?? "") + Self.compact(JSONLines.pretty(entry["input_schema"]))
                if let server = MCPServers.server(ofTool: name) {
                    servers.add(server, tool: name, text: text)
                    return nil
                }
                return toolPart(name, text: text)
            }
        case "hook_additional_context":
            let text = (attachment["content"] as? [String])?.joined(separator: "\n\n") ?? attachment["content"] as? String ?? ""
            return [Part(group: .hooks, name: attachment["hookName"] as? String ?? "hook", tokens: TokenEstimate.tokens(text), use: .always)]
        default:
            return ClaudeSessions.contextParts(of: attachment, startingAt: 0).map {
                Part(group: .other, name: $0.title, source: $0.source, tokens: TokenEstimate.tokens($0.text), use: .always)
            }
        }
    }

    /// One part per group and name: a hook that ran twice, a tool listed and then recorded.
    static func merged(_ parts: [Part]) -> [Part] {
        var order: [String] = []
        var byID: [String: Part] = [:]
        for part in parts {
            if var existing = byID[part.id] {
                existing.tokens += part.tokens
                existing.detail = existing.detail ?? part.detail
                byID[part.id] = existing
            } else {
                order.append(part.id)
                byID[part.id] = part
            }
        }
        return order.compactMap { byID[$0] }
    }

    /// `oh-my-claudecode:ralph` called as `ralph`, or the other way round.
    static func sameSkill(_ called: String, _ listed: String) -> Bool {
        func base(_ name: String) -> Substring { name.split(separator: ":").last ?? Substring(name) }
        return called == listed || (base(called) == base(listed) && (called.contains(":") != listed.contains(":")))
    }

    /// A pretty-printed schema as the model gets it: without the indentation.
    static func compact(_ json: String) -> String {
        json.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.joined()
    }

    /// A system prompt block's first line, without heading marks, cut short.
    static func title(of section: String) -> String {
        let line = section.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let title = line.trimmingCharacters(in: CharacterSet(charactersIn: "# ").union(.whitespaces))
        guard !title.isEmpty else { return "Section" }
        return title.count > 60 ? String(title.prefix(59)) + "…" : title
    }
}

/// MCP servers by a key that matches a server's display name (`claude.ai Claude Docs`) and its
/// tool prefix (`mcp__claude_ai_Claude_Docs__…`).
struct MCPServers {
    private struct Server {
        var name: String
        var tokens = 0
        var tools = Set<String>()
        var hasInstructions = false
    }

    private var servers: [String: Server] = [:]
    private var order: [String] = []

    /// `mcp__server__tool` → `server`.
    static func server(ofTool name: String) -> String? {
        guard name.hasPrefix("mcp__") else { return nil }
        let rest = name.dropFirst(5)
        guard let end = rest.range(of: "__") else { return nil }
        return String(rest[..<end.lowerBound])
    }

    static func key(_ name: String) -> String {
        String(name.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "_" })
    }

    private mutating func edit(_ name: String, _ change: (inout Server) -> Void) {
        let key = Self.key(name)
        if servers[key] == nil {
            order.append(key)
            servers[key] = Server(name: name)
        }
        change(&servers[key]!)
    }

    mutating func add(_ server: String, tool: String, text: String) {
        edit(server) { $0.tokens += TokenEstimate.tokens(text); $0.tools.insert(tool) }
    }

    /// Instructions carry the display name, which reads better than the tool prefix.
    mutating func add(_ server: String, instructions: String) {
        edit(server) { $0.tokens += TokenEstimate.tokens(instructions); $0.name = server; $0.hasInstructions = true }
    }

    func parts(calls: [String: Int]) -> [ContextFootprint.Part] {
        order.compactMap { key in
            guard let server = servers[key] else { return nil }
            let called = calls.filter { Self.server(ofTool: $0.key).map(Self.key) == key }
            let total = called.values.reduce(0, +)
            let tools = server.tools.count
            var detail = "\(tools) tool\(tools == 1 ? "" : "s")" + (server.hasInstructions ? " and instructions" : "")
            if !called.isEmpty {
                let names = called.sorted { ($0.value, $1.key) > ($1.value, $0.key) }.prefix(5).map { call in
                    let short = call.key.split(separator: "__").last.map(String.init) ?? call.key
                    return call.value > 1 ? "\(short) ×\(call.value)" : short
                }
                detail += "; called: " + names.joined(separator: ", ") + (called.count > 5 ? "…" : "")
            }
            return ContextFootprint.Part(group: .mcp, name: server.name, source: "MCP server",
                                         tokens: server.tokens, use: total > 0 ? .used : .unused,
                                         calls: total, detail: detail)
        }
    }
}
