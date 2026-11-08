import Foundation

extension Transcriber {
    /// Save to Knowledge…: the summary note. Frontmatter, title, a line with date and people, a
    /// link that opens the meeting's transcript in Meetings (`transcriptLink`), the summary. The
    /// transcript stays in Meetings: no second note.
    public static func knowledgeNote(_ meeting: Meeting, name: String, summary: String, transcriptLink: Bool = false) -> String {
        var lines = head(meeting, title: name)
        if transcriptLink { lines += ["Transcript: [Open the transcript in Meetings](\(transcriptURL(meeting.id)))", ""] }
        return lines.joined(separator: "\n") + "\n" + summary
    }

    /// `akit://meetings/open?id=2026-11-07/1854&tab=transcript`: AKit shows that meeting on its
    /// Transcript tab (from the Knowledge screen, Obsidian or a browser).
    public static func transcriptURL(_ id: String) -> String {
        var parts = URLComponents()
        parts.scheme = "akit"
        parts.host = "meetings"
        parts.path = "/open"
        parts.queryItems = [URLQueryItem(name: "id", value: id), URLQueryItem(name: "tab", value: "transcript")]
        return parts.url?.absoluteString ?? "akit://meetings"
    }

    private static func head(_ meeting: Meeting, title: String) -> [String] {
        let date = meeting.started.formatted(date: .long, time: .shortened)
        let people = meeting.speakerKeys.map(meeting.speakerName).filter { !$0.isEmpty }
        var head = ["---", "kind: meeting"]
        if !meeting.tagList.isEmpty { head.append("tags: [\(meeting.tagList.map { "\"\($0)\"" }.joined(separator: ", "))]") }
        return head + ["---", "# \(title)", "", "*\(date)*" + (people.isEmpty ? "" : " · " + people.joined(separator: ", ")), ""]
    }
}
