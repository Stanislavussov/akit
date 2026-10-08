import AKitFoundation
import AKitModel
import Foundation

/// One saved conversation of a harness, as shown in the list.
/// Built from a quick look at the start and end of the file; the messages
/// are read only when the session is opened (see `SessionTranscript`).
public struct SessionSummary: Identifiable, Hashable, Sendable {
    public var id: String { file.path }

    public let harness: HarnessID
    public let file: URL
    /// Name set by the user or the harness, else the first prompt. Token-like values are masked.
    public let title: String
    /// Folder the harness was started in.
    public let project: URL?
    public let started: Date?
    /// Last change of the file.
    public let modified: Date
    public let size: Int
    /// Harness version that wrote the session, if recorded (Claude Code does).
    public let harnessVersion: String?

    public init(harness: HarnessID, file: URL, title: String, project: URL?, started: Date?, modified: Date,
                size: Int, harnessVersion: String? = nil) {
        self.harness = harness
        self.file = file
        self.title = SecretFilter.masked(title)
        self.project = project
        self.started = started
        self.modified = modified
        self.size = size
        self.harnessVersion = harnessVersion
    }
}

/// The messages of one session, in conversation order.
public struct SessionTranscript: Sendable, Hashable {
    public var items: [TranscriptItem]
    /// Models that answered, in order of first use.
    public var models: [String]
    public var usage: SessionUsage
    /// The person's ratings of runs, kept apart from `items` so item ids (which notes and quotes
    /// refer to) don't move and nothing that reads items sees them. In the order of their runs.
    public var ratings: [RunRating]
    /// Pi: the id of the last item at or before each log entry of the active branch, so a run's
    /// anchor (its last entry) finds where the run ends. Empty for other harnesses.
    public var endItems: [String: Int]

    public init(items: [TranscriptItem] = [], models: [String] = [], usage: SessionUsage = SessionUsage(), ratings: [RunRating] = [],
                endItems: [String: Int] = [:]) {
        self.items = items
        self.models = models
        self.usage = usage
        self.ratings = ratings
        self.endItems = endItems
    }
}

/// The person's rating of one run as the session log holds it (AKit's Pi extension writes it after
/// the run; it never reaches the model): the latest of the run's ratings, `none` left out.
public struct RunRating: Sendable, Hashable {
    /// `good` or `bad`.
    public let rating: String
    public let comment: String?
    /// The run's last entry (Pi: its entry id).
    public let anchor: String?
    public let timestamp: Date?
    /// The id of the item that ends the rated run; nil when the run is not on the active branch.
    public let afterItem: Int?

    public init(rating: String, comment: String?, anchor: String?, timestamp: Date?, afterItem: Int?) {
        (self.rating, self.comment, self.anchor, self.timestamp, self.afterItem) = (rating, comment, anchor, timestamp, afterItem)
    }

    public var isGood: Bool { rating == "good" }
}

public struct TranscriptItem: Identifiable, Sendable, Hashable {
    public enum Kind: Sendable, Hashable {
        case user
        case assistant
        case thinking
        case toolCall(name: String)
        case toolResult(name: String?, isError: Bool)
        /// Anything that is not a message: compaction, model switch, slash command…
        case event(String)
    }

    public let id: Int
    public let kind: Kind
    public let text: String
    public let timestamp: Date?
    /// A tool result's outcome, read from its real text before a secrets file's output was
    /// hidden; nil for other items (and items made by hand, whose text is classified instead).
    public let outcome: ToolResultOutcome?

    public init(id: Int, kind: Kind, text: String, timestamp: Date?, outcome: ToolResultOutcome? = nil) {
        self.id = id
        self.kind = kind
        self.text = text
        self.timestamp = timestamp
        self.outcome = outcome
    }
}

/// Collects transcript items and numbers them.
struct TranscriptBuilder {
    private(set) var items: [TranscriptItem] = []
    private(set) var models: [String] = []

