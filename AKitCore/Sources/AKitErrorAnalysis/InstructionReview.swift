import AKitFoundation
import AKitInsights
import AKitInstructions
import AKitLab
import AKitModel
import AKitSessions
import Foundation

/// Analyze… parts 2 and 3 (docs/design/global-instructions.md): a model reads the global text
/// (review), and a model matches the user's reactions in recorded sessions to it (sessions).
/// One call each, through the chosen agent's own sign-in, behind the send gate.
extension InstructionAnalysis {
    /// What exists on this Mac, so the review can tell a stale name from a real one.
    public struct Inventory: Sendable {
        public var skills: [String]
        public var mcpServers: [String]
        public var harnesses: [String]

        public init(skills: [String] = [], mcpServers: [String] = [], harnesses: [String] = []) {
            self.skills = skills
            self.mcpServers = mcpServers
            self.harnesses = harnesses
        }
    }

    /// One reaction of the user in a recorded session: what they wrote and what the agent had done.
    public struct Evidence: Sendable, Hashable {
        public let session: String
        public let project: String?
        public let kind: String
        public let text: String
        public let agentBefore: String

        public init(session: String, project: String?, kind: String, text: String, agentBefore: String) {
            self.session = session
            self.project = project
            self.kind = kind
            self.text = text
            self.agentBefore = agentBefore
        }
    }

    static let severityScale = """
        Severity:
        - critical: the rule makes the agent destroy data, leak a secret, or do the opposite of what the user wants;
        - high: two rules contradict, or a rule the agent must follow is unclear enough that it is broken often;
        - medium: a vague rule the agent can't follow or check; a rule that names a skill, tool, path or command that \
        doesn't exist; a rule in the wrong place (it belongs to one project or one skill);
        - low: a rule that costs tokens and changes nothing (the model does it anyway), or repeats another rule;
        - nit: wording.
        Confidence: 0.25 a guess; 0.5 likely; 0.75 verified in the text; 1 certain.
        """

    public static let schema = """
        {"type":"object","additionalProperties":false,"required":["findings"],"properties":{"findings":{"type":"array","items":{\
        "type":"object","additionalProperties":false,"required":["severity","title","why","section","file","places","suggestion","confidence"],\
        "properties":{"severity":{"type":"string","enum":["critical","high","medium","low","nit"]},"title":{"type":"string"},\
        "why":{"type":"string"},"section":{"type":["string","null"]},"file":{"type":["string","null"]},\
        "places":{"type":"array","items":{"type":"string"}},"suggestion":{"type":["string","null"]},"confidence":{"type":"number"}}}}}}
        """

    static let answerRules = """
        Answer with JSON only: {"findings": [...]}. Each finding: severity, title (at most 8 words), why (one or two \
        sentences: the problem and its effect on the agent), section (the section's id as given, e.g. "## Commits"; null \
        for the whole text), file (the file path as given), places (session keys or other paths; may be empty), suggestion \
        (the whole new text of the section, heading included; "" to remove the section; null when you have none), \
        confidence. Worst first. At most 15 findings. Don't report formatting or Markdown style.
        """

