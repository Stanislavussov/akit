import Foundation

/// Claude Code session files: `<config>/projects/<encoded cwd>/<session id>.jsonl`.
/// Each line is an entry: `user`, `assistant`, `system`, `attachment` (context the
/// harness injected), plus metadata such as `ai-title`. Subagent runs live in
/// `<session id>/subagents/` and are not listed.
enum ClaudeSessions {
    typealias Object = JSONLines.Object

    static func list(configRoot: URL) -> [SessionSummary] {
        let projects = configRoot.appending(path: "projects")
        let files = SkillScanner.children(of: projects)
            .filter(SkillScanner.isDirectory)
            .flatMap { folder in
                SkillScanner.children(of: folder).filter { $0.pathExtension == "jsonl" }
            }
        return JSONLines.summaries(of: files) { summary(of: $0) }
    }

    static func summary(of file: URL) -> SessionSummary? {
        var cwd: String?
        var version: String?
        var started: Date?
        var firstPrompt: String?
        JSONLines.scanHead(of: file) { entry in
            cwd = cwd ?? entry["cwd"] as? String
            version = version ?? entry["version"] as? String
            started = started ?? JSONLines.date(entry["timestamp"])
            firstPrompt = firstPrompt ?? promptText(entry)
            return cwd != nil && firstPrompt != nil
        }

        var customTitle: String?
        var aiTitle: String?
        var summaryTitle: String?
        for entry in JSONLines.tail(of: file) {
            switch entry["type"] as? String {
            case "custom-title": customTitle = entry["customTitle"] as? String ?? customTitle
            case "ai-title": aiTitle = entry["aiTitle"] as? String ?? aiTitle
            case "summary": summaryTitle = entry["summary"] as? String ?? summaryTitle
            default: break
            }
        }
        // A file with nothing but metadata (e.g. an aborted start) is not a conversation.
        guard firstPrompt != nil || aiTitle != nil || customTitle != nil else { return nil }

        let title = [customTitle, aiTitle, summaryTitle, firstPrompt.map { JSONLines.titleLine(SecretFilter.masked($0)) }]
            .compactMap { $0 }.first { !$0.isEmpty } ?? "Untitled session"
        let info = JSONLines.fileInfo(file)
        return SessionSummary(harness: .claudeCode, file: file, title: title,
                              project: cwd.map { URL(filePath: $0, directoryHint: .isDirectory) },
                              started: started, modified: info.modified, size: info.size, harnessVersion: version)
    }

    /// Text the user typed, or nil for tool results, harness-injected and meta entries.
    static func promptText(_ entry: Object) -> String? {
        guard entry["type"] as? String == "user", !isSidechain(entry),
              entry["isMeta"] as? Bool != true, entry["isCompactSummary"] as? Bool != true,
              let message = entry["message"] as? Object else { return nil }
        if let blocks = message["content"] as? [Object], blocks.contains(where: { $0["type"] as? String == "tool_result" }) {
            return nil
        }
        let text = JSONLines.text(of: message["content"]).trimmingCharacters(in: .whitespacesAndNewlines)
        // Slash commands and their output are wrapped in tags like <command-name>.
        if text.isEmpty || text.hasPrefix("<") || text.hasPrefix("[Request interrupted") { return nil }
        return text
    }

    static func isSidechain(_ entry: Object) -> Bool { entry["isSidechain"] as? Bool == true }

    // MARK: - Transcript

    static func transcript(of file: URL) throws -> SessionTranscript {
        let data = try Data(contentsOf: file)
        var builder = TranscriptBuilder()
        var tools: [String: ToolCall] = [:]
        var shellReadsSecret = false // the last `!` shell command read a secret file

        for entry in try JSONLines.objects(in: data) {
            // Side chains: subagents of old versions, written into the main file.
            if isSidechain(entry) {
                recordUsage(entry, in: &builder.subagentUsage)
                continue
            }
            let time = JSONLines.date(entry["timestamp"])
            switch entry["type"] as? String {
            case "user":
                addUser(entry, at: time, tools: tools, shellReadsSecret: &shellReadsSecret, to: &builder)
            case "assistant":
                guard let message = entry["message"] as? Object else { continue }
                builder.noteModel((message["model"] as? String).flatMap { $0 == "<synthetic>" ? nil : $0 })
                recordUsage(entry, in: &builder.usage)
                for block in message["content"] as? [Object] ?? [] {
                    switch block["type"] as? String {
                    case "text":
                        builder.add(.assistant, block["text"] as? String ?? "", at: time)
                    case "thinking":
                        builder.add(.thinking, block["thinking"] as? String ?? "", at: time)
                    case "tool_use":
                        let name = block["name"] as? String ?? "tool"
                        let input = JSONLines.pretty(SecretFilter.redactedInput(block["input"]))
                        if let id = block["id"] as? String {
                            tools[id] = ToolCall(name: name, readsSecretFile: SecretFilter.readsSecretFile(block["input"]))
                        }
                        builder.add(.toolCall(name: name), input, at: time)
                    default:
                        break
                    }
                }
            case "system":
                switch entry["subtype"] as? String {
                case "compact_boundary": builder.add(.event("Compacted"), "Earlier messages were summarized", at: time)
                case "local_command": builder.add(.event("Command"), stripTags(entry["content"] as? String ?? ""), at: time)
                case "turn_duration":
                    if let milliseconds = entry["durationMs"] as? NSNumber, let end = time {
                        builder.addActiveTurn(DateInterval(start: end.addingTimeInterval(-milliseconds.doubleValue / 1000),
                                                           end: end))
                    }
                default: break
                }
            default:
                break
            }
        }
        try addSubagents(of: file, to: &builder)
        return builder.transcript
    }

