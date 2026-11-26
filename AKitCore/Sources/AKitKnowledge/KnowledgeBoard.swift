import AKitFoundation
import Foundation

/// The task notes of a feature and their board (K44). A task note is a note with `kind: task`;
/// its frontmatter is the card:
///
/// ```yaml
/// kind: task
/// ado: 321325                 # required: the Azure DevOps work item ID, digits
/// status: doing               # required: todo | doing | review | done
/// depends: [321318, 321322]   # optional: the work items it waits for, ADO IDs
/// rule: [R-CW-04]             # optional: the rules it delivers
/// ```
///
/// and its title's number (`(5) COL-321325 — …`, K42) is the order of delivery. The board keeps no
/// file of its own: it reads the notes of a folder, and moving a card writes the note's `status:`
/// line (one line, every other byte kept, P4) like Properties and `akit kb set` do. So a change
/// made anywhere (the board, Properties, `kb set`, an editor) is seen everywhere.
public enum KnowledgeTask {
    /// The kind of a task note. The board, lint and the Inbox's `task` check read this name.
    public static let kind = "task"
    /// The fields of the kind in `kb.yaml` (`KnowledgeKinds.defaults`).
    public static let fields = ["ado", "status", "depends", "rule"]
    /// The fields a card can't do without.
    public static let required = ["ado", "status"]

    /// A column of the board, in board order.
    public enum Status: String, Codable, Sendable, CaseIterable {
        case todo, doing, review, done

        public var title: String {
            switch self {
            case .todo: "To Do"
            case .doing: "Doing"
            case .review: "Review"
            case .done: "Done"
            }
        }
    }

    /// What is missing or wrong in a task note's fields, one line each; empty when the board can
    /// show it as it should. Read from a note with `kind: task` (the caller checks the kind).
    public static func problems(_ note: KnowledgeNote) -> [String] {
        let front = note.frontmatter
        var problems: [String] = []
        switch text(front["ado"]) {
        case nil: problems.append("ado: missing; the Azure DevOps work item ID, like ado: 321325")
        case let value? where !isID(value): problems.append("ado: “\(value)” is not a work item ID (digits only)")
        default: break
        }
        switch text(front["status"]) {
        case nil: problems.append("status: missing; one of \(statusList)")
        case let value? where Status(rawValue: value) == nil: problems.append("status: “\(value)” is not one of \(statusList)")
        default: break
        }
        let bad = list(front["depends"]).filter { !isID($0) }
        if !bad.isEmpty {
            problems.append("depends: \(bad.map { "“\($0)”" }.joined(separator: ", ")) \(bad.count == 1 ? "is not a work item ID" : "are not work item IDs") (digits, like depends: [321318])")
        }
        return problems
    }

    public static var statusList: String { Status.allCases.map(\.rawValue).joined(separator: ", ") }

    /// A frontmatter value as one trimmed string; nil when unset or empty.
    static func text(_ value: Any?) -> String? {
        guard let value, !(value is NSNull), !(value is [Any]) else { return nil }
        let text = "\(value)".trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? nil : text
    }

    /// A frontmatter value as a list: a YAML list, or one value as a list of one.
    static func list(_ value: Any?) -> [String] {
        if let items = value as? [Any] {
            return items.map { "\($0)".trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }
        return text(value).map { [$0] } ?? []
    }

    static func isID(_ value: String) -> Bool { !value.isEmpty && value.count <= 12 && value.allSatisfy(\.isASCII) && value.allSatisfy(\.isNumber) }

    // MARK: - Board

    /// One task note as a card.
    public struct Card: Codable, Sendable, Equatable, Identifiable {
        /// A work item the task waits for: its task note and status when the base has one.
        public struct Dependency: Codable, Sendable, Equatable {
            public let ado: String
            public let note: String?
            public let number: Int?
            public let status: Status?

            /// Not done yet: no note says so.
            public var open: Bool { status != .done }
        }

        public var id: String { note }
        public let note: String
        public let title: String
        /// The title's number (K42): the order of delivery.
        public let number: Int?
        public let ado: String?
        /// nil when `status:` is missing or not a known one: the card is in `unsorted`.
        public let status: Status?
        public let depends: [Dependency]
        public let rule: [String]
        /// `problems(_:)` of the note: what the board needs and doesn't have.
        public let problems: [String]

        /// A dependency with a task note that isn't done: the card waits.
        public var blocked: Bool { depends.contains { $0.note != nil && $0.open } }
    }

    public struct Column: Codable, Sendable, Equatable {
        public let status: Status
        public let title: String
        public let cards: [Card]
    }

    /// `akit kb board FOLDER --json` and the Board view.
    public struct Board: Codable, Sendable, Equatable {
        public let base: String
        /// The area or a folder in it (`spikes/odstoupeni od smlouvy`).
        public let folder: String
        public let columns: [Column]
        /// Cards without a status the board knows: they need their fields first.
        public let unsorted: [Card]

        public var cards: [Card] { columns.flatMap(\.cards) + unsorted }
    }

    /// The order of cards in a column: by title number (cards without one last), then ADO ID, then title.
    static func ordered(_ cards: [Card]) -> [Card] {
        cards.sorted { a, b in
            switch (a.number, b.number) {
            case let (x?, y?) where x != y: return x < y
            case (.some, nil): return true
            case (nil, .some): return false
            default:
                if a.ado != b.ado { return (Int(a.ado ?? "") ?? .max) < (Int(b.ado ?? "") ?? .max) }
                return a.title.localizedStandardCompare(b.title) == .orderedAscending
            }
        }
    }
}

extension KnowledgeBase {
    /// The task notes of every area, with their text (for the board and lint).
    func taskNotes() -> [(entry: NoteEntry, note: KnowledgeNote)] {
        ((try? notes()) ?? []).compactMap { entry in
            guard entry.kind == KnowledgeTask.kind, let note = KnowledgeNote.load(noteFile(entry.id)) else { return nil }
            return (entry, note)
        }
    }

