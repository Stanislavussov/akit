import AKitFoundation
import AKitKnowledge
import AKitLab
import SwiftUI

/// Ask Pi about the note in view (K30, `KnowledgeAsk`): a chat at the bottom of the note panel.
/// Each question goes to the user's own Pi with their setup; the next one continues the same Pi
/// conversation. The panel shows the note's latest chat; New Chat starts another.
@MainActor @Observable
final class KnowledgeAskModel {
    /// The Pi model the questions use; empty: Lab's default Pi agent.
    static let modelKey = "knowledgeAsk.model"
    /// Destinations (`pi|provider`) "Don't ask again" was ticked for.
    static let skipConfirmKey = "knowledgeAsk.dontConfirmDestinations"

    /// The confirmation before the first send to a destination in this launch.
    struct Consent {
        let key: String
        let destination: String
        let answer: CheckedContinuation<Bool, Never>
    }

    /// Snapshots: `--tab knowledge-ask` opens the panel with a made-up chat.
    var isOpen = DebugSnapshot.options?.tab == "knowledge-ask"
    /// The note the panel is about.
    private(set) var note: KnowledgeAsk.Note?
    private(set) var chat: KnowledgeAsk.Chat?
    private(set) var entries: [KnowledgeAsk.Entry] = []
    var draft = ""
    /// The passage the next question is about (Ask Pi About This Section, or the selection in Edit).
    var passage: String?
    /// The question being answered now, and what Pi does.
    private(set) var asking: (question: String, passage: String?)?
    private(set) var step = ""
    /// A refusal before anything was asked (no Pi, the sending policy, not confirmed).
    var problem: String?
    private(set) var consent: Consent?
    private var confirmed = Set<String>()
    private var scope: Cancellation.Scope?
    /// Where "Open in Pi" opened, for one line under the header.
    private(set) var openedIn: String?

    var isRunning: Bool { asking != nil }

    /// The agent: the chosen Pi model, else Lab's default Pi agent.
    var agent: LabAgent {
        let fallback = LabRuns.defaultAgent(.pi, env: .current)
        let chosen = (UserDefaults.standard.string(forKey: Self.modelKey) ?? "").trimmingCharacters(in: .whitespaces)
        return LabAgent(harness: .pi, model: chosen.isEmpty ? fallback.model : chosen, effort: fallback.effort)
    }

    /// Shows the panel for `note`, with its latest chat.
    func show(_ note: KnowledgeAsk.Note) {
        if DebugSnapshot.options?.tab == "knowledge-ask" {
            self.note = note
            entries = Self.cannedChat
            return
        }
        guard note != self.note else { return }
        if isRunning { stop() }
        self.note = note
        chat = KnowledgeAsk.latestChat(note: note.id, base: note.base, env: .current)
        entries = chat.map(KnowledgeAsk.entries) ?? []
        (passage, problem, openedIn) = (nil, nil, nil)
    }

    func newChat() {
        stop()
        (chat, entries, draft, passage, problem, openedIn) = (nil, [], "", nil, nil, nil)
    }

    func stop() {
        scope?.cancel()
        answerConsent(send: false, dontAskAgain: false)
    }

    /// Sends the draft (and the passage) about the note: a new chat on the first question.
    func send(noteText: String, cwd: URL) {
        let question = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let note, !question.isEmpty, !isRunning else { return }
        let passage = passage
        let agent = agent
        let env = HarnessEnvironment.current
        let scope = Cancellation.Scope()
        self.scope = scope
        (asking, step, problem) = ((question, passage), "Starting Pi…", nil)
        draft = ""
        self.passage = nil
        Task {
            do {
                let chat = try self.chat ?? KnowledgeAsk.newChat(note: note, cwd: cwd, env: env)
                self.chat = chat
                let entry = try await Cancellation.$scope.withValue(scope) {
                    try await KnowledgeAsk.ask(question, passage: passage, noteText: noteText, in: chat, agent: agent, env: env,
                                               confirm: { destination in await self.confirm(destination, agent: agent) },
                                               progress: { line in Task { @MainActor in self.step = line } })
                }
                if self.chat == chat { entries.append(entry) }
            } catch {
                problem = error.localizedDescription
                // Nothing was asked: the question goes back to the field.
                if draft.isEmpty { draft = question }
                if self.passage == nil { self.passage = passage }
            }
            asking = nil
            self.scope = nil
        }
    }

    /// Open in Pi: interactive Pi in a terminal, going on from the last good answer.
    func openInPi() {
        guard let chat else { return }
        let agent = agent
        Task {
            do {
                let script = try KnowledgeAsk.openScript(chat, agent: agent, env: .current)
                openedIn = try await Launcher.openInteractive(script: script, folder: URL(filePath: chat.cwd, directoryHint: .isDirectory),
                                                              title: "Ask Pi: \(chat.note.title)", env: .current)
            } catch {
                problem = error.localizedDescription
            }
        }
    }

