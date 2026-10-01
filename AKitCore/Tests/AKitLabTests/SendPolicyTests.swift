import Foundation
import Testing
import AKitFoundation
import AKitModel
@testable import AKitLab

/// The sending policy, account checks, the send log and one model call, with fake `claude`
/// and `pi` in a temporary home.
@Suite(.serialized)
struct SendPolicyTests {
    let home: URL
    let fm = FileManager.default

    init() throws {
        home = fm.temporaryDirectory.appending(path: "akit-send-\(UUID().uuidString)")
        try fm.createDirectory(at: home.appending(path: "bin"), withIntermediateDirectories: true)
    }

    var env: HarnessEnvironment {
        HarnessEnvironment(homeDirectory: home, variables: ["HOME": home.path],
                           executableSearchPaths: [home.appending(path: "bin"), URL(filePath: "/usr/bin"), URL(filePath: "/bin")])
    }

    func write(_ path: String, _ text: String, executable: Bool = false) throws {
        let url = home.appending(path: path)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
        if executable { try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path) }
    }

    let claudeAccount = SendDestination(harness: .claudeCode, provider: "anthropic", account: "me@example.com", org: "Me")
    let copilot = SendDestination(harness: .pi, provider: "github-copilot", account: "me", org: "acme")

    // MARK: Policy

    @Test func personalMacAllowsTheSameOriginOnly() {
        #expect(SendPolicy.decide(origin: .claudeSession, destination: claudeAccount, isWork: false, allowed: []).allowed)
        #expect(!SendPolicy.decide(origin: .claudeSession, destination: copilot, isWork: false, allowed: []).allowed)
        #expect(SendPolicy.decide(origin: .piSession(providers: ["github-copilot"]), destination: copilot, isWork: false, allowed: []).allowed)
        // A session that mixed providers has no single origin.
        #expect(!SendPolicy.decide(origin: .piSession(providers: ["github-copilot", "opencode-go"]), destination: copilot,
                                   isWork: false, allowed: []).allowed)
        #expect(!SendPolicy.decide(origin: .piSession(providers: ["opencode-go"]), destination: copilot, isWork: false, allowed: []).allowed)
    }

    @Test func crossOriginNeedsTheAllowedList() {
        var entry = copilot
        entry.account = " ME "
        let decision = SendPolicy.decide(origin: .claudeSession, destination: copilot, isWork: false, allowed: [entry])
        #expect(decision.allowed)
        var otherOrg = copilot
        otherOrg.org = "other"
        #expect(!SendPolicy.decide(origin: .claudeSession, destination: copilot, isWork: false, allowed: [otherOrg]).allowed)
    }

    @Test func workMacSendsOnlyToTheList() {
        let refused = SendPolicy.decide(origin: .claudeSession, destination: claudeAccount, isWork: true, allowed: [])
        #expect(!refused.allowed)
        #expect(refused.reason.contains("work Mac"))
        #expect(SendPolicy.decide(origin: .claudeSession, destination: claudeAccount, isWork: true, allowed: [claudeAccount]).allowed)
        #expect(!SendPolicy.decide(origin: .code(.claudeCode), destination: claudeAccount, isWork: true, allowed: []).allowed)
    }

    @Test func piOriginComesFromTheSessionsAnswers() throws {
        try write("pi.jsonl", """
            {"type":"session","id":"x"}
            {"type":"message","message":{"role":"user","content":[]}}
            {"type":"message","message":{"role":"assistant","provider":"github-copilot","content":[]}}

            """)
        #expect(SendOrigin.of(harness: .pi, sessionFile: home.appending(path: "pi.jsonl")) == .piSession(providers: ["github-copilot"]))
        #expect(SendOrigin.of(harness: .claudeCode, sessionFile: home.appending(path: "pi.jsonl")) == .claudeSession)
    }

    // MARK: Accounts

    @Test func claudeAccountNeedsAnEmailAndAnOrg() throws {
        let ok = try SendAccounts.claudeDestination(statusJSON: #"{"loggedIn":true,"apiProvider":"firstParty","email":"me@example.com","orgId":"o-1","orgName":"Me"}"#)
        #expect(ok == claudeAccount)
        let bedrock = try SendAccounts.claudeDestination(statusJSON: #"{"loggedIn":true,"apiProvider":"Bedrock","email":"a@b.c","orgId":"o-2"}"#)
        #expect(bedrock.provider == "bedrock")
        #expect(bedrock.org == "o-2")
        #expect(throws: SendAccounts.Failure.self) { try SendAccounts.claudeDestination(statusJSON: #"{"loggedIn":true,"email":"me@example.com"}"#) }
        #expect(throws: SendAccounts.Failure.self) { try SendAccounts.claudeDestination(statusJSON: #"{"loggedIn":false}"#) }
        #expect(throws: SendAccounts.Failure.self) { try SendAccounts.claudeDestination(statusJSON: "not json") }
    }

    @Test func claudeAccountIsAskedFromTheHarness() async throws {
        try write("bin/claude", """
            #!/bin/sh
            [ "$1 $2 $3" = "auth status --json" ] && echo '{"loggedIn":true,"apiProvider":"firstParty","email":"me@example.com","orgName":"Me"}'

            """, executable: true)
        let agent = LabAgent(harness: .claudeCode, model: "opus", effort: "high")
        let destination = try await SendAccounts.destination(of: agent, settings: LabSettings(), env: env)
        #expect(destination == claudeAccount)
    }

    @Test func piNeedsAnEnteredAccountAndAReadyProvider() async throws {
        try write("bin/pi", """
            #!/bin/sh
            case "$*" in
              *"--provider github-copilot"*) echo '{"status":"ready","provider":"github-copilot"}' ;;
              *) echo '{"status":"not_ready","reason":"credentials_not_configured"}' ;;
            esac

            """, executable: true)
        let agent = LabAgent(harness: .pi, model: "github-copilot/gpt-6.1", effort: "high")
        await #expect(throws: SendAccounts.Failure.self) {
            _ = try await SendAccounts.destination(of: agent, settings: LabSettings(), env: env)
        }
        let settings = LabSettings(piAccounts: [PiAccount(provider: "github-copilot", account: "me", org: "acme")])
        #expect(try await SendAccounts.destination(of: agent, settings: settings, env: env) == copilot)
        let other = LabAgent(harness: .pi, model: "anthropic/claude", effort: "high")
        let both = LabSettings(piAccounts: settings.piAccounts + [PiAccount(provider: "anthropic", account: "me", org: "me")])
        await #expect(throws: SendAccounts.Failure.self) {
            _ = try await SendAccounts.destination(of: other, settings: both, env: env)
        }
    }

    // MARK: Send log and limit

    @Test func sendLogAppendsAndEstimatesFromRecordedCost() throws {
        let first = SendRecord(purpose: "notes", session: "claude-code:a", runID: nil, destination: claudeAccount, model: "opus",
                               inputCharacters: 1000, usage: SendUsage(input: 300, cached: 0, output: 50, cost: 0.10))
        try SendLog.append(first, env: env)
        try SendLog.append(SendRecord(purpose: "verifier", session: "claude-code:a", runID: nil, destination: claudeAccount,
                                      model: "opus", inputCharacters: 3000, usage: SendUsage(input: 900, output: 20, cost: 0.30)),
                           env: env)
        let records = SendLog.records(env: env)
        #expect(records.count == 2)
        #expect(records[0].purpose == "notes")
        #expect(records[0].scrubVersion == Scrubber.version)
        let estimate = try #require(SendLog.estimate(characters: 2000, harness: .claudeCode, model: "opus", records: records))
        #expect(abs(estimate - 0.20) < 1e-9)
        #expect(SendLog.estimate(characters: 2000, harness: .claudeCode, model: "sonnet", records: records) == nil)
        #expect(abs(SendLog.monthCost(records) - 0.40) < 1e-9)
        let attributes = try fm.attributesOfItem(atPath: SendLog.file(env: env).path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }

    @Test func monthlyLimitRefusesWhatWouldPassIt() throws {
        try SendLog.append(SendRecord(purpose: "notes", session: nil, runID: nil, destination: claudeAccount, model: "opus",
                                      inputCharacters: 1000, usage: SendUsage(cost: 4.50)), env: env)
        let settings = LabSettings(monthlyLimit: 5)
        try SendLog.checkLimit(estimate: 0.40, settings: settings, env: env)
        #expect(throws: SendAccounts.Failure.self) { try SendLog.checkLimit(estimate: 0.60, settings: settings, env: env) }
        // Last month's cost doesn't count.
        let nextMonth = Calendar.current.date(byAdding: .month, value: 1, to: .now)!
        try SendLog.checkLimit(estimate: 0.60, settings: settings, env: env, now: nextMonth)
        try SendLog.checkLimit(estimate: 100, settings: LabSettings(), env: env)
    }

    @Test func settingsKeepOldFilesReadable() throws {
        try write(".akit/lab/settings.json", #"{"reportLanguage":"ru"}"#)
        let settings = LabSettings.load(env: env)
        #expect(settings.reportLanguage == .russian)
        #expect(settings.allowedDestinations.isEmpty)
        #expect(settings.monthlyLimit == nil)
        var changed = settings
        changed.allowedDestinations = [copilot]
        changed.piAccounts = [PiAccount(provider: "github-copilot", account: "me", org: "acme")]
        changed.monthlyLimit = 20
        try changed.save(env: env)
        #expect(LabSettings.load(env: env) == changed)
    }

    // MARK: One model call

    /// A fake `claude` that answers `-p` with a JSON result and records its stdin.
    func fakeClaude(result: String) throws {
        try write("bin/claude", """
            #!/bin/sh
            if [ "$1 $2" = "auth status" ]; then
              echo '{"loggedIn":true,"apiProvider":"firstParty","email":"me@example.com","orgName":"Me"}'; exit 0
            fi
            cat > "$HOME/stdin.txt"
            echo "$@" > "$HOME/args.txt"
            echo '\(result)'

            """, executable: true)
    }

    @Test func modelCallScrubsSendsAndLogs() async throws {
        try fakeClaude(result: #"{"type":"result","is_error":false,"result":"","structured_output":{"ok":true},"usage":{"input_tokens":10,"cache_creation_input_tokens":5,"cache_read_input_tokens":100,"output_tokens":7},"total_cost_usd":0.02}"#)
        let agent = LabAgent(harness: .claudeCode, model: "opus", effort: "high")
        let gate = try await SendGate.open(agent: agent, env: env)
        let token = "ghp_" + String(repeating: "a1B2", count: 9)
        let request = ModelCall.Request(agent: agent, purpose: "notes", system: "You check.", input: "token \(token) here",
                                        schema: #"{"type":"object"}"#, origin: .claudeSession, session: "claude-code:s1", runID: "r1")
        let answer = try await ModelCall.run(request, gate: gate, folder: home.appending(path: "work"), env: env)
        #expect(answer.text == #"{"ok":true}"#)
        #expect(answer.usage == SendUsage(input: 15, cached: 100, output: 7, cost: 0.02))
        let sent = try String(contentsOf: home.appending(path: "stdin.txt"), encoding: .utf8)
        #expect(!sent.contains(token))
        let args = try String(contentsOf: home.appending(path: "args.txt"), encoding: .utf8)
        #expect(args.contains("--no-session-persistence"))
        #expect(args.contains("--json-schema"))
        let records = SendLog.records(env: env)
        #expect(records.count == 1)
        #expect(records[0].session == "claude-code:s1")
        #expect(records[0].account == "me@example.com")
        #expect(records[0].usage.cost == 0.02)
        #expect((records[0].scrubbed ?? [:]).values.reduce(0, +) >= 1)
        // The input file is gone after the call.
        #expect(try fm.contentsOfDirectory(atPath: home.appending(path: "work").path).isEmpty)
    }

    @Test func modelCallRefusesBeforeSending() async throws {
        try fakeClaude(result: #"{"type":"result","is_error":false,"result":"x"}"#)
        let agent = LabAgent(harness: .claudeCode, model: "opus", effort: "high")
        let gate = SendGate(destination: claudeAccount, isWork: true, settings: LabSettings())
        let request = ModelCall.Request(agent: agent, purpose: "notes", system: "s", input: "data", origin: .claudeSession)
        await #expect(throws: SendAccounts.Failure.self) {
            _ = try await ModelCall.run(request, gate: gate, folder: home.appending(path: "work"), env: env)
        }
        #expect(!fm.fileExists(atPath: home.appending(path: "stdin.txt").path))
        #expect(SendLog.records(env: env).isEmpty)
    }

    @Test func rateLimitedCallsAreRetriedWithBackoff() async throws {
        try write("bin/claude", """
            #!/bin/sh
            n=$(cat "$HOME/count" 2>/dev/null || echo 0); n=$((n+1)); echo $n > "$HOME/count"
            if [ $n -lt 3 ]; then
              echo '{"type":"result","is_error":true,"result":"API Error: 429 Too Many Requests"}'
            else
              echo '{"type":"result","is_error":false,"result":"done","usage":{"input_tokens":1,"output_tokens":1}}'
            fi

            """, executable: true)
        let agent = LabAgent(harness: .claudeCode, model: "opus", effort: "high")
        let gate = SendGate(destination: claudeAccount, isWork: false, settings: LabSettings())
        let request = ModelCall.Request(agent: agent, purpose: "notes", system: "s", input: "data", origin: .claudeSession)
        let pauses = Pauses()
        let answer = try await ModelCall.run(request, gate: gate, folder: home.appending(path: "work"), env: env,
                                             sleep: { pauses.add($0) })
        #expect(answer.text == "done")
        #expect(pauses.all == [.seconds(10), .seconds(20)])
        #expect(SendLog.records(env: env).count == 1)
    }

    @Test func piAnswersAreReadFromItsEvents() throws {
        let lines = [
            #"{"type":"message_end","message":{"role":"user","content":[]}}"#,
            #"{"type":"message_end","message":{"role":"assistant","stopReason":"stop","content":[{"type":"text","text":"{\"a\":1}"}],"usage":{"input":10,"output":3,"cacheRead":40,"cacheWrite":2,"cost":{"total":0.01}}}}"#,
            #"{"type":"agent_settled"}"#,
        ]
        let answer = try ModelCall.piAnswer(lines)
        #expect(answer.text == #"{"a":1}"#)
        #expect(answer.usage == SendUsage(input: 12, cached: 40, output: 3, cost: 0.01))
        let failed = [#"{"type":"message_end","message":{"role":"assistant","stopReason":"error","errorMessage":"429 rate limit","content":[]}}"#]
        #expect(throws: ModelCall.Failure.self) { try ModelCall.piAnswer(failed) }
        #expect((try? ModelCall.piAnswer(failed)) == nil)
    }

    final class Pauses: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [Duration] = []
        func add(_ pause: Duration) { lock.withLock { stored.append(pause) } }
        var all: [Duration] { lock.withLock { stored } }
    }
}
