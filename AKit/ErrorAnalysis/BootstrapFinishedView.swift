import AKitErrorAnalysis
import AKitFoundation
import AKitLab
import SwiftUI

/// A labeled session: the user's notes, then the model's review of it (queued from here),
/// the model's proposed pairs and the user's confirmation of them.
struct BootstrapFinishedView: View {
    @Environment(AnalysisModel.self) private var analysis
    @Environment(AppModel.self) private var model
    let entry: BootstrapReservations.Entry
    let title: String
    @State private var showReview = false
    @State private var showNotes = false

    var body: some View {
        let data = analysis.data
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if let label = data.labels[entry.sessionKey] {
                    header(label)
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Your notes (\(label.notes.count))").font(.title3.bold())
                        if label.notes.isEmpty { Text("No problems noted.").foregroundStyle(.secondary) }
                        ForEach(label.notes) { NoteView(note: $0) }
                    }
                    modelSide(label, notes: data.notes(of: entry.sessionKey), pairing: data.pairings[entry.sessionKey])
                } else {
                    Text("The label file of this session is missing.").foregroundStyle(.secondary)
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .sheet(isPresented: $showReview) { BootstrapReviewSheet(entry: entry, title: title) }
        .sheet(isPresented: $showNotes) { QueueModelNotesSheet() }
    }

    private func header(_ label: Bootstrap.Label) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.title2.bold()).lineLimit(2)
            HStack(spacing: 8) {
                if let outcome = label.outcome { OutcomeBadge(outcome: outcome) }
                if let date = label.labeledAt {
                    Text("Labeled \(date.formatted(date: .abbreviated, time: .shortened))").foregroundStyle(.secondary)
                }
            }
            let steps = [label.deviation.decisiveStep.map { "decided about step #\($0)" },
                         label.deviation.observedStep.map { "visible about step #\($0)" }].compactMap(\.self)
            if !steps.isEmpty { Text(steps.joined(separator: " · ").capitalizedFirstLetter).foregroundStyle(.secondary) }
            Text(entry.sessionKey).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
        }
    }

    @ViewBuilder private func modelSide(_ label: Bootstrap.Label, notes: SessionNotes?, pairing: Bootstrap.Pairing?) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("The model's review").font(.title3.bold())
            if let notes {
                HStack {
                    Text("\(notes.notes.count) notes, \(notes.accepted.count) accepted by the verifier · \(Bootstrap.notesVersion(notes.notesConfig))")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button(pairing == nil ? "Propose Pairs…" : "Propose Again…", systemImage: "link") {
                        analysis.send = .pairs(label, notes: notes)
                    }
                    .help("The model pairs your notes with its own (a model call; the cost first)")
                }
            } else if let run = activeRun {
                HStack {
                    ProgressView().controlSize(.small)
                    Text("A review is \(run.status == .running ? "running" : "queued") in the Lab.").foregroundStyle(.secondary)
                    Button("Show in Lab") {
                        model.revealLabRun = run.id
                        model.section = .lab
                    }
                    .controlSize(.small)
                }
            } else {
                HStack {
                    Text("No model has reviewed this session yet. Now that you have labeled it, one may.").foregroundStyle(.secondary)
                    Spacer()
                    Button("Review with Model…", systemImage: "flask") { showReview = true }
                    Button("Queue Model Notes…") { showNotes = true }
                        .help("One Lab batch over every labeled session, instead of one review each")
                }
            }
        }
        if let notes, let pairing {
            PairingEditor(label: label, notes: notes, pairing: pairing).id(pairing)
        }
    }

    /// A review of this session queued or running in the Lab.
    private var activeRun: LabRun? {
        model.labRuns.first { $0.spec.kind == .review && $0.spec.reviewedTranscript == entry.transcript && ($0.status == .queued || $0.status == .running) }
    }
}

private extension String {
    var capitalizedFirstLetter: String { prefix(1).uppercased() + dropFirst() }
}

/// The user's notes and the model's side by side: the proposed pairs preselected, the user
/// changes them and ticks the model notes that are real problems, then confirms.
private struct PairingEditor: View {
    @Environment(AnalysisModel.self) private var analysis
    let label: Bootstrap.Label
    let notes: SessionNotes
    let pairing: Bootstrap.Pairing
    /// Human note id → model note id.
    @State private var pairs: [String: String]
    @State private var agreed: Set<String>

