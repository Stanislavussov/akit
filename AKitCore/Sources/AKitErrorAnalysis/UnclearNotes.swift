import AKitFoundation
import Foundation

/// `labels/unclear.json`: notes the human couldn't place in any mode. They are kept, because
/// they are the main source of future modes. Outside `modes/`, so never in git.
public struct UnclearNotes: Sendable {
    public struct Entry: Codable, Hashable, Sendable {
        public var sessionKey: String
        public var noteID: String
        public var text: String
        public var addedAt: Date

        public init(sessionKey: String, noteID: String, text: String, addedAt: Date = .now) {
            self.sessionKey = sessionKey
            self.noteID = noteID
            self.text = text
            self.addedAt = addedAt
        }
    }

    let file: URL

    public init(env: HarnessEnvironment) {
        file = AnalysisPaths(env: env).labels.appending(path: "unclear.json")
    }

    public func all() -> [Entry] {
        (try? Data(contentsOf: file)).flatMap { try? AnalysisJSON.decoder.decode([Entry].self, from: $0) } ?? []
    }

    /// Adds the note once; adding it again keeps the first entry.
    @discardableResult
    public func add(_ entry: Entry) throws -> [Entry] {
        try JSONFile.update(file, empty: [Entry]()) { entries in
            if !entries.contains(where: { $0.sessionKey == entry.sessionKey && $0.noteID == entry.noteID }) { entries.append(entry) }
            return entries
        }
    }

    /// Removes the note, for example once it was placed in a mode.
    @discardableResult
    public func remove(sessionKey: String, noteID: String) throws -> [Entry] {
        try JSONFile.update(file, empty: [Entry]()) { entries in
            entries.removeAll { $0.sessionKey == sessionKey && $0.noteID == noteID }
            return entries
        }
    }
}