    /// The folder id of an area or a folder in it, as typed (`spikes`, `spikes/odstoupeni od smlouvy`,
    /// `areas/spikes/…/`), checked to exist.
    public func boardFolder(_ name: String) throws(Failure) -> String {
        var folder = Self.nfc(name.trimmingCharacters(in: .whitespaces))
        if folder.hasPrefix("areas/") { folder = String(folder.dropFirst("areas/".count)) }
        while folder.hasSuffix("/") { folder.removeLast() }
        let parts = folder.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !folder.isEmpty, parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
              FileWalk.isDirectory(areasFolder.appending(path: folder, directoryHint: .isDirectory)) else {
            throw Failure(message: "No folder “\(name)” in \(root.path)/areas. Give an area (spikes) or a folder in it (spikes/odstoupeni od smlouvy).")
        }
        return folder
    }

    /// The board of a folder: its task notes (and those of its subfolders) in status columns. A
    /// dependency names the task note of its ADO ID from anywhere in the base.
    public func board(folder name: String) throws(Failure) -> KnowledgeTask.Board {
        let folder = try boardFolder(name)
        let tasks = taskNotes()
        var byADO: [String: (entry: NoteEntry, status: KnowledgeTask.Status?)] = [:]
        for task in tasks {
            guard let ado = KnowledgeTask.text(task.note.frontmatter["ado"]), byADO[ado] == nil else { continue }
            byADO[ado] = (task.entry, KnowledgeTask.text(task.note.frontmatter["status"]).flatMap(KnowledgeTask.Status.init))
        }
        let cards = tasks.filter { Self.nfc($0.entry.id).hasPrefix(folder + "/") }.map { task in
            let front = task.note.frontmatter
            let depends = KnowledgeTask.list(front["depends"]).map { ado in
                let found = byADO[ado]
                return KnowledgeTask.Card.Dependency(ado: ado, note: found?.entry.id, number: found?.entry.number, status: found?.status)
            }
            return KnowledgeTask.Card(note: task.entry.id, title: task.entry.title, number: task.entry.number,
                                      ado: KnowledgeTask.text(front["ado"]),
                                      status: KnowledgeTask.text(front["status"]).flatMap(KnowledgeTask.Status.init),
                                      depends: depends, rule: KnowledgeTask.list(front["rule"]),
                                      problems: KnowledgeTask.problems(task.note))
        }
        let columns = KnowledgeTask.Status.allCases.map { status in
            KnowledgeTask.Column(status: status, title: status.title, cards: KnowledgeTask.ordered(cards.filter { $0.status == status }))
        }
        return KnowledgeTask.Board(base: root.path, folder: folder, columns: columns,
                                   unsorted: KnowledgeTask.ordered(cards.filter { $0.status == nil }))
    }

    /// Moves a card: the task note's `status:` line set, nothing else (`setProperties`). The caller
    /// commits (the CLI at once, the app through the commit queue). Refused for a note that isn't
    /// a task note.
    @discardableResult
    public func move(task id: String, to status: KnowledgeTask.Status) throws(Failure) -> (path: String, changed: Bool) {
        guard let note = KnowledgeNote.load(noteFile(id)) else { throw Failure(message: "No note \(id) in \(root.path).") }
        guard note.kind == KnowledgeTask.kind else {
            throw Failure(message: "\(id) is no task note (kind: \(note.kind ?? "none")); only a note with kind: task is on a board.")
        }
        return try setProperties(note: id, set: [("status", .string(status.rawValue))])
    }
}
