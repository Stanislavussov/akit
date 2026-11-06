import AppKit
import MeetingsCore
import SwiftUI

/// Ask… (M24): questions over the meetings of a scope; the answer cites `[n]`, which open the
/// meetings. Follow-ups carry the earlier answers.
struct AskView: View {
    @Bindable var model: MeetingsModel
    @Environment(\.dismiss) private var dismiss
    @State private var draft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Ask About Meetings").font(.title3.bold())
                Spacer()
                Button("New Chat") { model.newChat() }
                    .disabled(model.askTurns.isEmpty || model.asking)
            }
            HStack(spacing: 10) {
                Picker("Meetings", selection: $model.askScope) {
                    if let id = model.selectedID { Text("This meeting").tag(MeetingAsk.Scope.meeting(id)) }
                    Text("Last 7 days").tag(MeetingAsk.Scope.days(7))
                    Text("Last 30 days").tag(MeetingAsk.Scope.days(30))
                    Text("All meetings").tag(MeetingAsk.Scope.all)
                }
                .fixedSize()
                Picker("Tag", selection: $model.askTag) {
                    Text("Any tag").tag(String?.none)
                    ForEach(model.allTags, id: \.tag) { Text("#" + $0.tag).tag(Optional($0.tag)) }
                }
                .fixedSize()
                Spacer()
                let count = MeetingAsk.meetings(model.meetings, scope: model.askScope, tag: model.askTag).count
                Text("\(count) meeting\(count == 1 ? "" : "s")").font(.caption).foregroundStyle(.secondary)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        if model.askTurns.isEmpty {
                            Text("Ask what was said or decided, who does what, or what a meeting was about. The summaries of the meetings in scope go to the summary model, with the transcripts that match your words best; about $0.01 a question with Flash-Lite.")
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        ForEach(model.askTurns) { turn in
                            AskTurnView(model: model, turn: turn) { dismiss() }.id(turn.id)
                        }
                    }
                    .padding(.vertical, 4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: model.askTurns) { _, turns in
                    if let last = turns.last { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } }
                }
            }
            .frame(maxHeight: .infinity)
            HStack(alignment: .bottom) {
                TextField("Ask about your meetings…", text: $draft, axis: .vertical)
                    .lineLimit(1...5)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(send)
                if model.asking { ProgressView().controlSize(.small) }
                Button("Ask", action: send)
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(model.asking || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 680, height: 620)
        // Another scope numbers the meetings anew: earlier [n] would point at other meetings.
        .onChange(of: model.askScope) { model.newChat() }
        .onChange(of: model.askTag) { model.newChat() }
    }

    private func send() {
        guard !model.asking, !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let question = draft
        draft = ""
        Task { await model.ask(question) }
    }
}

struct AskTurnView: View {
    let model: MeetingsModel
    let turn: MeetingsModel.AskTurn
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(turn.question).bold().textSelection(.enabled)
                Spacer()
                Text(turn.scope).font(.caption).foregroundStyle(.secondary)
            }
            if let answer = turn.answer {
                Text(Self.linked(answer, sources: turn.sources))
                    .textSelection(.enabled)
                    .environment(\.openURL, OpenURLAction { url in
                        guard let id = Self.meetingID(url) else { return .systemAction }
                        model.select(id)
                        close()
                        return .handled
                    })
                if !turn.sources.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(turn.sources.keys.sorted(), id: \.self) { n in
                            if let id = turn.sources[n], let meeting = model.meetings.first(where: { $0.id == id }) {
                                Button("[\(n)] \(meeting.displayTitle) — \(meeting.started.formatted(date: .abbreviated, time: .shortened))") {
                                    model.select(id)
                                    close()
                                }
                                .buttonStyle(.link)
                                .font(.caption)
                            }
                        }
                    }
                }
                Text(String(format: "%d meeting%@ in scope · $%.4f", turn.meetings, turn.meetings == 1 ? "" : "s", turn.cost))
                    .font(.caption2).foregroundStyle(.tertiary)
            } else if let problem = turn.problem {
                Label(problem, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).font(.callout).textSelection(.enabled)
            } else {
                HStack { ProgressView().controlSize(.small); Text("Asking…").foregroundStyle(.secondary) }
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
    }

    /// The answer's Markdown with each `[n]` that names a meeting as a link to it; line breaks kept.
    static func linked(_ text: String, sources: [Int: String]) -> AttributedString {
        let marked = text.replacing(/\[(\d+)\]/) { match in
            guard let n = Int(match.1), let id = sources[n] else { return String(match.0) }
            return "[\\[\(n)\\]](x-meeting:\(id.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""))"
        }
        return (try? AttributedString(markdown: marked, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
    }

    static func meetingID(_ url: URL) -> String? {
        guard url.scheme == "x-meeting" else { return nil }
        return String(url.absoluteString.dropFirst("x-meeting:".count)).removingPercentEncoding
    }
}
