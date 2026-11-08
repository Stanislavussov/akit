import Foundation

/// M37: after Pi wrote the summary, a second Pi run looks in Azure DevOps through the user's own
/// Pi MCP server for what relates to the meeting: work items and their links, rules, wiki pages,
/// history (pull requests, commits, earlier discussion) and artifacts (builds, pipelines,
/// releases), with the meeting's tags and the work items' tags as search words. When a GitLab
/// server is set too, Pi also looks at the repositories' tags and searches their code for how
/// the topic is built today. Read only: Pi gets only these servers' tools, and every tool
/// whose name says it writes is taken away. The answer is Markdown for the meeting's own tab.
public struct PiDevOpsResearch: Sendable {
    let settings: MeetingsSettings
    let local: LocalEnvironment
    let environment: [String: String]?

    public init(settings: MeetingsSettings, local: LocalEnvironment, environment: [String: String]? = nil) {
        self.settings = settings
        self.local = local
        self.environment = environment
    }

    /// The tab the answer goes to. Summarize Again writes it again.
    public static let tabName = "Azure DevOps & GitLab"

    /// Words in a tool's name that say it changes something in Azure DevOps.
    static let writeWords = ["create", "update", "add", "delete", "remove", "link", "unlink", "assign", "run", "queue", "set",
                             "reply", "resolve", "push", "merge", "complete", "abandon", "vote", "approve", "start", "cancel",
                             "upload", "edit", "close", "move", "rename", "write", "post", "trigger"]

    /// Names whose server is Azure DevOps when the settings name none.
    public static func isDevOps(server: String) -> Bool {
        let name = server.lowercased()
        return name.contains("azure") || name.contains("devops") || name == "ado" || name.hasPrefix("ado-") || name.hasPrefix("ado_")
    }

    public static func isGitLab(server: String) -> Bool { server.lowercased().contains("gitlab") }

    /// The server a run uses: the one the settings name, else the first that `matches`.
    public static func server(named: String?, among servers: [String], matches: (String) -> Bool = isDevOps) -> String? {
        if let named, !named.isEmpty { return named }
        return servers.first(where: matches)
    }

    /// Pi writes MCP tools as `mcp__<server>__<tool>`, the server's name with every other
    /// character as `_`.
    static func normalized(_ server: String) -> String {
        String(server.unicodeScalars.map { ($0.isASCII && CharacterSet.alphanumerics.contains($0)) || $0 == "_" ? Character($0) : "_" })
    }

    static func system(language: String, gitLab: Bool, repositories: [String]) -> String {
        let repos = repositories.isEmpty ? "the repositories the meeting or the work items name" : repositories.joined(separator: ", ")
        let gitLabPart = gitLab ? """
        Then, with the GitLab tools: look at the tags of \(repos) (which release holds the change) and search their \
        code, merge requests and commits for how the topic is built today (files, modules, endpoints, flags). \
        Put that under ## In the code, one line per repository: what you found, with a link to the file or merge request.

        """ : ""
        return """
        You look up Azure DevOps\(gitLab ? " and GitLab" : "") for a meeting, only through the tools you have (call them with codemode; \
        find tools with tool_search). Never create, change or delete anything: only read and search.
        Search with the meeting's own words: its tags (the line "Tags:"), names of services, products, features, people, \
        ticket and PR numbers, errors. Look at the tags of the work items you find and search by those tags too.
        Find: related work items (bugs, tasks, stories, features, epics) and their links (parent, child, related, \
        duplicates); rules and agreements (definition of done, policies, wiki pages that set how to work); wiki pages \
        on the topic; history (pull requests, commits, earlier comments and discussions on the same problem); \
        artifacts (builds, pipelines, releases, test runs, attachments).
        \(gitLabPart)Write in \(language), Markdown only, no preamble. Start with ## Found outside the meeting: 3 to 6 short \
        bullets on what you found that the meeting did not say: what is already done or released, what contradicts what was \
        said, what is new (an older decision, a rule, a related bug), and risks; each with its link. Then these sections, \
        leaving out an empty one: \
        ## Work items, ## Links between them, ## Rules, ## Wiki, ## History, ## Artifacts\(gitLab ? ", ## In the code" : ""), ## Open questions. \
        Each line: the item's id or name as a Markdown link to its web address when you have one, then one \
        short sentence on how it relates to the meeting. Put only what you found; never make up an id \
        or a link. When nothing relates, write one line saying so.
        Last, for the summary's numbered lines (the lines "N| - …" in the input: tasks, decisions, topics), give the items \
        that a line is about, in one block at the very end and nothing after it:
        ```json
        {"links": [{"line": N, "items": [{"title": "#123 short name", "url": "https://…"}]}]}
        ```
        Only lines an item is clearly about, at most 3 items a line, only links you found. With none, {"links": []}.
        """
    }

