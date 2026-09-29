import Foundation

/// Pi session files: `<sessions>/--<cwd with - for />--/<time>_<uuid>.jsonl`.
/// The first line is a `session` header (id, cwd); the other entries form a tree via
/// `id`/`parentId` so branches live in one file. See docs/session-format.md in Pi.
enum PiSessions {
    typealias Object = JSONLines.Object

    /// `PI_CODING_AGENT_SESSION_DIR`, then `sessionDir` from the global settings, then `<config>/sessions`.
    /// A relative `sessionDir` points inside each project and is not followed.
    static func folder(configRoot: URL, in env: HarnessEnvironment) -> URL {
        if let custom = env.variables["PI_CODING_AGENT_SESSION_DIR"], !custom.isEmpty {
            return env.expand(custom)
        }
        if let data = try? Data(contentsOf: configRoot.appending(path: "settings.json")),
           let settings = try? JSONSerialization.jsonObject(with: data) as? Object,
           let dir = settings["sessionDir"] as? String, dir.hasPrefix("/") || dir.hasPrefix("~") {
            return env.expand(dir)
        }
        return configRoot.appending(path: "sessions")
    }

    static func list(folder: URL) -> [SessionSummary] {
        let files = FileWalk.children(of: folder)
            .filter(FileWalk.isDirectory)
            .flatMap { dir in FileWalk.children(of: dir).filter { $0.pathExtension == "jsonl" } }
        return JSONLines.summaries(of: files) { summary(of: $0) }
    }

    static func summary(of file: URL) -> SessionSummary? {
        var header: Object?
        var firstPrompt: String?
        var name: String?
        JSONLines.scanHead(of: file) { entry in
            if header == nil, entry["type"] as? String == "session" { header = entry }
            if entry["type"] as? String == "session_info" { name = entry["name"] as? String ?? name }
            if firstPrompt == nil, entry["type"] as? String == "message",
               let message = entry["message"] as? Object, message["role"] as? String == "user" {
                let text = JSONLines.text(of: message["content"]).trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty { firstPrompt = text }
            }
            return header != nil && firstPrompt != nil
        }
        guard let header else { return nil }
        // The latest name wins; `/name` may be used late in a long session.
        for entry in JSONLines.tail(of: file) where entry["type"] as? String == "session_info" {
            name = entry["name"] as? String ?? name
        }
        let title = [name, firstPrompt.map { JSONLines.titleLine(SecretFilter.masked(promptTitle($0))) }]
            .compactMap { $0 }.first { !$0.isEmpty } ?? "Untitled session"
        let info = JSONLines.fileInfo(file)
        return SessionSummary(harness: .pi, file: file, title: title,
                              project: (header["cwd"] as? String).map { URL(filePath: $0, directoryHint: .isDirectory) },
                              started: JSONLines.date(header["timestamp"]), modified: info.modified, size: info.size)
    }

