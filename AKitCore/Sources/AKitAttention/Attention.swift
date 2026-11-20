import AKitBrain
import AKitFoundation
import Foundation

/// One thing the Attention screen and `akit attention` show (docs/design/attention.md): a failed
/// run, a finished review, an eval verdict, a proposal waiting in an inbox. Read from the files
/// the other screens write; nothing is run to find it.
public struct AttentionItem: Codable, Sendable, Hashable, Identifiable {
    public enum Level: String, Codable, Sendable, CaseIterable, Comparable {
        /// Something failed: a run, a check, a send. Fix it or run it again.
        case problem
        /// Not broken, but it waits for a decision or looks off.
        case check
        /// Finished work to read: a review, a report, an eval verdict, a proposal.
        case ready

        public var title: String {
            switch self {
            case .problem: "Needs a Fix"
            case .check: "Needs a Look"
            case .ready: "Ready to Read"
            }
        }

        public static func < (lhs: Level, rhs: Level) -> Bool {
            allCases.firstIndex(of: lhs)! < allCases.firstIndex(of: rhs)!
        }
    }

    public enum Source: String, Codable, Sendable, CaseIterable {
        case lab, review, analysis, evals, flows, mcp, knowledge, brain

        public var title: String {
            switch self {
            case .lab: "Lab"
            case .review: "Review"
            case .analysis: "Error Analysis"
            case .evals: "Evals"
            case .flows: "Flow Runs"
            case .mcp: "MCP Servers"
            case .knowledge: "Knowledge"
            case .brain: "Brain"
            }
        }
    }

    /// Stable while the thing lives: `lab:<run id>`, `mcp:<check key>`.
    public let id: String
    public let level: Level
    public let source: Source
    /// One line: what happened, to what.
    public let title: String
    /// One or two short sentences: why it matters or what the next step is.
    public let detail: String
    public let date: Date?
    public let link: AttentionLink
    /// Changes when the thing changes (a new status, another check): a dismissed item comes back then.
    public let fingerprint: String

    public init(id: String, level: Level, source: Source, title: String, detail: String, date: Date?, link: AttentionLink,
                fingerprint: String) {
        self.id = id
        self.level = level
        self.source = source
        self.title = title
        self.detail = detail
        self.date = date
        self.link = link
        self.fingerprint = fingerprint
    }
}

/// Where an item lives: a sidebar screen, its tab and what to select there. As a URL,
/// `akit://lab?item=<run id>` or `akit://analysis?tab=evals&item=swiftui`: the app opens that place.
public struct AttentionLink: Codable, Sendable, Hashable {
    /// The sidebar section's id: `lab`, `review`, `analysis`, `runs`, `mcp`, `knowledge`, `brain`.
    public var screen: String
    public var tab: String?
    /// What to select: a run id, a batch, a layer, an MCP check key.
    public var item: String?
    /// The folder it lives in: a flow run's project, a knowledge base.
    public var folder: String?

    public init(screen: String, tab: String? = nil, item: String? = nil, folder: String? = nil) {
        self.screen = screen
        self.tab = tab
        self.item = item
        self.folder = folder
    }

    public var url: URL {
        var components = URLComponents()
        components.scheme = "akit"
        components.host = screen
        let query = [("tab", tab), ("item", item), ("folder", folder)].compactMap { name, value in
            value.map { URLQueryItem(name: name, value: $0) }
        }
        components.queryItems = query.isEmpty ? nil : query
        return components.url ?? URL(string: "akit://\(screen)")!
    }

    /// `akit://<screen>?tab=…&item=…&folder=…`; nil for another scheme. The screen is not checked.
    public init?(url: URL) {
        guard url.scheme?.lowercased() == "akit", let host = url.host(percentEncoded: false), !host.isEmpty else { return nil }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value.flatMap { $0.isEmpty ? nil : $0 } }
        self.init(screen: host.lowercased(), tab: value("tab"), item: value("item"), folder: value("folder"))
    }
}

public enum Attention {
    /// Runs, reviews, batches, eval verdicts and checks older than this are left out: by then they
    /// were read, or no longer matter. Brain problems and inbox proposals count at any age.
    public static let recentDays = 14

    /// Everything that needs attention, problems first, newest first within a level. Reads only.
    /// `brain` gives the layers whose eval verdicts are read and the brain's own problems;
    /// `projects` the folders whose flow runs are read.
    public static func collect(env: HarnessEnvironment, brain: Brain?, projects: [URL], now: Date = .now) -> [AttentionItem] {
        let since = now.addingTimeInterval(-Double(recentDays) * 86_400)
        let items = AttentionSources.lab(env: env, since: since)
            + AttentionSources.review(env: env, since: since)
            + AttentionSources.analysis(env: env, since: since)
            + AttentionSources.agentReports(env: env, since: since)
            + AttentionSources.evals(env: env, layers: brain?.layers.map(\.name) ?? [], since: since)
            + AttentionSources.flows(env: env, projects: projects, since: since)
            + AttentionSources.mcp(env: env, since: since)
            + AttentionSources.knowledge(env: env)
            + AttentionSources.brain(brain)
        return sorted(items)
    }

    public static func sorted(_ items: [AttentionItem]) -> [AttentionItem] {
        items.sorted { a, b in
            if a.level != b.level { return a.level < b.level }
            if a.date != b.date { return (a.date ?? .distantPast) > (b.date ?? .distantPast) }
            return a.title < b.title
        }
    }

    /// The first line of a message, at most `limit` characters: a detail stays one glance long.
    static func short(_ text: String, limit: Int = 200) -> String {
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? ""
        return line.count > limit ? String(line.prefix(limit - 1)) + "…" : line
    }

    static func plural(_ count: Int, _ noun: String) -> String { "\(count) \(noun)\(count == 1 ? "" : "s")" }
}

/// Items the person dismissed, kept with their fingerprint in `~/.akit/attention.json`: one stays
/// hidden until it changes. Holds ids only (run ids, layer names, check keys), never a secret.
public struct AttentionDismissals: Codable, Sendable, Equatable {
    public var items: [String: String] = [:]

    public init(items: [String: String] = [:]) { self.items = items }

    static func file(home: URL) -> URL { home.appending(path: ".akit/attention.json") }

    public static func load(home: URL) -> AttentionDismissals {
        (try? Data(contentsOf: file(home: home))).flatMap { try? JSONDecoder().decode(AttentionDismissals.self, from: $0) } ?? .init()
    }

    public func hides(_ item: AttentionItem) -> Bool { items[item.id] == item.fingerprint }

    /// Hides these items; entries of items no longer shown are dropped, so the file stays small.
    public static func dismiss(_ dismissed: [AttentionItem], current: [AttentionItem], home: URL) throws {
        var saved = load(home: home)
        let live = Set(current.map(\.id))
        saved.items = saved.items.filter { live.contains($0.key) }
        for item in dismissed { saved.items[item.id] = item.fingerprint }
        try saved.write(home: home)
    }

    /// Shows them again.
    public static func restore(_ ids: [String], home: URL) throws {
        var saved = load(home: home)
        for id in ids { saved.items[id] = nil }
        try saved.write(home: home)
    }

    private func write(home: URL) throws {
        let url = Self.file(home: home)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}
