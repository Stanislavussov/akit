import Foundation

/// Numbers of one recorded session, computed by AKit from the transcript and git,
/// never reported by the agent. Written into a run's `result.json`.
public struct SessionMetrics: Codable, Sendable, Hashable {
    /// API calls of the main conversation (one per response id).
    public var calls = 0
    /// Input + cache creation + output of the main conversation: what each call added.
    public var freshTokens = 0
    public var cacheReadTokens = 0
    public var outputTokens = 0
    public var peakContext = 0
    /// Context of the first call: system prompt, tools, instructions, skill listing.
    public var baselineContext = 0
    public var contextRent = ContextRent()
    public var toolCalls = 0
    /// Failed tool calls, without rejected ones.
    public var toolErrors = 0
    /// `Read` of a file and range already read, with no edit of that file in between.
    public var rereads = 0
    public var interrupts = 0
    /// Tool calls the user or a permission rule refused.
    public var rejected = 0
    public var compactions = 0
    public var commits: [LabCommit] = []
    /// First to last recorded message.
    public var wallSeconds: Int?
    /// Time the harness worked on prompts (Claude Code records it per turn).
    public var activeSeconds: Int?
    public var subagentCalls = 0
    public var subagentFreshTokens = 0
    /// Models that answered, in order of first use.
    public var models: [String] = []

    public init() {}

    /// Commits whose place on the main branch is known and that never got there.
    public var unmergedCommits: Int { commits.filter { $0.onMainBranch == false }.count }
}

/// A commit made in the session: the `[branch sha] subject` line `git commit` printed.
public struct LabCommit: Codable, Sendable, Hashable {
    public var sha: String
    public var subject: String
    /// nil = unknown (the folder is gone or isn't a repository).
    public var onMainBranch: Bool?

    public init(sha: String, subject: String, onMainBranch: Bool? = nil) {
        self.sha = sha
        self.subject = subject
        self.onMainBranch = onMainBranch
    }
}

/// Where the session's input tokens went. Each part is tokens × the number of calls that
/// sent them again (context rent); the parts add up to the session's total context sent.
/// The split of the growth between two calls is by characters, so it is approximate.
public struct ContextRent: Codable, Sendable, Hashable {
    /// The first call's context (and the first after each compaction).
    public var baseline = 0
    /// Results of Read, Grep, Glob and read-only shell commands (cat, sed -n, grep…).
    public var readCode = 0
    /// The agent's own text, thinking and tool inputs (heredoc file writes stay in context).
    public var ownOutput = 0
    /// Harness and plugin additions: hook context, reminders, loaded skills.
    public var injections = 0
    /// User prompts, other tool results, and whatever the characters don't explain.
    public var other = 0

    public init(baseline: Int = 0, readCode: Int = 0, ownOutput: Int = 0, injections: Int = 0, other: Int = 0) {
        self.baseline = baseline
        self.readCode = readCode
        self.ownOutput = ownOutput
        self.injections = injections
        self.other = other
    }

    public var total: Int { baseline + readCode + ownOutput + injections + other }

    /// Part of the total, 0…1.
    public func share(_ part: Int) -> Double { total > 0 ? Double(part) / Double(total) : 0 }
}
