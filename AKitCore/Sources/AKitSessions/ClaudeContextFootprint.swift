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

    /// Claude Code and Pi sessions; nil for other harnesses.
    public static func read(_ session: SessionSummary) throws -> SessionOverview? {
        switch session.harness {
        case .claudeCode: try ClaudeSessions.overview(of: session.file)
        case .pi: try PiSessions.overview(of: session.file)
        default: nil
        }
    }

    /// Harnesses whose sessions have an overview.
    public static func isAvailable(for harness: HarnessID) -> Bool { harness == .claudeCode || harness == .pi }
}

extension ClaudeSessions {
    /// The overview of a Claude Code session's main conversation. The context footprint (see
    /// `ContextFootprint`) comes from the `prompt_snapshot` (system prompt, tools), the
    /// attachments before the first answer (rules files, skill and subagent listings, MCP
    /// instructions, deferred tools, hook context) and what the conversation called.
    static func overview(of file: URL) throws -> SessionOverview {
        let data = try Data(contentsOf: file, options: .mappedIfSafe)
        let markers = ["\"type\":\"attachment\"", "\"type\":\"assistant\"", "command-name>", "\"tool_result\"",
                       "[Request interrupted by user for tool use]"].map { Data($0.utf8) }
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
    /// Skill calls by the model (the `Skill` tool) and by the user (`/name`).
    private var skillCalls: [String: Int] = [:]
    private var userSkillCalls: [String: Int] = [:]
    private var agentCalls: [String: Int] = [:]
    /// Tool use id → tool name and whether it read a secret file, until its result comes.
    private var pending: [String: (name: String, readsSecret: Bool)] = [:]
    private var outcomeTools: [String: ToolOutcomes.Tool] = [:]
    /// Tools whose results the latest user entry rejected: Claude Code follows a stopped tool
    /// call's rejection with `[Request interrupted by user for tool use]`.
    private var lastRejected: [String] = []

    mutating func read(_ entry: Object) {
        switch entry["type"] as? String {
        case "attachment":
            guard let attachment = entry["attachment"] as? Object else { return }
            if attachment["type"] as? String == "prompt_snapshot" {
                // The first call's: later snapshots (after a compaction or resume) can differ.
                // The first snapshots often have no tools; the list comes with a later one.
                let prompt = attachment["systemPrompt"]
                if sections == nil { sections = (prompt as? [String]) ?? (prompt as? String).map { [$0] } }
                if tools.isEmpty { tools = PromptTool.list(attachment["tools"]) }
            } else if beforeFirstAnswer {
                attachments.append(attachment)
            }
        case "assistant":
            guard let message = entry["message"] as? Object else { return }
            beforeFirstAnswer = false
            // Parallel calls each get their own result entry; the interrupt line follows them all.
            lastRejected = []
            if let usage = message["usage"] as? Object, message["model"] as? String != "<synthetic>" {
                let id = message["id"] as? String ?? entry["requestId"] as? String ?? UUID().uuidString
                if seenCalls.insert(id).inserted { contexts.append(ClaudeLogFormat.tokens(fromClaudeUsage: usage).context) }
            }
            for block in message["content"] as? [Object] ?? [] where block["type"] as? String == "tool_use" {
                let name = block["name"] as? String ?? ""
                let input = block["input"] as? Object ?? [:]
                toolCalls[name, default: 0] += 1
                if let id = block["id"] as? String { pending[id] = (name, SecretFilter.readsSecretFile(input)) }
                if name == "Skill", let skill = input["skill"] as? String { skillCalls[skill, default: 0] += 1 }
                if name == "Agent" || name == "Task" {
                    agentCalls[input["subagent_type"] as? String ?? "general-purpose", default: 0] += 1
                }
            }
        case "user":
            guard let message = entry["message"] as? Object else { return }
            let blocks = message["content"] as? [Object] ?? []
            for block in blocks where block["type"] as? String == "tool_result" {
                guard let id = block["tool_use_id"] as? String, let call = pending.removeValue(forKey: id) else { continue }
                // Classified from the real text; a secret file's output is never kept as the example.
                let result = JSONLines.text(of: block["content"])
                let outcome = ToolOutcomes.outcome(tool: call.name, result: result, isError: block["is_error"] as? Bool == true)
                record(call.name, outcome, example: call.readsSecret ? SecretFilter.hiddenOutput : result)
                if outcome == .rejected { lastRejected.append(call.name) }
            }
            guard entry["isMeta"] as? Bool != true else { return }
            let text = JSONLines.text(of: message["content"]).trimmingCharacters(in: .whitespacesAndNewlines)
            if text.hasPrefix("[Request interrupted by user for tool use]") {
                for tool in lastRejected { move(tool, from: .rejected, to: .interrupted) }
                lastRejected = []
            }
            // Same rule as Insights: a skill run by `/name` is written as `<command-message>…`.
            if text.hasPrefix("<command-message>"), let command = ClaudeLogFormat.tag("command-name", in: text),
               command.hasPrefix("/"), command.count > 1 {
                userSkillCalls[String(command.dropFirst()), default: 0] += 1
            }
        default:
            break
        }
    }

    private mutating func record(_ tool: String, _ outcome: ToolOutcomes.Outcome, example: String = "") {
        var entry = outcomeTools[tool] ?? ToolOutcomes.Tool(name: tool)
        entry.counts[outcome, default: 0] += 1
        if outcome != .ok, entry.examples[outcome] == nil {
            // Masked before it is cut, so a cut can't leave part of a secret unmatched.
            if let line = Self.firstLine(example) { entry.examples[outcome] = String(SecretFilter.masked(line).prefix(200)) }
        }
        outcomeTools[tool] = entry
    }

    private mutating func move(_ tool: String, from: ToolOutcomes.Outcome, to: ToolOutcomes.Outcome) {
        guard var entry = outcomeTools[tool], entry.count(from) > 0 else { return }
        entry.counts[from]! -= 1
        entry.examples[to] = entry.examples[to] ?? entry.examples[from]
        if entry.counts[from] == 0 {
            entry.counts[from] = nil
            entry.examples[from] = nil
        }
        entry.counts[to, default: 0] += 1
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
        for call in pending.values { reader.record(call.name, .noResult) }
        return ToolOutcomes(tools: Array(reader.outcomeTools.values))
    }

    var footprint: ContextFootprint? {
        guard let sections else { return nil }
        var parts: [Part] = []
        var servers = MCPServers()

        for section in sections {
            parts.append(Part(group: .systemPrompt, name: SecretFilter.masked(Self.title(of: section)),
                              tokens: TokenEstimate.tokens(section), use: .always, text: section))
        }
        for tool in tools {
            let schema = Self.compact(tool.schema)
            if let server = MCPServers.server(ofTool: tool.name) {
                servers.add(server, tool: tool.name, text: tool.name + tool.description + schema)
            } else {
                parts.append(toolPart(tool.name, description: tool.description, schema: schema, pretty: tool.schema))
            }
        }
        for attachment in attachments {
            parts += self.parts(of: attachment, servers: &servers)
        }
        parts += servers.parts(calls: toolCalls)
        return ContextFootprint(harness: .claudeCode, parts: Self.merged(parts), callContexts: contexts)
    }

    /// A tool of the harness itself (MCP and plugin tools go to their server).
    private func toolPart(_ name: String, description: String, schema: String, pretty: String? = nil) -> Part {
        let calls = toolCalls[name] ?? 0
        let described = TokenEstimate.tokens(name + description), schemaTokens = TokenEstimate.tokens(schema)
        let detail = schema.isEmpty ? nil : "Description ≈ \(described) tokens · input schema ≈ \(schemaTokens) tokens"
        let text = description + ((pretty ?? schema).isEmpty ? "" : "\n\nInput schema:\n" + (pretty ?? schema))
        return Part(group: .tools, name: name, source: "Built into Claude Code", tokens: described + schemaTokens,
                    use: calls > 0 ? .used : .unused, calls: calls, detail: detail, text: text)
    }

    private func parts(of attachment: Object, servers: inout MCPServers) -> [Part] {
        switch attachment["type"] as? String {
        case "instructions":
            return (attachment["files"] as? [Object] ?? []).compactMap { file in
                guard let text = file["content"] as? String else { return nil }
                let path = file["path"] as? String
                let name = path.map { URL(filePath: $0).lastPathComponent } ?? "Instructions"
                let kind = (file["type"] as? String).map { " · \($0)" } ?? ""
                return Part(group: .rules, name: name + kind, source: path, tokens: TokenEstimate.tokens(text), use: .always, text: text)
            }
        case "skill_listing":
            let listed = ClaudeLogFormat.listedSkills(attachment)
            let names = listed.map(\.name)
            let byModel = Self.callsBySkill(skillCalls, listed: names)
            let byUser = Self.callsBySkill(userSkillCalls, listed: names)
            return listed.map { skill in
                let calls = byModel[skill.name] ?? 0, userCalls = byUser[skill.name] ?? 0
                let plugin = skill.name.split(separator: ":").first.map(String.init)
                // The listing is for the model: a skill only you ran with /name didn't need it.
                let detail = calls == 0 && userCalls > 0
                    ? "Only you ran it (/\(skill.name) ×\(userCalls)); the model never needed its description." : nil
                return Part(group: .skills, name: skill.name, source: skill.name.contains(":") ? plugin.map { "plugin \($0)" } : nil,
                            tokens: TokenEstimate.tokens(skill.line), use: calls > 0 ? .used : .unused, calls: calls, detail: detail,
                            text: skill.line)
            }
        case "agent_listing_delta":
            let lines = attachment["addedLines"] as? [String] ?? []
            return (attachment["addedTypes"] as? [String] ?? []).map { type in
                let line = lines.first { $0.hasPrefix("- \(type):") || $0 == "- \(type)" } ?? type
                let calls = agentCalls[type] ?? 0
                return Part(group: .subagents, name: type, tokens: TokenEstimate.tokens(line), use: calls > 0 ? .used : .unused, calls: calls,
                            text: line)
            }
        case "mcp_instructions_delta":
            let names = attachment["addedNames"] as? [String] ?? []
            let longestFirst = names.sorted { $0.count > $1.count }
            for block in attachment["addedBlocks"] as? [String] ?? [] {
                let name = longestFirst.first { block == "## \($0)" || block.hasPrefix("## \($0)\n") } ?? names.first ?? "MCP"
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
                    var part = toolPart(name, description: line == name ? "" : line, schema: "")
                    part.detail = "Deferred: only the name is sent until the model loads the tool with ToolSearch."
                    parts.append(part)
                }
            }
            return parts
        case "deferred_tools_record":
            return (attachment["entries"] as? [Object] ?? []).compactMap { entry in
                guard let name = entry["name"] as? String else { return nil }
                let description = entry["description"] as? String ?? "", pretty = JSONLines.pretty(entry["input_schema"])
                if let server = MCPServers.server(ofTool: name) {
                    servers.add(server, tool: name, text: name + description + Self.compact(pretty))
                    return nil
                }
                return toolPart(name, description: description, schema: Self.compact(pretty), pretty: pretty)
            }
        case "hook_additional_context":
            let text = (attachment["content"] as? [String])?.joined(separator: "\n\n") ?? attachment["content"] as? String ?? ""
            return [Part(group: .hooks, name: attachment["hookName"] as? String ?? "hook", tokens: TokenEstimate.tokens(text), use: .always,
                         text: text)]
        default:
            return ClaudeSessions.contextParts(of: attachment, startingAt: 0).map {
                Part(group: .other, name: $0.title, source: $0.source, tokens: TokenEstimate.tokens($0.text), use: .always, text: $0.text)
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
                existing.text = [existing.text, part.text].compactMap { $0 }.joined(separator: "\n\n")
                byID[part.id] = existing
            } else {
                order.append(part.id)
                byID[part.id] = part
            }
        }
        return order.compactMap { byID[$0] }
    }

