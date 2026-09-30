import Foundation

/// What a run does: `run.json`, written once when the run is queued.
public struct RunSpec: Codable, Sendable, Hashable {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        /// An agent reads a recorded session and writes a review.
        case review
        /// An agent redoes a commit in an isolated clone; hidden tests judge it.
        case replay
    }

    public var schema = 1
    public var id: String
    public var kind: Kind
    /// "Review: Fix the login bug", "Replay 1c9cf65 · lean · 2/3".
    public var title: String
    public var createdAt: Date
    /// Where the terminal tab opens (a worktree or repository root).
    public var folder: String
    public var environment: LabEnvironment
    /// Absolute path of the `akit` that queued the run; the tab runs `<akit> lab run <id>`.
    public var akit: String
    /// Claude Code session id of the run's own agent, chosen by AKit.
    public var sessionID: String

    // Review
    public var reviewedTranscript: String?
    public var reviewedTitle: String?
    /// The harness and model that write the review; nil = Claude Code with your settings.
    public var agent: LabAgent?

    // Replay
    public var repo: String?
    public var commit: String?
    public var setup: LabSetup?
    public var repeatIndex: Int?
    public var repeats: Int?
    /// Keep the clone instead of moving it to the Trash at the end.
    public var keep: Bool

    public init(id: String, kind: Kind, title: String, createdAt: Date = .now, folder: String,
                environment: LabEnvironment, akit: String, sessionID: String = UUID().uuidString.lowercased(),
                reviewedTranscript: String? = nil, reviewedTitle: String? = nil, agent: LabAgent? = nil, repo: String? = nil, commit: String? = nil,
                setup: LabSetup? = nil, repeatIndex: Int? = nil, repeats: Int? = nil, keep: Bool = false) {
        self.id = id
        self.kind = kind
        self.title = title
        self.createdAt = createdAt
        self.folder = folder
        self.environment = environment
        self.akit = akit
        self.sessionID = sessionID
        self.reviewedTranscript = reviewedTranscript
        self.reviewedTitle = reviewedTitle
        self.agent = agent
        self.repo = repo
        self.commit = commit
        self.setup = setup
        self.repeatIndex = repeatIndex
        self.repeats = repeats
        self.keep = keep
    }

    /// `20260930-181502-a1b2`: sorts by creation time.
    public static func newID(at date: Date = .now) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: date) + "-" + UUID().uuidString.prefix(4).lowercased()
    }
}

/// How Claude Code is started for a replay. Model and effort are always pinned, since
/// `lean` doesn't read the user settings that set them.
public struct LabSetup: Codable, Sendable, Hashable {
    public enum Name: String, Codable, Sendable, CaseIterable {
        /// Your normal setup.
        case full
        /// `--setting-sources project`: no user plugins or hooks.
        case lean
    }

    public var name: Name
    public var model: String
    public var effort: String

    public init(name: Name, model: String, effort: String) {
        self.name = name
        self.model = model
        self.effort = effort
    }

    /// "lean · opus · high": runs with the same label are compared with each other.
    public var label: String { "\(name.rawValue) · \(model) · \(effort)" }

    var flags: [String] {
        (name == .lean ? ["--setting-sources", "project"] : []) + ["--model", model, "--effort", effort]
    }
}

/// The harness a review agent runs in. Replays use Claude Code only: their numbers come
/// from Claude Code transcripts.
public enum LabHarness: String, Codable, Sendable, CaseIterable {
    case claudeCode = "claude-code"
    case pi

    public var title: String {
        switch self {
        case .claudeCode: "Claude Code"
        case .pi: "Pi"
        }
    }

    /// The command that runs it headless.
    public var command: String {
        switch self {
        case .claudeCode: "claude"
        case .pi: "pi"
        }
    }

    /// `--effort` for Claude Code, `--thinking` for Pi.
    public var efforts: [String] {
        switch self {
        case .claudeCode: ["low", "medium", "high", "xhigh", "max"]
        case .pi: ["off", "minimal", "low", "medium", "high", "xhigh", "max"]
        }
    }
}

/// Who writes a review: a harness, a model (`opus`; for Pi `provider/model`), an effort, and
/// how the model is used. Both modes go through the harness, with its own sign-in and model
/// settings; AKit never reads the harness's keys.
public struct LabAgent: Codable, Sendable, Hashable {
    public enum Mode: String, Codable, Sendable, CaseIterable {
        /// One model call with no tools and none of your customizations: AKit sends a digest
        /// of the session, the model answers with JSON, AKit writes the review files.
        case call
        /// An agent with file tools reads the whole transcript in parts and writes the files.
        case agent

        public var title: String {
            switch self {
            case .call: "One model call"
            case .agent: "Agent with file tools"
            }
        }
    }

    public var harness: LabHarness
    public var model: String
    public var effort: String
    public var mode: Mode

    public init(harness: LabHarness, model: String, effort: String, mode: Mode = .call) {
        self.harness = harness
        self.model = model
        self.effort = effort
        self.mode = mode
    }

