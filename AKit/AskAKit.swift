import AKitFoundation
import AKitHelp
import AKitLab
import SwiftUI

/// Ask AKit: a chat in a side panel that answers what something on the screen means and how
/// to use it, from AKit's guides and the screen's data (`docs/design/ask-akit.md`). Each
/// question is one model call through the chosen harness's own sign-in, with the send policy,
/// scrub, monthly limit and send log of every call (`ModelCall`). The chat is not saved.
@MainActor @Observable
final class AskAKitModel {
    struct Message: Identifiable, Hashable {
        let id = UUID()
        var role: AskTurn.Role
        var text: String
        /// The element a question was about (Ask AKit About This).
        var about: String?
        /// The guide sections an answer cites.
        var sources: [AskAKit.Source] = []
        /// An error in place of an answer: not sent as an earlier turn.
        var failed = false
        /// A question: what went out for it (What Was Sent), once the call has started.
        var sent: Sent?
    }

    /// What one question sent, as it left the Mac: the scrubbed input, the guide sections in
    /// the system prompt and its size, and where it went.
    struct Sent: Hashable {
        var destination: String
        var input: String
        var sections: [AskAKit.Source]
        var systemCharacters: Int
    }

    /// A question to send.
    struct Pending {
        var question: String
        var element: AskContext.Element?
        var screen: SidebarSection
        var inSettingsLanguage: Bool
    }

    /// The confirmation before the first send to a destination (harness and provider) in this
    /// launch: the call waits for the answer.
    struct Consent {
        /// `harness|provider`.
        let key: String
        /// The account's label (`SendDestination.label`), with the harness and model.
        let destination: String
        /// The harness's title, for the dialog's title.
        let harness: String
        let answer: CheckedContinuation<Bool, Never>
    }

    /// The agent's settings, shared with the panel's fields (`@AppStorage`).
    static let harnessKey = "ask.harness"
    static let modelKey = "ask.model"
    static let effortKey = "ask.effort"
    /// Settings → Ask before Ask AKit sends (default on); off never asks.
    static let confirmKey = "ask.confirmBeforeSend"
    /// The destinations (`harness|provider`) "Don't ask again" was ticked for; Settings clears them.
    static let skipConfirmKey = "ask.dontConfirmDestinations"
    /// Bumped by Settings when the switch is turned on again: this launch's confirmations go too.
    static let confirmResetKey = "ask.confirmResets"
    /// What Ask AKit About This asks.
    static let aboutQuestion = "What does this mean, why does it matter, and what can I do about it?"

    var isOpen = DebugSnapshot.options?.ask == true
    private(set) var messages: [Message] = []
    var draft = ""
    /// The element the next questions are about, until New Chat or the screen changes.
    var focus: AskContext.Element?
    /// The screen in view; RootView keeps it current. Another screen drops the focus.
    var section: SidebarSection = DebugSnapshot.options?.section ?? .overview {
        didSet { if oldValue != section { focus = nil } }
    }
    /// What a screen's own view shows now (`.askAKitScreen`), per screen.
    var screenFacts: [SidebarSection: String] = [:]
    /// Texts from sessions that must never go out as screen data, beyond the session titles
    /// AppModel has: RootView adds the error analysis modes' names and definitions.
    var sessionTexts: () -> [String] = { [] }
    private let app: AppModel
    /// True from a send until its task has really ended (its harness process is gone): New Chat
    /// or Stop during a call never lets a second call start beside it.
    private(set) var isRunning = false
    /// The confirmation shown now; nil when none waits.
    private(set) var consent: Consent?
    /// Destinations confirmed in this launch.
    private var confirmed = Set<String>()
    /// The Settings reset `confirmed` belongs to.
    private var confirmedReset = UserDefaults.standard.integer(forKey: confirmResetKey)
    private var call: Task<Void, Never>?
    /// The running call's processes: Stop and New Chat cancel it, which ends the harness's
    /// process (ChildProcess follows this scope, not Task cancellation).
    private var scope: Cancellation.Scope?
    /// Counts chats: an answer that arrives after New Chat is dropped.
    private var chat = 0
    /// The agent the next call runs with; `refreshAgent()` works it out again.
    private(set) var agent = LabAgent(harness: .claudeCode, model: "", effort: "")
    private var guides: [AskAKit.Guide]?
    private var search: GuideSearch?

