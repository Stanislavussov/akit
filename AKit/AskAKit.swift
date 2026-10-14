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
    }

    /// The agent's settings, shared with the panel's fields (`@AppStorage`).
    static let harnessKey = "ask.harness"
    static let modelKey = "ask.model"
    static let effortKey = "ask.effort"
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
    private let app: AppModel
    private(set) var isRunning = false
    private var call: Task<Void, Never>?
    /// Counts chats: an answer that arrives after New Chat is dropped.
    private var chat = 0
    private var guides: [AskAKit.Guide]?
    private var search: GuideSearch?

    init(app: AppModel) {
        self.app = app
        if DebugSnapshot.options?.ask == true {
            messages = Self.cannedChat
            focus = AskContext.Element(title: Self.cannedChat[0].about ?? "", facts: "")
        }
    }

    /// The screen as a question sees it: what it is for, what AKit found for it, and what its
    /// view shows now.
    var screen: AskContext {
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

    /// Opens the panel and asks about `element` on the current screen.
    func ask(about element: AskContext.Element) {
        isOpen = true
        focus = element
        send(Self.aboutQuestion, about: element.title, inSettingsLanguage: true)
    }

    func newChat() {
        call?.cancel()
        call = nil
        isRunning = false
        chat += 1
        messages = []
        focus = nil
        draft = ""
    }

    func stop() { call?.cancel() }

    /// The agent the next call runs with: the panel's choice, else Lab's default for the harness.
    var agent: LabAgent {
        let defaults = UserDefaults.standard
        let installed = LabHarness.allCases.filter { HarnessEnvironment.current.findExecutable($0.command) != nil }
        var harness = LabHarness(rawValue: defaults.string(forKey: Self.harnessKey) ?? "") ?? .claudeCode
        if !installed.contains(harness), let first = installed.first { harness = first }
        let fallback = LabRuns.defaultAgent(harness, env: .current)
        let model = (defaults.string(forKey: Self.modelKey) ?? "").trimmingCharacters(in: .whitespaces)
        let effort = defaults.string(forKey: Self.effortKey) ?? ""
        return LabAgent(harness: harness, model: model.isEmpty ? fallback.model : model,
                        effort: harness.efforts.contains(effort) ? effort : fallback.effort)
    }

    /// Sends the draft.
    func sendDraft() {
        let question = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, !isRunning else { return }
        draft = ""
        send(question, about: focus?.title, inSettingsLanguage: false)
    }

    private func send(_ question: String, about: String?, inSettingsLanguage: Bool) {
        guard !isRunning else { return }
        var context = screen
        context.element = focus
        let history = messages.filter { !$0.failed }.map { AskTurn(role: $0.role, text: $0.text) }
        messages.append(Message(role: .user, text: question, about: about))
        let agent = self.agent
        let chat = self.chat
        isRunning = true
        // Not detached: Stop cancels the task, and that stops the harness's process.
        call = Task {
            let reply: Message
            do {
                let (guides, search) = await loadGuides()
                let language = inSettingsLanguage ? LabSettings.load(env: .current).reportLanguage.name : nil
                let prepared = await Task.detached {
                    AskAKit.prepare(question: question, context: context, history: history, guides: guides, search: search,
                                    language: language)
                }.value
                let env = HarnessEnvironment.current
                let gate = try await SendGate.open(agent: agent, env: env)
                let folder = FileManager.default.temporaryDirectory.appending(path: "akit-ask-\(UUID().uuidString)")
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                defer { try? FileManager.default.removeItem(at: folder) }
                // The screen's data is the user's harness setup: the chosen harness's own account
                // is its origin, so a work Mac sends it only to an allowed destination.
                let answer = try await ModelCall.run(
                    ModelCall.Request(agent: agent, purpose: "ask akit", system: prepared.system, input: prepared.input,
                                      schema: AskAKit.schema, origin: .code(agent.harness)),
                    gate: gate, folder: folder, env: env)
                try Task.checkCancellation()
                let text = AskAKit.answer(from: answer.text)
                reply = Message(role: .assistant, text: text, sources: AskAKit.sources(in: text, guides: guides))
            } catch is CancellationError {
                reply = Message(role: .assistant, text: "Stopped.", failed: true)
            } catch {
                reply = Message(role: .assistant, text: error.localizedDescription, failed: true)
            }
            guard chat == self.chat else { return }
            messages.append(reply)
            isRunning = false
            call = nil
        }
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
        Message(role: .user, text: aboutQuestion, about: "Skill Listing (Claude Code's skill descriptions in every request)"),
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
        content.onChange(of: facts, initial: true) { ask.screenFacts[section] = facts }
    }
}

extension View {
    /// Adds Ask AKit About This to the view's context menu. For a view that already has a
    /// context menu, put `AskAKitMenuItem` in that menu instead.
    func askAKit(_ title: String, facts: [String] = []) -> some View {
        contextMenu { AskAKitMenuItem(title: title, facts: facts) }
    }

    /// What the screen shows now (`label: value` lines), for Ask AKit's questions on it.
    func askAKitScreen(_ section: SidebarSection, facts: [String]) -> some View {
        modifier(AskScreenFacts(section: section, facts: facts.filter { !$0.isEmpty }.joined(separator: "\n")))
    }
}

/// The context menu item: opens Ask AKit and asks about the element, with its visible values.
struct AskAKitMenuItem: View {
    @Environment(AskAKitModel.self) private var ask
    let title: String
    var facts: [String] = []

    var body: some View {
        Button("Ask AKit About This", systemImage: "questionmark.bubble") {
            ask.ask(about: AskContext.Element(title: title, facts: facts.filter { !$0.isEmpty }.joined(separator: "\n")))
        }
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
        // `[title](screens#id)` in an answer opens the Guide window at that section.
        .environment(\.openURL, OpenURLAction { url in
            guard url.scheme == nil, let section = url.fragment else { return .systemAction }
            open(Guide(rawValue: url.path) ?? .screens, section)
            return .handled
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
            // Data leaves this Mac: say what and where, every time.
            Text("Sends your question, this screen's data and the chat so far to \(agentName), with the account signed in there. Logged in Lab → Sends.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .onAppear { inputFocused = true }
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
