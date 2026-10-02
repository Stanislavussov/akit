import AKitErrorAnalysis
import AKitFoundation
import AKitSessions
import AppKit
import SwiftUI

/// Labeling one reserved session, blind: the scrubbed transcript with numbered steps, and
/// the user's notes, outcome and deviation steps. The model's notes are never shown here.
struct BootstrapLabelingView: View {
    @Environment(AnalysisModel.self) private var analysis
    let entry: BootstrapReservations.Entry
    let title: String
    @State private var items: [TranscriptItem]?
    @State private var loadError: String?
    @State private var notes: [Note] = []
    @State private var outcome: Outcome?
    @State private var decisive = ""
    @State private var observed = ""
    /// The step a new note starts at.
    @State private var selected: Int?
    @State private var noteDescription = ""
    @State private var quote = ""
    @State private var step = ""
    @State private var error: String?
    @State private var busy = false
    @State private var confirmFinish = false

    var body: some View {
        HSplitView {
            transcript
                .frame(minWidth: 300, idealWidth: 460, maxWidth: .infinity, maxHeight: .infinity)
            form
                .frame(minWidth: 300, idealWidth: 380, maxWidth: 560, maxHeight: .infinity)
        }
        .task(id: entry.sessionKey) { await load() }
    }

    private func load() async {
        let entry = entry, env = analysis.env
        if let label = analysis.data.labels[entry.sessionKey] {
            notes = label.notes
            outcome = label.outcome
            decisive = label.deviation.decisiveStep.map(String.init) ?? ""
            observed = label.deviation.observedStep.map(String.init) ?? ""
        }
        do {
            let loaded = try await Task.detached {
                try Bootstrap.items(transcript: entry.transcript, sessionKey: entry.sessionKey, env: env)
            }.value
            items = loaded.filter { $0.kind != .thinking }
            // Snapshots: `--query <step>` starts a note at that step.
            if let step = DebugSnapshot.options?.query.flatMap(Int.init), let item = items?.first(where: { $0.id == step }) { select(item) }
        } catch {
            loadError = "The transcript can't be read: \(error.localizedDescription)"
        }
    }

    // MARK: Transcript

    @ViewBuilder private var transcript: some View {
        if let items {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    Text("Scrubbed as a model would see it. Click a step's number to start a note there.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    ForEach(items) { item in
                        StepRow(item: item, selected: selected == item.id) { select(item) }
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else if let loadError {
            ContentUnavailableView("No Transcript", systemImage: "doc.questionmark", description: Text(loadError))
        } else {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func select(_ item: TranscriptItem) {
        selected = item.id
        step = String(item.id)
        quote = PreviewLine.line(item.text)
    }

    // MARK: Form

    private var form: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.title3.bold()).lineLimit(2)
                    Text(entry.sessionKey).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                    Label("The model's notes on this session stay hidden until you finish.", systemImage: "eye.slash")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                newNote
                Divider()
                yourNotes
                Divider()
                session
                if let error {
                    Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red).font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    Spacer()
                    Button("Save Draft") { save(finish: false) }.disabled(busy)
                    Button("Finish…") { finish() }
                        .disabled(busy || outcome == nil)
                        .help(outcome == nil ? "Give the session's outcome first" : "Done labeling: now a model may review it")
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .confirmationDialog("Finish labeling this session?", isPresented: $confirmFinish) {
            Button("Finish") { save(finish: true) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your \(AnalysisText.notes(notes.count)) and the outcome become the session's blind label. After this a model may review the session, and once it has, its notes show next to yours. You can reopen it later, but after you have seen the model's notes it is no longer blind.")
        }
    }

    /// A note typed but not added would be lost: Finish waits until it is added or cleared.
    private var draftNote: Bool {
        !noteDescription.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !quote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func finish() {
        error = nil
        guard !draftNote else {
            error = "A note is still being written: Add Note, or Clear it, before you finish."
            return
        }
        confirmFinish = true
    }

    private var newNote: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("New note").font(.headline)
            if let selected, let item = items?.first(where: { $0.id == selected }) {
                Text("Select the quote in step #\(selected):").font(.callout).foregroundStyle(.secondary)
                QuotePicker(text: String(item.text.prefix(20_000))) { quote = $0 }
                    .frame(height: 110)
                    .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
            }
            TextField("What went wrong", text: $noteDescription, axis: .vertical)
                .lineLimit(2...5)
                .textFieldStyle(.roundedBorder)
            TextField("Quote from the step", text: $quote, axis: .vertical)
                .lineLimit(1...4)
                .font(.callout.monospaced())
                .textFieldStyle(.roundedBorder)
            HStack {
                TextField("Step", text: $step, prompt: Text("Step #"))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 80)
                Spacer()
                if draftNote {
                    Button("Clear") {
                        noteDescription = ""
                        quote = ""
                    }
                    .help("Empty “What went wrong” and the quote")
                }
                Button("Add Note", systemImage: "plus", action: addNote)
                    .disabled(noteDescription.trimmingCharacters(in: .whitespaces).isEmpty || Int(step) == nil
                              || quote.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    private func addNote() {
        guard let number = Int(step) else { return }
        notes.append(Note(id: "h\(notes.count + 1)", source: .human, description: noteDescription.trimmingCharacters(in: .whitespacesAndNewlines),
                          step: number, quote: quote.trimmingCharacters(in: .whitespacesAndNewlines)))
        noteDescription = ""
        quote = ""
    }

    private var yourNotes: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Your notes (\(notes.count))").font(.headline)
            if notes.isEmpty {
                Text("None yet. A session with no problems is a valid label too.").font(.callout).foregroundStyle(.secondary)
            }
            ForEach(Array(notes.enumerated()), id: \.offset) { index, note in
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("step #\(note.step)").font(.caption).foregroundStyle(.secondary)
                        Text(note.description).fixedSize(horizontal: false, vertical: true)
                        QuoteText(text: note.quote)
                    }
                    Button("Delete", systemImage: "trash") { notes.remove(at: index) }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                        .help("Delete this note")
                }
            }
        }
    }

    private var session: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("The session").font(.headline)
            Picker("Outcome", selection: $outcome) {
                Text("Not set").tag(Outcome?.none)
                ForEach(Outcome.allCases, id: \.self) { Text($0.title).tag(Outcome?.some($0)) }
            }
            stepField("Decided about step", text: $decisive,
                      help: "The error that decided the outcome")
            stepField("Visible about step", text: $observed,
                      help: "The first moment the problem showed, if later")
            Text("Both are approximate: \"about here\" is enough.").font(.caption).foregroundStyle(.secondary)
        }
    }

    private func stepField(_ title: String, text: Binding<String>, help: String) -> some View {
        HStack {
            Text(title)
            TextField(title, text: text, prompt: Text("#"))
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .frame(width: 70)
            if let selected {
                Button("Use #\(selected)") { text.wrappedValue = String(selected) }.controlSize(.small)
            }
        }
        .help(help)
    }

    private func save(finish: Bool) {
        busy = true
        error = nil
        let label = Bootstrap.Label(sessionKey: entry.sessionKey, transcript: entry.transcript, notes: notes, outcome: outcome,
                                    deviation: Deviation(decisiveStep: Int(decisive), observedStep: Int(observed)),
                                    labeledAt: finish ? .now : nil)
        let items = items
        Task {
            do {
                try await analysis.run { env in
                    try Bootstrap.LabelStore(env: env).save(label, items: items)
                    return finish ? "Finished labeling: \(label.notes.count) notes. A model may review the session now."
                        : "Saved a draft with \(label.notes.count) notes."
                }
            } catch {
                self.error = error.localizedDescription
            }
            busy = false
        }
    }
}