    var canOpenInPi: Bool { entries.contains(where: \.isGood) && !isRunning && chat != nil }

    // MARK: - Consent

    private func confirm(_ destination: SendDestination, agent: LabAgent) async -> Bool {
        let key = "\(destination.harness.rawValue)|\(destination.provider)"
        if confirmed.contains(key) || (UserDefaults.standard.stringArray(forKey: Self.skipConfirmKey) ?? []).contains(key) { return true }
        guard isOpen else { return false }
        let label = "Pi · \(agent.model.isEmpty ? "default model" : agent.model) · \(destination.label)"
        return await withCheckedContinuation { answer in consent = Consent(key: key, destination: label, answer: answer) }
    }

    func answerConsent(send: Bool, dontAskAgain: Bool) {
        guard let consent else { return }
        self.consent = nil
        if send {
            confirmed.insert(consent.key)
            if dontAskAgain {
                let defaults = UserDefaults.standard
                defaults.set(Array(Set(defaults.stringArray(forKey: Self.skipConfirmKey) ?? []).union([consent.key])).sorted(),
                             forKey: Self.skipConfirmKey)
            }
        }
        consent.answer.resume(returning: send)
    }

    /// What `--tab knowledge-ask` snapshots print.
    var manifest: [String] {
        ["ask pi: \(note?.id ?? "-"), model \(agent.model.isEmpty ? "default" : agent.model), \(entries.count) answer\(entries.count == 1 ? "" : "s")"
            + (passage.map { ", passage \($0.count) characters" } ?? "")]
            + entries.map { "ask pi \($0.id): \($0.question)" + ($0.passage == nil ? "" : " (passage)") + " → " + ($0.answer.map { "\($0.count) characters" } ?? $0.error ?? "-") }
    }

    /// A made-up chat about the sample base's orders-api (snapshots, guide screenshots).
    static let cannedChat: [KnowledgeAsk.Entry] = [
        KnowledgeAsk.Entry(id: "q1", question: "Which services read the order created event?", passage: nil,
                           asked: Date(timeIntervalSince1970: 1_761_900_000), answered: Date(timeIntervalSince1970: 1_761_900_040),
                           answer: """
                               Two services read **order created**:

                               - `billing` makes the invoice (the arrow *events* on the map `overview`).
                               - `warehouse` in the space `logistics` reserves the goods.

                               Source: `akit kb search "order created"` and the note `payments/order-events`.
                               """, error: nil, session: "demo-1"),
        KnowledgeAsk.Entry(id: "q2", question: "What happens when billing is down?", passage: "## Events\n- order created\n- retry after 5 min",
                           asked: Date(timeIntervalSince1970: 1_761_900_100), answered: Date(timeIntervalSince1970: 1_761_900_150),
                           answer: "orders-api keeps the event and sends it again after 5 minutes (the *retry* line of this section). Nothing is lost while billing is down.",
                           error: nil, session: "demo-2"),
    ]
}

/// The Ask Pi panel under the note: header, messages, the field.
struct KnowledgeAskPanel: View {
    @Environment(KnowledgeModel.self) private var model
    @Environment(AppModel.self) private var app
    @AppStorage(KnowledgeAskModel.modelKey) private var modelName = ""
    @State private var models: [String] = []
    @State private var dontAskAgain = false
    @FocusState private var inputFocused: Bool

