import AKitFoundation
import Foundation

// Names that carry no text from sessions, for data that leaves the Mac as setup data (Ask
// AKit, `docs/design/ask-akit.md`). An emergent mode's id is a slug of the name a model gave
// it from session notes; a control task's id from a session (or a reproduction) is a slug of
// its prompt. Seed modes and commit tasks are named by AKit or the repository: their ids stay.

extension Mode {
    /// The seed's own id; for an emergent mode "an emergent failure mode #1a2b": a short hash
    /// of the id, stable and distinct, without its words.
    public var neutralName: String {
        origin.isSeed ? id : "an emergent \(kind.rawValue) mode #\(NeutralName.hash(id))"
    }
}

extension ControlTask {
    /// A commit task's id; for a task from a session or a reproduction "a control task from a
    /// session #1a2b".
    public var neutralName: String {
        switch source {
        case .commit: id
        case .session: "a control task from a session #\(NeutralName.hash(id))"
        case .reproduction: "a control task from a reproduction #\(NeutralName.hash(id))"
        }
    }
}

extension ControlTask {
    /// The neutral name of the task with `id` among `tasks`; a task that is gone (removed,
    /// its cells kept) is "a removed control task #1a2b", since its id may be a prompt slug.
    public static func neutralName(of id: String, in tasks: [ControlTask]) -> String {
        tasks.first { $0.id == id }?.neutralName ?? "a removed control task #\(NeutralName.hash(id))"
    }

    /// The ids that are made from session words (a session or reproduction task's prompt
    /// slug): Ask AKit's backstop never lets them out.
    public static func sessionDerivedIDs(_ tasks: [ControlTask]) -> [String] {
        tasks.filter { if case .commit = $0.source { false } else { true } }.map(\.id)
    }
}

extension Mode {
    /// The ids that are made from session words (an emergent mode's name slug, kept after a
    /// rename): Ask AKit's backstop never lets them out.
    public static func sessionDerivedIDs(_ modes: [Mode]) -> [String] {
        modes.filter { !$0.origin.isSeed }.map(\.id)
    }
}

extension ControlTask.Oracle {
    /// `label` without a mode's id (an assertion names its mode, which may be emergent).
    public var neutralLabel: String {
        if case .assertion = self { return "assertion: the mode's code check" }
        return label
    }
}

enum NeutralName {
    /// The first 4 hex digits of the text's SHA-256.
    static func hash(_ text: String) -> String { String(Checksum.sha256(Data(text.utf8)).prefix(4)) }
}