    init(app: AppModel) {
        self.app = app
        refreshAgent()
        if DebugSnapshot.options?.ask == true {
            messages = Self.cannedChat
            focus = AskContext.Element(title: Self.cannedChat[0].about ?? "", facts: "")
        }
    }

    /// The screen in view as a question sees it.
    var screen: AskContext { context(for: section) }

    /// A screen as a question sees it: what it is for, what AKit found for it, and what its
    /// view shows now.
    func context(for section: SidebarSection) -> AskContext {
        let facts = [section.summary, appFacts(section), screenFacts[section] ?? ""].filter { !$0.isEmpty }
        return AskContext(screen: section.rawValue, screenTitle: section.title, summary: facts.joined(separator: "\n"))
    }

    /// Counts and names AKit has for a screen anyway.
    private func appFacts(_ section: SidebarSection) -> String {
        func names(_ list: [String], limit: Int = 30) -> String {
            list.prefix(limit).joined(separator: ", ") + (list.count > limit ? ", … (\(list.count - limit) more)" : "")
        }
        switch section {
        case .overview:
            return app.installations.map { "Harness: \($0.displayName) \(app.versions[$0.id] ?? ""), config \($0.configRoot.tildePath)" }
                .joined(separator: "\n")
        case .skills:
            let global = app.skills.filter { $0.scope == .global }.count
            return "Skills found: \(app.skills.count) (\(global) global)\nNames: \(names(app.skills.map(\.name)))"
        case .mcp:
            return "MCP servers found: \(app.mcpServers.count)\nNames: \(names(app.mcpServers.map(\.name)))"
        case .sessions:
            return "Saved sessions: \(app.sessions.count)"
        case .lab:
            let active = app.labRuns.filter { $0.status == .running || $0.status == .queued }.count
            return "Lab runs: \(app.labRuns.count) (\(active) running or queued)"
        case .brain:
            return app.brain == nil ? "No brain repo found at \(app.brainPath)" : "Brain repo: \(app.brainPath)"
        default:
            return ""
        }
    }

    func toggle() { isOpen.toggle() }

    /// Opens the panel and asks about `element` on `screen` (the current one by default; a
    /// sidebar item names its own). Ignored while a call runs: the menu item is off then too.
    func ask(about element: AskContext.Element, screen: SidebarSection? = nil) {
        guard !isRunning else { return }
        isOpen = true
        send(Pending(question: Self.aboutQuestion, element: element, screen: screen ?? section, inSettingsLanguage: true))
    }

    func newChat() {
        // The old call ends on its own once its process is gone; until then isRunning stays.
        stop()
        chat += 1
        messages = []
        focus = nil
        draft = ""
    }

    func stop() {
        scope?.cancel()
        call?.cancel()
        // A confirmation still open: not sent.
        answerConsent(send: false, dontAskAgain: false)
    }

    /// Whether a send to `key` (`harness|provider`) asks first.
    static func needsConsent(_ key: String, confirmedThisLaunch: Set<String>) -> Bool {
        let defaults = UserDefaults.standard
        let asks = defaults.object(forKey: confirmKey) as? Bool ?? true
        return asks && !confirmedThisLaunch.contains(key) && !(defaults.stringArray(forKey: skipConfirmKey) ?? []).contains(key)
    }

    /// The confirmation's Send or Cancel; "Don't ask again" stores the destination.
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

    /// Asks before the first send to a destination; true to send.
    private func confirm(_ destination: SendDestination, agent: LabAgent) async -> Bool {
        let key = "\(destination.harness.rawValue)|\(destination.provider)"
        let reset = UserDefaults.standard.integer(forKey: Self.confirmResetKey)
        if reset != confirmedReset {
            confirmed = []
            confirmedReset = reset
        }
        guard Self.needsConsent(key, confirmedThisLaunch: confirmed) else { return true }
        // A closed panel can't show the confirmation: not sent.
        guard isOpen else { return false }
        let label = "\(agent.harness.title) · \(agent.model.isEmpty ? "default model" : agent.model) · \(destination.label)"
        return await withCheckedContinuation { answer in
            consent = Consent(key: key, destination: label, harness: destination.harness.title, answer: answer)
        }
    }