    /// The global files, each section with an id the answer names.
    static func listing(_ globals: [Text]) -> String {
        globals.map { global in
            let sections = InstructionText.units(global.text).filter { !$0.isBlank }.map { unit in
                "<section id=\"\(title(unit))\"\(unit.isAKitBlock ? " source=\"brain\"" : "")>\n\(unit.text.trimmingCharacters(in: .newlines))\n</section>"
            }
            return "<file path=\"\(global.path)\" read-by=\"\(global.harnesses.joined(separator: ", "))\">\n" + sections.joined(separator: "\n") + "\n</file>"
        }.joined(separator: "\n\n")
    }

    // MARK: - Review

    public static func reviewPrompt(globals: [Text], inventory: Inventory) -> (system: String, input: String) {
        let system = """
            You review the global instructions of AI coding agents (Claude Code, Pi, …): the text every session of every \
            project gets before the user's first message, in every model request. Find what makes the agent worse or costs \
            tokens for nothing:
            1. Contradictions: two rules (in one file or in two files one agent reads) that can't both be followed.
            2. Vague rules: the agent can't tell when it applies or whether it followed it ("be careful", "write good code").
            3. Rules with no effect: what a capable model does anyway, so they only cost tokens.
            4. Stale names: a skill, MCP server, tool, path or command that isn't in the inventory below.
            5. Wrong place: a rule for one project, language or tool that every session pays for; it belongs in that \
            project's file or in a skill (loaded only when needed).
            6. Duplicates and drift: the same rule twice, or two versions of it in the files of different agents.
            7. Order and size: the important rules buried under long reference tables.
            A section marked source="brain" comes from the user's brain (core layer); suggest changes there too.
            \(severityScale)
            \(answerRules)
            """
        let input = """
            Inventory of this Mac:
            - skills: \(inventory.skills.sorted().joined(separator: ", "))
            - MCP servers: \(inventory.mcpServers.sorted().joined(separator: ", "))
            - agents: \(inventory.harnesses.joined(separator: ", "))

            \(listing(globals))
            """
        return (system, input)
    }

    // MARK: - Sessions

    /// The user's reactions in recorded sessions of the last `days` days (Claude Code, Pi; Lab's
    /// own runs left out): interrupts, refusals, bad ratings, pushbacks and the next messages
    /// that correct or narrow, each with what the agent had just done. Busiest sessions first,
    /// at most `maxSessions`, at most `perSession` reactions each.
    public static func evidence(days: Int, maxSessions: Int = 40, perSession: Int = 4, env: HarnessEnvironment,
                                now: Date = .now) -> (items: [Evidence], origins: [SendOrigin], sessions: Int) {
        guard let database = try? AnalysisIndex.open(env: env), let sessions = try? AnalysisIndex.sessions(database) else { return ([], [], 0) }
        let since = now.addingTimeInterval(-Double(days) * 86_400)
        let lab = IndexedSessions.labKeys(env: env)
        let recent = sessions.filter { !lab.contains($0.key) && ($0.lastActivity ?? $0.started ?? .distantPast) >= since && $0.requests >= 3 }
            .sorted { $0.requests > $1.requests }.prefix(maxSessions)
        var items: [Evidence] = [], origins: [SendOrigin] = [], used = 0
        for session in recent {
            guard let summary = IndexedSessions.summary(session), let transcript = try? SessionReader.transcript(of: summary) else { continue }
            let ratings = UserReactions.ratings(of: transcript, file: summary.file, env: env)
            let reactions = UserReactions.of(transcript.items, ratings: ratings).filter { $0.kind != .goodRating && !$0.text.isEmpty }
            guard !reactions.isEmpty else { continue }
            used += 1
            origins.append(SendOrigin.of(harness: summary.harness, sessionFile: summary.file))
            for reaction in reactions.prefix(perSession) {
                let before = transcript.items.last { $0.id < reaction.step && $0.kind == .assistant }?.text ?? ""
                items.append(Evidence(session: session.key, project: session.cwd.map { FileWalk.tilde(URL(filePath: $0), home: env.homeDirectory) },
                                      kind: reaction.kind.rawValue, text: SecretFilter.masked(reaction.text),
                                      agentBefore: SecretFilter.masked(String(before.prefix(300)))))
            }
        }
        return (items, origins, used)
    }

    public static func sessionsPrompt(globals: [Text], evidence: [Evidence]) -> (system: String, input: String) {
        let system = """
            You match a user's reactions in recorded AI coding sessions to the agents' global instructions. Each reaction \
            is what the user wrote after the agent acted (an interrupt, a refused tool call, a bad rating, a pushback, or \
            the next message), with what the agent had just said. Find:
            1. Broken rules: a section of the instructions that the agent didn't follow, so the user had to correct it. \
            Title "Broken: <rule>"; places = the session keys; severity by how often and how costly.
            2. Missing rules: something the user asked for by hand in two or more sessions and no section says. Title \
            "Missing: <rule>"; section null; suggestion = a short new section (## heading and the rule) that would have \
            prevented it; places = the session keys.
            3. Rules that misled: the agent followed a section and the user corrected exactly that. Suggest the fix.
            Ignore reactions about the task itself (a wrong file, a new requirement) that no global rule could cover. A \
            follow-up that just continues the work is no evidence. Count sessions, not messages.
            \(severityScale)
            \(answerRules)
            """
        let reactions = evidence.map { item in
            "<reaction session=\"\(item.session)\" project=\"\(item.project ?? "")\" kind=\"\(item.kind)\">\n"
                + (item.agentBefore.isEmpty ? "" : "agent: \(item.agentBefore)\n") + "user: \(item.text)\n</reaction>"
        }
        return (system, listing(globals) + "\n\n<reactions>\n" + reactions.joined(separator: "\n") + "\n</reactions>")
    }

    // MARK: - Answer

    public struct AnswerFailure: Error, LocalizedError {
        public let message: String
        public var errorDescription: String? { message }
    }

    /// The findings of a model's answer. Unknown severities become `medium`; a confidence is kept
    /// in 0…1. Throws when the answer isn't the asked JSON.
    public static func findings(from answer: String, part: Part) throws -> [Finding] {
        let text = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        let json = text.first == "{" ? text : text.firstIndex(of: "{").flatMap { start in text.lastIndex(of: "}").map { String(text[start...$0]) } } ?? text
        guard let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
              let list = object["findings"] as? [[String: Any]] else {
            throw AnswerFailure(message: "The model's answer has no findings list.")
        }
        return list.compactMap { raw in
            guard let title = raw["title"] as? String, !title.isEmpty else { return nil }
            let places = (raw["places"] as? [String]) ?? []
            return Finding(part: part, severity: (raw["severity"] as? String).flatMap(Severity.init(rawValue:)) ?? .medium,
                           title: title, why: raw["why"] as? String ?? "", section: raw["section"] as? String, file: raw["file"] as? String,
                           places: places, suggestion: raw["suggestion"] as? String,
                           confidence: (raw["confidence"] as? Double).map { min(1, max(0, $0)) })
        }
    }

    /// One call for a part: the gate is checked (send policy, scrub, monthly limit, send log in ModelCall).
    public static func call(_ part: Part, system: String, input: String, agent: LabAgent, origins: [SendOrigin],
                            env: HarnessEnvironment) async throws -> [Finding] {
        let gate = try await SendGate.open(agent: agent, env: env)
        let folder = FileManager.default.temporaryDirectory.appending(path: "akit-instructions-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let answer = try await ModelCall.run(
            ModelCall.Request(agent: agent, purpose: part == .review ? "instruction review" : "instruction sessions",
                              system: system, input: input, schema: schema, origins: origins),
            gate: gate, folder: folder, env: env)
        return try findings(from: answer.text, part: part)
    }

    // MARK: - Running a part

    /// The index's name of a harness (`claude`, `pi`, `codex`, `opencode`).
    public static func indexName(_ harness: HarnessID) -> String {
        switch harness {
        case .claudeCode: "claude"
        case .openCode: "opencode"
        default: harness.rawValue
        }
    }

    /// The global files of the harnesses (one entry per real file), and the instruction files of
    /// each project folder that load with them.
    public static func inputs(harnesses: [HarnessID], projects folders: [URL], env: HarnessEnvironment) -> (globals: [Text], projects: [Project]) {
        let home = env.homeDirectory
        func texts(_ project: URL?) -> [Text] {
            var order: [String] = [], readers: [String: [String]] = [:], bodies: [String: (path: String, text: String)] = [:]
            for harness in harnesses {
                for entry in InstructionScanner.view(harness: harness, project: project, env: env).loaded
                where (project == nil) == (entry.level == .global) {
                    let key = entry.file.resolvingSymlinksInPath().path
                    if readers[key] == nil { order.append(key); bodies[key] = (FileWalk.tilde(entry.file, home: home), entry.text) }
                    readers[key, default: []].append(indexName(harness))
                }
            }
            return order.map { Text(path: bodies[$0]!.path, harnesses: readers[$0]!, text: bodies[$0]!.text) }
        }
        let globals = texts(nil)
        // A session in the home folder reads ~/.claude/CLAUDE.md as its project's file too: a
        // global file is never a project file here.
        let real = { (path: String) in
            URL(filePath: path.hasPrefix("~/") ? home.path + path.dropFirst(1) : path).resolvingSymlinksInPath().path
        }
        let globalPaths = Set(globals.map { real($0.path) })
        let projects = folders.compactMap { folder -> Project? in
            let files = texts(folder).filter { !globalPaths.contains(real($0.path)) }
            return files.isEmpty ? nil : Project(folder: FileWalk.tilde(folder, home: home), files: files)
        }
        return (globals, projects)
    }

    /// Runs one part over this Mac's global files and saves it into the report (the part's
    /// earlier findings go). `agent` is needed for `.review` and `.sessions`.
    public static func run(_ part: Part, days: Int = 30, harnesses: [HarnessID], projects extra: [URL] = [], inventory: Inventory = .init(),
                           agent: LabAgent?, env: HarnessEnvironment) async throws -> Report {
        var report = load(env: env) ?? Report(days: days)
        report.days = days
        let recorded = recorded(days: days, env: env)
        var notes: [String] = []
        switch part {
        case .size:
            // Projects: the brain's ones on this Mac and the folders of recent sessions (busiest 30).
            var seen: Set<String> = [], folders: [URL] = []
            for url in extra + recorded.folders.prefix(30).map({ URL(filePath: $0, directoryHint: .isDirectory) }) where FileWalk.isDirectory(url) {
                if seen.insert(url.standardizedFileURL.path).inserted { folders.append(url) }
            }
            let (globals, projects) = inputs(harnesses: harnesses, projects: folders, env: env)
            let result = sizeAndRepeats(globals: globals, projects: projects, requests: recorded.requests)
            report.costs = result.costs
            if recorded.requests.isEmpty { notes.append("No recorded sessions in the window: costs count no requests.") }
            report.merge(.size, findings: result.findings)
        case .review:
            guard let agent else { throw AnswerFailure(message: "Pick the agent that reads the text.") }
            let globals = inputs(harnesses: harnesses, projects: [], env: env).globals
            guard !globals.isEmpty else { throw AnswerFailure(message: "No global instruction file to review.") }
            let prompt = reviewPrompt(globals: globals, inventory: inventory)
            let findings = try await call(.review, system: prompt.system, input: prompt.input, agent: agent, origins: codeOrigins(globals), env: env)
            report.merge(.review, findings: findings)
        case .sessions:
            guard let agent else { throw AnswerFailure(message: "Pick the agent that reads the sessions.") }
            let globals = inputs(harnesses: harnesses, projects: [], env: env).globals
            let found = evidence(days: days, env: env)
            guard !found.items.isEmpty else {
                throw AnswerFailure(message: "No reactions of yours in recorded sessions of the last \(days) days (Claude Code, Pi): nothing to match.")
            }
            let prompt = sessionsPrompt(globals: globals, evidence: found.items)
            let findings = try await call(.sessions, system: prompt.system, input: prompt.input, agent: agent,
                                          origins: codeOrigins(globals) + found.origins, env: env)
            notes.append("Sessions: \(found.sessions) with \(found.items.count) reactions of yours in the last \(days) days.")
            report.merge(.sessions, findings: findings)
        }
        report.notes = notes
        try save(report, env: env)
        return report
    }

    /// Instruction files are code: their origin is the harness that reads them.
    static func codeOrigins(_ globals: [Text]) -> [SendOrigin] {
        let names = Set(globals.flatMap(\.harnesses))
        return (names.contains("claude") || names.contains("opencode") ? [SendOrigin.code(.claudeCode)] : [])
            + (names.contains("pi") ? [SendOrigin.code(.pi)] : [])
    }
}
