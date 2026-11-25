import AKitFoundation
import AKitLab
import Foundation

/// The passes of a review on Claude Code (R69, `harness: claude-code`): `claude -p` in the run's
/// worktree with Read, Grep and Glob only, no MCP server, no CLAUDE.md, skills, hooks or plugins
/// (`--safe-mode --strict-mcp-config`), and nothing that would ask (`--permission-prompts none`).
/// Pi's extension can't load here, so a pass hands its result back as the structured output of
/// `--json-schema`, and AKit writes it into the same files the extension's tools write
/// (`passes/<pass>.json`, `passes/boundaries.json`, `passes/overview.json`,
/// `passes/gaps-<pass>.jsonl`): everything after the passes is the same for both harnesses.
/// The path policy is Claude Code's own: it reads only the working folder and the `--add-dir`
/// folders, and the deny rules below keep the files `ReviewExtension.isBlocked` keeps from Pi.
/// With `claude: github` (R69k) a pass also has WebFetch, allowed only for GitHub's hosts: any
/// other address is denied, as nothing may ask.
enum ReviewClaude {
    static func tools(github: Bool) -> String { github ? "Read,Grep,Glob,WebFetch" : "Read,Grep,Glob" }

    /// The hosts WebFetch may read with `claude: github`; a redirect elsewhere is another fetch, denied.
    static let gitHubHosts = ["github.com", "api.github.com", "raw.githubusercontent.com"]

    /// What a pass hands back.
    enum Kind: Equatable {
        case brief, overview, findings, verifier
    }

    static func kind(of pass: String) -> Kind {
        switch pass {
        case "brief": .brief
        case "overview": .overview
        case "verifier": .verifier
        default: .findings
        }
    }

    /// The names `ReviewExtension.isBlocked` blocks, as Claude Code permission rules. A Read rule
    /// holds for Grep and Glob too.
    static let deniedReads = ["**/.env*", "**/secrets/**", "**/id_*", "**/*.pem", "**/*.key", "**/*.p12", "**/*.pfx", "**/*.jks",
                              "**/*.keystore", "**/auth.json", "**/settings.local.json", "**/.npmrc", "**/.netrc", "**/.pypirc",
                              "**/.git-credentials"]

    static func settings(github: Bool) -> String {
        var permissions = ["deny": deniedReads.map { "Read(\($0))" }]
        if github { permissions["allow"] = gitHubHosts.map { "WebFetch(domain:\($0))" } }
        return json(["permissions": permissions])
    }

    /// Pi's session arguments as Claude Code's: a session id seen before is resumed, a fork
    /// resumes the session as a new one.
    static func sessionArguments(_ pi: [String], known: Set<String>) -> [String] {
        guard pi.count == 2 else { return [] }
        switch pi[0] {
        case "--fork": return ["--resume", pi[1], "--fork-session"]
        case "--session-id": return known.contains(pi[1]) ? ["--resume", pi[1]] : ["--session-id", pi[1]]
        default: return []
        }
    }

    /// The arguments of one pass; the prompt goes on stdin.
    static func arguments(kind: Kind, model: ReviewModelChoice, session: [String], system: URL?, folders: [URL], github: Bool = false) -> [String] {
        var arguments = ["-p", "--output-format", "stream-json", "--verbose"] + session
        if !model.model.isEmpty { arguments += ["--model", model.model] }
        if !model.thinking.isEmpty { arguments += ["--effort", model.thinking] }
        arguments += ["--tools", tools(github: github), "--safe-mode", "--strict-mcp-config", "--permission-prompts", "none",
                      "--settings", settings(github: github), "--json-schema", schema(kind)]
        for folder in folders { arguments += ["--add-dir", folder.path] }
        if let system { arguments += ["--append-system-prompt-file", system.path] }
        return arguments
    }

    // MARK: - The answer's shape

    static let severities = ReviewSeverity.allCases.map(\.rawValue)

