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
    /// The question being answered now, and what Pi does; `generation` is the chat it was asked in.
    private var running: (question: String, passage: String?, generation: Int)?
    /// The running question, when it belongs to the chat on screen (another note's stays hidden).
    var asking: (question: String, passage: String?)? {
        running.flatMap { $0.generation == generation ? ($0.question, $0.passage) : nil }
    }
    private(set) var step = ""
    /// A refusal before anything was asked (no Pi, the sending policy, not confirmed).
    var problem: String?
    private(set) var consent: Consent?
    private var confirmed = Set<String>()
    private var scope: Cancellation.Scope?
    /// Where "Open in Pi" opened, for one line under the header.
    private(set) var openedIn: String?

    /// A question runs, in this chat or (stopping) in one left a moment ago: no new one starts.
    var isRunning: Bool { running != nil }
    /// The question running is this chat's (Stop and the spinner show).
    var isAskingHere: Bool { asking != nil }

    /// The agent: the chosen Pi model, else Lab's default Pi agent.
    var agent: LabAgent {
        let fallback = LabRuns.defaultAgent(.pi, env: .current)
        let chosen = (UserDefaults.standard.string(forKey: Self.modelKey) ?? "").trimmingCharacters(in: .whitespaces)
        return LabAgent(harness: .pi, model: chosen.isEmpty ? fallback.model : chosen, effort: fallback.effort)
    }

    /// Counts what the panel shows (another note, New Chat): a send that ends after a change
    /// leaves the panel as it is.
    private var generation = 0

    /// Shows the panel for `note`, with its latest chat. The same note (base and id) with a new
    /// title (an outside edit) only updates the title: a running question goes on.
    func show(_ note: KnowledgeAsk.Note) {
        if DebugSnapshot.options?.tab == "knowledge-ask" {
            self.note = note
            entries = Self.cannedChat
            return
        }
        if let current = self.note, current.baseRoot == note.baseRoot, current.id == note.id {
            self.note = note
            return
        }
        if isRunning { stop() }
        generation += 1
        self.note = note
        chat = KnowledgeAsk.latestChat(note: note.id, base: note.base, env: .current)
        entries = chat.map(KnowledgeAsk.entries) ?? []
        (passage, problem, openedIn) = (nil, nil, nil)
    }

    func newChat() {
        stop()
        generation += 1
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
        let generation = generation
        (running, step, problem) = ((question, passage, generation), "Starting Pi…", nil)
        draft = ""
        self.passage = nil
        Task {
            do {
                let chat = try self.chat ?? KnowledgeAsk.newChat(note: note, cwd: cwd, env: env)
                if generation == self.generation { self.chat = chat }
                let entry = try await Cancellation.$scope.withValue(scope) {
                    try await KnowledgeAsk.ask(question, passage: passage, noteText: noteText, in: chat, agent: agent, env: env,
                                               confirm: { destination in await self.confirm(destination, agent: agent) },
                                               progress: { line in Task { @MainActor in self.step = line } })
                }
                if generation == self.generation {
                    entries.append(entry)
                } else if self.chat == chat {
                    // The chat left and came back meanwhile: what is on disk is the truth.
                    entries = KnowledgeAsk.entries(chat)
                }
            } catch {
                // Only into the chat it was asked in: the panel may show another note by now.
                if generation == self.generation {
                    problem = error.localizedDescription
                    // Not sent (refused, not confirmed): the question goes back to the field. One
                    // Pi answered but AKit couldn't save stays out of it.
                    if (error as? KnowledgeAsk.Failure)?.sent != true {
                        if draft.isEmpty { draft = question }
                        if self.passage == nil { self.passage = passage }
                    }
                }
            }
            // The process is gone: the next question may start.
            running = nil
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

    /// When the next proposal of this chat with the same id was made: `ref`'s proposal ended
    /// before it (ids are reused).
    func nextCreated(after ref: KnowledgeAsk.ProposalRef) -> String? {
        let all = entries.flatMap { $0.proposals ?? [] }
        guard let index = all.firstIndex(of: ref) else { return nil }
        return all[(index + 1)...].first { $0.id == ref.id }?.created
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
        let model = agent.model.isEmpty ? "default" : agent.model
        let head = "ask pi: \(note?.id ?? "-"), model \(model), \(entries.count) answer\(entries.count == 1 ? "" : "s")"
            + (passage.map { ", passage \($0.count) characters" } ?? "")
        return [head] + entries.map(Self.line)
    }

    private static func line(_ entry: KnowledgeAsk.Entry) -> String {
        let result: String = entry.answer.map { "\($0.count) characters" } ?? entry.error ?? "-"
        let proposals: String = entry.proposals.map { ", proposals " + $0.map(\.id).joined(separator: ", ") } ?? ""
        return "ask pi \(entry.id): \(entry.question)" + (entry.passage == nil ? "" : " (passage)") + " → " + result + proposals
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
                           answer: "orders-api keeps the event and sends it again after 5 minutes (the *retry* line of this section). Nothing is lost while billing is down. billing's note doesn't say so yet: I proposed a section for it.",
                           error: nil, session: "demo-2", proposals: [KnowledgeAsk.ProposalRef(id: "2026-10-24-payments-billing", created: nil)]),
    ]
}

