import AKitFoundation
import AKitLab
import SwiftUI

/// Translate on model-written output (`docs/design/translate.md`): the Translate menu picks a
/// language, a cached translation shows at once, a new one is sent after a confirmation with
/// the translation model (Settings → Translation model). The screen shows the translated texts
/// in place of the originals, under a label with Show Original; the stored output never changes.
@MainActor @Observable
final class Translator {
    /// The confirmation before a send: what goes where and the "≈" cost, or why it can't go
    /// (`plan.refusal`, with what to do) before anything is confirmed.
    struct Pending {
        let language: LabLanguage
        let source: OutputTranslation.Source
        let plan: OutputTranslation.Plan
        let cost: String
    }

    private(set) var result: OutputTranslation.Result?
    /// The originals the result translates, by key: a text that changed since (an edited
    /// request, another run's) shows as it is.
    private var originals: [String: String] = [:]
    /// The language being translated to now.
    private(set) var busy: LabLanguage?
    var error: String?
    var pending: Pending?
    private var task: Task<Void, Never>?
    /// The processes of the running account check or call: Stop and `reset` end them
    /// (ChildProcess follows this scope, not Task cancellation), as Ask AKit's Stop does.
    private var scope: Cancellation.Scope?
    /// Bumped by `reset` and Stop: a call that ends after it is dropped.
    private var generation = 0

    /// The translation of a text, else the original.
    func text(_ key: String, _ original: String) -> String {
        guard let result, originals[key] == original else { return original }
        return result.text(key, original: original)
    }

    /// Picks a language: the cached translation, else the confirmation. `source` runs off the
    /// main actor (it may read a transcript for its origin).
    func translate(to language: LabLanguage, source: @escaping @Sendable () -> OutputTranslation.Source?) {
        guard busy == nil else { return }
        error = nil
        busy = language
        let generation = generation
        let scope = Cancellation.Scope()
        self.scope = scope
        task = Task {
            // The cache first; else the plan: the account checks and the policy for the
            // translation model, then for the output's own model (a review's Pi model). Nothing
            // is sent before the confirmation.
            enum Found: Sendable {
                case nothing
                case cached(OutputTranslation.Source, OutputTranslation.Result)
                case plan(OutputTranslation.Source, OutputTranslation.Plan, String)
            }
            let found: Found
            do {
                found = try await Task.detached {
                    try await Cancellation.$scope.withValue(scope) { () -> Found in
                        guard let source = source(), !source.isEmpty else { return .nothing }
                        let env = HarnessEnvironment.current
                        let agent = OutputTranslation.agent(settings: LabSettings.load(env: env))
                        if let cached = OutputTranslation.cached(source, to: language, configured: agent) { return .cached(source, cached) }
                        let plan = try await OutputTranslation.plan(source, configured: agent, env: env)
                        if scope.isCancelled { throw CancellationError() }
                        let estimate = SendLog.estimate(characters: source.characters, purpose: OutputTranslation.purpose,
                                                        harness: plan.agent.harness, model: plan.agent.model, records: SendLog.records(env: env))
                        let cost = estimate.map { $0 < 0.01 ? "≈ under $0.01" : String(format: "≈ $%.2f", $0) }
                            ?? "no estimate yet (no recorded calls of this model)"
                        return .plan(source, plan, cost)
                    }
                }.value
            } catch {
                guard generation == self.generation else { return }
                busy = nil
                self.scope = nil
                if !(error is CancellationError) { self.error = error.localizedDescription }
                return
            }
            guard generation == self.generation else { return }
            busy = nil
            self.scope = nil
            switch found {
            case .nothing: error = "There is no text to translate."
            case .cached(let source, let result): show(result, of: source)
            case .plan(let source, let plan, let cost): pending = Pending(language: language, source: source, plan: plan, cost: cost)
            }
        }
    }

