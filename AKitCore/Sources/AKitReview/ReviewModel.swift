import Foundation

/// How bad a finding is. Ordered: `nit` < `low` < `medium` < `high` < `critical`.
public enum ReviewSeverity: String, Codable, Sendable, CaseIterable, Comparable {
    case nit, low, medium, high, critical

    public static func < (a: ReviewSeverity, b: ReviewSeverity) -> Bool {
        allCases.firstIndex(of: a)! < allCases.firstIndex(of: b)!
    }
}

/// Where a configuration value came from (`docs/design/review.md`, "Levels").
public enum ReviewSource: String, Codable, Sendable {
    /// Shipped with AKit: used while the brain has no `review` layer (or lacks the item).
    case builtIn = "built-in"
    case brain
    case project
    case run
}

/// A value and the level that set it.
public struct Sourced<Value: Codable & Sendable & Hashable>: Codable, Sendable, Hashable {
    public var value: Value
    public var source: ReviewSource

    public init(_ value: Value, _ source: ReviewSource) {
        self.value = value
        self.source = source
    }
}

/// One merge request, named by its web address.
public struct MergeRequestRef: Codable, Sendable, Hashable {
    /// `https://gitlab.example.com`, no trailing slash.
    public var host: String
    /// `team/orders-service`.
    public var projectPath: String
    public var iid: Int

    public init(host: String, projectPath: String, iid: Int) {
        self.host = host
        self.projectPath = projectPath
        self.iid = iid
    }

    /// The host of a local workspace review: there is no merge request.
    public static let localHost = "local"

    /// A local workspace review (`ReviewRunSpec.local` says which).
    public static func local(_ name: String) -> MergeRequestRef { MergeRequestRef(host: localHost, projectPath: name, iid: 0) }

    public var isLocal: Bool { host == Self.localHost }

    /// The merge request's page; empty for a local review.
    public var url: String { isLocal ? "" : "\(host)/\(projectPath)/-/merge_requests/\(iid)" }
    /// `team/orders-service!12`, or `orders-service (local)`.
    public var label: String { isLocal ? "\(projectPath) (local)" : "\(projectPath)!\(iid)" }

    /// `https://host/group/sub/project/-/merge_requests/12[/diffs][#…]`; nil for anything else.
    public static func parse(_ text: String) -> MergeRequestRef? {
        guard let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http", let host = url.host() else { return nil }
        let parts = url.path().split(separator: "/").map(String.init)
        guard let dash = parts.firstIndex(of: "-"), dash >= 2, parts.count > dash + 2, parts[dash + 1] == "merge_requests",
              let iid = Int(parts[dash + 2]), iid > 0 else { return nil }
        let port = url.port.map { ":\($0)" } ?? ""
        return MergeRequestRef(host: "\(scheme)://\(host)\(port)", projectPath: parts[..<dash].joined(separator: "/"), iid: iid)
    }
}
