import AKitKnowledge
import AKitReview
import SwiftUI

/// "Missing in the knowledge base" of one run (`ReviewKnowledgeGaps`): searches with no answer,
/// gaps the passes reported about the base, notes the review used without a description. Each
/// row proposes a note or a description to the base's Inbox; the person accepts it there.
struct ReviewKnowledgeGapsSection: View {
    let gaps: [ReviewKnowledgeGap]
    let run: String
    /// The base the run read (`knowledgeBasePath`); nil: the run read none.
    let base: URL?
    @State private var proposing: ReviewKnowledgeGap?
    @State private var proposed: Set<String> = []

    var body: some View {
        if !gaps.isEmpty {
            DisclosureGroup("Missing in the knowledge base (\(gaps.count))") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("What the review looked for in the knowledge base and didn't find, and the notes it used without a description "
                         + "(agents read that one line first and open a note only when they need it). Propose a note: it waits in the "
                         + "base's Inbox until you accept it.")
                        .font(.caption).foregroundStyle(.secondary)
                    ForEach(gaps) { gap in
                        HStack(alignment: .firstTextBaseline) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(Self.title(gap)).fontWeight(.medium)
                                if !gap.why.isEmpty { Text(gap.why).font(.caption).foregroundStyle(.secondary) }
                                Text(([gap.area.map { "area \($0)" }].compactMap { $0 } + ["by \(gap.passes.joined(separator: ", "))"])
                                    .joined(separator: " · "))
                                    .font(.caption2).foregroundStyle(.tertiary)
                            }
                            Spacer()
                            if proposed.contains(gap.id) {
                                Label("In the Inbox", systemImage: "tray.and.arrow.down").font(.caption).foregroundStyle(.secondary)
                            } else {
                                Button(gap.kind == .noDescription ? "Propose Description…" : "Propose Note…") { proposing = gap }
                                    .disabled(base == nil)
                                    .help(base == nil ? "The run read no knowledge base." : "A proposal for the base's Inbox: nothing changes until you accept it there")
                            }
                        }
                    }
                }
                .padding(.top, 4)
            }
            // Snapshots: `--tab kb-propose` opens the sheet of the first gap that asks for a new note.
            .onChange(of: gaps, initial: true) {
                if DebugSnapshot.options?.tab == "kb-propose", proposing == nil { proposing = gaps.first { $0.kind != .noDescription } }
            }
            .sheet(item: $proposing) { gap in
                if let base {
                    ReviewKnowledgeProposeSheet(gap: gap, run: run, base: base) { proposed.insert(gap.id) }
                }
            }
        }
    }

    static func title(_ gap: ReviewKnowledgeGap) -> String {
        switch gap.kind {
        case .search: "No answer for “\(gap.subject)”"
        case .reported: gap.subject
        case .noDescription: "\(gap.subject) has no description"
        }
    }
}

/// One proposal from a review's gap: a new note (area, name, description, text) or a
/// `description:` for a note without one. It goes to the base's Inbox with the run in its reason.
struct ReviewKnowledgeProposeSheet: View {
    @Environment(\.dismiss) private var dismiss
    let gap: ReviewKnowledgeGap
    let run: String
    let base: URL
    let done: () -> Void
    @State private var area = ""
    @State private var name = ""
    @State private var description = ""
    @State private var text = ""
    @State private var areas: [String] = []
    @State private var problem: String?

    private var isNew: Bool { gap.kind != .noDescription }
    private var canPropose: Bool {
        let filled = { (value: String) in !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        return filled(description) && (!isNew || (filled(area) && filled(name)))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                Section {
                    Text(ReviewKnowledgeGapsSection.title(gap)).fontWeight(.medium)
                    if !gap.why.isEmpty { Text(gap.why).font(.caption).foregroundStyle(.secondary) }
                }
                if isNew {
                    Picker(selection: $area) {
                        Text("Choose an area…").tag("")
                        ForEach(areas, id: \.self) { Text($0).tag($0) }
                    } label: { RequiredLabel("Area") }
                    TextField(text: $name, prompt: Text("e.g. refund-webhook")) { RequiredLabel("Note name") }
                } else {
                    LabeledContent("Note", value: gap.subject)
                }
                TextField(text: $description, prompt: Text("one line: what the note is about")) { RequiredLabel("Description") }
                if isNew {
                    Section("Text") {
                        TextEditor(text: $text).font(.body.monospaced()).frame(minHeight: 140)
                    }
                }
                if let problem {
                    Text(problem).font(.caption).foregroundStyle(.red)
                }
            }
            .formStyle(.grouped)
            HStack {
                Text("* Required.").font(.caption).foregroundStyle(.red)
                Text("The proposal waits in the knowledge base's Inbox; nothing changes until you accept it there.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Propose") { propose() }.keyboardShortcut(.defaultAction).disabled(!canPropose)
            }
            .padding()
        }
        .frame(width: 560, height: isNew ? 560 : 320)
        .onAppear {
            let knowledge = KnowledgeBase(root: base)
            areas = knowledge.areas().map(\.name).sorted()
            if let suggested = gap.area, areas.contains(suggested) { area = suggested }
            text = ReviewKnowledgeGaps.draftBody(gap)
        }
    }

    private func propose() {
        let knowledge = KnowledgeBase(root: base)
        guard KnowledgeBase.isBase(knowledge.root) else {
            problem = "\(base.path) has no git, so it can only be read: a proposal needs a base (akit kb init --base PATH)."
            return
        }
        let line = description.trimmingCharacters(in: .whitespacesAndNewlines)
        let note = isNew ? "\(area)/\(name.trimmingCharacters(in: .whitespacesAndNewlines))" : gap.subject
        let draft = KnowledgeInbox.Draft(.note(note, body: isNew ? text : "", set: [.init(key: "description", value: line)]),
                                         reason: ReviewKnowledgeGaps.reason(gap, run: run), author: "akit-review")
        do {
            _ = try knowledge.propose(draft)
            done()
            dismiss()
        } catch {
            problem = error.message
        }
    }
}