    /// The confirmation's Translate: the call, in a scope Stop ends.
    func send() {
        guard let pending, let gate = pending.plan.gate else { return }
        self.pending = nil
        busy = pending.language
        let generation = generation
        let scope = Cancellation.Scope()
        self.scope = scope
        task = Task {
            do {
                let result = try await Task.detached {
                    try await Cancellation.$scope.withValue(scope) {
                        try await OutputTranslation.translate(pending.source, to: pending.language, agent: pending.plan.agent,
                                                              own: pending.plan.isOwnModel, gate: gate, env: .current)
                    }
                }.value
                guard generation == self.generation else { return }
                show(result, of: pending.source)
            } catch {
                guard generation == self.generation else { return }
                if !(error is CancellationError) { self.error = error.localizedDescription }
            }
            busy = nil
            self.scope = nil
        }
    }

    /// Stop: ends the running account check or call; nothing shows from it.
    func stop() {
        generation += 1
        scope?.cancel()
        scope = nil
        task?.cancel()
        task = nil
        busy = nil
    }

    func showOriginal() {
        result = nil
        originals = [:]
        error = nil
    }

    /// Another output in the same view: its own originals, nothing waiting.
    func reset() {
        stop()
        pending = nil
        showOriginal()
    }

    private func show(_ result: OutputTranslation.Result, of source: OutputTranslation.Source) {
        self.result = result
        originals = Dictionary(source.parts.map { ($0.key, $0.text) }, uniquingKeysWith: { first, _ in first })
    }
}

/// The Translate menu: the languages and Show Original, with the confirmation before a send.
/// `id` names the output: when it changes, the translation of the last one goes.
struct TranslateMenu: View {
    let translator: Translator
    let id: String
    let source: @Sendable () -> OutputTranslation.Source?

    var body: some View {
        Menu {
            ForEach(LabLanguage.allCases, id: \.self) { language in
                Button(language.name) { translator.translate(to: language, source: source) }
            }
            Divider()
            Button("Show Original") { translator.showOriginal() }
                .disabled(translator.result == nil)
        } label: {
            Label("Translate", systemImage: "globe")
        }
        .fixedSize()
        .disabled(translator.busy != nil)
        .help("Show this model-written text in another language, with the translation model (Settings → Translation model). The original stays as it is.")
        .onChange(of: id) { translator.reset() }
        .confirmationDialog(title, isPresented: Binding(get: { translator.pending != nil }, set: { if !$0 { translator.pending = nil } })) {
            if translator.pending?.plan.gate != nil {
                Button("Translate") { translator.send() }
                Button("Cancel", role: .cancel) { translator.pending = nil }
            } else {
                Button("OK", role: .cancel) { translator.pending = nil }
            }
        } message: {
            if let pending = translator.pending {
                if let refusal = pending.plan.refusal {
                    Text(refusal + " To translate it, add a destination in Settings → Sending policy (Add Destination…), "
                         + "or pick a model the policy allows in Settings → Translation model.")
                } else {
                    let model = OutputTranslation.label(pending.plan.agent, own: pending.plan.isOwnModel, source: pending.source)
                    Text("Sends \(characters(pending.source.characters)) of this output to \(model) · \(pending.plan.agent.effort): \(pending.cost). "
                         + (pending.plan.isOwnModel
                            ? "The sending policy doesn't let it go to the translation model, so \(pending.source.ownAgentName) translates it: it got this data already. "
                            : "")
                         + "The monthly limit applies. The translation is kept next to the output, so showing it again costs nothing.")
                }
            }
        }
    }

    private var title: String {
        guard let pending = translator.pending else { return "Translate?" }
        return pending.plan.gate == nil ? "Can't translate to \(pending.language.name)" : "Translate to \(pending.language.name)?"
    }

    private func characters(_ count: Int) -> String {
        count < 1000 ? "about \(count) characters" : "about \(count / 1000)K characters"
    }
}

