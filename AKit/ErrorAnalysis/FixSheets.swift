import AKitErrorAnalysis
import AKitFoundation
import SwiftUI

/// `akit analysis fix draft`: the layer, the text, exemplar notes, the expected observable
/// change and the "helped" criterion, written before any run.
struct FixDraftSheet: View {
    @Environment(AnalysisModel.self) private var analysis
    @Environment(\.dismiss) private var dismiss
    let mode: Mode
    @State private var layer: FixDraft.Layer
    @State private var skillName: String
    @State private var text: String
    @State private var expected: String
    @State private var helped: String
    @State private var exemplars: Set<NoteRef>
    @State private var error: String?
    @State private var busy = false

    init(mode: Mode, draft: FixDraft?) {
        self.mode = mode
        _layer = State(initialValue: draft?.layer ?? .claudeMD)
        _skillName = State(initialValue: draft?.skillName ?? "")
        _text = State(initialValue: draft?.text ?? "")
        _expected = State(initialValue: draft?.expectedChange ?? "")
        _helped = State(initialValue: draft?.helpedCriterion
            ?? "P(after < before) ≥ 0.95 on the mode's check, 15+ sessions a side, and no more than 50% that it got worse.")
        _exemplars = State(initialValue: Set(draft?.exemplars ?? []))
    }

    private var routed: [NoteRef] { (analysis.data.seenByMode[mode.id] ?? []).sorted() }

    private var canSave: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !expected.trimmingCharacters(in: .whitespaces).isEmpty
            && !helped.trimmingCharacters(in: .whitespaces).isEmpty && (layer != .skill || !skillName.trimmingCharacters(in: .whitespaces).isEmpty)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Fix for \(mode.name)").font(.title2.bold())
            Text("Write it down before any run, with what should change in transcripts and when it counts as helped. You apply it; AKit never changes your setup.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if mode.fix == .applied || mode.fixAppliedAt != nil {
                Label("Saving moves the fix back to draft and clears T.", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .font(.callout)
            }
            HStack {
                Picker("Layer", selection: $layer) {
                    ForEach(FixDraft.Layer.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .fixedSize()
                if layer == .skill {
                    TextField("Skill folder", text: $skillName, prompt: Text("skill folder, e.g. build-before-done"))
                        .textFieldStyle(.roundedBorder)
                }
            }
            if layer.patchFile(skillName: skillName.isEmpty ? nil : skillName) == nil {
                Text("A \(layer.title.lowercased()) can't be tried on control tasks; only production signals will judge it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            field("Text") {
                TextEditor(text: $text)
                    .font(.callout)
                    .frame(height: 100)
                    .padding(4)
                    .background(.background, in: RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
            }
            field("Expected change in transcripts") {
                TextField("Expected change", text: $expected, prompt: Text("what you should see once it works"), axis: .vertical)
                    .lineLimit(2...3)
                    .textFieldStyle(.roundedBorder)
                    .labelsHidden()
            }
            field("Helped when") {
                TextField("Helped when", text: $helped, axis: .vertical)
                    .lineLimit(2...3)
                    .textFieldStyle(.roundedBorder)
                    .labelsHidden()
            }
            Text("Exemplar notes (\(exemplars.count) of \(routed.count) routed here)").font(.headline)
            List(routed, id: \.self) { ref in
                Toggle(isOn: Binding(get: { exemplars.contains(ref) }, set: { on in
                    if on { exemplars.insert(ref) } else { exemplars.remove(ref) }
                })) {
                    PoolNoteView(ref: ref, data: analysis.data)
                }
            }
            .frame(height: 170)
            if let error {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red).font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save Draft", action: save).keyboardShortcut(.defaultAction).disabled(busy || !canSave)
            }
        }
        .padding(20)
        .frame(width: 660)
    }

    private func field<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.headline)
            content()
        }
    }

    private func save() {
        busy = true
        error = nil
        let skill = skillName.trimmingCharacters(in: .whitespaces)
        let draft = FixDraft(modeID: mode.id, layer: layer, skillName: layer == .skill ? skill : nil, text: text,
                             exemplars: exemplars.sorted(), expectedChange: expected.trimmingCharacters(in: .whitespacesAndNewlines),
                             helpedCriterion: helped.trimmingCharacters(in: .whitespacesAndNewlines))
        let name = mode.name
        Task {
            do {
                try await analysis.run { env in
                    try FixStore(env: env).save(draft)
                    _ = try await ModeStore(env: env).setFix(draft.modeID, .draft)
                    return "Drafted a \(draft.layer.title.lowercased()) for \(name). Apply it yourself, then Mark Applied."
                }
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
            busy = false
        }
    }
}

/// `akit analysis fix applied [--at]`: T, the anchor of before and after.
struct MarkAppliedSheet: View {
    @Environment(AnalysisModel.self) private var analysis
    @Environment(\.dismiss) private var dismiss
    let mode: Mode
    @State private var date = Date.now
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Mark the Fix Applied").font(.title2.bold())
            Text("T: sessions that started before it count as before, the rest as after. Use the moment the change reached your setup.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            DatePicker("Applied at", selection: $date, in: ...Date.now)
            if let error { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red).font(.callout) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Mark Applied", action: save).keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 440)
    }

    private func save() {
        let id = mode.id, name = mode.name, date = date
        Task {
            do {
                try await analysis.run { env in
                    _ = try await ModeStore(env: env).setFix(id, .applied, at: date)
                    return "\(name): fix applied at \(date.formatted(date: .abbreviated, time: .shortened))."
                }
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

/// `akit analysis fix status MODE rejected --reason`.
struct RejectFixSheet: View {
    @Environment(AnalysisModel.self) private var analysis
    @Environment(\.dismiss) private var dismiss
    let mode: Mode
    @State private var reason = ""
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Reject the Fix").font(.title2.bold())
            TextField("Why", text: $reason, prompt: Text("the reason, for later"), axis: .vertical)
                .lineLimit(2...4)
                .textFieldStyle(.roundedBorder)
            if let error { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red).font(.callout) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Reject", role: .destructive, action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(reason.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 440)
    }

    private func save() {
        let id = mode.id, name = mode.name, reason = reason
        Task {
            do {
                try await analysis.run { env in
                    _ = try await ModeStore(env: env).setFix(id, .rejected, reason: reason)
                    return "\(name): fix rejected."
                }
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}
