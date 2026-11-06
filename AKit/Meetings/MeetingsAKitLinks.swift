import AKitFoundation
import AKitKnowledge
import Foundation
import MeetingsCore
import MeetingsUI

/// Meetings → AKit (docs/design/meetings.md, M25): the meeting's tasks into the Notebook, a line
/// into the Work Log, facts as proposals into the knowledge base's Inbox. All three live in the
/// knowledge base the Knowledge screen shows; writes go to its commit queue like the screens' own.
@MainActor enum MeetingsAKitLinks {
    static func make(knowledge: KnowledgeModel, worklog: WorkLogModel) -> MeetingsLinks {
        func base() async throws -> KnowledgeBase {
            if knowledge.base == nil { await knowledge.load() }
            guard let base = knowledge.base else {
                throw KnowledgeBase.Failure(message: "No knowledge base yet. Create one on the Knowledge screen first: the Notebook, the Work Log and the Inbox live in it.")
            }
            return base
        }
        var links = MeetingsLinks()
        links.notebookTabs = {
            let tabs = KnowledgeNotebook(base: try await base()).tabs()
            return tabs.isEmpty ? [KnowledgeNotebook.firstTab] : tabs
        }
        links.addTasks = { lines, tab in
            let base = try await base()
            let notebook = KnowledgeNotebook(base: base)
            let old = try notebook.text(tab)
            let day = NotebookModel.dayFormatter.string(from: .now)
            // Each line goes first under today's heading, so the last one is added first.
            var text = old
            for line in lines.reversed() { text = KnowledgeNotebook.adding("- [ ] " + line, to: text, under: day) }
            let (path, outcome) = try notebook.save(tab, bytes: Data(text.utf8), expectedHash: KnowledgeWrite.hash(of: notebook.file(tab)))
            guard case .saved = outcome else {
                throw KnowledgeBase.Failure(message: "The Notebook tab \(tab) changed while AKit wrote it. Try again.")
            }
            knowledge.enqueueEdit(path, in: base)
        }
        links.addToWorkLog = { line in
            _ = try await base()
            try worklog.addMeeting(line.title, at: line.started, summary: line.summary)
        }
        links.knowledgeNotes = {
            try await base().notes().map { FactFinder.Note(id: $0.id, title: $0.title) }
        }
        links.propose = { facts, source in
            let base = try await base()
            var written = 0
            var refused: [String] = []
            for fact in facts {
                do {
                    try base.propose(KnowledgeInbox.Draft(.note(fact.note, body: fact.body, set: []),
                                                          reason: fact.reason.isEmpty ? source : "\(source): \(fact.reason)", author: "meetings"))
                    written += 1
                } catch {
                    refused.append("\(fact.note): \(error.localizedDescription)")
                }
            }
            return (written, refused)
        }
        return links
    }
}
