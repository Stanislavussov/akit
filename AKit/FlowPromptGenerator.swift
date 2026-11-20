import AKitFlows
import AKitFoundation
import AKitLab
import SwiftUI

/// Generate… on a step card: Pi writes or changes the step's prompt from the user's request and
/// the flow (`FlowPromptWriter`), in one model call with the sending policy, scrub and send log
/// (`ModelCall`). The new prompt lands in the draft; Save writes it, Undo on the card brings the
/// old one back.
struct FlowPromptGenerator: View {
    let flow: Flow
    let step: String
    let models: [String]
    let apply: (String) -> Void
    @State private var request = ""
    @State private var model: String
    /// Pi's --thinking for the call; writing a prompt needs little.
    @State private var reasoning = "low"
    @State private var running: Task<Void, Never>?
    @State private var problem: String?

    init(flow: Flow, step: String, models: [String], apply: @escaping (String) -> Void) {
        self.flow = flow
        self.step = step
        self.models = models
        self.apply = apply
        _model = State(initialValue: flow.step(step)?.model ?? models.first ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Generate the Instructions").font(.headline)
            Text("Pi writes the step's instructions from your request and the flow. They land in the card; Save keeps them.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            TextField("What should the step do, or what to change? Empty: make it shorter and clearer",
                      text: $request, axis: .vertical)
                .lineLimit(3...6)
                .textFieldStyle(.roundedBorder)
            PiModelPicker(selection: $model, models: models, empty: "Choose a model",
                          help: "The model that writes the instructions (pi --list-models)", allowsOther: false) { Text("Model") }
            Picker("Reasoning", selection: $reasoning) {
                ForEach(FlowTemplates.thinkingLevels, id: \.self) { Text($0).tag($0) }
            }
            .fixedSize()
            .help("How much the model reasons while it writes the instructions (pi --thinking)")
            if let problem {
                Label(problem, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                if running != nil {
                    ProgressView().controlSize(.small)
                    Button("Cancel") { running?.cancel() }
                } else {
                    Button("Generate") { start() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(model.isEmpty)
                }
            }
        }
        .padding(12)
        .frame(width: 400)
    }

    private func start() {
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
            } catch is CancellationError {
            } catch {
                problem = error.localizedDescription
            }
        }
    }

    /// The gate, the scrub check and the call. A prompt the scrub would change is not sent: the
    /// masked text would come back into the flow.
    private nonisolated static func call(input: String, agent: LabAgent) async throws -> String {
        let env = HarnessEnvironment.current
        let gate = try await SendGate.open(agent: agent, env: env)
        guard gate.scrub(input).text == input, gate.scrub(FlowPromptWriter.system).text == FlowPromptWriter.system else {
            throw FlowPromptWriter.Failure(message: "The send scrub would mask parts of the prompt, and the answer would bring the masked text back. AKit doesn't send it: edit the prompt by hand.")
        }
        let folder = FileManager.default.temporaryDirectory.appending(path: "akit-flow-prompt-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        return try await Cancellation.followingTask {
            try await ModelCall.run(
                ModelCall.Request(agent: agent, purpose: "flow prompt", system: FlowPromptWriter.system, input: input,
                                  schema: FlowPromptWriter.schema, origin: .code(.pi)),
                gate: gate, folder: folder, env: env).text
        }
    }
}