    static func arguments(model: String?, servers: [String], input: URL, system: String) -> [String] {
        let prefixes = servers.map { "mcp__\(normalized($0))__" }
        let excluded = prefixes.flatMap { prefix in writeWords.map { "\(prefix)*\($0)*" } }.joined(separator: ",")
        var arguments = ["-p", "Find what in Azure DevOps relates to the attached meeting.", "--mode", "json", "--no-session", "--offline",
                         "--no-skills", "--no-context-files", "--no-prompt-templates", "--no-extensions",
                         "-e", "builtin:mcp", "-e", "builtin:codemode", "-e", "builtin:tool-search",
                         "--tools", "codemode,tool_search," + prefixes.map { $0 + "*" }.joined(separator: ","), "--exclude-tools", excluded,
                         "--system-prompt", system]
        if let model, !model.isEmpty { arguments += ["--model", model] }
        return arguments + ["@\(input.path)"]
    }

    /// What Pi gets: the summary first (the topics), then the transcript (ids and names said aloud).
    static func input(meeting: Meeting, summary: String) -> String {
        """
        # Meeting: \(meeting.displayTitle)

        Tags: \(meeting.tagList.isEmpty ? "none" : meeting.tagList.joined(separator: ", "))

        \(numbered(summary))

        # Transcript

        \(Transcriber.plainTranscript(meeting))
        """
    }

    /// The summary with its list lines numbered (`12| - [ ] Me: …`), so Pi can name a line to link.
    static func numbered(_ summary: String) -> String {
        summary.components(separatedBy: "\n").enumerated().map { n, line in
            line.hasPrefix("- ") ? "\(n + 1)| \(line)" : line
        }.joined(separator: "\n")
    }

    public struct Link: Equatable, Sendable {
        public var title: String
        public var url: String
    }

    /// Pi's answer split: the tab's Markdown and the links per summary line (from the last
    /// ```json block with "links"). Only http(s) links are kept.
    static func split(_ answer: String) -> (tab: String, links: [Int: [Link]]) {
        guard let open = answer.range(of: "```json", options: [.backwards, .caseInsensitive]) else { return (answer, [:]) }
        // A block cut off at its end has no closing fence: it goes out of the tab all the same.
        let close = answer.range(of: "```", range: open.upperBound..<answer.endIndex)
        let block = answer[open.upperBound..<(close?.lowerBound ?? answer.endIndex)]
        let tab = (String(answer[..<open.lowerBound]) + (close.map { String(answer[$0.upperBound...]) } ?? ""))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard block.contains("\"links\"") else { return (answer, [:]) }
        guard let object = (try? JSONSerialization.jsonObject(with: Data(block.utf8))) as? [String: Any],
              let list = object["links"] as? [[String: Any]] else { return (tab, [:]) }
        var links: [Int: [Link]] = [:]
        for entry in list {
            guard let line = (entry["line"] as? NSNumber)?.intValue, let items = entry["items"] as? [[String: Any]] else { continue }
            for item in items {
                guard let url = (item["url"] as? String)?.trimmingCharacters(in: .whitespaces),
                      url.hasPrefix("https://") || url.hasPrefix("http://"), !url.contains(where: { $0 == ")" || $0.isWhitespace }) else { continue }
                let raw = ((item["title"] as? String) ?? "").components(separatedBy: .newlines).joined(separator: " ")
                    .replacingOccurrences(of: "]", with: ")").replacingOccurrences(of: "[", with: "(").trimmingCharacters(in: .whitespaces)
                let safe = url.replacingOccurrences(of: "(", with: "%28").replacingOccurrences(of: "<", with: "%3C").replacingOccurrences(of: ">", with: "%3E")
                if (links[line]?.count ?? 0) < 3 { links[line, default: []].append(Link(title: raw.isEmpty ? safe : raw, url: safe)) }
            }
        }
        return (tab, links)
    }

