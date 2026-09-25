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

    public init(items: [TranscriptItem] = [], models: [String] = []) {
        self.items = items
        self.models = models
    }
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

    public init(id: Int, kind: Kind, text: String, timestamp: Date?) {
        self.id = id
        self.kind = kind
        self.text = text
        self.timestamp = timestamp
    }
}

/// Collects transcript items and numbers them.
struct TranscriptBuilder {
    private(set) var items: [TranscriptItem] = []
    private(set) var models: [String] = []

    /// Token-like values are masked (see SecretFilter).
    mutating func add(_ kind: TranscriptItem.Kind, _ text: String, at timestamp: Date?) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        items.append(TranscriptItem(id: items.count, kind: kind, text: SecretFilter.masked(trimmed), timestamp: timestamp))
    }

    /// Output of a tool that read a secrets file is replaced as a whole.
    mutating func addToolOutput(_ kind: TranscriptItem.Kind, _ text: String, readSecretFile: Bool, at timestamp: Date?) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        add(kind, readSecretFile ? SecretFilter.hiddenOutput : text, at: timestamp)
    }

    mutating func noteModel(_ model: String?) {
        guard let model, !model.isEmpty, !models.contains(model) else { return }
        models.append(model)
    }

    var transcript: SessionTranscript { SessionTranscript(items: items, models: models) }
}

/// Sessions of all installed harnesses. Read-only.
public enum SessionScanner {
    /// Newest first.
    public static func scan(installations: [HarnessInstallation],
                            adapters: [any HarnessAdapter] = HarnessCatalog.adapters,
                            in env: HarnessEnvironment) -> [SessionSummary] {
        let installed = Set(installations.map(\.id))
        return adapters.filter { installed.contains($0.id) }
            .flatMap { $0.sessions(in: env) }
            .sorted { $0.modified > $1.modified }
    }
}
