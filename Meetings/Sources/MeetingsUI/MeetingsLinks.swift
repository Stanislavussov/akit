import Foundation
import MeetingsCore

/// M25: what the host app can do with a meeting outside the package. AKit passes its Notebook,
/// Work Log and knowledge base; `Meetings.app` passes `.none` and the menu is hidden. Each
/// closure throws a `LocalizedError` the screen shows.
public struct MeetingsLinks {
    /// The Notebook's tabs (the first is the default), for Add Tasks to Notebook….
    public var notebookTabs: (@MainActor () async throws -> [String])?
    /// Adds task lines (without `- [ ]`) under today's heading of a Notebook tab.
    public var addTasks: (@MainActor (_ lines: [String], _ tab: String) async throws -> Void)?
    /// Adds one `#meeting` line at the meeting's start.
    public var addToWorkLog: (@MainActor (_ entry: WorkLogLine) async throws -> Void)?
    /// The knowledge base's notes, for the fact call.
    public var knowledgeNotes: (@MainActor () async throws -> [FactFinder.Note])?
    /// Writes the facts as proposals into the base's Inbox; returns how many were written and
    /// why the others were not.
    public var propose: (@MainActor (_ facts: [MeetingFact], _ source: String) async throws -> (written: Int, refused: [String]))?

    public init() {}

    @MainActor public static let none = MeetingsLinks()

    public var isEmpty: Bool { addTasks == nil && addToWorkLog == nil && propose == nil }

    /// A Work Log line: when, the title, a short summary.
    public struct WorkLogLine: Sendable, Equatable {
        public var started: Date
        public var title: String
        public var summary: String?

        public init(started: Date, title: String, summary: String?) {
            self.started = started
            self.title = title
            self.summary = summary
        }
    }
}