    /// Works out the agent: the panel's choice, else Lab's default for the harness. A chosen
    /// harness that isn't installed falls back to one that is, with that one's own default
    /// model and effort (the stored model belongs to the other harness). Called when the panel
    /// opens and when its fields change, not on every redraw (it reads files).
    func refreshAgent() {
        let defaults = UserDefaults.standard
        let installed = LabHarness.allCases.filter { HarnessEnvironment.current.findExecutable($0.command) != nil }
        let chosen = LabHarness(rawValue: defaults.string(forKey: Self.harnessKey) ?? "") ?? .claudeCode
        let harness = installed.contains(chosen) ? chosen : installed.first ?? chosen
        let fallback = LabRuns.defaultAgent(harness, env: .current)
        guard harness == chosen else {
            agent = fallback
            return
        }
        let model = (defaults.string(forKey: Self.modelKey) ?? "").trimmingCharacters(in: .whitespaces)
        let effort = defaults.string(forKey: Self.effortKey) ?? ""
        agent = LabAgent(harness: harness, model: model.isEmpty ? fallback.model : model,
                         effort: harness.efforts.contains(effort) ? effort : fallback.effort)
    }

    /// Sends the draft.
    func sendDraft() {
        let question = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, !isRunning else { return }
        draft = ""
        send(Pending(question: question, element: focus, screen: section, inSettingsLanguage: false))
    }

    private func send(_ question: Pending) {
        guard !isRunning else { return }
        let element = question.element
        let about = question.element?.title
        let inSettingsLanguage = question.inSettingsLanguage
        var context = context(for: question.screen)
        context.element = question.element
        let question = question.question
        // Screen data is setup data only: no session titles (first prompts), no mode names or
        // definitions. The views send ids and numbers; this catches what a fact still quotes.
        let hidden = app.sessions.map(\.title) + self.sessionTexts()
        let history = messages.filter { !$0.failed }.map { AskTurn(role: $0.role, text: $0.text) }
        let asked = Message(role: .user, text: question, about: about)
        messages.append(asked)
        let agent = self.agent
        let chat = self.chat
        let scope = Cancellation.Scope()
        self.scope = scope
        isRunning = true
        call = Task {
            let reply: Message
            do {
                let (guides, search) = await loadGuides()
                let language = inSettingsLanguage ? LabSettings.load(env: .current).reportLanguage.name : nil
                // Off the main actor: the backstop scans every session title.
                let prepared = await Task.detached {
                    AskAKit.prepare(question: question, context: context.redacting(hidden), history: history, guides: guides,
                                    search: search, language: language)
                }.value
                if scope.isCancelled { throw CancellationError() }
                let env = HarnessEnvironment.current
                let folder = FileManager.default.temporaryDirectory.appending(path: "akit-ask-\(UUID().uuidString)")
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                defer { try? FileManager.default.removeItem(at: folder) }
                // The account check (SendAccounts runs it as a ChildProcess) and the call run
                // their processes in this call's scope: Stop ends either.
                let answer = try await Cancellation.$scope.withValue(scope) {
                    let gate = try await SendGate.open(agent: agent, env: env)
                    if scope.isCancelled { throw CancellationError() }
                    guard await confirm(gate.destination, agent: agent) else { throw NotSent() }
                    if scope.isCancelled { throw CancellationError() }
                    let destination = "\(agent.harness.title) · \(agent.model.isEmpty ? "default model" : agent.model) · \(gate.destination.label)"
                    let id = asked.id, sources = prepared.sources, system = prepared.system.count
                    // The screen's data is the user's harness setup: the chosen harness's own
                    // account is its origin, so a work Mac sends it only to an allowed destination.
                    return try await ModelCall.run(
                        ModelCall.Request(agent: agent, purpose: "ask akit", system: prepared.system, input: prepared.input,
                                          schema: AskAKit.schema, origin: .code(agent.harness)),
                        gate: gate, folder: folder, env: env,
                        // Only now does it leave: What Was Sent, and the element becomes the focus.
                        onSend: { input in
                            Task { @MainActor in
                                self.didSend(Sent(destination: destination, input: input, sections: sources, systemCharacters: system),
                                             message: id, element: element, chat: chat)
                            }
                        })
                }
                if scope.isCancelled { throw CancellationError() }
                // Reading the answer parses JSON: off the main actor.
                let raw = answer.text
                reply = await Task.detached {
                    let text = AskAKit.answer(from: raw)
                    return Message(role: .assistant, text: text, sources: AskAKit.sources(in: text, guides: guides))
                }.value
            } catch is CancellationError {
                reply = Message(role: .assistant, text: "Stopped.", failed: true)
            } catch is NotSent {
                reply = Message(role: .assistant, text: "Not sent.", failed: true)
            } catch {
                reply = Message(role: .assistant, text: error.localizedDescription, failed: true)
            }
            // Only now is the process gone: the next send may start.
            isRunning = false
            call = nil
            self.scope = nil
            guard chat == self.chat else { return }
            messages.append(reply)
        }
    }