    static func schema(_ kind: Kind) -> String {
        var properties: [String: Any] = ["gaps": ["type": "array", "items": gap,
                                                  "description": "What you needed and couldn't read; an empty list when nothing"]]
        var required = ["gaps"]
        switch kind {
        case .brief:
            properties["brief"] = ["type": "string", "description": "The brief, in the shape the prompt asks for"]
            properties["boundaries"] = ["type": "array", "maxItems": 50, "items": boundary]
            required += ["brief", "boundaries"]
        case .overview:
            properties["points"] = ["type": "array", "maxItems": 8, "items": ["type": "string", "maxLength": 400],
                                    "description": "3–5 short points on what happens"]
            properties["modules"] = ["type": "array", "maxItems": 20, "items": [
                "type": "object",
                "properties": ["name": ["type": "string", "maxLength": 120],
                               "files": ["type": "array", "maxItems": 50, "items": ["type": "string"],
                                         "description": "Its changed files, as paths in the repository"],
                               "why": ["type": "string", "maxLength": 400, "description": "Why it changes"]],
                "required": ["name", "files", "why"]]]
            properties["why_sources"] = ["type": "array", "items": ["type": "string", "enum": ReviewOverview.WhySource.allCases.map(\.rawValue)],
                                         "description": "Where the why comes from"]
            properties["flow"] = ["type": "string", "maxLength": 6000,
                                  "description": "A Mermaid flowchart or sequenceDiagram, at most 40 nodes; changed parts in class changed"]
            properties["flow_kind"] = ["type": "string", "enum": ["flowchart", "sequenceDiagram"]]
            required += ["points", "modules", "why_sources"]
        case .findings:
            properties["findings"] = ["type": "array", "items": finding]
            required += ["findings"]
        case .verifier:
            properties["verdicts"] = ["type": "array", "items": verdict]
            required += ["verdicts"]
        }
        return json(["type": "object", "properties": properties, "required": required])
    }

    static var trace: [String: Any] { [
        "type": "array",
        "description": "The path from the cause to the harm, in order: where the value or the call comes from, the changed code, who gets hurt",
        "maxItems": 8,
        "items": ["type": "object",
                  "properties": ["file": ["type": "string", "description": "Path in the repository"],
                                 "line": ["type": ["integer", "null"]],
                                 "quote": ["type": "string", "description": "The exact code of that line, copied from the file"],
                                 "note": ["type": "string", "description": "What happens there, in one short sentence"]],
                  "required": ["file", "quote", "note"]],
    ] }

    static var finding: [String: Any] { [
        "type": "object",
        "properties": [
            "kind": ["type": "string", "enum": ["finding", "ac", "question"]],
            "file": ["type": ["string", "null"], "description": "Path in the repository"],
            "side": ["type": "string", "enum": ["new", "old"], "description": "new: the line in the changed file; old: a removed line"],
            "line": ["type": ["integer", "null"]],
            "title": ["type": "string"],
            "evidence": ["type": "string", "description": "The exact code line(s) you rely on, copied from the file; never a secret's value"],
            "why": ["type": "string"],
            "severity": ["type": "string", "enum": severities],
            "confidence": ["type": "number", "minimum": 0, "maximum": 1],
            "suggestion": ["type": "string", "description": "Replacement code for the anchored line, when there is a clear fix"],
            "related": ["type": "array", "items": ["type": "string"]],
            "preExisting": ["type": "boolean", "description": "true: the problem is already there at the base commit; this change didn't bring it"],
            "trace": trace,
        ],
        "required": ["title", "evidence", "why", "severity", "confidence"],
    ] }

    static var verdict: [String: Any] { [
        "type": "object",
        "properties": [
            "id": ["type": "string"],
            "verdict": ["type": "string", "enum": ["confirmed", "rejected", "question", "merged"]],
            "note": ["type": "string"],
            "into": ["type": "string"],
            "severity": ["type": "string", "enum": severities],
            "confidence": ["type": "number", "minimum": 0, "maximum": 1],
            "preExisting": ["type": "boolean", "description": "true: the problem is already there at the base commit"],
            "trace": trace,
        ],
        "required": ["id", "verdict", "note"],
    ] }

    static var boundary: [String: Any] { [
        "type": "object",
        "properties": [
            "kind": ["type": "string", "enum": ReviewBoundary.Kind.allCases.map(\.rawValue)],
            "direction": ["type": "string", "enum": ["provides", "uses"]],
            "name": ["type": "string", "maxLength": 120,
                     "description": "What to search for in other repositories: an endpoint path, a package, module, topic or variable name"],
            "file": ["type": "string", "description": "The changed file in the repository"],
            "side": ["type": "string", "enum": ["new", "old"], "description": "new: a line of the changed file; old: a removed line"],
            "line": ["type": ["integer", "null"]],
            "quote": ["type": "string", "maxLength": 500, "description": "The exact code line that declares or uses it; never a secret's value"],
            "note": ["type": "string", "maxLength": 300, "description": "One short sentence: what changes for its users"],
        ],
        "required": ["kind", "direction", "name", "file", "quote"],
    ] }