/// Settings → Translation model: the harness, model and effort Translate uses, kept in
/// `~/.akit/lab/settings.json` (`akit translate model` sets it too). Unset: Claude Code · haiku.
struct TranslationModelSection: View {
    @Environment(AppModel.self) private var model
    @Binding var lab: LabSettings
    @State private var models: [String] = []

    /// As stored: an empty Claude Code model shows the prompt (haiku) while typing.
    private var agent: LabAgent { lab.translationAgent ?? OutputTranslation.defaultAgent }

    var body: some View {
        Section {
            Picker("Harness", selection: Binding(get: { agent.harness }, set: { harness in
                guard harness != agent.harness else { return }
                // A small model of the harness: haiku for Claude Code, Pi's default otherwise.
                let small = harness == OutputTranslation.defaultAgent.harness ? OutputTranslation.defaultAgent.model : ""
                let effort = harness.efforts.contains(OutputTranslation.defaultAgent.effort) ? OutputTranslation.defaultAgent.effort : harness.efforts[0]
                set(LabAgent(harness: harness, model: small, effort: effort, mode: .call))
            })) {
                ForEach(model.labHarnesses, id: \.self) { Text($0.title).tag($0) }
            }
            HStack {
                TextField("Model", text: Binding(get: { agent.model }, set: { name in
                    var changed = agent
                    changed.model = name.trimmingCharacters(in: .whitespaces)
                    set(changed)
                }), prompt: Text(agent.harness == .pi ? "Pi's default" : "haiku"))
                Menu("Models") {
                    ForEach(models, id: \.self) { name in
                        Button(name) {
                            var changed = agent
                            changed.model = name
                            set(changed)
                        }
                    }
                }
                .fixedSize()
                .disabled(models.isEmpty)
                .help(agent.harness == .pi ? "Models Pi has credentials for (pi --list-models)" : "Claude Code model aliases")
            }
            Picker(agent.harness == .pi ? "Thinking" : "Effort", selection: Binding(get: { agent.effort }, set: { effort in
                var changed = agent
                changed.effort = effort
                set(changed)
            })) {
                ForEach(agent.harness.efforts, id: \.self) { Text($0).tag($0) }
            }
            if agent != OutputTranslation.defaultAgent {
                Button("Reset to Default") { lab.translationAgent = nil }
            }
        } header: {
            Text("Translation model")
        } footer: {
            Text("Translate on reviews, notes and Ask AKit answers sends the text to this model: a small one is enough. Each translation is one call under the sending policy and the monthly limit, and is kept next to the output.")
                .foregroundStyle(.secondary)
        }
        .task(id: agent.harness) {
            models = []
            let harness = agent.harness
            let found = await model.labModels(for: harness)
            if agent.harness == harness { models = found }
        }
    }

    /// The default is stored as nil; Claude Code with no model uses haiku.
    private func set(_ agent: LabAgent) {
        lab.translationAgent = agent == OutputTranslation.defaultAgent ? nil : agent
    }
}

/// Above translated text: what it is and the way back; the progress and a refusal too.
struct TranslationNote: View {
    let translator: Translator

    var body: some View {
        if let language = translator.busy {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Translating to \(language.name)…").foregroundStyle(.secondary)
                Button("Stop") { translator.stop() }
                    .controlSize(.small)
                    .help("Stop the account check or the model call; nothing is shown from it")
            }
            .font(.callout)
        } else if let error = translator.error {
            Label(error, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.red)
                .font(.callout)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        } else if let result = translator.result {
            HStack(spacing: 8) {
                Label(result.label, systemImage: "globe")
                    .foregroundStyle(.blue)
                    .help("Translated on \(result.createdAt.formatted(date: .abbreviated, time: .shortened)). The original is unchanged.")
                Button("Show Original") { translator.showOriginal() }
                    .controlSize(.small)
            }
            .font(.callout)
        }
    }
}