/// One numbered transcript step: user turns highlighted, tools collapsed to a line.
private struct StepRow: View {
    let item: TranscriptItem
    let selected: Bool
    let select: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Button("#\(item.id)", action: select)
                .buttonStyle(.borderless)
                .font(.callout.monospacedDigit())
                .frame(width: 44, alignment: .trailing)
                .help("Start a note at step #\(item.id)")
            content
        }
        .padding(4)
        .background(selected ? Color.accentColor.opacity(0.15) : .clear, in: RoundedRectangle(cornerRadius: 6))
        .overlay {
            if selected { RoundedRectangle(cornerRadius: 6).stroke(Color.accentColor.opacity(0.6)) }
        }
    }

    @ViewBuilder private var content: some View {
        switch item.kind {
        case .user:
            LongText(text: item.text)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
        case .assistant:
            LongText(text: item.text)
        case .thinking:
            EmptyView()
        case .toolCall(let name):
            Collapsible(title: name, icon: "wrench.and.screwdriver", tint: .teal, text: item.text, monospaced: true)
        case .toolResult(let name, let isError):
            Collapsible(title: isError ? "\(name ?? "Tool") failed" : "\(name ?? "Tool") result",
                        icon: isError ? "xmark.octagon" : "arrow.turn.down.right",
                        tint: isError ? .red : .secondary, text: item.text, monospaced: true)
        case .event(let title):
            Collapsible(title: title, icon: "info.circle", tint: .orange, text: item.text, monospaced: false)
        }
    }
}

/// A step's text, read-only; selecting part of it sets the note's quote.
struct QuotePicker: NSViewRepresentable {
    let text: String
    let onSelect: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onSelect: onSelect) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.drawsBackground = false
        if let view = scroll.documentView as? NSTextView {
            view.isEditable = false
            view.isSelectable = true
            view.drawsBackground = false
            view.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
            view.textContainerInset = NSSize(width: 4, height: 4)
            view.delegate = context.coordinator
            view.string = text
        }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.onSelect = onSelect
        if let view = scroll.documentView as? NSTextView, view.string != text { view.string = text }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var onSelect: (String) -> Void

        init(onSelect: @escaping (String) -> Void) { self.onSelect = onSelect }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            let range = view.selectedRange()
            guard range.length > 0 else { return }
            onSelect((view.string as NSString).substring(with: range).trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }
}