    static var gap: [String: Any] { [
        "type": "object",
        "properties": [
            "system": ["type": "string", "description": "repository, knowledge, tests or other"],
            "needed": ["type": "string"],
            "why": ["type": "string"],
            "how_to_get": ["type": "string"],
            "effect": ["type": "string", "description": "Which findings or checks are less certain without it"],
        ],
        "required": ["system", "needed", "why"],
    ] }

    // MARK: - Saving the answer

    /// Writes a pass's structured answer where the extension's tools write theirs. Returns the
    /// brief's text for the brief.
    @discardableResult
    static func save(_ answer: [String: Any], kind: Kind, pass: String, role: String?, folder: URL) throws -> String? {
        let gaps = (answer["gaps"] as? [[String: Any]] ?? []).compactMap { gap -> String? in
            guard let needed = gap["needed"] as? String, let why = gap["why"] as? String else { return nil }
            return json(["system": gap["system"] as? String ?? "other", "needed": needed, "why": why,
                         "howToGet": gap["how_to_get"] as? String ?? "", "effect": gap["effect"] as? String ?? "", "reportedBy": pass])
        }
        if !gaps.isEmpty { try write(gaps.map { $0 + "\n" }.joined(), to: folder.appending(path: "passes/gaps-\(pass).jsonl")) }
        switch kind {
        case .brief:
            let boundaries = Array((answer["boundaries"] as? [Any] ?? []).prefix(50))
            try write(json(["pass": pass, "boundaries": boundaries]), to: folder.appending(path: "passes/boundaries.json"))
            return answer["brief"] as? String
        case .overview:
            try write(json(["pass": pass, "points": answer["points"] ?? [], "modules": answer["modules"] ?? [],
                            "why_sources": answer["why_sources"] ?? [], "flow": answer["flow"] ?? NSNull(),
                            "flow_kind": answer["flow_kind"] ?? NSNull()]),
                      to: folder.appending(path: "passes/overview.json"))
        case .findings:
            // The role's limit and the trusted checks are `ReviewCandidates.collect`'s, as for Pi.
            try write(json(["pass": pass, "role": role ?? "", "findings": answer["findings"] ?? [], "verdicts": [Any]()]),
                      to: folder.appending(path: "passes/\(pass).json"))
        case .verifier:
            try write(json(["pass": pass, "role": role ?? "", "findings": [Any](), "verdicts": answer["verdicts"] ?? []]),
                      to: folder.appending(path: "passes/\(pass).json"))
        }
        return nil
    }

    // MARK: - Running one pass

    /// Runs `claude` with the prompt on stdin. Every line goes, masked, to `stream`; the result
    /// line gives the session, the usage, the answer and the structured output.
    static func run(_ claude: URL, arguments: [String], prompt: URL, directory: URL, environment: [String: String], timeout: TimeInterval,
                    stream: URL, onLine: (@Sendable (String) -> Void)? = nil) async -> (output: PiJSONStream.Output, answer: [String: Any]?) {
        try? FileManager.default.createDirectory(at: stream.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: stream.path, contents: nil)
        let handle = try? FileHandle(forWritingTo: stream)
        let collector = Lines()
        let exit = await ChildProcess.run(claude, arguments: arguments, directory: directory, environment: environment, input: prompt,
                                          timeout: timeout, onStart: { collector.start() }) { line in
            collector.add(line)
            handle?.write(Data((JSONMask.jsonLine(line) + "\n").utf8))
            onLine?(line)
        }
        try? handle?.close()
        var (output, answer) = parse(collector.lines)
        output.started = collector.started
        if let exit, exit.exitedNormally { output.exitStatus = exit.status }
        if exit == nil { output.error = "Claude Code couldn't start." }
        else if exit?.cancelled == true { output.error = "Stopped." }
        else if exit?.timedOut == true { output.error = "The pass timed out." }
        else if output.error == nil, answer == nil {
            let tail = collector.lines.filter { !$0.hasPrefix("{") }.suffix(5).joined(separator: " ")
            output.error = exit?.succeeded == true ? "Claude Code gave no structured answer."
                : "Claude Code exited with status \(exit?.status ?? -1)" + (tail.isEmpty ? "." : ": \(SecretFilter.masked(String(tail.suffix(300))))")
        }
        return (output, answer)
    }