    /// Token-like values are masked (see SecretFilter).
    mutating func add(_ kind: TranscriptItem.Kind, _ text: String, at timestamp: Date?, outcome: ToolResultOutcome? = nil) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        items.append(TranscriptItem(id: items.count, kind: kind, text: SecretFilter.masked(trimmed), timestamp: timestamp,
                                    outcome: outcome))
    }

    /// The text of a failed tool call that returned none: the failure still shows and counts.
    static let noOutput = "(no output)"

    private(set) var ratings: [RunRating] = []
    var endItems: [String: Int] = [:]

    /// A rating of the run that ends at item `after`; kept in the order of their runs.
    mutating func addRating(_ rating: String, anchor: String?, comment: String?, at timestamp: Date?, after: Int?) {
        let text = comment?.trimmingCharacters(in: .whitespacesAndNewlines)
        ratings.append(RunRating(rating: rating, comment: text.flatMap { $0.isEmpty ? nil : SecretFilter.masked($0) },
                                 anchor: anchor, timestamp: timestamp, afterItem: after))
        ratings.sort { ($0.afterItem ?? .max) < ($1.afterItem ?? .max) }
    }

    /// Output of a tool that read a secrets file is replaced as a whole; a tool result's outcome
    /// is read from the real text first. A successful result with no text is left out.
    mutating func addToolOutput(_ kind: TranscriptItem.Kind, _ text: String, readSecretFile: Bool, at timestamp: Date?) {
        var outcome: ToolResultOutcome?
        if case .toolResult(let name, let isError) = kind { outcome = ToolResultOutcome(tool: name ?? "", result: text, isError: isError) }
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            guard case .toolResult(_, true) = kind else { return }
            add(kind, Self.noOutput, at: timestamp, outcome: outcome)
            return
        }
        add(kind, readSecretFile ? SecretFilter.hiddenOutput : text, at: timestamp, outcome: outcome)
    }

    mutating func noteModel(_ model: String?) {
        guard let model, !model.isEmpty, !models.contains(model) else { return }
        models.append(model)
    }

    /// Token usage of the main conversation and of subagents.
    var usage = UsageCounter()
    var subagentUsage = UsageCounter()
    var subagentRuns = 0
    private var activeTurns: [DateInterval] = []

    /// A turn the harness worked on. Turns can overlap (a prompt queued while another
    /// runs), so active time is the length of their union, not the sum.
    mutating func addActiveTurn(_ turn: DateInterval) {
        activeTurns.append(turn)
    }

    private var activeTime: TimeInterval? {
        guard !activeTurns.isEmpty else { return nil }
        var total: TimeInterval = 0
        var current: DateInterval?
        for turn in activeTurns.sorted(by: { $0.start < $1.start }) {
            if let open = current, turn.start <= open.end {
                current = DateInterval(start: open.start, end: max(open.end, turn.end))
            } else {
                total += current?.duration ?? 0
                current = turn
            }
        }
        return total + (current?.duration ?? 0)
    }

    var transcript: SessionTranscript { SessionTranscript(items: items, models: models, usage: sessionUsage, ratings: ratings,
                                                                   endItems: endItems) }

    private var sessionUsage: SessionUsage {
        var result = SessionUsage()
        result.models = usage.models
        result.subagentModels = subagentUsage.models
        result.subagentRuns = subagentRuns
        let contexts = usage.contexts
        result.peakContext = contexts.max() ?? 0
        result.lastContext = contexts.last ?? 0
        result.activeTime = activeTime
        result.firstActivity = items.lazy.compactMap(\.timestamp).first
        result.lastActivity = items.reversed().lazy.compactMap(\.timestamp).first
        var tools: [String: Int] = [:]
        for item in items {
            switch item.kind {
            case .user: result.userPrompts += 1
            case .toolCall(let name): tools[name, default: 0] += 1
            case .event(let title): if title == "Compacted" { result.compactions += 1 }
            case .assistant, .thinking, .toolResult: break
            }
        }
        result.toolErrors = FailureSignals(items).toolErrors
        result.toolCalls = tools.values.reduce(0, +)
        result.tools = tools.map { ToolCount(name: $0.key, calls: $0.value) }
            .sorted { ($0.calls, $1.name) > ($1.calls, $0.name) }
        return result
    }
}

/// Sessions of all installed harnesses. Read-only.
public enum SessionScanner {
    /// Newest first. Harnesses whose sessions AKit can't read (custom ones too) add none.
    public static func scan(installations: [HarnessInstallation], in env: HarnessEnvironment) -> [SessionSummary] {
        installations.flatMap { sessions(of: $0, in: env) }
            .sorted { $0.modified > $1.modified }
    }

    /// Saved conversations of one harness (any order).
    static func sessions(of installation: HarnessInstallation, in env: HarnessEnvironment) -> [SessionSummary] {
        switch installation.id {
        case .claudeCode:
            // `<config>/projects/*/<session id>.jsonl`.
            ClaudeSessions.list(configRoot: installation.configRoot)
        case .pi:
            PiSessions.list(folder: PiLogFormat.folder(configRoot: installation.configRoot, in: env))
        default:
            []
        }
    }
}

/// Messages of saved sessions. Read-only.
public enum SessionReader {
    /// Messages of one session from `SessionScanner.scan`. Empty for a harness AKit can't read.
    public static func transcript(of session: SessionSummary) throws -> SessionTranscript {
        switch session.harness {
        case .claudeCode: try ClaudeSessions.transcript(of: session.file)
        case .pi: try PiSessions.transcript(of: session.file)
        default: SessionTranscript()
        }
    }
}
