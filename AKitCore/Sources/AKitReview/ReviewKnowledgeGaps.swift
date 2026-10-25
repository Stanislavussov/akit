import AKitFoundation
import AKitKnowledge
import Foundation

/// What a review missed in the knowledge base (`akit review kb-gaps`, the run's "Missing in the
/// knowledge base"): searches no section answered, gaps the passes reported with
/// `system: knowledge`, and notes the review used that have no `description:` (agents read that
/// line first and open a note only when it is the one they need). Each one can become a
/// proposal in the base's Inbox; nothing is written here.
public struct ReviewKnowledgeGap: Codable, Sendable, Hashable, Identifiable {
    public enum Kind: String, Codable, Sendable {
        /// `akit_kb_search` found no section with every word.
        case search
        /// A pass called `akit_report_context_gap` with `system: knowledge`.
        case reported
        /// A note the review used has no `description:`.
        case noDescription = "no-description"
    }

    /// `k1`, `k2`, … in the order of the list.
    public var id: String
    public var kind: Kind
    /// The search words, what a note should hold, or the note's id (`payments/billing`).
    public var subject: String
    /// Why it matters, as the pass said; empty for a search.
    public var why: String
    /// The area or note it belongs to, as the pass said, or the search's area.
    public var area: String?
    /// The passes that met it.
    public var passes: [String]
}

public enum ReviewKnowledgeGaps {
    /// The gaps of the run in `folder`: searches first, then reported gaps, then notes without a
    /// description. A search counts only when no search of the run with the same words found
    /// anything; reported gaps and searches are one row per text, whatever the pass.
    public static func read(folder: URL, base: URL?) -> [ReviewKnowledgeGap] {
        var gaps: [ReviewKnowledgeGap] = []
        func add(_ kind: ReviewKnowledgeGap.Kind, _ subject: String, why: String = "", area: String? = nil, pass: String) {
            let key = normalized(subject)
            guard !key.isEmpty else { return }
            if let index = gaps.firstIndex(where: { $0.kind == kind && normalized($0.subject) == key }) {
                if !gaps[index].passes.contains(pass) { gaps[index].passes.append(pass) }
                return
            }
            gaps.append(ReviewKnowledgeGap(id: "", kind: kind, subject: subject, why: why, area: area, passes: [pass]))
        }
        let calls = ReviewMCPData.calls(in: folder)
        var used: [(note: String, pass: String)] = []
        var answered = Set<String>()
        var empty: [(query: String, area: String?, pass: String)] = []
        for call in calls where !call.isError {
            let input = call.inputObject
            let answer = call.text.joined(separator: "\n")
            let object = (try? JSONSerialization.jsonObject(with: Data(answer.utf8))) as? JSONObject
            switch call.tool {
            case "akit_kb_search":
                guard let query = (input["query"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !query.isEmpty,
                      let results = object?["results"] as? [JSONObject] else { continue }
                if results.isEmpty {
                    empty.append((query, (input["area"] as? String).flatMap { $0.isEmpty ? nil : $0 }, call.pass))
                } else {
                    answered.insert(normalized(query))
                    used += results.compactMap { $0["note"] as? String }.map { ($0, call.pass) }
                }
            case "akit_kb_show":
                if let note = object?["note"] as? String { used.append((note, call.pass)) }
            default:
                continue
            }
        }
        for search in empty where !answered.contains(normalized(search.query)) {
            add(.search, search.query, area: search.area, pass: search.pass)
        }
        let reported = ReviewJSON.read([ContextGap].self, from: folder.appending(path: "gaps.json")) ?? []
        for gap in reported where gap.system.lowercased() == "knowledge" && gap.reportedBy != "gather" {
            add(.reported, gap.needed, why: gap.why, area: gap.howToGet.isEmpty ? nil : gap.howToGet, pass: gap.reportedBy)
        }
        if let base {
            let knowledge = KnowledgeBase(root: base)
            let card = cardNotes(folder: folder).map { (note: $0, pass: "gather") }
            var lacks: [String: Bool] = [:]
            for (note, pass) in card + used {
                let missing = lacks[note] ?? (KnowledgeNote.load(knowledge.noteFile(note)).map { !$0.hasDescription } ?? false)
                lacks[note] = missing
                if missing { add(.noDescription, note, area: note.split(separator: "/").first.map(String.init), pass: pass) }
            }
        }
        for index in gaps.indices { gaps[index].id = "k\(index + 1)" }
        return gaps
    }

    /// The gaps of a run folder, with the base its Gather used (`knowledgeBasePath` in `run.json`).
    public static func read(run folder: URL) -> [ReviewKnowledgeGap] {
        let spec = ReviewJSON.read(ReviewRunSpec.self, from: folder.appending(path: "run.json"))
        return read(folder: folder, base: spec?.knowledgeBasePath.map { URL(filePath: $0, directoryHint: .isDirectory) })
    }

    /// The `akit kb propose` command that turns a gap into a proposal (the person fills in the text).
    public static func proposeCommand(_ gap: ReviewKnowledgeGap, run: String, base: String?) -> String {
        func quoted(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let where_ = base.map { " --base \(quoted($0))" } ?? ""
        switch gap.kind {
        case .noDescription:
            return "akit kb propose --note \(gap.subject) --set 'description=<one line>' --reason \(quoted(reason(gap, run: run)))\(where_)"
        case .search, .reported:
            return "akit kb propose --note AREA/NAME --set 'description=<one line>' --file NOTE.md --reason \(quoted(reason(gap, run: run)))\(where_)"
        }
    }

    /// The note ids the run's knowledge card lists (`- payments/billing (billing)…`).
    static func cardNotes(folder: URL) -> [String] {
        guard let text = try? String(contentsOf: folder.appending(path: "context/\(ReviewKnowledgeCard.fileName)"), encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { line -> String? in
            guard line.hasPrefix("- "), let space = line.dropFirst(2).firstIndex(of: " "),
                  line[space...].hasPrefix(" (") else { return nil }
            let id = String(line[line.index(line.startIndex, offsetBy: 2)..<space])
            return id.contains("/") && !id.contains("->") ? id : nil
        }
    }

    static func normalized(_ text: String) -> String {
        text.lowercased().split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    /// A first draft for the base's Inbox: a new note for a search or a reported gap, a
    /// `description:` for a note without one. The person edits it before it is proposed.
    public static func draftBody(_ gap: ReviewKnowledgeGap) -> String {
        switch gap.kind {
        case .noDescription:
            return ""
        case .search, .reported:
            let title = gap.subject.trimmingCharacters(in: .whitespacesAndNewlines)
            var lines = ["# \(title)", ""]
            if !gap.why.isEmpty { lines += ["Why a review needed it: \(gap.why)", ""] }
            lines += ["(What the team knows about it.)", ""]
            return lines.joined(separator: "\n")
        }
    }

    /// The reason a proposal from this gap carries into the Inbox.
    public static func reason(_ gap: ReviewKnowledgeGap, run: String) -> String {
        switch gap.kind {
        case .search: "AKit review \(run) searched for \"\(gap.subject)\" and found nothing"
        case .reported: "AKit review \(run) needed it: \(gap.subject)"
        case .noDescription: "AKit review \(run) used this note; it had no description"
        }
    }
}
