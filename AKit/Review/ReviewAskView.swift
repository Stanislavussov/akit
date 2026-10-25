import AKitReview
import SwiftUI

/// Ask… / Add Note… (`ReviewAsk`): one question or note to Pi about a finding or the whole
/// review. Pi answers with the review in mind; a note may change the findings (a new version).
struct ReviewAskSheet: View {
    @Environment(ReviewModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    /// nil: the review as a whole.
    let finding: ReviewFinding?
    let kind: ReviewConversationEntry.Kind
    @State private var text = ""

    private var title: String {
        (kind == .question ? "Ask about " : "Add a note to ") + (finding.map { "\($0.id): \($0.title)" } ?? "the whole review")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline).lineLimit(2)
            Text(kind == .question
                 ? "Pi answers from the code, the context pack and this review. It changes no finding unless you ask it to."
                 : "What you know that the review didn't: Pi takes it as true unless the code shows otherwise, and may confirm, reject or correct findings, or add one. The changes come as a new version; nothing goes to GitLab before you approve it.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            TextEditor(text: $text).font(.body).frame(minHeight: 120)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(.separator))
            HStack {
                Text("Pi uses the run's verifier model and the sending policy, as Discuss in Pi… does.").font(.caption2).foregroundStyle(.tertiary)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(kind == .question ? "Ask" : "Add Note") {
                    model.ask(finding: finding?.id, kind: kind, text: text)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.asking != nil)
            }
        }
        .padding()
        .frame(width: 520, height: 320)
    }
}

/// The questions and notes about one finding or the whole review, with Pi's answers.
struct ReviewThreadView: View {
    @Environment(ReviewModel.self) private var model
    let run: ReviewWorkflow.Run
    /// nil: the review as a whole.
    let finding: String?
    @State private var proposing: ReviewKnowledgeGap?

    var body: some View {
        let entries = model.thread(finding)
        if !entries.isEmpty || model.asking == (finding ?? "") {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(entries) { entry in
                    VStack(alignment: .leading, spacing: 3) {
                        Label(entry.text, systemImage: entry.kind == .question ? "questionmark.bubble" : "note.text")
                            .font(.callout).textSelection(.enabled)
                        if let answer = entry.answer {
                            Text(answer).font(.callout).foregroundStyle(.secondary).textSelection(.enabled).padding(.leading, 22)
                        } else if let error = entry.error {
                            Text(error).font(.caption).foregroundStyle(.red).padding(.leading, 22)
                        }
                        if let version = entry.version {
                            Text("Version \(version) of the findings: " + (entry.changes ?? []).joined(separator: "; "))
                                .font(.caption).foregroundStyle(.orange).padding(.leading, 22)
                        }
                        if entry.kind == .note, run.spec.knowledgeBasePath != nil {
                            Button("Propose to Knowledge Base…") { proposing = Self.gap(entry, finding: run.finding(entry.finding)) }
                                .buttonStyle(.link).font(.caption).padding(.leading, 22)
                                .help("Your note as a note of the knowledge base, so the next review knows it: it waits in the base's Inbox")
                        }
                    }
                }
                if model.asking == (finding ?? "") {
                    HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Pi is answering…").font(.caption).foregroundStyle(.secondary) }
                }
            }
            .padding(8)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
            .sheet(item: $proposing) { gap in
                if let base = run.spec.knowledgeBasePath {
                    ReviewKnowledgeProposeSheet(gap: gap, run: run.id, base: URL(filePath: base, directoryHint: .isDirectory),
                                                initialText: model.thread(finding).first { "note-\($0.id)" == gap.id }.map { "# \(gap.subject)\n\n\($0.text)\n" }) {}
                }
            }
        }
    }

    /// A note of the developer as a knowledge base proposal: its first line names it, the
    /// finding says why a review needed it.
    static func gap(_ entry: ReviewConversationEntry, finding: ReviewFinding?) -> ReviewKnowledgeGap {
        let first = entry.text.split(whereSeparator: \.isNewline).first.map(String.init) ?? entry.text
        return ReviewKnowledgeGap(id: "note-\(entry.id)", kind: .reported, subject: String(first.prefix(80)),
                                  why: finding.map { "\($0.id): \($0.title)" } ?? "the review as a whole", area: nil, passes: ["you"])
    }
}