    /// The confirmation's Cancel.
    private struct NotSent: Error {}

    /// The question went out: What Was Sent, and its element is the focus from now on.
    private func didSend(_ sent: Sent, message: UUID, element: AskContext.Element?, chat: Int) {
        guard chat == self.chat else { return }
        if let index = messages.firstIndex(where: { $0.id == message }) { messages[index].sent = sent }
        if let element { focus = element }
    }

    /// What a link in an answer may open: a section a guide has, or an https page.
    func linkTarget(_ url: URL) -> AskAKit.LinkTarget {
        AskAKit.linkTarget(url, guides: guides ?? [])
    }

    /// Every guide in the bundle and one search over them, read once.
    private func loadGuides() async -> ([AskAKit.Guide], GuideSearch) {
        if let guides, let search { return (guides, search) }
        let loaded = await Task.detached {
            let documents = Dictionary(uniqueKeysWithValues: Guide.allCases.compactMap { guide in guide.load().map { (guide, $0) } })
            let guides: [AskAKit.Guide] = Guide.allCases.compactMap { guide in documents[guide].map { (guide.rawValue, guide.title, $0) } }
            return (guides, Guide.searchIndex(documents))
        }.value
        guides = loaded.0
        search = loaded.1
        return loaded
    }

    /// `make snapshot ASK=1`: a chat as it looks after one Ask AKit About This; no model call.
    private static let cannedChat: [Message] = [
        Message(role: .user, text: aboutQuestion, about: "Skill Listing (Claude Code's skill descriptions in every request)",
                sent: Sent(destination: "Claude Code · opus · Anthropic · me@example.com",
                           input: "Screen: Insights\nWhat the screen shows now:\nScope: All Sessions\nWindow: 30 days\nRecommendations: 2\nThe question is about: Skill Listing\nSessions measured: 25\n\nQuestion: \(aboutQuestion)",
                           sections: [AskAKit.Source(guide: "screens", section: "insights", title: "Insights"),
                                      AskAKit.Source(guide: "screens", section: "skills", title: "Skills")],
                           systemCharacters: 31_480)),
        Message(role: .assistant, text: """
            **Skill Listing** — это список скиллов с описаниями, который Claude Code кладёт в каждый запрос к модели. По нему модель решает, какой скилл вызвать.

            - У списка есть бюджет: доля окна контекста. Если описания не влезают, Claude Code показывает часть скиллов только по имени, и модель хуже их выбирает.
            - Каждое описание стоит токенов в каждом запросе, даже если скилл не нужен.

            Что делать: сначала разберите **Recommendations** выше. Скилл, который модель не вызывает, сделайте ручным (**Apply…**) или перенесите в проект (**Move to Project…**). Только потом поднимайте бюджет.

            Подробно: [Insights](screens#insights), [Skills](screens#skills).
            """, sources: [AskAKit.Source(guide: "screens", section: "insights", title: "Insights"),
                           AskAKit.Source(guide: "screens", section: "skills", title: "Skills")]),
        Message(role: .user, text: "А где посмотреть, какие скиллы не вызывались?"),
        Message(role: .assistant, text: """
            В таблице ниже на этом же экране. Включите **Unused Only**: останутся скиллы без единого вызова за окно. Правый щелчок по строке открывает действия со скиллом.

            Подробно: [Insights](screens#insights).
            """, sources: [AskAKit.Source(guide: "screens", section: "insights", title: "Insights")]),
    ]
}

