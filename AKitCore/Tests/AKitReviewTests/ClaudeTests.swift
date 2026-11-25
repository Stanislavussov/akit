import AKitFoundation
import AKitLab
import AKitSessions
@testable import AKitReview
import Foundation
import Testing

extension ReviewProcessTests {
    /// R69: a local review whose passes run on Claude Code. A fake `claude` answers each pass with
    /// `~/fake/claude-<pass>.json` as its structured output (the pass is read from the prompt) and
    /// saves its arguments and prompt as `~/fake/claude-args-<pass>.txt` and `claude-prompt-<pass>.txt`.
    struct ClaudeTests {
        static let fakeClaude = #"""
        #!/bin/sh
        case "$*" in *"auth status"*) echo '{"loggedIn":true,"email":"me@example.com","orgName":"Me","apiProvider":"firstParty"}'; exit 0 ;; esac
        mkdir -p "$HOME/fake"
        PROMPT=$(cat)
        case "$PROMPT" in
          *"Pass 1 of the review: the brief"*) PASS=brief; DEFAULT='{"brief":"Intent: count the total.","boundaries":[],"gaps":[]}' ;;
          *"Next pass: the overview"*) PASS=overview; DEFAULT='{"points":["Cart counts a total."],"modules":[],"why_sources":["none"],"gaps":[]}' ;;
          *"Next pass: you are the "*) PASS="role-$(printf '%s' "$PROMPT" | sed -n 's/.*Next pass: you are the `\([a-z-]*\)` reviewer.*/\1/p' | head -1)"; DEFAULT='{"findings":[],"gaps":[]}' ;;
          *) PASS=verifier; DEFAULT='{"verdicts":[],"gaps":[]}' ;;
        esac
        printf '%s\n' "$@" > "$HOME/fake/claude-args-$PASS.txt"
        printf '%s' "$PROMPT" > "$HOME/fake/claude-prompt-$PASS.txt"
        ID=""; prev=""; FORK=""
        for a in "$@"; do
          case "$prev" in --session-id|--resume) ID="$a" ;; esac
          [ "$a" = "--fork-session" ] && FORK=1
          prev="$a"
        done
        [ -n "$FORK" ] && ID="fork-$ID"
        ANSWER="$DEFAULT"
        [ -f "$HOME/fake/claude-$PASS.json" ] && ANSWER=$(tr -d '\n' < "$HOME/fake/claude-$PASS.json")
        echo "{\"type\":\"system\",\"subtype\":\"init\",\"session_id\":\"$ID\",\"tools\":[\"Read\",\"Grep\",\"Glob\"]}"
        echo '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Read","input":{"file_path":"src/Cart.swift"}}]}}'
        echo "{\"type\":\"result\",\"subtype\":\"success\",\"is_error\":false,\"result\":\"done\",\"session_id\":\"$ID\",\"total_cost_usd\":0.02,\"usage\":{\"input_tokens\":100,\"cache_creation_input_tokens\":900,\"cache_read_input_tokens\":2000,\"output_tokens\":300},\"structured_output\":$ANSWER}"
        """#

        static var choices: ReviewRunChoices {
            var choices = ReviewRunChoices()
            choices.settings.harness = .claudeCode
            return choices
        }

        func args(_ home: TempHome, _ pass: String) -> [String] {
            ((try? String(contentsOf: home.url.appending(path: "fake/claude-args-\(pass).txt"), encoding: .utf8)) ?? "")
                .split(separator: "\n").map(String.init)
        }

        func prompt(_ home: TempHome, _ pass: String) -> String {
            (try? String(contentsOf: home.url.appending(path: "fake/claude-prompt-\(pass).txt"), encoding: .utf8)) ?? ""
        }

        @Test func runsEveryPassOnClaudeCodeWithoutMCP() async throws {
            let (home, repo) = try LocalTests().workspace()
            home.write("bin/claude", Self.fakeClaude, executable: true)
            let inspection = try await ReviewLocal.inspect(path: repo, env: home.env)
            let target = try await ReviewLocal.target(inspection, mode: .all, env: home.env)
            let result = try await ReviewRuns.startLocal(target, project: nil, choices: Self.choices, env: home.env, brain: nil)
            let spec = result.spec
            #expect(spec.onClaude && spec.harness?.source == .run)
            #expect(spec.passes.value == ReviewModelChoice(model: "sonnet", thinking: "high"), "the built-in claude: models, not Pi's")
            #expect(spec.verifier.value == ReviewModelChoice(model: "opus", thinking: "high"))
            #expect(spec.access.inPasses == false && spec.mcpServers == [] && spec.steps == nil)
            let folder = ReviewPaths(home: home.url).run(spec.id)

            home.write("fake/claude-role-bug-hunter.json", #"""
            {"findings":[{"file":"src/Cart.swift","line":3,"side":"new","title":"Celková cena počítá položky dvakrát","evidence":"var total: Int { items.count * 2 }",
              "why":"Košík se dvěma položkami ukáže čtyři","severity":"high","confidence":0.9,
              "trace":[{"file":"src/Cart.swift","line":2,"quote":"var items: [String] = []","note":"položky košíku"},
                       {"file":"src/Cart.swift","line":3,"quote":"var total: Int { items.count * 2 }","note":"počet se zdvojí"}]}],
             "gaps":[{"system":"tests","needed":"Testy košíku","why":"Žádný test nepokrývá total"}]}
            """#)
            home.write("fake/claude-verifier.json", #"{"verdicts":[{"id":"f1","verdict":"confirmed","note":"Řádek 3 zdvojuje počet"}],"gaps":[]}"#)
            let findings = try await ReviewPasses.run(folder: folder, env: home.env)
            #expect(findings.findings.map(\.title) == ["Celková cena počítá položky dvakrát", "A secrets file in the change"],
                    "the role's finding, then AKit's own secret scan of the workspace's .env")
            #expect(!FileManager.default.fileExists(atPath: folder.appending(path: "akit-review.ts").path), "no Pi extension")
            #expect(!FileManager.default.fileExists(atPath: home.url.appending(path: "fake/args-brief.txt").path), "Pi never runs")

            let log = try #require(ReviewJSON.read(ReviewPassLog.self, from: folder.appending(path: "passes.json")))
            #expect(log.brief == "Intent: count the total.", "the brief's structured text")
            let brief = args(home, "brief")
            for flag in ["--safe-mode", "--strict-mcp-config", "--json-schema", "--append-system-prompt-file"] { #expect(brief.contains(flag)) }
            #expect(!brief.contains("--mcp-config") && !brief.contains("--resume"))
            func value(_ arguments: [String], _ flag: String) -> String? { arguments.firstIndex(of: flag).map { arguments[$0 + 1] } }
            #expect(value(brief, "--tools") == "Read,Grep,Glob" && value(brief, "--permission-prompts") == "none")
            #expect(value(brief, "--model") == "sonnet" && value(brief, "--effort") == "high" && value(brief, "--session-id") == log.mainSession)
            #expect(value(brief, "--settings")?.contains("Read(**/.env*)") == true)
            #expect(brief.contains(folder.appending(path: "context").path), "the context pack is an added folder")
            #expect(value(args(home, "overview"), "--resume") == log.mainSession && args(home, "overview").contains("--fork-session"))
            #expect(value(args(home, "role-bug-hunter"), "--resume") == log.mainSession, "the roles go on in the brief's session")
            let verifier = args(home, "verifier")
            #expect(value(verifier, "--model") == "opus" && value(verifier, "--session-id") != log.mainSession && !verifier.contains("--resume"))
            #expect(log.passes.allSatisfy { $0.credits > 0 } && log.passes.first?.usage.cached == 2000)

            // No prompt names a Pi tool.
            let system = try String(contentsOf: folder.appending(path: "prompts/system.md"), encoding: .utf8)
            #expect(system.contains("Read, Grep and Glob") && system.contains(folder.appending(path: "context/README.md").path))
            for text in [system, prompt(home, "brief"), prompt(home, "overview"), prompt(home, "role-bug-hunter"), prompt(home, "verifier")] {
                // The overview's one `akit_` is a rule for Mermaid ids, not a tool.
                let text = text.replacingOccurrences(of: "ids that start with `akit_`", with: "")
                #expect(!text.contains("akit_") && !text.contains("codemode") && !text.contains("`read`"))
            }
            #expect(prompt(home, "brief").contains("`brief`") && prompt(home, "brief").contains("`boundaries`"))

            let gaps = try #require(ReviewJSON.read([ContextGap].self, from: folder.appending(path: "gaps.json")))
            #expect(gaps.contains { $0.needed == "Testy košíku" && $0.reportedBy == "role-bug-hunter" })
            #expect(SessionScanner.isReviewRun(folder.appending(path: "worktree"), env: home.env))
            await #expect(throws: ReviewDiscuss.Failure.self, "Discuss goes on in Pi") { try await ReviewDiscuss.setup(folder, env: home.env) }
            #expect(try ReviewWorkflow.load(folder).translationSource.ownAgent?.harness == .claudeCode, "a translation goes where the passes went")
        }

        @Test func refusesWhatNeedsMCPOrPi() async throws {
            let (home, repo) = try LocalTests().workspace()
            let inspection = try await ReviewLocal.inspect(path: repo, env: home.env)
            let target = try await ReviewLocal.target(inspection, mode: .all, env: home.env)
            var withLink = Self.choices
            withLink.links = ["https://example.com/design"]
            await #expect(throws: ReviewResolver.Failure.self) { try await ReviewRuns.startLocal(target, project: nil, choices: withLink, env: home.env, brain: nil) }
            var withServer = Self.choices
            withServer.extraServers = ["wiki"]
            await #expect(throws: ReviewResolver.Failure.self) { try await ReviewRuns.startLocal(target, project: nil, choices: withServer, env: home.env, brain: nil) }
            var withStep = Self.choices
            withStep.pi = ReviewPiExtras(flags: [], steps: [ReviewStepConfig(command: "/skill:x")])
            await #expect(throws: ReviewResolver.Failure.self) { try await ReviewRuns.startLocal(target, project: nil, choices: withStep, env: home.env, brain: nil) }
            var piThinking = Self.choices
            piThinking.settings.verifier = ReviewModelChoice(model: "", thinking: "minimal")
            await #expect(throws: ReviewResolver.Failure.self) { try await ReviewRuns.startLocal(target, project: nil, choices: piThinking, env: home.env, brain: nil) }
            await #expect(throws: ReviewRuns.Failure.self) {
                try await ReviewRuns.start(mr: FakeMergeRequest.ref, project: nil, choices: Self.choices, env: home.env, brain: nil)
            }
        }
    }
}

struct ReviewHarnessConfigTests {
    @Test func readsTheHarnessAndClaudesOwnModels() throws {
        let patch = try ReviewSettingsPatch.parse(ReviewYAML.map("""
        harness: claude-code
        models: { passes: github-copilot/gpt-5, verifier: github-copilot/claude-opus }
        claude:
          models: { passes: haiku, verifier: opus }
          thinking: { verifier: max }
        """), where: "review.yaml")
        #expect(patch.harness == .claudeCode)
        #expect(patch.passes?.model == "github-copilot/gpt-5", "Pi's models stay where they were")
        #expect(patch.claudePasses == ReviewModelChoice(model: "haiku") && patch.claudeVerifier == ReviewModelChoice(model: "opus", thinking: "max"))
        #expect(throws: ReviewRole.Failure.self) { try ReviewSettingsPatch.parse(ReviewYAML.map("harness: codex"), where: "x") }
        #expect(throws: ReviewRole.Failure.self) { try ReviewSettingsPatch.parse(ReviewYAML.map("claude: { thinking: { passes: minimal } }"), where: "x") }
        let builtIn = try ReviewSettingsPatch.parse(ReviewYAML.map(ReviewBuiltIns.defaultsYAML), where: "built-in")
        #expect(builtIn.harness == .pi && builtIn.claudeVerifier?.model == "opus")
    }

    @Test func aPersonalMacSendsALocalReviewToClaudeCode() {
        let claude = SendDestination(harness: .claudeCode, provider: "anthropic", account: "me@example.com", org: "Me")
        #expect(SendPolicy.decide(origin: .localReview, destination: claude, isWork: false, allowed: []).allowed)
        #expect(!SendPolicy.decide(origin: .localReview, destination: claude, isWork: true, allowed: []).allowed, "a work Mac's list decides")
        #expect(SendPolicy.decide(origin: .localReview, destination: claude, isWork: true, allowed: [claude]).allowed)
        #expect(!SendPolicy.decide(origin: .mergeRequest, destination: claude, isWork: false, allowed: []).allowed, "a merge request stays with Pi")
        // An entry for local reviews only: Claude Code gets nothing else from this work Mac.
        var reviewOnly = claude
        reviewOnly.localReviewOnly = true
        #expect(SendPolicy.decide(origin: .localReview, destination: claude, isWork: true, allowed: [reviewOnly]).allowed)
        #expect(!SendPolicy.decide(origin: .code(.pi), destination: claude, isWork: true, allowed: [reviewOnly]).allowed)
        #expect(!SendPolicy.decide(origin: .mergeRequest, destination: claude, isWork: true, allowed: [reviewOnly]).allowed)
        #expect(reviewOnly.label.hasSuffix("· local reviews only"))
        var settings = LabSettings(allowedDestinations: [reviewOnly])
        _ = settings.allow(reviewOnly)
        #expect(settings.allowedDestinations == [reviewOnly])
        _ = settings.allow(claude)
        #expect(settings.allowedDestinations.map(\.localReviewOnly) == [nil], "an entry for everything widens it")
    }

    @Test func translatesClaudesAnswerIntoTheExtensionsFiles() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "claude-save-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let answer: [String: Any] = ["findings": [["title": "a", "severity": "high"], ["kind": "ac", "title": "row"]],
                                     "gaps": [["system": "tests", "needed": "n", "why": "w", "how_to_get": "h"], ["why": "no needed"]]]
        try ReviewClaude.save(answer, kind: .findings, pass: "role-x", role: "x", folder: folder)
        let saved = try JSONSerialization.jsonObject(with: Data(contentsOf: folder.appending(path: "passes/role-x.json"))) as? [String: Any]
        #expect((saved?["findings"] as? [[String: Any]])?.compactMap { $0["title"] as? String } == ["a", "row"])
        #expect(saved?["role"] as? String == "x")
        let gaps = try String(contentsOf: folder.appending(path: "passes/gaps-role-x.jsonl"), encoding: .utf8)
        #expect(gaps.split(separator: "\n").count == 1 && gaps.contains("\"howToGet\":\"h\"") && gaps.contains("\"reportedBy\":\"role-x\""))
        #expect(ReviewClaude.sessionArguments(["--fork", "m"], known: []) == ["--resume", "m", "--fork-session"])
        #expect(ReviewClaude.sessionArguments(["--session-id", "m"], known: ["m"]) == ["--resume", "m"])
        #expect(ReviewClaude.sessionArguments(["--session-id", "n"], known: ["m"]) == ["--session-id", "n"])
    }
}
