import AKitBrain
import AKitFoundation
import AKitModel
import Foundation

/// Where session data or repository code goes: a harness, the provider behind it, and the
/// account and plan/organization it is billed to (`docs/design/error-analysis.md`,
/// "Sending policy"). Copilot through Pi is granted by an organization, so the org is part
/// of the entry, not only the login.
public struct SendDestination: Codable, Hashable, Sendable {
    public var harness: LabHarness
    /// `anthropic` (Claude Code signed in with claude.ai or the Console), `bedrock`,
    /// `vertex`; for Pi its provider id (`github-copilot`, `opencode-go`, …).
    public var provider: String
    /// The e-mail or login.
    public var account: String
    /// The plan or organization: Claude's organization, the GitHub org that grants Copilot.
    public var org: String

    public init(harness: LabHarness, provider: String, account: String, org: String) {
        self.harness = harness
        self.provider = provider
        self.account = account
        self.org = org
    }

    /// "Pi · github-copilot · me@example.com · acme".
    public var label: String { "\(harness.title) · \(provider) · \(account) · \(org)" }

    /// The same destination, ignoring case and surrounding spaces.
    public func matches(_ other: SendDestination) -> Bool {
        func same(_ a: String, _ b: String) -> Bool {
            a.trimmingCharacters(in: .whitespaces).caseInsensitiveCompare(b.trimmingCharacters(in: .whitespaces)) == .orderedSame
        }
        return harness == other.harness && same(provider, other.provider) && same(account, other.account) && same(org, other.org)
    }
}

/// The account behind one Pi provider, entered by the user: Pi has no whoami, and AKit
/// never reads a harness's keys to ask the provider itself.
public struct PiAccount: Codable, Hashable, Sendable {
    public var provider: String
    public var account: String
    public var org: String

    public init(provider: String, account: String, org: String) {
        self.provider = provider
        self.account = account
        self.org = org
    }
}

/// Where the data being sent came from, for the same-origin rule.
public enum SendOrigin: Hashable, Sendable {
    /// A Claude Code session: produced by Claude Code with the account signed in on this Mac.
    /// Transcripts don't record the account, so the account signed in now stands for it.
    case claudeSession
    /// A Pi session and the providers its answers came from (Pi records one per answer).
    case piSession(providers: Set<String>)
    /// Repository code an agent works on (replays, control runs): the user already gives it
    /// to that harness in daily work, so its own signed-in account counts as the origin.
    case code(LabHarness)

    /// The origin of a recorded session; for Pi, the providers its answers came from.
    public static func of(harness: HarnessID, sessionFile: URL) -> SendOrigin {
        guard harness == .pi else { return .claudeSession }
        var providers = Set<String>()
        for entry in (try? Data(contentsOf: sessionFile)).flatMap({ try? JSONLines.objects(in: $0) }) ?? [] {
            if let message = entry["message"] as? [String: Any], message["role"] as? String == "assistant",
               let provider = message["provider"] as? String, !provider.isEmpty {
                providers.insert(provider)
            }
        }
        return .piSession(providers: providers)
    }
}

/// Whether data may go to a destination. Code checks run locally and never ask.
public enum SendPolicy {
    public struct Decision: Hashable, Sendable {
        public let allowed: Bool
        /// Why, in one sentence the user can act on.
        public let reason: String
    }

    /// - Work Mac: only destinations on the allowed list (empty by default).
    /// - Personal Mac: the allowed list, plus the same origin: a transcript may go to the
    ///   provider and account that produced it.
    public static func decide(origin: SendOrigin, destination: SendDestination, isWork: Bool, allowed: [SendDestination]) -> Decision {
        if allowed.contains(where: { $0.matches(destination) }) {
            return Decision(allowed: true, reason: "\(destination.label) is on the allowed list.")
        }
        if isWork {
            return Decision(allowed: false, reason: "This is a work Mac: session data goes only to destinations on the allowed list "
                                + "(Settings → Lab), and \(destination.label) isn't on it.")
        }
        if sameOrigin(origin, destination) {
            return Decision(allowed: true, reason: "Same origin: \(destination.label) produced this data.")
        }
        return Decision(allowed: false, reason: "\(destination.label) didn't produce this data (\(origin.label)). "
                            + "Add it to the allowed list in Settings → Lab to send it there.")
    }

    static func sameOrigin(_ origin: SendOrigin, _ destination: SendDestination) -> Bool {
        switch origin {
        case .claudeSession:
            return destination.harness == .claudeCode
        case .piSession(let providers):
            // A session that mixed providers has no single origin.
            return destination.harness == .pi && providers.count == 1
                && providers.first?.caseInsensitiveCompare(destination.provider) == .orderedSame
        case .code(let harness):
            return destination.harness == harness
        }
    }
}

extension SendOrigin {
    var label: String {
        switch self {
        case .claudeSession: "a Claude Code session"
        case .piSession(let providers):
            providers.isEmpty ? "a Pi session with no recorded provider"
                : "a Pi session through \(providers.sorted().joined(separator: ", "))"
        case .code(let harness): "repository code worked on with \(harness.title)"
        }
    }
}

/// Finds out who a destination is, at the start of every review, batch and control run.
/// An account that can't be determined, or one without plan or org data, refuses the call.
public enum SendAccounts {
    public struct Failure: Error, LocalizedError {
        public let message: String
        public var errorDescription: String? { message }
    }