    /// Calls per listed skill. A call names the listed skill exactly, or by its base name
    /// (`ralph` for `omc:ralph`, or the other way round) when only one listed skill has that base.
    static func callsBySkill(_ calls: [String: Int], listed: [String]) -> [String: Int] {
        func base(_ name: String) -> Substring { name.split(separator: ":").last ?? Substring(name) }
        var result: [String: Int] = [:]
        for (called, count) in calls {
            if listed.contains(called) {
                result[called, default: 0] += count
            } else {
                let matches = listed.filter { base($0) == base(called) }
                if matches.count == 1 { result[matches[0], default: 0] += count }
            }
        }
        return result
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
        var instructions: String?
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
        edit(server) { $0.tokens += TokenEstimate.tokens(instructions); $0.name = server; $0.instructions = instructions }
    }

    func parts(calls: [String: Int]) -> [ContextFootprint.Part] {
        order.compactMap { key in
            guard let server = servers[key] else { return nil }
            let called = calls.filter { Self.server(ofTool: $0.key).map(Self.key) == key }
            let total = called.values.reduce(0, +)
            let tools = server.tools.count
            var detail = "\(tools) tool\(tools == 1 ? "" : "s")" + (server.instructions != nil ? " and instructions" : "")
            if !called.isEmpty {
                let names = called.sorted { ($0.value, $1.key) > ($1.value, $0.key) }.prefix(5).map { call in
                    let short = call.key.split(separator: "__").last.map(String.init) ?? call.key
                    return call.value > 1 ? "\(short) ×\(call.value)" : short
                }
                detail += "; called: " + names.joined(separator: ", ") + (called.count > 5 ? "…" : "")
            }
            return ContextFootprint.Part(group: .mcp, name: server.name, source: "MCP server",
                                         tokens: server.tokens, use: total > 0 ? .used : .unused,
                                         calls: total, detail: detail,
                                         text: ([server.instructions].compactMap { $0 } + ["Tools:\n" + server.tools.sorted().joined(separator: "\n")])
                                             .joined(separator: "\n\n"))
        }
    }
}
