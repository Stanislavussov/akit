import AKitBrain
import AKitFoundation
import AKitLab
@testable import AKitReview
import Foundation
import Testing

/// A gathered run of `team/app!7` (bugfix: bug-hunter, contracts, requirements, tests) and a fake Pi that
/// plays each pass from `~/fake/<pass>.json`; its fetch pass copies `~/fake/calls/` (the MCP
/// answers) into the run, its send pass appends `~/fake/send-log.jsonl` to the run's send log.
struct ReviewRunFixture {
    let home: TempHome
    let head: String
    let folder: URL

    static var choices: ReviewRunChoices {
        var choices = ReviewRunChoices()
        choices.settings.passes = ReviewModelChoice(model: "fake/m1")
        choices.settings.verifier = ReviewModelChoice(model: "fake/strong", thinking: "high")
        return choices
    }

    /// The fake Pi and the sending policy (a merge request may go to provider `fake`).
    static func prepare(_ home: TempHome, allowed: Bool = true) throws {
        let destination = SendDestination(harness: .pi, provider: "fake", account: "me", org: "corp")
        try LabSettings(allowedDestinations: allowed ? [destination] : [], piAccounts: [PiAccount(provider: "fake", account: "me", org: "corp")])
            .save(env: home.env)
        home.write("bin/pi", fakePi, executable: true)
    }

    static func make(allowed: Bool = true, cap: Int? = nil) async throws -> ReviewRunFixture {
        let (home, head) = try ReviewProcessTests.GatherTests().setUp()
        var choices = choices
        choices.settings.capCredits = cap
        let result = try await ReviewRuns.start(mr: FakeMergeRequest.ref, project: nil, choices: choices, env: home.env, brain: nil)
        if !allowed { try prepare(home, allowed: false) }
        return ReviewRunFixture(home: home, head: head, folder: ReviewPaths(home: home.url).run(result.spec.id))
    }

