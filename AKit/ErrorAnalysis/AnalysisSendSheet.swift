import AKitErrorAnalysis
import AKitFoundation
import AKitLab
import SwiftUI

/// One analysis model call (clustering, retro-matching, pairing, first modes, similar
/// cases): the model to send to and the "≈" cost first, then the call off the main thread
/// with a progress line. A refused send comes back as an error with the policy's reason.
struct AnalysisSend: Identifiable {
    let id = UUID()
    let title: String
    /// What goes out, in one sentence.
    let detail: String
    let characters: Int
    /// The model that must answer (a mode's judge); nil: the user picks one.
    var fixedAgent: LabAgent? = nil
    /// The call; returns the message for the screen.
    let work: @Sendable (LabAgent, SendGate, HarnessEnvironment) async throws -> String?
}

private extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}

struct AnalysisSendSheet: View {
    @Environment(AnalysisModel.self) private var analysis
    @Environment(\.dismiss) private var dismiss
    let send: AnalysisSend
    @State private var harness: LabHarness = .claudeCode
    @State private var modelName = ""
    @State private var effort = "high"
    @State private var records: [SendRecord] = []
    @State private var error: String?
    @State private var busy = false

    private var agent: LabAgent {
        send.fixedAgent ?? LabAgent(harness: harness, model: modelName.trimmingCharacters(in: .whitespaces), effort: effort, mode: .call)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(send.title).font(.title2.bold())
            Text(send.detail)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let fixed = send.fixedAgent {
                Label("The mode's judge answers: \(fixed.label).", systemImage: "person.badge.shield.checkmark")
                    .font(.callout)
            } else {
                Form {
                    ReviewAgentFields(harness: $harness, modelName: $modelName, effort: $effort)
                }
                .formStyle(.grouped)
                .scrollDisabled(true)
                .scrollContentBackground(.hidden)
                .frame(height: 150)
            }
            Text("\(AnalysisText.size(send.characters).capitalizedFirst) to \(agent.label): \(AnalysisText.cost(characters: send.characters, agent: agent, records: records)).")
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            Text("The sending policy in Settings → Lab decides whether it may go there; the monthly limit applies.")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
                    .font(.callout)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                if busy {
                    ProgressView().controlSize(.small)
                    Text("Waiting for the model…").font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction).disabled(busy)
                Button("Send", action: start)
                    .keyboardShortcut(.defaultAction)
                    .disabled(busy || (agent.harness == .claudeCode && agent.model.isEmpty))
            }
        }
        .padding(20)
        .frame(width: 540)
        .interactiveDismissDisabled(busy)
        .task {
            let env = analysis.env
            records = await Task.detached { SendLog.records(env: env) }.value
        }
    }

    private func start() {
        busy = true
        error = nil
        let agent = agent
        let work = send.work
        Task {
            do {
                try await analysis.run { env in
                    let gate = try await SendGate.open(agent: agent, env: env)
                    return try await work(agent, gate, env)
                }
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
            busy = false
        }
    }
}
