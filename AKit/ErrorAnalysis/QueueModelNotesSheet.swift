import AKitErrorAnalysis
import AKitFoundation
import AKitLab
import SwiftUI

/// Queues the model's notes on every labeled bootstrap session as one batch in the Lab
/// (`akit analysis bootstrap notes`): each session with inclusion 1, not a sample.
struct QueueModelNotesSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(AnalysisModel.self) private var analysis
    @Environment(\.dismiss) private var dismiss
    @State private var harness: LabHarness = .claudeCode
    @State private var modelName = ""
    @State private var effort = "high"
    @State private var error: String?
    @State private var busy = false

    private var labeled: [BootstrapReservations.Entry] { analysis.data.reservations.filter { $0.labeledAt != nil } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Queue Model Notes").font(.title2.bold())
            Text("One batch in the Lab over your \(labeled.count) labeled sessions: for each, the model writes notes, the verifier checks them and matching routes them to modes. Then pair the model's notes with yours to measure its recall.")
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
            Text("Transcripts go out under the sending policy in Settings → Lab; the monthly limit applies.")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let error {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red).font(.callout)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Queue \(labeled.count) Sessions", action: queue)
                    .keyboardShortcut(.defaultAction)
                    .disabled(busy || labeled.isEmpty || (harness == .claudeCode && modelName.trimmingCharacters(in: .whitespaces).isEmpty))
            }
        }
        .padding(20)
        .frame(width: 520)
    }

    private func queue() {
        busy = true
        error = nil
        let agent = LabAgent(harness: harness, model: modelName.trimmingCharacters(in: .whitespaces), effort: effort, mode: .call)
        let sessions = labeled.map { (key: $0.sessionKey, file: $0.transcript) }
        Task {
            do {
                let run = try await model.queueBootstrapNotes(sessions, agent: agent, environment: nil)
                analysis.message = "Queued \(run.spec.title) in the Lab."
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
            busy = false
        }
    }
}
