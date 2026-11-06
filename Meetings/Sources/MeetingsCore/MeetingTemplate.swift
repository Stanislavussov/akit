import Foundation

/// M22: what kind of meeting it is, so the summary lists the sections that kind needs between
/// Summary and Decisions/Tasks. `sections` holds one section per line, `Heading: what goes in it`
/// (the part after the colon is optional). General has none.
public struct MeetingTemplate: Codable, Equatable, Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var sections: String

    public init(id: String, name: String, sections: String) {
        self.id = id
        self.name = name
        self.sections = sections
    }

    public static let generalID = "general"

    public static let builtIn: [MeetingTemplate] = [
        MeetingTemplate(id: generalID, name: "General", sections: ""),
        MeetingTemplate(id: "one-on-one", name: "1:1", sections: """
        Feedback: what each person said about the other's work
        Concerns: worries, blockers, how the person feels
        Growth: goals, skills, career
        """),
        MeetingTemplate(id: "standup", name: "Standup", sections: """
        Per person: one item per person: done since last time, next, blocked by
        Blockers: who is blocked by what, and who can help
        """),
        MeetingTemplate(id: "client", name: "Client call", sections: """
        Needs: what the client wants and why
        Questions: what the client asked, each with the answer given
        Commitments: what we promised, with dates when said
        """),
        MeetingTemplate(id: "interview", name: "Interview", sections: """
        Candidate: background and experience in brief
        Strengths
        Concerns
        Recommendation: hire or not and why, only when the transcript supports it
        """),
        MeetingTemplate(id: "retro", name: "Retro", sections: """
        Went well
        Went badly
        Ideas: what to try next time
        """),
    ]

    /// The section lines, without empty ones.
    public var sectionLines: [String] {
        sections.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// A new own template's id, never one used before (a meeting may still name a removed one).
    public static func newID() -> String { "own-" + UUID().uuidString.prefix(8).lowercased() }
}
