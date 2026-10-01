import AKitFoundation
import Foundation

/// `labels/reservations.json`: sessions picked for bootstrap labeling. A reserved session is
/// kept away from ad-hoc reviews and batches until the user has labeled it, so the model's
/// notes can't be seen first and the labeling stays blind.
public struct BootstrapReservations: Sendable {
    public struct Entry: Codable, Hashable, Sendable {
        public var sessionKey: String
        public var transcript: String
        public var reservedAt: Date
        /// Set when the user has finished labeling the session.
        public var labeledAt: Date?

        public init(sessionKey: String, transcript: String, reservedAt: Date = .now, labeledAt: Date? = nil) {
            self.sessionKey = sessionKey
            self.transcript = transcript
            self.reservedAt = reservedAt
            self.labeledAt = labeledAt
        }
    }

    let file: URL

    public init(env: HarnessEnvironment) {
        file = AnalysisPaths(env: env).labels.appending(path: "reservations.json")
    }

    public func all() -> [Entry] {
        (try? Data(contentsOf: file)).flatMap { try? AnalysisJSON.decoder.decode([Entry].self, from: $0) } ?? []
    }

    public func save(_ entries: [Entry]) throws {
        try JSONFile.write(entries, to: file)
    }

    /// Changes the reservations as they are on disk now, under their lock.
    public func update(_ change: (inout [Entry]) throws -> Void) throws {
        try JSONFile.update(file, empty: [Entry]()) { try change(&$0) }
    }

    /// Reserved and not labeled yet: no model may look at it.
    public func isReserved(_ sessionKey: String) -> Bool {
        all().contains { $0.sessionKey == sessionKey && $0.labeledAt == nil }
    }

    /// Every session ever reserved: they never enter a batch sample, labeled or not.
    public func keys() -> Set<String> { Set(all().map(\.sessionKey)) }
}
