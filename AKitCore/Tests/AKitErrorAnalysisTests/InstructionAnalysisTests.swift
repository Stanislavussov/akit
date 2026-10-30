import Foundation
import Testing
import AKitFoundation
import AKitInsights
@testable import AKitErrorAnalysis

/// Analyze… of the global instructions, part 1: costs and repeats, no model.
struct InstructionAnalysisTests {
    let big = "## Skills\n" + String(repeating: "| skill | keywords | when |\n", count: 200)

    @Test func costsCountTheRequestsOfTheHarnessesThatReadTheFile() {
        let globals = [InstructionAnalysis.Text(path: "~/.claude/CLAUDE.md", harnesses: ["claude", "opencode"], text: "## Commits\nShort lines.\n")]
        let result = InstructionAnalysis.sizeAndRepeats(globals: globals, projects: [], requests: ["claude": 100, "pi": 50])
        let cost = try! #require(result.costs.first)
        #expect(cost.section == "## Commits" && cost.requests == 100 && cost.sent == cost.tokens * 100)
        #expect(result.findings.isEmpty)
    }

    @Test func aLargeSectionAndProjectRepeatsAreFindings() {
        let globals = [InstructionAnalysis.Text(path: "~/.pi/agent/AGENTS.md", harnesses: ["pi"], text: "## Commits\nShort lines.\n\n## Style\nTabs.\n\n" + big)]
        let projects = [
            InstructionAnalysis.Project(folder: "~/Projects/a", files: [
                .init(path: "~/Projects/a/AGENTS.md", harnesses: ["pi", "claude"], text: "# A\n\n## commits\n\nShort lines.\n\n## Style\nSpaces.\n"),
            ]),
            // Claude-only files don't load with Pi's global file.
            InstructionAnalysis.Project(folder: "~/Projects/b", files: [
                .init(path: "~/Projects/b/CLAUDE.md", harnesses: ["claude"], text: "## Commits\nShort lines.\n"),
            ]),
        ]
        let findings = InstructionAnalysis.sizeAndRepeats(globals: globals, projects: projects, requests: ["pi": 10]).findings
        #expect(findings.map(\.title).sorted() == ["Another version in projects", "Large section", "Repeated in projects"])
        let repeated = findings.first { $0.title == "Repeated in projects" }
        #expect(repeated?.section == "## Commits" && repeated?.places == ["~/Projects/a/AGENTS.md:3"])
        #expect(findings.first { $0.title == "Another version in projects" }?.severity == .medium)
    }

    @Test func aSectionInTwoGlobalFilesOfOneHarness() {
        let globals = [
            InstructionAnalysis.Text(path: "~/.claude/CLAUDE.md", harnesses: ["claude"], text: "## Commits\nShort lines.\n"),
            InstructionAnalysis.Text(path: "~/.claude/rules.md", harnesses: ["claude"], text: "## Commits\nShort lines.\n"),
            InstructionAnalysis.Text(path: "~/.pi/agent/AGENTS.md", harnesses: ["pi"], text: "## Commits\nShort lines.\n"),
        ]
        let findings = InstructionAnalysis.sizeAndRepeats(globals: globals, projects: [], requests: [:]).findings
        #expect(findings.map(\.title) == ["Twice in global files"] && findings.first?.places == ["~/.claude/rules.md"])
    }

    @Test func aPartsFindingsReplaceItsEarlierOnesAndTheReportRoundTrips() throws {
        var report = InstructionAnalysis.Report(days: 30)
        let old = InstructionAnalysis.Finding(part: .size, severity: .low, title: "Old", why: "", section: nil, file: nil)
        let kept = InstructionAnalysis.Finding(part: .review, severity: .high, title: "Kept", why: "", section: nil, file: nil)
        report.merge(.size, findings: [old])
        report.merge(.review, findings: [kept])
        report.merge(.size, findings: [])
        #expect(report.findings == [kept] && Set(report.parts) == [.size, .review])
        let data = try JSONEncoder().encode(report)
        #expect(try JSONDecoder().decode(InstructionAnalysis.Report.self, from: data).findings == [kept])
    }
}

/// Analyze… parts 2 and 3: the prompts, the answer, and the user's reactions in sessions.
struct InstructionReviewTests {
    let home: URL
    let fm = FileManager.default

    init() throws {
        home = fm.temporaryDirectory.appending(path: "akit-instr-review-\(UUID().uuidString)")
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
    }

    var env: HarnessEnvironment {
        HarnessEnvironment(homeDirectory: home, variables: ["HOME": home.path],
                           executableSearchPaths: [URL(filePath: "/usr/bin"), URL(filePath: "/bin")])
    }

    let globals = [InstructionAnalysis.Text(path: "~/.claude/CLAUDE.md", harnesses: ["claude"],
                                            text: "Lead.\n\n<!-- akit:core:start -->\n## Commits\nShort.\n<!-- akit:core:end -->\n\n## Style\nTabs.\n")]