/// Keeps a screen's facts in Ask AKit's context while the view is on screen.
private struct AskScreenFacts: ViewModifier {
    @Environment(AskAKitModel.self) private var ask
    let section: SidebarSection
    let facts: String

    func body(content: Content) -> some View {
        content
            .onChange(of: facts, initial: true) { ask.screenFacts[section] = facts }
            // Gone with its view (no session open any more), unless another view set its own.
            .onDisappear { if ask.screenFacts[section] == facts { ask.screenFacts[section] = nil } }
    }
}

extension View {
    /// Adds Ask AKit About This to the view's context menu. For a view that already has a
    /// context menu, put `AskAKitMenuItem` in that menu instead. The facts are built only when
    /// the item is chosen.
    /// `copy`: a Copy item first, for a row whose label isn't selectable (so that a right-click
    /// on it reaches this menu).
    func askAKit(_ title: String, facts: @autoclosure @escaping () -> [String] = [], copy: String? = nil) -> some View {
        contextMenu {
            if let copy {
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(copy, forType: .string)
                }
                Divider()
            }
            AskAKitMenuItem(title: title, facts: facts())
        }
    }

    /// What the screen shows now (`label: value` lines), for Ask AKit's questions on it.
    func askAKitScreen(_ section: SidebarSection, facts: [String]) -> some View {
        modifier(AskScreenFacts(section: section, facts: facts.filter { !$0.isEmpty }.joined(separator: "\n")))
    }
}

/// The context menu item: opens Ask AKit and asks about the element, with its visible values.
/// Off while Ask AKit is answering.
struct AskAKitMenuItem: View {
    @Environment(AskAKitModel.self) private var ask
    let title: String
    let facts: () -> [String]
    /// The screen the element belongs to, when it isn't the one in view (a sidebar item).
    var screen: SidebarSection?

    init(title: String, facts: @autoclosure @escaping () -> [String] = [], screen: SidebarSection? = nil) {
        self.title = title
        self.facts = facts
        self.screen = screen
    }

    var body: some View {
        Button("Ask AKit About This", systemImage: "questionmark.bubble") {
            ask.ask(about: AskContext.Element(title: title, facts: facts().filter { !$0.isEmpty }.joined(separator: "\n")), screen: screen)
        }
        .disabled(ask.isRunning)
    }
}

/// The side panel: the chat, the agent, what is sent and where.
struct AskAKitPanel: View {
    @Environment(AskAKitModel.self) private var ask
    @Environment(AppModel.self) private var model
    @Environment(GuideNavigator.self) private var guides
    @Environment(\.openWindow) private var openWindow
    @AppStorage(AskAKitModel.harnessKey) private var harnessRaw = LabHarness.claudeCode.rawValue
    @AppStorage(AskAKitModel.modelKey) private var modelName = ""
    @AppStorage(AskAKitModel.effortKey) private var effort = ""
    @State private var choosingAgent = false
    @State private var dontAskAgain = false
    @FocusState private var inputFocused: Bool

