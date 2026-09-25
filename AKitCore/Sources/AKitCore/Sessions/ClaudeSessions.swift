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

        let title = [customTitle, aiTitle, summaryTitle, firstPrompt.map { JSONLines.titleLine($0) }]
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
        var toolNames: [String: String] = [:]

        for entry in JSONLines.objects(in: data) where !isSidechain(entry) {
            let time = JSONLines.date(entry["timestamp"])
            switch entry["type"] as? String {
            case "user":
                addUser(entry, at: time, toolNames: toolNames, to: &builder)
            case "assistant":
                guard let message = entry["message"] as? Object else { continue }
                builder.noteModel((message["model"] as? String).flatMap { $0 == "<synthetic>" ? nil : $0 })
                for block in message["content"] as? [Object] ?? [] {
                    switch block["type"] as? String {
                    case "text":
                        builder.add(.assistant, block["text"] as? String ?? "", at: time)
                    case "thinking":
                        builder.add(.thinking, block["thinking"] as? String ?? "", at: time)
                    case "tool_use":
                        let name = block["name"] as? String ?? "tool"
                        if let id = block["id"] as? String { toolNames[id] = name }
                        builder.add(.toolCall(name: name), JSONLines.pretty(block["input"]), at: time)
                    default:
                        break
                    }
                }
            case "system":
                switch entry["subtype"] as? String {
                case "compact_boundary": builder.add(.event("Compacted"), "Earlier messages were summarized", at: time)
                case "local_command": builder.add(.event("Command"), stripTags(entry["content"] as? String ?? ""), at: time)
                default: break
                }
            default:
                break
            }
        }
        return builder.transcript
    }

    private static func addUser(_ entry: Object, at time: Date?, toolNames: [String: String],
                                to builder: inout TranscriptBuilder) {
        guard entry["isMeta"] as? Bool != true, let message = entry["message"] as? Object else { return }
        let content = message["content"]
        if entry["isCompactSummary"] as? Bool == true {
            builder.add(.event("Compaction summary"), JSONLines.text(of: content), at: time)
            return
        }
        if let blocks = content as? [Object] {
            for block in blocks where block["type"] as? String == "tool_result" {
                let name = (block["tool_use_id"] as? String).flatMap { toolNames[$0] }
                builder.add(.toolResult(name: name, isError: block["is_error"] as? Bool == true),
                            JSONLines.text(of: block["content"]), at: time)
            }
            let text = JSONLines.text(of: blocks.filter { $0["type"] as? String != "tool_result" })
            addPrompt(text, at: time, to: &builder)
        } else {
            addPrompt(JSONLines.text(of: content), at: time, to: &builder)
        }
    }

    private static func addPrompt(_ text: String, at time: Date?, to builder: inout TranscriptBuilder) {
        if text.hasPrefix("<command-name>") || text.hasPrefix("<command-message>") {
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
        let data = try Data(contentsOf: file)
        var sections: [String]?
        var tools: [PromptTool] = []
        var context: [PromptContextPart] = []
        var beforeFirstAnswer = true

        for entry in JSONLines.objects(in: data) where !isSidechain(entry) {
            if entry["type"] as? String == "assistant" { beforeFirstAnswer = false }
            guard entry["type"] as? String == "attachment", let attachment = entry["attachment"] as? Object else { continue }
            if attachment["type"] as? String == "prompt_snapshot" {
                let prompt = attachment["systemPrompt"]
                sections = (prompt as? [String]) ?? (prompt as? String).map { [$0] } ?? sections
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

    /// Attachments that only concern the UI or hold account data are left out.
    static let hiddenAttachments: Set<String> = [
        "credential_org", "hook_success", "hook_system_message", "remote_session_change", "auto_mode",
        "file-history-snapshot", "atis-latch",
    ]

    static func contextParts(of attachment: Object, startingAt id: Int) -> [PromptContextPart] {
        let type = attachment["type"] as? String ?? ""
        guard !hiddenAttachments.contains(type) else { return [] }
        func part(_ title: String, _ text: String?, source: String? = nil) -> [PromptContextPart] {
            guard let text, !text.isEmpty else { return [] }
            return [PromptContextPart(id: id, title: title, source: source, text: text)]
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
                                         source: path, text: text)
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
        default:
            // Other known shapes carry their rendered text directly.
            let title = type.replacingOccurrences(of: "_", with: " ").capitalized
            return part(title, attachment["text"] as? String ?? attachment["content"] as? String)
        }
    }
}