    @Test func thePromptsNameEverySectionAndTheBrainsOnes() {
        let review = InstructionAnalysis.reviewPrompt(globals: globals, inventory: .init(skills: ["tdd"], mcpServers: ["gitlab"], harnesses: ["Claude Code"]))
        #expect(review.input.contains("<section id=\"## Commits\" source=\"brain\">"))
        #expect(review.input.contains("<section id=\"## Style\">") && review.input.contains("<section id=\"Lead.\">"))
        #expect(review.input.contains("skills: tdd") && review.input.contains("MCP servers: gitlab"))
        let evidence = [InstructionAnalysis.Evidence(session: "claude:1", project: "~/p", kind: "pushback", text: "No, tabs!", agentBefore: "I used spaces.")]
        let sessions = InstructionAnalysis.sessionsPrompt(globals: globals, evidence: evidence)
        #expect(sessions.input.contains("<reaction session=\"claude:1\" project=\"~/p\" kind=\"pushback\">\nagent: I used spaces.\nuser: No, tabs!"))
    }

    @Test func findingsAreReadFromTheAnswerEvenWithProseAround() throws {
        let answer = """
            Here you go:
            {"findings":[{"severity":"high","title":"Broken: tabs","why":"Twice.","section":"## Style","file":"~/.claude/CLAUDE.md",
            "places":["claude:1","claude:2"],"suggestion":null,"confidence":1.4},
            {"severity":"weird","title":"Missing: tests first","why":"","section":null,"file":null,"places":[],"suggestion":"## Tests\\nFirst.","confidence":0.5},
            {"severity":"low","title":"","why":"no title"}]}
            """
        let findings = try InstructionAnalysis.findings(from: answer, part: .sessions)
        #expect(findings.count == 2)
        #expect(findings[0].severity == .high && findings[0].places == ["claude:1", "claude:2"] && findings[0].confidence == 1)
        #expect(findings[1].severity == .medium && findings[1].suggestion == "## Tests\nFirst." && findings[1].section == nil)
        #expect(throws: InstructionAnalysis.AnswerFailure.self) { try InstructionAnalysis.findings(from: "no json", part: .review) }
    }

    func writeSession(_ id: String, messages: [(role: String, text: String)]) throws {
        let folder = home.appending(path: ".claude/projects/-work")
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let now = ISO8601DateFormatter().string(from: .now)
        let lines = messages.enumerated().map { index, message -> [String: Any] in
            message.role == "user"
                ? ["type": "user", "cwd": "/work", "sessionId": id, "timestamp": now, "message": ["role": "user", "content": message.text]]
                : ["type": "assistant", "sessionId": id, "timestamp": now,
                   "message": ["id": "m-\(id)-\(index)", "model": "claude-opus-5-5", "role": "assistant",
                               "content": [["type": "text", "text": message.text]], "usage": ["input_tokens": 10, "output_tokens": 5]]]
        }
        let text = lines.map { String(decoding: try! JSONSerialization.data(withJSONObject: $0), as: UTF8.self) }.joined(separator: "\n") + "\n"
        try Data(text.utf8).write(to: folder.appending(path: "\(id).jsonl"))
    }

    @Test func evidenceIsTheUsersReactionsWithWhatTheAgentDidBefore() async throws {
        let id = "33333333-3333-4333-8333-333333333333"
        try writeSession(id, messages: [
            ("user", "Format the file"), ("assistant", "Done, I used spaces."),
            ("user", "No, I told you to use tabs"), ("assistant", "Fixed: tabs now."),
            ("user", "Thanks, now commit"), ("assistant", "Committed."),
        ])
        // Too short to count: fewer than 3 requests.
        try writeSession("44444444-4444-4444-8444-444444444444", messages: [("user", "Hi"), ("assistant", "Hello"), ("user", "No, wrong")])
        let database = try IndexSchema.open(InsightsPaths(env: env).database)
        _ = try await SessionImporter.importAndBind(env: env, projectsRoot: home.appending(path: "Projects"), database: database)

        let found = InstructionAnalysis.evidence(days: 14, env: env)
        #expect(found.sessions == 1 && found.origins.count == 1)
        #expect(found.items.map(\.kind) == ["pushback", "follow-up"])
        let first = try #require(found.items.first)
        #expect(first.session == "claude:\(id)" && first.text == "No, I told you to use tabs" && first.agentBefore == "Done, I used spaces.")
        #expect(InstructionAnalysis.evidence(days: 14, env: env, now: .now.addingTimeInterval(30 * 86_400)).items.isEmpty, "older than the window")
    }

    @Test func onlyFilesClaudeOrPiReadAreSent() {
        var notes: [String] = []
        let globals = [
            InstructionAnalysis.Text(path: "~/.claude/CLAUDE.md", harnesses: ["claude", "opencode"], text: "a"),
            InstructionAnalysis.Text(path: "~/.codex/AGENTS.md", harnesses: ["codex"], text: "b"),
            InstructionAnalysis.Text(path: "~/.config/opencode/AGENTS.md", harnesses: ["opencode"], text: "c"),
        ]
        let sent = InstructionAnalysis.sendable(globals, notes: &notes)
        #expect(sent.map(\.path) == ["~/.claude/CLAUDE.md"] && notes.count == 2)
        #expect(InstructionAnalysis.codeOrigins(sent) == [.code(.claudeCode)])
    }
}