    var body: some View {
        @Bindable var ask = ask
        VStack(spacing: 0) {
            header
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        if ask.messages.isEmpty { intro }
                        ForEach(ask.messages) { message in
                            AskMessageView(message: message, open: open).id(message.id)
                        }
                        if ask.isRunning {
                            ProgressView("Waiting for \(ask.agent.harness.title)…")
                                .controlSize(.small)
                                .id("waiting")
                        }
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onAppear { proxy.scrollTo(ask.messages.last?.id, anchor: .bottom) }
                .onChange(of: ask.messages.count) {
                    withAnimation { proxy.scrollTo(ask.isRunning ? "waiting" : ask.messages.last?.id as AnyHashable?, anchor: .bottom) }
                }
            }
            Divider()
            footer
        }
        .frame(minWidth: 280)
        // The first send to a destination (harness and provider) in this launch, until Don't ask
        // again: what leaves the Mac and where. The call waits for the answer.
        .confirmationDialog("Send to \(ask.consent?.harness ?? ask.agent.harness.title)?", isPresented: Binding(get: { ask.consent != nil }, set: { shown in
            if !shown { answer(false) }
        }), titleVisibility: .visible) {
            Button("Send") { answer(true) }
            Button("Cancel", role: .cancel) { answer(false) }
        } message: {
            Text("""
                Ask AKit sends one request to \(ask.consent?.destination ?? agentName), with the account signed in there:
                • your question and the chat so far;
                • this screen's data: names, counts, ids, statuses and numbers (never text from sessions);
                • the values of the element you asked about;
                • the AKit guide sections that fit the question.
                The sending policy, the scrub and the monthly limit apply, and Lab → Sends logs it. What Was Sent under each question shows it. Settings → Ask before Ask AKit sends brings this back after Don't ask again.
                """)
        }
        .dialogSuppressionToggle("Don't ask again", isSuppressed: $dontAskAgain)
        // The agent is worked out here, not on every redraw.
        .onAppear { ask.refreshAgent() }
        // A hidden panel can't show the confirmation: the waiting call isn't sent.
        .onDisappear { if ask.consent != nil { answer(false) } }
        // Not per keystroke of the model field: when the harness or effort changes, and when the
        // agent popover closes.
        .onChange(of: "\(harnessRaw)|\(effort)") { ask.refreshAgent() }
        .onChange(of: choosingAgent) { _, open in if !open { ask.refreshAgent() } }
        // `[title](screens#id)` in an answer opens the Guide window at that section.
        // Only a guide section the guides have (in the Guide window) or an https page (in the
        // browser) opens; a file, an app's scheme or an unknown section does nothing.
        .environment(\.openURL, OpenURLAction { url in
            switch ask.linkTarget(url) {
            case .guide(let source):
                open(Guide(rawValue: source.guide) ?? .screens, source.section)
                return .handled
            case .web(let page):
                return .systemAction(page)
            case .discard:
                return .discarded
            }
        })
    }

    private var header: some View {
        HStack(spacing: 8) {
            Label("Ask AKit", systemImage: "questionmark.bubble").font(.headline)
            Spacer()
            Button(agentName, systemImage: "cpu") { choosingAgent = true }
                .labelStyle(.titleOnly)
                .buttonStyle(.borderless)
                .lineLimit(1)
                .help("The harness, model and effort that answer; the harness's own sign-in is used")
                .popover(isPresented: $choosingAgent, arrowEdge: .bottom) {
                    Form {
                        // Harness, model (with the models it offers) and effort, as in Lab. Empty
                        // model: Lab's default for the harness.
                        ReviewAgentFields(harness: harness, modelName: $modelName, effort: $effort, keepsValues: !modelName.isEmpty)
                    }
                    .formStyle(.grouped)
                    .frame(width: 340)
                    .fixedSize(horizontal: false, vertical: true)
                }
            Button("New Chat", systemImage: "square.and.pencil") { ask.newChat() }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .disabled(ask.messages.isEmpty && ask.focus == nil)
                .help("Clear this chat and start a new one")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Ask what a label, number, badge or insight on this screen means, or how to do something.")
            Text("Answers come from AKit's guides and what the \(ask.screen.screenTitle) screen shows. Right-click a row, metric or badge and choose Ask AKit About This to ask about it.")
                .foregroundStyle(.secondary)
        }
        .font(.callout)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var footer: some View {
        @Bindable var ask = ask
        return VStack(alignment: .leading, spacing: 8) {
            if let focus = ask.focus {
                HStack(spacing: 6) {
                    Label("About: \(focus.title)", systemImage: "scope").lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 0)
                    Button("Clear", systemImage: "xmark.circle.fill") { ask.focus = nil }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                        .help("Ask about the whole screen again")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            HStack(alignment: .bottom, spacing: 8) {
                TextField("Ask about \(ask.screen.screenTitle)…", text: $ask.draft, axis: .vertical)
                    .lineLimit(1...6)
                    .textFieldStyle(.roundedBorder)
                    .focused($inputFocused)
                    .onSubmit { ask.sendDraft() }
                if ask.isRunning {
                    Button("Stop", systemImage: "stop.circle") { ask.stop() }
                        .help("Stop waiting for the answer")
                } else {
                    Button("Send", systemImage: "arrow.up.circle.fill") { ask.sendDraft() }
                        .disabled(ask.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .help("Send the question (Return)")
                }
            }
            .labelStyle(.iconOnly)
            .controlSize(.large)
            if ask.draft.count > AskAKit.questionLimit {
                Label("Only the first \(AskAKit.questionLimit.formatted()) characters are sent.", systemImage: "scissors")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            // Data leaves this Mac: say what and where, every time.
            Text("Sends your question, this screen's data and the chat so far to \(agentName), with the account signed in there. Logged in Lab → Sends.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .onAppear { inputFocused = true }
    }

    /// The confirmation's answer; the suppression toggle starts unticked next time.
    private func answer(_ send: Bool) {
        ask.answerConsent(send: send, dontAskAgain: send && dontAskAgain)
        dontAskAgain = false
    }

    /// "Claude Code · opus".
    private var agentName: String {
        let agent = ask.agent
        return agent.harness.title + " · " + (agent.model.isEmpty ? "default model" : agent.model)
    }

    private var harness: Binding<LabHarness> {
        Binding(get: { LabHarness(rawValue: harnessRaw) ?? .claudeCode }, set: { harnessRaw = $0.rawValue })
    }

    private func open(_ guide: Guide, _ section: String) {
        guides.show(guide, section: section)
        openWindow(id: GuideView.windowID)
    }
}

/// One message: the question on the right, the answer as the guides' Markdown with its sources.
private struct AskMessageView: View {
    let message: AskAKitModel.Message
    let open: (Guide, String) -> Void

    var body: some View {
        switch message.role {
        case .user:
            VStack(alignment: .trailing, spacing: 3) {
                if let about = message.about {
                    Text("About: \(about)").font(.caption).foregroundStyle(.secondary)
                }
                Text(message.text)
                    .textSelection(.enabled)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(Color.accentColor.opacity(0.15), in: RoundedRectangle(cornerRadius: 10))
                if let sent = message.sent {
                    SentDisclosure(sent: sent, open: open)
                }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        case .assistant:
            if message.failed {
                Label(message.text, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    GuideBlocks(blocks: Self.blocks(message.text), highlight: nil)
                        .textSelection(.enabled)
                    if !message.sources.isEmpty {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Sources").font(.caption.bold()).foregroundStyle(.secondary)
                            ForEach(message.sources) { source in
                                Button(source.title, systemImage: "book") { open(Guide(rawValue: source.guide) ?? .screens, source.section) }
                                    .buttonStyle(.link)
                                    .help("Open the \(Guide(rawValue: source.guide)?.title ?? source.guide) guide at this section")
                            }
                        }
                        .font(.callout)
                    }
                }
            }
        }
    }

    /// The answer's Markdown as guide blocks; a heading in it becomes a bold line.
    static func blocks(_ text: String) -> [GuideDocument.Block] {
        let document = GuideDocument.parse(text)
        var blocks = document.intro
        func add(_ section: GuideDocument.Section) {
            blocks.append(.paragraph("**\(section.title)**"))
            blocks += section.blocks
            section.subsections.forEach(add)
        }
        document.sections.forEach(add)
        return blocks
    }
}

/// What Was Sent under a question: where it went, the input as the scrub left it, and the
/// guide sections the system prompt carried.
private struct SentDisclosure: View {
    let sent: AskAKitModel.Sent
    let open: (Guide, String) -> Void

    var body: some View {
        DisclosureGroup("What Was Sent") {
            VStack(alignment: .leading, spacing: 6) {
                Text("To \(sent.destination)").font(.caption)
                Text("System prompt: Ask AKit's rules and \(sent.sections.count) guide sections, \(sent.systemCharacters.formatted()) characters")
                    .font(.caption)
                ForEach(sent.sections) { source in
                    Button(source.title) { open(Guide(rawValue: source.guide) ?? .screens, source.section) }
                        .buttonStyle(.link)
                        .font(.caption)
                }
                Text("Input, after the scrub:").font(.caption.bold())
                LongText(text: sent.input, monospaced: true, limit: 2_000)
                    .font(.caption)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }
}