    /// Subagents of newer versions: `<session>/subagents/agent-*.jsonl`. Only their usage is read.
    private static func addSubagents(of file: URL, to builder: inout TranscriptBuilder) throws {
        let folder = file.deletingPathExtension().appending(path: "subagents")
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        let usageLine = Data(#""usage""#.utf8)
        for agent in files where agent.pathExtension == "jsonl" {
            guard let data = try? Data(contentsOf: agent) else { continue }
            builder.subagentRuns += 1
            for entry in try JSONLines.objects(in: data, where: { JSONLines.contains($0, usageLine) })
            where entry["type"] as? String == "assistant" {
                recordUsage(entry, in: &builder.subagentUsage)
            }
        }
    }

    /// `message.usage` of an assistant entry. Lines of one response share `message.id`.
    private static func recordUsage(_ entry: Object, in counter: inout UsageCounter) {
        guard entry["type"] as? String == "assistant", let message = entry["message"] as? Object,
              let usage = message["usage"] as? Object else { return }
        func count(_ key: String, in object: Object? = usage) -> Int { (object?[key] as? NSNumber)?.intValue ?? 0 }
        let tokens = TokenCounts(input: count("input_tokens"), output: count("output_tokens"),
                                 cacheRead: count("cache_read_input_tokens"),
                                 cacheWrite: count("cache_creation_input_tokens"),
                                 reasoning: count("thinking_tokens", in: usage["output_tokens_details"] as? Object))
        counter.record(id: message["id"] as? String ?? entry["requestId"] as? String,
                       model: message["model"] as? String, tokens: tokens)
    }

    struct ToolCall {
        let name: String
        let readsSecretFile: Bool
    }

    private static func addUser(_ entry: Object, at time: Date?, tools: [String: ToolCall],
                                shellReadsSecret: inout Bool, to builder: inout TranscriptBuilder) {
        guard entry["isMeta"] as? Bool != true, let message = entry["message"] as? Object else { return }
        let content = message["content"]
        if entry["isCompactSummary"] as? Bool == true {
            builder.add(.event("Compaction summary"), JSONLines.text(of: content), at: time)
            return
        }
        if let blocks = content as? [Object] {
            for block in blocks where block["type"] as? String == "tool_result" {
                let call = (block["tool_use_id"] as? String).flatMap { tools[$0] }
                builder.addToolOutput(.toolResult(name: call?.name, isError: block["is_error"] as? Bool == true),
                                      JSONLines.text(of: block["content"]),
                                      readSecretFile: call?.readsSecretFile ?? false, at: time)
            }
            let text = JSONLines.text(of: blocks.filter { $0["type"] as? String != "tool_result" })
            addPrompt(text, at: time, shellReadsSecret: &shellReadsSecret, to: &builder)
        } else {
            addPrompt(JSONLines.text(of: content), at: time, shellReadsSecret: &shellReadsSecret, to: &builder)
        }
    }

    private static func addPrompt(_ text: String, at time: Date?, shellReadsSecret: inout Bool,
                                  to builder: inout TranscriptBuilder) {
        if text.hasPrefix("<bash-input>") {
            // `!` shell mode: the command, then its output in a separate entry.
            let command = stripTags(text)
            shellReadsSecret = SecretFilter.commandReadsSecretFile(command)
            builder.add(.event("Shell"), "$ \(command)", at: time)
        } else if text.hasPrefix("<bash-stdout>") || text.hasPrefix("<bash-stderr>") {
            builder.addToolOutput(.event("Shell output"), stripTags(text), readSecretFile: shellReadsSecret, at: time)
        } else if text.hasPrefix("<command-name>") || text.hasPrefix("<command-message>") {
            builder.add(.event("Command"), commandLine(text), at: time)
        } else if text.hasPrefix("<local-command-stdout>") || text.hasPrefix("<local-command-stderr>") {
            builder.add(.event("Command output"), stripTags(text), at: time)
        } else if text.hasPrefix("<local-command-caveat>") {
            return
        } else {
            builder.add(.user, text, at: time)
        }
    }

    /// `<command-name>/model</command-name><command-args>opus</command-args>` → `/model opus`.
    static func commandLine(_ text: String) -> String {
        func tag(_ name: String) -> String? {
            guard let open = text.range(of: "<\(name)>"), let close = text.range(of: "</\(name)>", range: open.upperBound..<text.endIndex)
            else { return nil }
            return String(text[open.upperBound..<close.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let name = tag("command-name") ?? tag("command-message") ?? ""
        let args = tag("command-args") ?? ""
        return args.isEmpty ? name : "\(name) \(args)"
    }

    static func stripTags(_ text: String) -> String {
        text.replacingOccurrences(of: "</?[a-z-]+>", with: "", options: .regularExpression)
    }
}

// MARK: - System prompt

extension ClaudeSessions {
    /// Claude Code (2.1.26x and newer) records the system prompt it sends as a
    /// `prompt_snapshot` attachment and reuses it until the conversation is compacted;
    /// the latest one is returned. Context comes from the attachments of the first request:
    /// Claude writes them around the first prompt, before the first answer.
    /// nil = the session has no snapshot (older versions).
    static func recordedPrompt(in file: URL) throws -> PromptSnapshot? {
        let data = try Data(contentsOf: file, options: .mappedIfSafe)
        // Most lines are messages and tool output; only decode the ones that matter here.
        let snapshotMarker = Data("\"prompt_snapshot\"".utf8)
        guard data.range(of: snapshotMarker) != nil else { return nil }
        let attachment = Data("\"type\":\"attachment\"".utf8)
        let assistant = Data("\"type\":\"assistant\"".utf8)
        var sections: [String]?
        var tools: [PromptTool] = []
        var context: [PromptContextPart] = []
        var beforeFirstAnswer = true

        let entries = try JSONLines.objects(in: data) { line in
            JSONLines.contains(line, attachment) || JSONLines.contains(line, assistant)
        }
        for entry in entries where !isSidechain(entry) {
            if entry["type"] as? String == "assistant" { beforeFirstAnswer = false }
            guard entry["type"] as? String == "attachment", let attachment = entry["attachment"] as? Object else { continue }
            if attachment["type"] as? String == "prompt_snapshot" {
                let prompt = attachment["systemPrompt"]
                sections = ((prompt as? [String]) ?? (prompt as? String).map { [$0] })?.map(SecretFilter.masked) ?? sections
                // Some snapshots carry only the prompt; keep the last tool list seen.
                let listed = PromptTool.list(attachment["tools"])
                if !listed.isEmpty { tools = listed }
            } else if beforeFirstAnswer {
                context += contextParts(of: attachment, startingAt: context.count)
            }
        }
        guard let sections else { return nil }
        return PromptSnapshot(harness: .claudeCode, source: .recorded(session: file), sections: sections,
                              tools: tools, context: context)
    }

    /// Only attachment types known to be model context are shown. Others (account data,
    /// hook stdout, UI state) and types added by future versions are left out.
    static func contextParts(of attachment: Object, startingAt id: Int) -> [PromptContextPart] {
        let type = attachment["type"] as? String ?? ""
        func part(_ title: String, _ text: String?, source: String? = nil) -> [PromptContextPart] {
            guard let text, !text.isEmpty else { return [] }
            return [PromptContextPart(id: id, title: title, source: source, text: SecretFilter.masked(text))]
        }
        func lines(_ key: String, separator: String = "\n") -> String? {
            (attachment[key] as? [String])?.joined(separator: separator)
        }

        switch type {
        case "instructions":
            let files = attachment["files"] as? [Object] ?? []
            return files.enumerated().compactMap { index, file in
                guard let text = file["content"] as? String else { return nil }
                let path = file["path"] as? String
                let name = path.map { URL(filePath: $0).lastPathComponent } ?? "Instructions"
                let kind = file["type"] as? String
                return PromptContextPart(id: id + index, title: kind.map { "\(name) · \($0)" } ?? name,
                                         source: path, text: SecretFilter.masked(text))
            }
        case "skill_listing":
            let count = attachment["skillCount"] as? Int
            return part(count.map { "Skills (\($0))" } ?? "Skills", attachment["content"] as? String)
        case "agent_listing_delta":
            return part("Subagents", lines("addedLines"))
        case "mcp_instructions_delta":
            return part("MCP server instructions", lines("addedBlocks", separator: "\n\n"))
        case "deferred_tools_delta":
            let names = attachment["addedNames"] as? [String] ?? []
            return part("Deferred tools (\(names.count))", names.joined(separator: "\n"))
        case "environment":
            return part("Environment", JSONLines.pretty(attachment["snapshot"]))
        case "session_context":
            let values = (attachment["context"] as? [String: String] ?? [:]).sorted { $0.key < $1.key }.map(\.value)
            return part("Session context", values.joined(separator: "\n\n"))
        case "hook_additional_context":
            let name = attachment["hookName"] as? String ?? "hook"
            return part("Hook · \(name)", lines("content", separator: "\n\n") ?? attachment["content"] as? String)
        case "date":
            return part("Date", attachment["date"] as? String)
        case "model":
            return part("Model", attachment["text"] as? String)
        case "total_tokens_reminder":
            return part("Token budget", attachment["text"] as? String)
        default:
            return []
        }
    }
}
