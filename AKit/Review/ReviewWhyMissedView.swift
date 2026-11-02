import AKitReview
import AppKit
import SwiftUI

/// One item of "Missed by the reviewer" with Why Missed? (`ReviewWhyMissed`): Pi names the
/// cause and what to change, then the chat under it takes follow-up questions.
struct ReviewMissedRow: View {
    @Environment(ReviewModel.self) private var model
    let run: ReviewWorkflow.Run
    let item: ReviewMissed
    @State private var draft = ""
    @State private var copied: String?
    @FocusState private var inputFocused: Bool

    private var thread: [ReviewWhyMissed.Entry] { model.whyThread(item.id) }
    private var asking: Bool { model.isAskingWhy(item.id) }
    /// A follow-up needs an answer to go on from.
    private var answered: Bool { thread.contains { $0.answer != nil && $0.session != nil } }
    private var canSend: Bool { !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && model.askingWhy == nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(item.id).font(.caption.monospaced()).foregroundStyle(.secondary)
                Text((item.file.map { "\($0)\(item.line.map { ":\($0)" } ?? ""): " } ?? "") + item.text).font(.callout).textSelection(.enabled)
                Spacer()
                if thread.isEmpty && !asking {
                    Button("Why Missed?") { model.askWhy(missed: item.id) }
                        .disabled(run.passes == nil || model.askingWhy != nil)
                        .help("Pi (the run's verifier model, reading only) traces this through the run: the diff, which roles read the file, what they found and what became of it. It names the cause and what to change so the next review catches it. Nothing changes and nothing goes to GitLab.")
                }
            }
            if !thread.isEmpty || asking { chat }
        }
    }

    @ViewBuilder private var chat: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(thread) { entry in
                VStack(alignment: .leading, spacing: 4) {
                    Label(entry.question.isEmpty ? "Why did the review miss this?" : entry.question, systemImage: "questionmark.bubble")
                        .font(.callout.weight(.medium)).textSelection(.enabled)
                    if let answer = entry.answer {
                        MarkdownText(text: answer).padding(.leading, 22)
                        HStack(spacing: 10) {
                            Text("\(entry.model.isEmpty ? "Pi's default model" : entry.model)" + String(format: " · %.1f credits", entry.credits))
                                .font(.caption2).foregroundStyle(.tertiary)
                            Button(copied == entry.id ? "Copied" : "Copy") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(answer, forType: .string)
                                copied = entry.id
                            }
                            .buttonStyle(.link).font(.caption)
                            .help("The answer as Markdown, for a role's SKILL.md or a note")
                        }
                        .padding(.leading, 22)
                    } else {
                        Text(entry.error ?? "Pi gave no answer.").font(.caption).foregroundStyle(.red).textSelection(.enabled).padding(.leading, 22)
                    }
                }
            }
            if asking {
                if let question = model.whyQuestion, !question.isEmpty {
                    Label(question, systemImage: "questionmark.bubble").font(.callout.weight(.medium))
                }
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(model.whyProgress.map { ReviewLive.split($0).title.trimmingCharacters(in: .whitespaces) } ?? "Pi is looking for the cause…").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            if !answered && !asking {
                Button(thread.isEmpty ? "Why Missed?" : "Ask Why Again") { model.askWhy(missed: item.id) }
                    .disabled(run.passes == nil || model.askingWhy != nil)
            } else {
                HStack(alignment: .bottom, spacing: 8) {
                    TextField("Ask a follow-up: which role, what to add to it…", text: $draft, axis: .vertical)
                        .lineLimit(1...5)
                        .textFieldStyle(.roundedBorder)
                        .focused($inputFocused)
                        // Return sends; Option-Return starts a new line.
                        .onSubmit { if canSend { send() } }
                    if asking {
                        Button("Stop", systemImage: "stop.circle") { model.stopWhy() }
                            .help("Stop Pi; this answer is not continued")
                    } else {
                        Button("Send", systemImage: "arrow.up.circle.fill") { send() }
                            .disabled(!canSend)
                            .help(model.askingWhy != nil ? "Pi is answering another item; send in a moment" : "Send the question to Pi (↩; ⌥↩ for a new line)")
                    }
                }
                .labelStyle(.iconOnly)
            }
        }
        .padding(8)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
    }

    private func send() {
        let text = draft
        draft = ""
        model.askWhy(missed: item.id, question: text)
    }
}