    /// A prompt that starts with an expanded skill (`<skill name="tdd" …>`) is titled by what follows it.
    static func promptTitle(_ text: String) -> String {
        guard text.hasPrefix("<skill "), let end = text.range(of: "</skill>") else { return text }
        let rest = text[end.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        return rest.isEmpty ? text : rest
    }

    /// `x` for a prompt that starts with an expanded skill `<skill name="x" …>`.
    static func skillPrefixName(_ text: String) -> String? {
        let start = "<skill name=\""
        guard text.hasPrefix(start) else { return nil }
        let rest = text.dropFirst(start.count)
        guard let quote = rest.firstIndex(of: "\""), quote > rest.startIndex else { return nil }
        return String(rest[..<quote])
    }

    // MARK: - Transcript

    static func transcript(of file: URL) throws -> SessionTranscript {
        let entries = try JSONLines.objects(in: try Data(contentsOf: file)).filter { $0["type"] as? String != "session" }
        var builder = TranscriptBuilder()
        var secretCalls = Set<String>()
        for entry in activeBranch(entries) {
            add(entry, secretCalls: &secretCalls, to: &builder)
        }
        // Usage counts every response in the file: abandoned branches were paid for too.
        for entry in entries {
            recordUsage(entry, in: &builder.usage)
        }
        return builder.transcript
    }

    /// `message.usage` of an assistant message: input, output, cacheRead, cacheWrite, cost.total.
    private static func recordUsage(_ entry: Object, in counter: inout UsageCounter) {
        guard entry["type"] as? String == "message", let message = entry["message"] as? Object,
              message["role"] as? String == "assistant", let usage = message["usage"] as? Object else { return }
        counter.record(id: entry["id"] as? String, model: message["model"] as? String,
                       provider: message["provider"] as? String, tokens: tokens(fromPiUsage: usage), cost: cost(fromPiUsage: usage))
    }

    /// Pi's `message.usage`: input, output, cacheRead, cacheWrite.
    static func tokens(fromPiUsage usage: Object) -> TokenCounts {
        func count(_ key: String) -> Int { (usage[key] as? NSNumber)?.intValue ?? 0 }
        return TokenCounts(input: count("input"), output: count("output"),
                           cacheRead: count("cacheRead"), cacheWrite: count("cacheWrite"))
    }

    /// `usage.cost.total` in US dollars, when Pi recorded it.
    static func cost(fromPiUsage usage: Object) -> Double? {
        ((usage["cost"] as? Object)?["total"] as? NSNumber)?.doubleValue
    }

    /// Entries from the root to the current leaf (the last entry written).
    /// Abandoned branches are left out. Without ids (old v1 files) all entries are kept.
    static func activeBranch(_ entries: [Object]) -> [Object] {
        var byID: [String: Object] = [:]
        for entry in entries {
            if let id = entry["id"] as? String { byID[id] = entry }
        }
        guard let leaf = entries.last(where: { $0["id"] is String }) else { return entries }
        var path: [Object] = []
        var seen = Set<String>()
        var current: Object? = leaf
        while let entry = current, let id = entry["id"] as? String, seen.insert(id).inserted {
            path.append(entry)
            current = (entry["parentId"] as? String).flatMap { byID[$0] }
        }
        return path.reversed()
    }

    private static func add(_ entry: Object, secretCalls: inout Set<String>, to builder: inout TranscriptBuilder) {
        let time = JSONLines.date(entry["timestamp"])
        switch entry["type"] as? String {
        case "message":
            guard let message = entry["message"] as? Object else { return }
            addMessage(message, at: time, secretCalls: &secretCalls, to: &builder)
        case "model_change":
            let model = [entry["provider"] as? String, entry["modelId"] as? String].compactMap { $0 }.joined(separator: "/")
            builder.add(.event("Model"), model, at: time)
        case "thinking_level_change":
            builder.add(.event("Thinking level"), entry["thinkingLevel"] as? String ?? "", at: time)
        case "compaction":
            builder.add(.event("Compacted"), entry["summary"] as? String ?? "", at: time)
        case "branch_summary":
            builder.add(.event("Branch summary"), entry["summary"] as? String ?? "", at: time)
        case "custom_message":
            guard entry["display"] as? Bool != false else { return }
            builder.add(.event(entry["customType"] as? String ?? "Extension"), JSONLines.text(of: entry["content"]), at: time)
        default:
            break // custom (extension state), label, session_info: not part of the conversation
        }
    }

    /// `secretCalls`: ids of tool calls that touched a secrets file; their results are hidden.
    private static func addMessage(_ message: Object, at time: Date?, secretCalls: inout Set<String>,
                                   to builder: inout TranscriptBuilder) {
        switch message["role"] as? String {
        case "user":
            builder.add(.user, JSONLines.text(of: message["content"]), at: time)
        case "assistant":
            builder.noteModel(message["model"] as? String)
            for block in message["content"] as? [Object] ?? [] {
                switch block["type"] as? String {
                case "text":
                    builder.add(.assistant, block["text"] as? String ?? "", at: time)
                case "thinking":
                    builder.add(.thinking, stripANSI(block["thinking"] as? String ?? ""), at: time)
                case "toolCall":
                    if let id = block["id"] as? String, SecretFilter.readsSecretFile(block["arguments"]) { secretCalls.insert(id) }
                    builder.add(.toolCall(name: block["name"] as? String ?? "tool"),
                                JSONLines.pretty(SecretFilter.redactedInput(block["arguments"])), at: time)
                default:
                    break
                }
            }
            if let error = message["errorMessage"] as? String {
                builder.add(.event("Error"), error, at: time)
            }
        case "toolResult":
            let hidden = (message["toolCallId"] as? String).map(secretCalls.contains) ?? false
            builder.addToolOutput(.toolResult(name: message["toolName"] as? String, isError: message["isError"] as? Bool == true),
                                  JSONLines.text(of: message["content"]), readSecretFile: hidden, at: time)
        case "bashExecution":
            let command = message["command"] as? String ?? ""
            let output = SecretFilter.commandReadsSecretFile(command) ? SecretFilter.hiddenOutput : message["output"] as? String ?? ""
            builder.add(.event("Shell"), "$ \(command)\n\(output)", at: time)
        case "custom":
            guard message["display"] as? Bool != false else { return }
            builder.add(.event(message["customType"] as? String ?? "Extension"), JSONLines.text(of: message["content"]), at: time)
        case "branchSummary", "compactionSummary":
            builder.add(.event("Summary"), message["summary"] as? String ?? "", at: time)
        default:
            break
        }
    }

    /// Some models' thinking is stored with terminal color codes.
    static func stripANSI(_ text: String) -> String {
        text.replacingOccurrences(of: "\u{1B}\\[[0-9;]*m", with: "", options: .regularExpression)
    }
}