    /// The destination an agent's calls go to, checked now.
    public static func destination(of agent: LabAgent, settings: LabSettings, env: HarnessEnvironment) async throws -> SendDestination {
        switch agent.harness {
        case .claudeCode: try await claude(env: env)
        case .pi: try await pi(provider: piProvider(of: agent, env: env), settings: settings, env: env)
        }
    }

    /// `claude auth status --json`: e-mail, organization and API provider, no secrets.
    static func claude(env: HarnessEnvironment) async throws -> SendDestination {
        guard let claude = env.findExecutable("claude") else { throw Failure(message: "Claude Code (claude) is not installed.") }
        let result = await ProcessRunner.run(claude, arguments: ["auth", "status", "--json"],
                                             environment: AgentRun.environment(env, runFolder: nil), timeout: 30)
        guard let result, result.succeeded else {
            throw Failure(message: "Couldn't check the Claude Code account (claude auth status): \(result?.failureText ?? "it didn't start").")
        }
        return try claudeDestination(statusJSON: result.output)
    }

    static func claudeDestination(statusJSON: String) throws -> SendDestination {
        let json = statusJSON.firstIndex(of: "{").map { String(statusJSON[$0...]) } ?? statusJSON
        guard let status = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] else {
            throw Failure(message: "claude auth status gave no JSON, so the account is unknown.")
        }
        guard status["loggedIn"] as? Bool != false else { throw Failure(message: "Claude Code is not signed in.") }
        func text(_ key: String) -> String? { (status[key] as? String).flatMap { $0.isEmpty ? nil : $0 } }
        guard let email = text("email") else { throw Failure(message: "claude auth status names no account, so the call is refused.") }
        guard let org = text("orgName") ?? text("orgId") else {
            throw Failure(message: "claude auth status names no organization for \(email), so the call is refused.")
        }
        let provider = switch text("apiProvider") ?? "firstParty" {
        case "firstParty": "anthropic"
        case let other: other.lowercased()
        }
        return SendDestination(harness: .claudeCode, provider: provider, account: email, org: org)
    }

    /// The account the user entered for the provider; Pi must also report the provider ready
    /// (`pi auth check`, which prints no credentials without `--credentials`).
    static func pi(provider: String, settings: LabSettings, env: HarnessEnvironment) async throws -> SendDestination {
        guard !provider.isEmpty else { throw Failure(message: "Which Pi provider? Pick a model as provider/model.") }
        guard let entry = settings.piAccounts.first(where: { $0.provider.caseInsensitiveCompare(provider) == .orderedSame }),
              !entry.account.trimmingCharacters(in: .whitespaces).isEmpty, !entry.org.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw Failure(message: "Pi has no account entered for \(provider), so Pi is refused on this Mac. "
                              + "Enter the account and plan/org in Settings → Lab.")
        }
        guard let pi = env.findExecutable("pi") else { throw Failure(message: "Pi (pi) is not installed.") }
        let result = await ProcessRunner.run(pi, arguments: ["auth", "check", "--provider", provider, "--json", "--no-refresh"],
                                             environment: AgentRun.environment(env, runFolder: nil), timeout: 30)
        let status = result.flatMap { result -> String? in
            let text = result.output
            let json = text.firstIndex(of: "{").map { String(text[$0...]) } ?? text
            return (try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])?["status"] as? String
        }
        guard status == "ready" else {
            throw Failure(message: "Pi isn't signed in to \(provider) (pi auth check: \(status ?? "no answer")).")
        }
        return SendDestination(harness: .pi, provider: provider, account: entry.account, org: entry.org)
    }

    /// `provider/model` names the provider; an empty model uses Pi's default provider.
    static func piProvider(of agent: LabAgent, env: HarnessEnvironment) -> String {
        if let slash = agent.model.firstIndex(of: "/") { return String(agent.model[..<slash]) }
        let settings = (try? Data(contentsOf: LabRuns.piRoot(env: env).appending(path: "settings.json")))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        return settings["defaultProvider"] as? String ?? ""
    }
}

/// The checked destination of one run: the account is looked up once at the start, and
/// each piece of data is checked against its own origin before it is sent.
public struct SendGate: Sendable {
    public let destination: SendDestination
    public let isWork: Bool
    public let settings: LabSettings

    public init(destination: SendDestination, isWork: Bool, settings: LabSettings) {
        self.destination = destination
        self.isWork = isWork
        self.settings = settings
    }

    /// Looks up the account behind `agent` now. Throws when it can't be determined, or when
    /// the Lab settings can't be read (`LabSettings.loadForSending`).
    public static func open(agent: LabAgent, env: HarnessEnvironment) async throws -> SendGate {
        let settings = try LabSettings.loadForSending(env: env)
        let destination = try await SendAccounts.destination(of: agent, settings: settings, env: env)
        return SendGate(destination: destination, isWork: MachineProfile.load(home: env.homeDirectory).isWork, settings: settings)
    }

    public func decide(_ origin: SendOrigin) -> SendPolicy.Decision {
        SendPolicy.decide(origin: origin, destination: destination, isWork: isWork, allowed: settings.allowedDestinations)
    }

    /// Throws the policy's reason when `origin` may not go here.
    public func check(_ origin: SendOrigin) throws {
        let decision = decide(origin)
        guard decision.allowed else { throw SendAccounts.Failure(message: "Not sent: \(decision.reason)") }
    }

    /// Scrubbed with the user's own patterns too.
    public func scrub(_ text: String) -> Scrubber.Result {
        Scrubber.scrub(text, own: settings.scrub)
    }
}
