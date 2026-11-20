import AKitFlows
import AKitFoundation
import AKitLab
import SwiftUI

/// Rewrite with Pi, under a step's instructions: the user says in their own words (any language)
/// what the step should do or what to change, and Pi rewrites the instructions in the form the
/// runner needs (`FlowPromptWriter`: what to do, when to end failed or blocked, what to hand
/// over, in English). One model call with the sending policy, scrub and send log (`ModelCall`).
/// The result lands in the field; Undo on the card brings the old text back, Save keeps it.
struct FlowInstructionsRewrite: View {
    let flow: Flow
    let step: String
    let models: [String]
    let apply: (String) -> Void
    @State private var request = ""
    @State private var model: String
    /// Pi's --thinking for the call; rewriting instructions needs little.
    @State private var reasoning = "low"
    @State private var running: Task<Void, Never>?
    @State private var problem: String?

    init(flow: Flow, step: String, models: [String], apply: @escaping (String) -> Void) {
        self.flow = flow
        self.step = step
        self.models = models
        self.apply = apply
        let own = flow.step(step).flatMap { $0.isClaudeCode ? nil : $0.model }
        _model = State(initialValue: own.flatMap { models.contains($0) ? $0 : nil } ?? models.first ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "sparkles").foregroundStyle(.secondary)
                TextField("Tell Pi what this step should do or change, in any language", text: $request)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { start() }
                    .disabled(running != nil)
                settings
                if running != nil {
                    ProgressView().controlSize(.small)
                    Button("Cancel") { running?.cancel() }
                } else {
                    Button("Rewrite with Pi") { start() }
                        .disabled(model.isEmpty)
                        .help("Pi rewrites the instructions above from your request: what to do, when to end failed or blocked, what to hand over. Empty request: shorter and clearer")
                }
            }
            if let problem {
                Label(problem, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// The model and reasoning of the rewrite, folded into one small menu.
    private var settings: some View {
        Menu {
            Picker("Model", selection: $model) {
                ForEach(models, id: \.self) { Text($0).tag($0) }
            }
            Picker("Reasoning", selection: $reasoning) {
                ForEach(FlowTemplates.thinkingLevels, id: \.self) { Text($0).tag($0) }
            }
        } label: {
            Text("\(model.split(separator: "/").last.map(String.init) ?? "no model") · \(reasoning)").font(.caption)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("The model that rewrites the instructions (pi --list-models) and how much it reasons (pi --thinking)")
    }

    private func start() {
        guard running == nil, !model.isEmpty else { return }
        problem = nil
        let input: String
        do {
            input = try FlowPromptWriter.input(flow: flow, step: step, request: request)
        } catch {
            problem = error.localizedDescription
            return
        }
        let agent = LabAgent(harness: .pi, model: model, effort: reasoning, mode: .call)
        running = Task {
            defer { running = nil }
            do {
                apply(try FlowPromptWriter.result(try await Self.call(input: input, agent: agent)))
                request = ""
            } catch is CancellationError {
            } catch {
                problem = error.localizedDescription
            }
        }
    }

    /// The gate, the scrub check and the call. Instructions the scrub would change are not sent:
    /// the masked text would come back into the flow.
    private nonisolated static func call(input: String, agent: LabAgent) async throws -> String {
        let env = HarnessEnvironment.current
        let gate = try await SendGate.open(agent: agent, env: env)
        guard gate.scrub(input).text == input, gate.scrub(FlowPromptWriter.system).text == FlowPromptWriter.system else {
            throw FlowPromptWriter.Failure(message: "The send scrub would mask parts of the instructions, and the answer would bring the masked text back. AKit doesn't send them: edit by hand.")
        }
        let folder = FileManager.default.temporaryDirectory.appending(path: "akit-flow-prompt-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        return try await Cancellation.followingTask {
            try await ModelCall.run(
                ModelCall.Request(agent: agent, purpose: "flow instructions", system: FlowPromptWriter.system, input: input,
                                  schema: FlowPromptWriter.schema, origin: .code(.pi)),
                gate: gate, folder: folder, env: env).text
        }
    }
}