/// A proposal Pi made in an answer (K32): its target, reason, checks and the diff Accept writes,
/// with Accept… / Reject… / Show in Inbox, the same actions and confirmations as the Inbox tab.
/// Once it has left the Inbox (here or elsewhere) the card says how it ended.
private struct AskProposalCard: View {
    @Environment(KnowledgeModel.self) private var model
    let ref: KnowledgeAsk.ProposalRef
    /// When the chat's next proposal with this id was made.
    let before: String?
    @State private var state: KnowledgeBase.ProposalState?
    /// What Accept would write, worked out once per proposal, inbox and note text (not per redraw).
    @State private var plan: Result<KnowledgeInbox.Plan, KnowledgeBase.Failure>?

    /// The Inbox's entry of this very proposal: the same id and the same `created`.
    private var entry: KnowledgeInbox.Entry? {
        model.proposals.first { $0.id == ref.id && (ref.created == nil || $0.created == ref.created) }
    }

    var body: some View {
        let entry = entry
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: entry?.kind == .arrow ? "arrow.right" : "doc.badge.plus").foregroundStyle(.tint)
                Text("Proposal: " + (entry.map { $0.arrow?.text ?? $0.target ?? ref.id } ?? ref.id)).bold().lineLimit(1)
                Spacer()
                if let entry {
                    if entry.checks.contains(where: { $0.status == .failed }) {
                        Image(systemName: "xmark.octagon.fill").foregroundStyle(.red).help("A check fails: Accept is refused")
                    } else if entry.checks.contains(where: { $0.status == .warning }) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).help("A check warns")
                    } else {
                        Image(systemName: "checkmark.circle").foregroundStyle(.green).help("Every check passes")
                    }
                }
            }
            if let entry {
                if let reason = entry.reason { Text(reason).font(.callout).foregroundStyle(.secondary).textSelection(.enabled) }
                ForEach(entry.checks.filter { $0.status != .passed }, id: \.name) { check in
                    Text("\(check.name): \(check.message ?? check.status.rawValue)").font(.caption).foregroundStyle(.orange)
                }
                switch plan {
                case .success(let plan)?:
                    ScrollView {
                        Text(plan.diff).font(.caption.monospaced()).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 160)
                case .failure(let error)?:
                    Text(error.message).font(.caption).foregroundStyle(.red)
                case nil:
                    EmptyView()
                }
                HStack {
                    Button("Accept…", systemImage: "checkmark") { model.requestAccept(entry) }
                        .disabled(entry.proposal == nil || entry.checks.contains { $0.status == .failed })
                        .help("See the change, then write it into the note and commit it, as in the Inbox; the old note is backed up")
                    Button("Reject…", systemImage: "xmark") { model.rejectRequest = ref.id }
                        .help("Move the proposal's file to the Trash; nothing in the base changes")
                    Button("Show in Inbox", systemImage: "tray") {
                        model.proposalID = ref.id
                        model.screenTab = .inbox
                    }
                    .help("Open this proposal on the Inbox tab, with its check model marks and Check Again")
                }
                .controlSize(.small)
            } else {
                Label(label, systemImage: state == .accepted ? "checkmark.circle.fill" : state == .pending ? "clock" : "xmark.circle")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .padding(8)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
        // Worked out when the proposal, the inbox or the open note's text changes.
        .task(id: "\(ref.id)|\(entry?.created ?? "-")|\(model.inboxCount)|\(model.proposals.count)|\(model.text.hashValue)") {
            plan = entry.flatMap(model.acceptPlan)
        }
        .task(id: entry == nil) {
            guard entry == nil, let base = model.base else { return }
            state = await base.state(ofProposal: ref.id, created: ref.created, before: before, env: model.env)
            // In inbox/ but not in the list yet (it was read before Pi wrote it): read it again.
            if state == .pending { model.readInbox() }
        }
    }

    private var label: String {
        switch state {
        case .accepted?: "Accepted"
        case .closed?: "Rejected or removed"
        case .pending?: "Pending: in the Inbox"
        case nil: "Looking it up…"
        }
    }
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
                        if ask.entries.isEmpty, !ask.isAskingHere {
                            Text("Ask your Pi about this note: what it means, who uses it, what's missing. Pi runs with your own setup (MCP servers, skills like /akit-context), so it can look things up in the base and in other systems. Changes to the base come as proposals you accept or reject here or in the Inbox; Pi is told to change nothing else (its bash and MCP tools stay on). The next question continues the same conversation.")
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
                            ForEach(entry.proposals ?? [], id: \.self) { ref in
                                AskProposalCard(ref: ref, before: ask.nextCreated(after: ref))
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
                .onChange(of: ask.entries.count, initial: true) {
                    // A new answer may have proposals: the Inbox list (and the cards) read them now.
                    model.readInbox()
                    proxy.scrollTo(ask.entries.last?.id, anchor: .bottom)
                }
                .onChange(of: ask.isAskingHere) { if ask.isAskingHere { proxy.scrollTo("running", anchor: .bottom) } }
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
                .help("Go on with this conversation in an interactive Pi in a terminal, from Pi's last answer. What you ask there doesn't come back to this panel")
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
                if ask.isAskingHere {
                    Button("Stop", systemImage: "stop.circle") { ask.stop() }
                        .help("Stop Pi and everything it started; this answer is not continued")
                } else {
                    Button("Send", systemImage: "arrow.up.circle.fill") { send() }
                        .keyboardShortcut(.return, modifiers: .command)
                        .disabled(ask.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || ask.isRunning)
                        .help(ask.isRunning ? "Pi is still stopping the question of the chat you left; send in a moment" : "Send the question to Pi (⌘↩)")
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