    private var ask: KnowledgeAskModel { model.ask }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        if ask.entries.isEmpty, !ask.isRunning {
                            Text("Ask your Pi about this note: what it means, who uses it, what's missing. Pi runs with your own setup (MCP servers, skills like /akit-context), so it can look things up in the base and in other systems. It reads only; it doesn't change files. The next question continues the same conversation.")
                                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                        ForEach(ask.entries) { entry in
                            question(entry.question, passage: entry.passage)
                            if let answer = entry.answer {
                                MarkdownText(text: answer).textSelection(.enabled)
                            }
                            if let error = entry.error {
                                Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.callout)
                                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        if let asking = ask.asking {
                            question(asking.question, passage: asking.passage)
                            HStack(spacing: 6) {
                                ProgressView().controlSize(.small)
                                Text(ask.step).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                            }
                            .id("running")
                        }
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: ask.entries.count, initial: true) { proxy.scrollTo(ask.entries.last?.id, anchor: .bottom) }
                .onChange(of: ask.isRunning) { if ask.isRunning { proxy.scrollTo("running", anchor: .bottom) } }
            }
            Divider()
            footer
        }
        .frame(minHeight: 160, idealHeight: 280)
        .confirmationDialog("Send to Pi?", isPresented: Binding(get: { ask.consent != nil }, set: { if !$0 { answer(false) } }),
                            titleVisibility: .visible) {
            Button("Send") { answer(true) }
            Button("Cancel", role: .cancel) { answer(false) }
        } message: {
            Text("""
                Ask Pi sends to \(ask.consent?.destination ?? "Pi"), with the account signed in there:
                • your question;
                • the first time in a chat: the base's name and folder, the note's path and its whole text (or the passage you asked about).
                Pi runs with your own setup: it may read files and the base, run commands and call your MCP servers to answer. The sending policy and the scrub apply, and Lab → Sends logs it.
                """)
        }
        .dialogSuppressionToggle("Don't ask again", isSuppressed: $dontAskAgain)
        .onDisappear { if ask.consent != nil { answer(false) } }
        .task {
            models = await app.labModels(for: .pi)
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Label("Ask Pi about \(ask.note?.title ?? "this note")", systemImage: "bubble.left.and.text.bubble.right")
                .font(.headline).lineLimit(1)
            Spacer()
            PiModelPicker(selection: $modelName, models: models, empty: "Lab default (\(LabRuns.defaultAgent(.pi, env: .current).model.isEmpty ? "Pi's default" : LabRuns.defaultAgent(.pi, env: .current).model))",
                          help: "The Pi model that answers (pi --list-models); AKit remembers it", allowsOther: false) {
                Text("Model")
            }
            .labelsHidden()
            .fixedSize()
            .disabled(ask.isRunning)
            Button("Open in Pi", systemImage: "terminal") { ask.openInPi() }
                .disabled(!ask.canOpenInPi)
                .help("Go on with this conversation in an interactive Pi in a terminal, from Pi's last answer")
            Button("New Chat", systemImage: "square.and.pencil") { ask.newChat() }
                .disabled(ask.entries.isEmpty && !ask.isRunning)
                .help("Start a new conversation about this note; the old one stays in ~/.akit/local/knowledge-ask")
            Button("Close", systemImage: "xmark") { ask.isOpen = false }
                .labelStyle(.iconOnly)
                .help("Hide the Ask Pi panel; the chat stays (⌥⌘A shows it again)")
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    private func question(_ text: String, passage: String?) -> some View {
        VStack(alignment: .trailing, spacing: 3) {
            if let passage {
                Text(passage.split(separator: "\n").prefix(3).joined(separator: "\n"))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(3)
                    .padding(.leading, 6)
                    .overlay(alignment: .leading) { Rectangle().fill(.tertiary).frame(width: 2) }
            }
            Text(text)
                .textSelection(.enabled)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color.accentColor.opacity(0.15), in: RoundedRectangle(cornerRadius: 10))
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    private var footer: some View {
        @Bindable var ask = model.ask
        return VStack(alignment: .leading, spacing: 6) {
            if let problem = ask.problem {
                Label(problem, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.caption)
                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
            if let opened = ask.openedIn {
                Text("Opened in \(opened): Pi goes on from its last answer there.").font(.caption).foregroundStyle(.secondary)
            }
            if let passage = ask.passage {
                HStack(spacing: 6) {
                    Label("About: \(passage.split(separator: "\n").first.map(String.init) ?? passage)", systemImage: "text.quote")
                        .lineLimit(1).truncationMode(.tail)
                    Spacer(minLength: 0)
                    Button("Clear Passage", systemImage: "xmark.circle.fill") { ask.passage = nil }
                        .labelStyle(.iconOnly).buttonStyle(.borderless)
                        .help("Ask about the whole note again")
                }
                .font(.caption).foregroundStyle(.secondary)
            }
            HStack(alignment: .bottom, spacing: 8) {
                TextField("Ask Pi about this note…", text: $ask.draft, axis: .vertical)
                    .lineLimit(1...5)
                    .textFieldStyle(.roundedBorder)
                    .focused($inputFocused)
                if ask.isRunning {
                    Button("Stop", systemImage: "stop.circle") { ask.stop() }
                        .help("Stop Pi and everything it started; this answer is not continued")
                } else {
                    Button("Send", systemImage: "arrow.up.circle.fill") { send() }
                        .keyboardShortcut(.return, modifiers: .command)
                        .disabled(ask.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .help("Send the question to Pi (⌘↩)")
                }
            }
            .labelStyle(.iconOnly)
            .controlSize(.large)
            Text("Sends your question (the first time also the note) to your Pi, with its own setup and sign-in. Logged in Lab → Sends.")
                .font(.caption2).foregroundStyle(.tertiary)
        }
        .padding(10)
        .onAppear { inputFocused = true }
        .onChange(of: ask.passage) { if ask.passage != nil { inputFocused = true } }
    }

    private func send() {
        guard let cwd = model.askWorkingFolder() else { return }
        model.ask.send(noteText: model.text, cwd: cwd)
    }

    private func answer(_ send: Bool) {
        ask.answerConsent(send: send, dontAskAgain: send && dontAskAgain)
        dontAskAgain = false
    }
}