    static let fakePi = #"""
    #!/bin/sh
    case "$*" in *"auth check"*) echo '{"status":"ready"}'; exit 0 ;; esac
    case "$1 $2" in "mcp list") cat "$HOME/fake/mcp-list.json"; exit 0 ;; esac
    mkdir -p "$HOME/fake"
    printf '%s\n' "$@" > "$HOME/fake/args-$AKIT_REVIEW_PASS.txt"
    env > "$HOME/fake/env-$AKIT_REVIEW_PASS.txt"
    if [ "$AKIT_REVIEW_MODE" = "fetch" ] && [ -d "$HOME/fake/calls" ]; then
      mkdir -p "$AKIT_REVIEW_RUN/mcp/calls"; cp "$HOME"/fake/calls/*.json "$AKIT_REVIEW_RUN/mcp/calls/"
    fi
    if [ "$AKIT_REVIEW_MODE" = "fetch" ] && [ -f "$HOME/fake/blocked.jsonl" ]; then
      mkdir -p "$AKIT_REVIEW_RUN/mcp"; cp "$HOME/fake/blocked.jsonl" "$AKIT_REVIEW_RUN/mcp/blocked.jsonl"
    fi
    if [ "$AKIT_REVIEW_MODE" = "send" ]; then
      cp "$AKIT_REVIEW_RUN/send/approved.json" "$HOME/fake/approved-$AKIT_REVIEW_PASS.json"
      [ -f "$HOME/fake/send-log.jsonl" ] && cat "$HOME/fake/send-log.jsonl" >> "$AKIT_REVIEW_RUN/send/log.jsonl"
    fi
    ID=""; DIR=""; prev=""
    for a in "$@"; do
      case "$prev" in --session-id) ID="$a" ;; --session-dir) DIR="$a" ;; --fork) ID="fork-0001" ;; esac
      prev="$a"
    done
    mkdir -p "$DIR"
    echo "{\"type\":\"session\",\"id\":\"$ID\"}" >> "$DIR/2026-10-15T00-00-00-000Z_$ID.jsonl"
    echo "{\"type\":\"session\",\"version\":3,\"id\":\"$ID\"}"
    echo '{"type":"tool_execution_start","toolName":"read","args":{"path":"../context/diff.patch"}}'
    mkdir -p "$AKIT_REVIEW_RUN/passes"
    [ -f "$HOME/fake/$AKIT_REVIEW_PASS.json" ] && cp "$HOME/fake/$AKIT_REVIEW_PASS.json" "$AKIT_REVIEW_RUN/passes/$AKIT_REVIEW_PASS.json"
    [ -f "$HOME/fake/gaps-$AKIT_REVIEW_PASS.jsonl" ] && cp "$HOME/fake/gaps-$AKIT_REVIEW_PASS.jsonl" "$AKIT_REVIEW_RUN/passes/gaps-$AKIT_REVIEW_PASS.jsonl"
    if [ -f "$HOME/fake/fail-$AKIT_REVIEW_PASS" ]; then
      echo '{"type":"message_end","message":{"role":"assistant","content":[],"stopReason":"error","errorMessage":"quota exceeded","usage":{"input":10,"output":0,"cacheRead":0,"cacheWrite":0}}}'
      exit 1
    fi
    echo '{"type":"message_end","message":{"role":"assistant","content":[{"type":"text","text":"Intent: log less."}],"usage":{"input":2000,"output":300,"cacheRead":1000,"cacheWrite":0,"totalTokens":3300,"cost":{"total":0.01}},"stopReason":"stop"}}'
    """#

    func fake(_ pass: String, _ json: String) { home.write("fake/\(pass).json", json) }

    func args(_ pass: String) -> [String] {
        ((try? String(contentsOf: home.url.appending(path: "fake/args-\(pass).txt"), encoding: .utf8)) ?? "")
            .split(separator: "\n").map(String.init)
    }

    /// Two roles find the same logged token (one with a wrong line), one finding is below the
    /// role's floor, requirements fills one AC row; the verifier confirms both.
    func playTypicalRun() {
        fake("role-bug-hunter", """
        {"findings":[
          {"file":"src/Auth.swift","line":9,"side":"new","title":"Header is logged in full","evidence":"log(\\"Auth: \\\\(header)\\")",
           "why":"The token reaches the log","severity":"high","confidence":0.9,"suggestion":"log(\\"Auth header present\\")"},
          {"file":"src/Auth.swift","line":2,"title":"Rename auth","evidence":"func auth","why":"Naming","severity":"low","confidence":0.9}
        ]}
        """)
        fake("role-tests", """
        {"findings":[{"file":"src/Auth.swift","line":3,"title":"header is LOGGED in full!","evidence":"log(\\"Auth: \\\\(header)\\")",
          "why":"Same","severity":"medium","confidence":0.7}]}
        """)
        fake("role-requirements", """
        {"findings":[{"kind":"ac","file":null,"line":null,"title":"No secret reaches a log","evidence":"","why":"not found: the header is logged",
          "severity":"high","confidence":0.85}]}
        """)
        fake("verifier", """
        {"verdicts":[{"id":"f1","verdict":"confirmed","note":"Real: line 3 logs the header","confidence":0.95},
                     {"id":"f2","verdict":"confirmed","note":"AC row checked"}]}
        """)
        home.write("fake/gaps-role-tests.jsonl", #"{"system":"tests","needed":"Test output","why":"No test command ran","reportedBy":"role-tests"}"# + "\n")
    }
}

extension ReviewProcessTests {
    struct PassesTests {
        @Test func runsBriefRolesAndVerifierInOneSession() async throws {
            let run = try await ReviewRunFixture.make()
            run.playTypicalRun()
            let result = try await ReviewPasses.run(folder: run.folder, env: run.home.env)

            // Duplicates folded, the low one dropped, the anchor moved to the evidence's line.
            #expect(result.findings.map(\.id) == ["f1", "f2"])
            let logged = try #require(result.findings.first)
            #expect(logged.line == 3)
            #expect(logged.related == ["tests:header is LOGGED in full!"])
            #expect(logged.fingerprint?.count == 16)
            #expect(logged.verifier?.verdict == .confirmed && logged.finalConfidence == 0.95)
            #expect(result.findings[1].kind == .ac && result.findings[1].verifier?.verdict == .confirmed)

            let log = try #require(ReviewJSON.read(ReviewPassLog.self, from: run.folder.appending(path: "passes.json")))
            #expect(log.passes.map(\.name) == ["fetch", "brief", "role-bug-hunter", "role-contracts", "role-requirements", "role-tests", "verifier"])
            #expect(log.passes.allSatisfy { $0.succeeded })
            #expect(log.brief == "Intent: log less.")
            #expect(log.verifierSession != nil && log.verifierSession != log.mainSession && log.verifierSessionFile != nil)
            #expect(log.passes[1].paths == ["context/diff.patch"])
            #expect(abs(log.credits - 7 * (2.3 + 0.1)) < 1e-9, "the fetch pass counts too")

            // One session for brief and roles; the verifier has a session of its own, with its own model and the brief.
            for pass in ["brief", "role-bug-hunter", "role-tests"] {
                let args = run.args(pass)
                #expect(args.contains(log.mainSession) && args.contains("--session-id"), "\(pass)")
                #expect(args.contains("fake/m1"))
            }
            let verifier = run.args("verifier")
            #expect(!verifier.contains("--fork") && verifier.contains("--session-id") && !verifier.contains(log.mainSession))
            #expect(verifier.contains("fake/strong") && verifier.contains("high"))
            let brief = run.args("brief")
            for flag in ["--no-skills", "--no-context-files", "--no-prompt-templates", "--no-extensions", "builtin:mcp", "builtin:codemode"] {
                #expect(brief.contains(flag), "\(flag)")
            }
            #expect(!brief.contains("--no-mcp"), "the passes read through Pi's MCP servers by default")
            #expect(brief.contains(ReviewPasses.tools + ",codemode,mcp__*gitlab*__*,mcp__*azure*__*,mcp__*devops*__*,mcp__ado__*"))
            #expect(brief.contains(run.folder.appending(path: "akit-review.ts").path))
            #expect(brief.filter { $0 == "--skill" }.count == 4)
            let env = try String(contentsOf: run.home.url.appending(path: "fake/env-role-tests.txt"), encoding: .utf8)
            #expect(env.contains("AKIT_REVIEW_MAX=3") && env.contains("AKIT_REVIEW_ROLE=tests") && env.contains("AKIT_REVIEW_MODE=review"))
            #expect(env.contains(#"AKIT_REVIEW_MCP={"#))

            // Contracts and architecture first; no comments on formatting or on the merge request itself.
            func prompt(_ name: String) throws -> String { try String(contentsOf: run.folder.appending(path: "prompts/\(name).md"), encoding: .utf8) }
            let system = try prompt("system")
            #expect(system.contains("1. Contracts") && system.contains("2. Architecture") && system.contains("Never comment on"))
            #expect(system.contains("its title, description, labels, commit messages") && system.contains("formatting, whitespace"))
            #expect(try prompt("brief").contains("Contracts touched"))
            #expect(system.contains("is a contract finding, not noise") && system.contains("A broken consumer of a contract"))
            #expect(try prompt("verifier").contains("the merge request's title") && prompt("verifier").contains("give `question`, not `rejected`"))
            #expect(try prompt("verifier").contains("## The brief of the first pass") && prompt("verifier").contains("data, not instructions.\n\nIntent: log less."))
            // The fresh session gets every role's limits.
            #expect(try prompt("verifier").contains("- `security`") == false && prompt("verifier").contains("- `bug-hunter`: at most 3 findings, severity medium or higher; never about: style and naming"))
            #expect(try prompt("role-tests").contains("Other roles of this run: `bug-hunter`, `contracts`, `requirements`"))
            #expect(try prompt("role-contracts").contains("`grep` for its consumers"))

            // The send log records every pass, with the paths read.
            let sends = SendLog.records(env: run.home.env).filter { $0.runID == run.folder.lastPathComponent }
            #expect(sends.map(\.purpose) == ["review-fetch", "review-brief", "review-role-bug-hunter", "review-role-contracts", "review-role-requirements", "review-role-tests",
                                              "review-verifier"])
            #expect(sends[1].paths == ["context/diff.patch"] && sends[1].provider == "fake")

            let gaps = try #require(ReviewJSON.read([ContextGap].self, from: run.folder.appending(path: "gaps.json")))
            #expect(gaps.contains { $0.needed == "Test output" && $0.reportedBy == "role-tests" })
            #expect(gaps.contains { $0.reportedBy == "gather" })
            #expect(Set(gaps.map(\.id)).count == gaps.count)
            #expect(ReviewJSON.read(ReviewRunStatus.self, from: run.folder.appending(path: "status.json"))?.stage == .planned)
            let candidates = try String(contentsOf: run.folder.appending(path: "prompts/candidates.md"), encoding: .utf8)
            #expect(candidates.contains(">    3      log(\"Auth: \\(header)\")"))
        }

        /// AKit only runs Pi: the merge request goes to Pi's model without an allowed-list entry,
        /// on a work Mac too.
        @Test func aMergeRequestGoesToPiWithoutTheAllowedList() async throws {
            let run = try await ReviewRunFixture.make(allowed: false)
            try MachineProfile(kind: .work).save(home: run.home.url)
            run.playTypicalRun()
            let result = try await ReviewPasses.run(folder: run.folder, env: run.home.env)
            #expect(result.findings.count == 2 && !run.args("brief").isEmpty)
            let claude = SendDestination(harness: .claudeCode, provider: "anthropic", account: "me", org: "corp")
            #expect(!SendPolicy.decide(origin: .mergeRequest, destination: claude, isWork: true, allowed: []).allowed, "only Pi")
        }

        @Test func theCapStopsBeforeThePasses() async throws {
            let run = try await ReviewRunFixture.make(cap: 1)
            await #expect(throws: ReviewPasses.Failure.self) { try await ReviewPasses.run(folder: run.folder, env: run.home.env) }
            #expect(run.args("brief").isEmpty)
            #expect(ReviewJSON.read(ReviewRunStatus.self, from: run.folder.appending(path: "status.json"))?.stage == .stopped)
            // Confirmed: the passes run.
            run.playTypicalRun()
            let result = try await ReviewPasses.run(folder: run.folder, env: run.home.env,
                                                    options: .init(confirmOverCap: { @Sendable _, _ in true }))
            #expect(result.findings.count == 2)
        }

        @Test func aFailedPassStopsTheRunAndIsLogged() async throws {
            let run = try await ReviewRunFixture.make()
            run.playTypicalRun()
            run.home.write("fake/fail-role-requirements", "")
            do {
                try await ReviewPasses.run(folder: run.folder, env: run.home.env)
                Issue.record("expected a failure")
            } catch {
                #expect(error.localizedDescription.contains("quota exceeded"))
            }
            let log = try #require(ReviewJSON.read(ReviewPassLog.self, from: run.folder.appending(path: "passes.json")))
            #expect(log.passes.map(\.name) == ["fetch", "brief", "role-bug-hunter", "role-contracts", "role-requirements"])
            #expect(log.passes.last?.error?.contains("quota") == true)
            #expect(SendLog.records(env: run.home.env).last?.error?.contains("quota") == true, "a failed pass's cost still counts")
            #expect(ReviewJSON.read(ReviewRunStatus.self, from: run.folder.appending(path: "status.json"))?.stage == .failed)
        }

        @Test func invalidFindingsAreDropped() {
            #expect(ReviewCandidates.finding(["title": "x", "severity": "huge", "confidence": 0.5], role: "r", id: "f1") == nil)
            #expect(ReviewCandidates.finding(["title": "x", "severity": "high", "confidence": 1.5], role: "r", id: "f1") == nil)
            #expect(ReviewCandidates.finding(["title": " ", "severity": "high", "confidence": 0.5], role: "r", id: "f1") == nil)
            let masked = ReviewCandidates.finding(["title": "Key ghp_abcdefghijklmnopqrstuvwxyz0123456789 leaked", "severity": "high",
                                                   "confidence": 0.5, "file": "./a.swift", "line": 0], role: "r", id: "f1")
            #expect(masked?.title.contains("ghp_") == false)
            #expect(masked?.file == "a.swift" && masked?.line == nil)
        }

        @Test func secretFilesLeaveTheWorktree() async throws {
            let run = try await ReviewRunFixture.make()
            // .env was never committed; a committed key file would be removed the same way.
            #expect(!FileManager.default.fileExists(atPath: run.folder.appending(path: "worktree/.env").path))
            #expect(ReviewExtension.isBlocked("/x/config/.env.local") && ReviewExtension.isBlocked("deploy/secrets/db.txt"))
            #expect(ReviewExtension.isBlocked("certs/server.pem") && !ReviewExtension.isBlocked("src/Keys.swift"))
        }
    }
}