    /// The events of one run: the files the reading tools reached, then the result line.
    static func parse(_ lines: [String]) -> (output: PiJSONStream.Output, answer: [String: Any]?) {
        var output = PiJSONStream.Output()
        var answer: [String: Any]?
        var seen = Set<String>()
        for line in lines where line.hasPrefix("{") {
            guard let event = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] else { continue }
            if output.session == nil, let id = event["session_id"] as? String { output.session = id }
            switch event["type"] as? String {
            case "assistant":
                for call in toolCalls(event) {
                    if let path = call.path, seen.insert(path).inserted { output.paths.append(path) }
                }
            case "result":
                if let id = event["session_id"] as? String { output.session = id }
                let usage = event["usage"] as? [String: Any] ?? [:]
                func count(_ key: String) -> Int { (usage[key] as? NSNumber)?.intValue ?? 0 }
                output.usage = SendUsage(input: count("input_tokens") + count("cache_creation_input_tokens"), cached: count("cache_read_input_tokens"),
                                         output: count("output_tokens"), cost: (event["total_cost_usd"] as? NSNumber)?.doubleValue)
                output.answer = event["result"] as? String
                if event["is_error"] as? Bool == true {
                    output.error = SecretFilter.masked(String((event["result"] as? String ?? "Claude Code stopped with an error.").prefix(300)))
                } else {
                    answer = event["structured_output"] as? [String: Any]
                }
            default:
                break
            }
        }
        return (output, answer)
    }

    struct Call {
        var name: String
        var input: [String: Any]
        /// The file or folder a reading tool reached.
        var path: String? { name == "Read" ? input["file_path"] as? String : name == "Grep" || name == "Glob" ? input["path"] as? String : nil }
    }

    static func toolCalls(_ event: [String: Any]) -> [Call] {
        let content = (event["message"] as? [String: Any])?["content"] as? [[String: Any]] ?? []
        return content.filter { $0["type"] as? String == "tool_use" }.compactMap { block in
            guard let name = block["name"] as? String else { return nil }
            return Call(name: name, input: block["input"] as? [String: Any] ?? [:])
        }
    }

    /// A Claude Code event as a line of the live log, in the words of Pi's (`ReviewPasses.liveEvent`).
    static func liveEvent(_ line: String, details: Bool) -> (title: String, detail: String?)? {
        guard line.hasPrefix("{"), line.contains("\"tool_use\"") || line.contains("\"type\":\"result\""),
              let event = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] else { return nil }
        if event["type"] as? String == "result" {
            let usage = event["usage"] as? [String: Any] ?? [:]
            let output = (usage["output_tokens"] as? NSNumber)?.intValue ?? 0
            return (event["is_error"] as? Bool == true ? "the pass ended with an error" : "answers (\(ReviewRunLog.tokens(output)) out)", nil)
        }
        guard let call = toolCalls(event).last else { return nil }
        let (name, args) = piWords(call)
        return (ReviewPasses.startTitle(name, args), details ? ReviewLive.clip(ReviewPasses.startDetail(name, args)) : nil)
    }

    /// A Claude Code call as the Pi tool that does the same.
    static func piWords(_ call: Call) -> (String, [String: Any]) {
        switch call.name {
        case "Read": return ("read", ["path": call.input["file_path"] ?? ""])
        case "Grep": return ("grep", ["path": call.input["path"] ?? ".", "pattern": call.input["pattern"] ?? ""])
        case "Glob": return ("find", ["path": call.input["path"] ?? ".", "pattern": call.input["pattern"] ?? ""])
        case "WebFetch": return ("fetch", ["url": call.input["url"] ?? ""])
        case "StructuredOutput":
            if call.input["boundaries"] != nil { return ("akit_submit_boundaries", call.input) }
            if call.input["points"] != nil { return ("akit_submit_overview", call.input) }
            return ("akit_submit_findings", call.input)
        default: return (call.name, call.input)
        }
    }

    // MARK: -

    static func json(_ object: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    static func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    private final class Lines: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [String] = []
        private var didStart = false
        func add(_ line: String) { lock.withLock { stored.append(line) } }
        func start() { lock.withLock { didStart = true } }
        var lines: [String] { lock.withLock { stored } }
        var started: Bool { lock.withLock { didStart } }
    }
}
