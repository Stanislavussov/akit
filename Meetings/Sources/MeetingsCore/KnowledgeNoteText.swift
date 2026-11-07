import Foundation

extension Transcriber {
    /// Save to Knowledge…: the summary note. Frontmatter, title, a line with date and people, a
    /// link to the transcript note (`transcriptNote` is its `area/name`), the summary.
    public static func knowledgeNote(_ meeting: Meeting, name: String, summary: String, transcriptNote: String? = nil) -> String {
        var lines = head(meeting, title: name)
        if let transcriptNote { lines += ["Transcript: [[\(transcriptNote)|\(transcriptTitle(name))]]", ""] }
        return lines.joined(separator: "\n") + "\n" + summary
    }

    /// The transcript note: the same head, a link back to the summary note (`summaryNote` is its
    /// `area/name`), every segment with its time and speaker.
    public static func knowledgeTranscript(_ meeting: Meeting, name: String, summaryNote: String) -> String {
        var lines = head(meeting, title: transcriptTitle(name))
        lines += ["Summary: [[\(summaryNote)|\(name)]]", "", plainTranscript(meeting)]
        return lines.joined(separator: "\n") + "\n"
    }

    /// The transcript note's name beside a summary note's name.
    public static func transcriptTitle(_ name: String) -> String { "\(name) – transcript" }

    private static func head(_ meeting: Meeting, title: String) -> [String] {
        let date = meeting.started.formatted(date: .long, time: .shortened)
        let people = meeting.speakerKeys.map(meeting.speakerName).filter { !$0.isEmpty }
        var head = ["---", "kind: meeting"]
        if !meeting.tagList.isEmpty { head.append("tags: [\(meeting.tagList.map { "\"\($0)\"" }.joined(separator: ", "))]") }
        return head + ["---", "# \(title)", "", "*\(date)*" + (people.isEmpty ? "" : " · " + people.joined(separator: ", ")), ""]
    }
}
