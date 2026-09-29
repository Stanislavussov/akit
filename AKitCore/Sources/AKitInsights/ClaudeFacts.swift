import AKitFoundation
import AKitSessions
import Foundation

/// Facts from Claude Code session lines (see ClaudeSessions for the format).
/// - `usage` of an assistant entry → request keyed by `message.id` (lines of one response repeat it);
/// - `tool_use` → tool call keyed by its id, `tool_result` → its output size and error;
///   a `Skill` tool_use is also a model call of that skill;
/// - `<command-name>/x` in a user entry → a user call: a skill when the entry starts with
///   `<command-message>` (then also a manual-call example: its arguments and the prompt before
///   it), else a built-in command like `/model` (stored with `extra.kind` `skill` / `command`);
/// - a `skill_listing` attachment → one listing keyed by the entry's uuid;
/// - subagent runs (`<session>/subagents/*.jsonl`, or `isSidechain` lines of older versions)
///   belong to the parent session and are marked as subagent facts;
/// - the session's `started` is the first dated line of its file. Claude Code now resumes by
///   appending to the same file; a file that copies an earlier session (older resumes, forks)
///   starts at the first copied line, and the copied session's own row is never touched.
struct ClaudeFacts {
    /// Bump when the facts read from a line change; files that still exist are re-read.
    /// 2: user calls say `extra.kind` (skill or built-in command).
    static let parserVersion = 2

    let sessionKey: String
    let isSubagentFile: Bool
    private(set) var session: Fact.Session?
    /// The user's last typed prompt in this read, for manual-call examples.
    private var lastPrompt: String?

    init(file: URL) {
        isSubagentFile = Self.isSubagentFile(file)
        sessionKey = "claude:" + Self.sessionID(of: file)
    }

    static func isSubagentFile(_ file: URL) -> Bool {
        file.deletingLastPathComponent().lastPathComponent == "subagents"
    }

    /// The file name without `.jsonl`; for a subagent run, the parent session's folder name.
    static func sessionID(of file: URL) -> String {
        isSubagentFile(file)
            ? file.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent
            : file.deletingPathExtension().lastPathComponent
    }

    /// The session itself, for main files that had any dated line. Subagent runs are not sessions.
    var sessionFact: Fact? { session.map(Fact.session) }

    mutating func facts(from entry: JSONLines.Object) -> [Fact] {
        let ts = JSONLines.date(entry["timestamp"])
        let isSubagent = isSubagentFile || ClaudeLogFormat.isSidechain(entry)
        if !isSubagentFile { note(entry, at: ts) }
        switch entry["type"] as? String {
        case "assistant":
            return assistantFacts(entry, at: ts, isSubagent: isSubagent)
        case "user":
            let facts = userFacts(entry, at: ts, isSubagent: isSubagent)
            if !isSubagent, let prompt = ClaudeLogFormat.promptText(entry) { lastPrompt = prompt }
            return facts
        case "attachment":
            guard let attachment = entry["attachment"] as? JSONLines.Object,
                  attachment["type"] as? String == "skill_listing", let key = entry["uuid"] as? String else { return [] }
            return [.skillListing(.init(key: key, ts: ts, isInitial: attachment["isInitial"] as? Bool == true,
                                        isSubagent: isSubagent, skills: Self.listedSkills(attachment)))]
        default:
            return []
        }
    }

    private mutating func note(_ entry: JSONLines.Object, at ts: Date?) {
        guard let ts else { return }
        var info = session ?? Fact.Session(nativeID: String(sessionKey.dropFirst("claude:".count)))
        info.cwd = info.cwd ?? entry["cwd"] as? String
        info.gitBranch = info.gitBranch ?? entry["gitBranch"] as? String
        info.harnessVersion = info.harnessVersion ?? entry["version"] as? String
        info.started = min(info.started ?? ts, ts)
        info.lastActivity = max(info.lastActivity ?? ts, ts)
        session = info
    }