    init(label: Bootstrap.Label, notes: SessionNotes, pairing: Bootstrap.Pairing) {
        self.label = label
        self.notes = notes
        self.pairing = pairing
        let chosen = pairing.confirmed ?? pairing.proposed
        _pairs = State(initialValue: Dictionary(chosen.map { ($0.human, $0.model) }, uniquingKeysWith: { first, _ in first }))
        _agreed = State(initialValue: Set(pairing.agreed ?? chosen.map(\.model)))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("Pairs").font(.title3.bold())
                if pairing.isConfirmed {
                    Label("Confirmed", systemImage: "checkmark.seal").foregroundStyle(.green)
                } else {
                    Text("Proposed by the model: check them").foregroundStyle(.orange)
                }
                Spacer()
                Button(pairing.isConfirmed ? "Save Changes" : "Confirm", action: confirm)
                    .keyboardShortcut(.defaultAction)
            }
            Text("Pair a note of yours with the model's note about the same problem. Tick the model's notes you agree are real problems: recall and precision come from this.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Yours").font(.headline)
                    ForEach(label.notes) { note in
                        VStack(alignment: .leading, spacing: 6) {
                            NoteView(note: note)
                            Picker("Same problem as", selection: binding(for: note.id)) {
                                Text("None").tag("")
                                ForEach(notes.notes) { model in
                                    Text("\(model.id) · #\(model.step) · \(model.description)").lineLimit(1).tag(model.id)
                                }
                            }
                            .controlSize(.small)
                        }
                        .card()
                    }
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
                VStack(alignment: .leading, spacing: 14) {
                    Text("The model's").font(.headline)
                    ForEach(notes.notes) { note in
                        VStack(alignment: .leading, spacing: 6) {
                            NoteView(note: note)
                            Toggle("A real problem", isOn: Binding(get: { agreed.contains(note.id) }, set: { on in
                                if on { agreed.insert(note.id) } else { agreed.remove(note.id) }
                            }))
                            .controlSize(.small)
                            if let human = pairs.first(where: { $0.value == note.id })?.key {
                                Text("Paired with your \(human)").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .card()
                    }
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
    }

    /// A model note is in at most one pair: choosing it here takes it from another note.
    private func binding(for human: String) -> Binding<String> {
        Binding(get: { pairs[human] ?? "" }, set: { model in
            if model.isEmpty {
                pairs[human] = nil
            } else {
                for (other, value) in pairs where value == model { pairs[other] = nil }
                pairs[human] = model
                agreed.insert(model)
            }
        })
    }

    private func confirm() {
        var saved = pairing
        saved.confirmed = pairs.sorted { $0.key < $1.key }.map { Bootstrap.Pairing.Pair(human: $0.key, model: $0.value) }
        saved.agreed = agreed.sorted()
        let pairing = saved
        analysis.act { env in
            try Bootstrap.PairingStore(env: env).save(pairing)
            return "Confirmed \(pairing.confirmed?.count ?? 0) pairs."
        }
    }
}

/// Queues the one-call model review of a labeled session in the Lab, as the Sessions screen does.
private struct BootstrapReviewSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(AnalysisModel.self) private var analysis
    @Environment(\.dismiss) private var dismiss
    let entry: BootstrapReservations.Entry
    let title: String
    @State private var harness: LabHarness = .claudeCode
    @State private var modelName = ""
    @State private var effort = "high"
    @State private var error: String?
    @State private var busy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Review with a Model").font(.title2.bold())
            Text("A one-call review of \"\(title)\" in the Lab: notes, the verifier and matching. Then the model's notes can be paired with yours.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Form {
                ReviewAgentFields(harness: $harness, modelName: $modelName, effort: $effort)
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
            .scrollContentBackground(.hidden)
            .frame(height: 150)
            if let error {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red).font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Queue and Start", action: queue)
                    .keyboardShortcut(.defaultAction)
                    .disabled(busy || (harness == .claudeCode && modelName.trimmingCharacters(in: .whitespaces).isEmpty))
            }
        }
        .padding(20)
        .frame(width: 520)
    }

    private func queue() {
        busy = true
        error = nil
        let agent = LabAgent(harness: harness, model: modelName.trimmingCharacters(in: .whitespaces), effort: effort, mode: .call)
        Task {
            do {
                let session = model.sessions.first { $0.file.path == entry.transcript } ?? entry.summary
                _ = try await model.queueReview(of: session, agent: agent, environment: nil)
                analysis.message = "Queued a review of \"\(title)\" in the Lab."
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
            busy = false
        }
    }
}