    /// The summary with each named list line ending in its links (`— [#123 …](url)`); a link the
    /// line has already is not added again, and a line that is not a list line stays as it is.
    static func linked(_ summary: String, _ links: [Int: [Link]]) -> String {
        var lines = summary.components(separatedBy: "\n")
        for (number, items) in links where number >= 1 && number <= lines.count {
            let line = lines[number - 1]
            guard line.hasPrefix("- ") else { continue }
            let new = items.filter { !line.contains($0.url) }.map { "[\($0.title)](\($0.url))" }
            if !new.isEmpty { lines[number - 1] = line + " — " + new.joined(separator: ", ") }
        }
        return lines.joined(separator: "\n")
    }

    /// Runs Pi with the server's tools; the Markdown of the tab. Throws when Pi failed.
    public func research(_ meeting: Meeting, summary: String) async throws -> (text: String, usage: PiEvents.Usage) {
        let variables = if let environment { environment } else { await LoginEnvironment.variables() }
        guard let pi = LoginEnvironment.find("pi", in: variables) else {
            throw MeetingsError.pi("pi is not on your login shell's PATH.")
        }
        let needsList = (settings.piDevOpsServer ?? "").isEmpty || (settings.piGitLab && (settings.piGitLabServer ?? "").isEmpty)
        let known = needsList ? await Self.servers(environment: variables) : []
        guard let server = Self.server(named: settings.piDevOpsServer, among: known) else {
            throw MeetingsError.pi("Pi has no Azure DevOps MCP server. Add one in Pi (MCP), or pick it in Meetings Settings → Pi.")
        }
        var servers = [server]
        if settings.piGitLab {
            guard let gitLab = Self.server(named: settings.piGitLabServer, among: known, matches: Self.isGitLab) else {
                throw MeetingsError.pi("Pi has no GitLab MCP server. Add one in Pi (MCP), or pick it in Meetings Settings → Pi.")
            }
            servers.append(gitLab)
        }
        let system = Self.system(language: settings.language, gitLab: settings.piGitLab, repositories: settings.piRepositories)
        let folder = FileManager.default.temporaryDirectory.appending(path: "meetings-pi-ado-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let input = folder.appending(path: "meeting.md")
        try Data(Self.input(meeting: meeting, summary: summary).utf8).write(to: input)
        let started = Date()
        let result = try await ChildRun.run(pi, Self.arguments(model: settings.piModel, servers: servers, input: input, system: system),
                                            environment: variables, directory: folder, background: true, pausable: false, timeout: 900,
                                            local: local, resume: LocalStatus(phase: .summarizing),
                                            onLine: PiSummarizer.steps(local))
        if let failure = PiEvents.failure(result.output) {
            MeetingsLog.error(.pi, "model error: \(failure)")
            throw MeetingsError.pi("the model answered with an error: \(PiEvents.short(failure)) (model \(settings.piModel ?? "Pi's default")). Check it in a terminal with pi, or choose another one in Meetings Settings → Pi.")
        }
        let text = PiEvents.answer(result.output).trimmingCharacters(in: .whitespacesAndNewlines)
        let usage = PiEvents.totalUsage(result.output)
        MeetingsLog.info(.pi, "azure devops: exit \(result.status), \(text.count) chars in \(Int(Date().timeIntervalSince(started))) s, servers \(servers.joined(separator: ", ")), \(usage.text)")
        guard result.status == 0, !text.isEmpty else {
            throw MeetingsError.pi("\(LocalTranscriber.tail(result.errors)) (exit \(result.status), servers \(servers.joined(separator: ", ")))")
        }
        return (text + "\n", usage)
    }

    /// The names of Pi's MCP servers (`pi mcp list --json`, it connects to each enabled one).
    public static func servers(environment: [String: String]? = nil) async -> [String] {
        let variables = if let environment { environment } else { await LoginEnvironment.variables() }
        guard let pi = LoginEnvironment.find("pi", in: variables),
              let result = try? await ChildRun.run(pi, ["mcp", "list", "--json"], environment: variables, background: false, pausable: false,
                                                   timeout: 120, local: LocalEnvironment(tick: .milliseconds(100)),
                                                   resume: LocalStatus(phase: .summarizing))
        else { return [] }
        return parseServers(String(decoding: result.output, as: UTF8.self))
    }

    static func parseServers(_ text: String) -> [String] {
        guard let start = text.firstIndex(of: "{"),
              let object = try? JSONSerialization.jsonObject(with: Data(text[start...].utf8)) as? [String: Any],
              let servers = object["servers"] as? [[String: Any]] else { return [] }
        return servers.compactMap { $0["name"] as? String }
    }
}