    private func assistantFacts(_ entry: JSONLines.Object, at ts: Date?, isSubagent: Bool) -> [Fact] {
        guard let message = entry["message"] as? JSONLines.Object else { return [] }
        var facts: [Fact] = []
        // Same rule as SessionUsage: synthetic entries (errors, interruptions) are no requests.
        if let usage = message["usage"] as? JSONLines.Object, let model = message["model"] as? String,
           !model.isEmpty, model != "<synthetic>",
           let key = message["id"] as? String ?? entry["requestId"] as? String {
            facts.append(.request(.init(key: key, ts: ts, model: model, tokens: ClaudeLogFormat.tokens(fromClaudeUsage: usage),
                                        cost: nil, isSubagent: isSubagent)))
        }
        for block in message["content"] as? [JSONLines.Object] ?? [] where block["type"] as? String == "tool_use" {
            guard let id = block["id"] as? String else { continue }
            let name = block["name"] as? String ?? "tool"
            let input = block["input"] as? JSONLines.Object
            let path = name == "Read" ? input?["file_path"] as? String : nil
            facts.append(.toolCall(.init(key: id, callID: id, ts: ts, name: name, inputBytes: Fact.jsonBytes(block["input"]),
                                         isSubagent: isSubagent, pathHash: path.map(Fact.sha256))))
            if name == "Skill", let skill = input?["skill"] as? String, !skill.isEmpty {
                let args = (input?["args"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                facts.append(.skillCall(.init(key: id, ts: ts, skill: skill, by: .model, isSubagent: isSubagent,
                                              hasArgs: !args.isEmpty)))
            }
        }
        return facts
    }

    private func userFacts(_ entry: JSONLines.Object, at ts: Date?, isSubagent: Bool) -> [Fact] {
        guard let message = entry["message"] as? JSONLines.Object else { return [] }
        var facts: [Fact] = []
        var content = message["content"]
        if let blocks = content as? [JSONLines.Object] {
            for block in blocks where block["type"] as? String == "tool_result" {
                guard let id = block["tool_use_id"] as? String else { continue }
                facts.append(.toolResult(callID: id, bytes: JSONLines.text(of: block["content"]).utf8.count,
                                         isError: block["is_error"] as? Bool == true))
            }
            content = blocks.filter { $0["type"] as? String != "tool_result" }
        }
        let text = JSONLines.text(of: content).trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("<command-name>") || text.hasPrefix("<command-message>") {
            guard entry["isMeta"] as? Bool != true, let key = entry["uuid"] as? String,
                  let command = ClaudeLogFormat.tag("command-name", in: text), command.hasPrefix("/"), command.count > 1
            else { return facts }
            let args = ClaudeLogFormat.tag("command-args", in: text) ?? ""
            let skill = String(command.dropFirst())
            let call = Fact.SkillCall(key: key, ts: ts, skill: skill, by: .user, isSubagent: isSubagent, hasArgs: !args.isEmpty)
            guard text.hasPrefix("<command-message>") else { return facts + [.command(call)] }
            facts.append(.skillCall(call))
            if !isSubagent {
                facts.append(.manualCallExample(.init(key: key, ts: ts, skill: skill, args: args, request: lastPrompt)))
            }
        }
        return facts
    }

    /// One entry per name in `names`. Its description is the `content` line `- <name>: …`
    /// (or `- <name>` alone). Plugin skill names contain `:`, so lines are matched by name,
    /// longest first, never split on `:`.
    static func listedSkills(_ attachment: JSONLines.Object) -> [Fact.ListedSkill] {
        let lines = (attachment["content"] as? String ?? "").split(separator: "\n").map(String.init)
        var names = attachment["names"] as? [String] ?? []
        if names.isEmpty {
            // Older listings without `names`: a name ends at the first ": ".
            names = lines.filter { $0.hasPrefix("- ") }.map { line in
                let body = line.dropFirst(2)
                return String(body.range(of: ": ").map { body[..<$0.lowerBound] } ?? body)
            }
        }
        let longestFirst = names.sorted { $0.count > $1.count }
        var descriptions: [String: String] = [:]
        for line in lines where line.hasPrefix("- ") {
            guard let name = longestFirst.first(where: { line == "- " + $0 || line.hasPrefix("- " + $0 + ":") }),
                  descriptions[name] == nil else { continue }
            let rest = line.dropFirst(2 + name.count)
            descriptions[name] = String(rest.dropFirst()).trimmingCharacters(in: .whitespaces)
        }
        var seen = Set<String>()
        return names.filter { seen.insert($0).inserted }.map { name in
            let description = descriptions[name] ?? ""
            return Fact.ListedSkill(name: name, descHash: description.isEmpty ? nil : Fact.sha256(description),
                                    descChars: description.count)
        }
    }
}