    /// Runs queued before modes existed were agents.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        harness = try container.decode(LabHarness.self, forKey: .harness)
        model = try container.decode(String.self, forKey: .model)
        effort = try container.decode(String.self, forKey: .effort)
        mode = try container.decodeIfPresent(Mode.self, forKey: .mode) ?? .agent
    }

    /// "Pi · opencode-go/kimi-k3 · high · one model call".
    public var label: String { "\(harness.title) · \(model.isEmpty ? "default model" : model) · \(effort) · \(mode.title.lowercased())" }

    var flags: [String] {
        switch harness {
        case .claudeCode: ["--model", model, "--effort", effort]
        // An empty model: Pi's own default.
        case .pi: (model.isEmpty ? [] : ["--model", model]) + ["--thinking", effort]
        }
    }
}

/// Where a run's terminal opens.
public enum LabEnvironment: String, Codable, Sendable, CaseIterable {
    case orca
    case herdr
    /// A child process of AKit with no window; output in `console.log`.
    case background

    public var title: String {
        switch self {
        case .orca: "Orca"
        case .herdr: "herdr"
        case .background: "Background"
        }
    }
}

/// `state.json`, rewritten by `akit lab run` at every phase change.
public struct RunState: Codable, Sendable, Hashable {
    public enum Status: String, Codable, Sendable {
        case queued, running, finished, cancelled, error
    }

    public enum Phase: String, Codable, Sendable {
        case prepare, agent, tests, metrics

        public var title: String {
            switch self {
            case .prepare: "Preparing"
            case .agent: "Agent working"
            case .tests: "Running tests"
            case .metrics: "Computing metrics"
            }
        }
    }

    public var status: Status
    public var phase: Phase?
    public var pid: Int32?
    /// The worker's process start time, so a reused pid isn't taken for it.
    public var pidStart: Double?
    public var startedAt: Date?
    public var updatedAt: Date
    /// Why the run stopped with an error.
    public var message: String?

    public init(status: Status, phase: Phase? = nil, pid: Int32? = nil, pidStart: Double? = nil, startedAt: Date? = nil,
                updatedAt: Date = .now, message: String? = nil) {
        self.status = status
        self.phase = phase
        self.pid = pid
        self.pidStart = pidStart
        self.startedAt = startedAt
        self.updatedAt = updatedAt
        self.message = message
    }
}

/// `launch.json`: where the run was started and how to bring its tab forward.
public struct LaunchInfo: Codable, Sendable, Hashable {
    public var environment: LabEnvironment
    public var launchedAt: Date
    /// Orca terminal handle.
    public var orcaTerminal: String?
    public var herdrWorkspace: String?
    public var herdrTab: String?
    public var herdrPane: String?
    /// Background: the worker's pid.
    public var pid: Int32?

    public init(environment: LabEnvironment, launchedAt: Date = .now, orcaTerminal: String? = nil, herdrWorkspace: String? = nil,
                herdrTab: String? = nil, herdrPane: String? = nil, pid: Int32? = nil) {
        self.environment = environment
        self.launchedAt = launchedAt
        self.orcaTerminal = orcaTerminal
        self.herdrWorkspace = herdrWorkspace
        self.herdrTab = herdrTab
        self.herdrPane = herdrPane
        self.pid = pid
    }
}

/// `result.json`, written by `akit lab run` at the end; the only writer.
public struct RunResult: Codable, Sendable, Hashable {
    public var schema = 1
    /// The run's own agent session.
    public var metrics: SessionMetrics?
    public var tests: TestOutcome?
    public var review: ReviewStatus?
    /// Why the run is left out of comparisons: the transcript mentions the answer.
    public var leaks: [String]?
    /// The agent's own error when it ended with one (a refused model call, no credit), masked.
    public var agentError: String?

    public init(metrics: SessionMetrics? = nil, tests: TestOutcome? = nil, review: ReviewStatus? = nil, leaks: [String]? = nil,
                agentError: String? = nil) {
        self.metrics = metrics
        self.tests = tests
        self.review = review
        self.leaks = leaks
        self.agentError = agentError
    }

    public var leaked: Bool { !(leaks ?? []).isEmpty }
}

public enum ReviewStatus: String, Codable, Sendable {
    case ok, missing, invalid
}

/// Hidden tests after a replay.
public struct TestOutcome: Codable, Sendable, Hashable {
    public enum Status: String, Codable, Sendable {
        case passed, failed
        case notRun = "not-run"
    }

    public struct Count: Codable, Sendable, Hashable {
        public var passed: Int
        public var total: Int
        public init(passed: Int, total: Int) {
            self.passed = passed
            self.total = total
        }
    }

    public var status: Status
    public var failToPass: Count
    public var passToPass: Count
    public var timeouts: Int
    /// Names of the tests that failed, for the details.
    public var failed: [String]
    /// Set when the tests couldn't run at all (the build failed).
    public var note: String?

    public init(status: Status, failToPass: Count, passToPass: Count, timeouts: Int = 0, failed: [String] = [], note: String? = nil) {
        self.status = status
        self.failToPass = failToPass
        self.passToPass = passToPass
        self.timeouts = timeouts
        self.failed = failed
        self.note = note
    }
}

/// `review.json`, written by the review agent: up to three improvements.
public struct Review: Codable, Sendable, Hashable {
    /// AKit shows at most this many, even when an agent writes more.
    public static let limit = 3

    public struct Finding: Codable, Sendable, Hashable {
        public var title: String
        public var detail: String
    }

    public var findings: [Finding]
}
