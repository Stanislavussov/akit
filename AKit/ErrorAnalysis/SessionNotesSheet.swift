import AKitErrorAnalysis
import AKitFoundation
import AKitInsights
import AKitLab
import AKitSessions
import SwiftUI

/// A reviewed session to show in `SessionNotesSheet`.
struct SessionNotesTarget: Identifiable, Hashable {
    let sessionKey: String
    var id: String { sessionKey }
}

/// One session's notes as the pool keeps them (`akit analysis notes SESSION`): outcome,
/// paragraph, accepted and rejected notes, advice, where each note is routed, and the
/// session's cheap signals (`akit analysis signals`). Route Again… routes the notes once more
/// (`akit analysis route SESSION`). Opened from batch rows, mode pages and the matrix.
struct SessionNotesSheet: View {
    struct Loaded: Sendable {
        var notes: SessionNotes?
        var modes: [Mode] = []
        var signals: SessionSignals?
        var signalsError: String?
        /// What routing again would send: the accepted notes, the modes and their exemplars.
        var routeCharacters = 0
    }

    @Environment(AnalysisModel.self) private var analysis
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let sessionKey: String
    /// Off when the sheet is opened from the Lab run it would show.
    var showsLabRun = true
    @State private var loaded: Loaded?
    @State private var send: AnalysisSend?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            Divider()
            if let loaded {
                if let notes = loaded.notes {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 20) {
                            ReviewNotesView(notes: notes)
                            routes(notes, modes: loaded.modes)
                            signals(loaded)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.trailing, 8)
                    }
                } else {
                    ContentUnavailableView("No Notes", systemImage: "doc.questionmark",
                                           description: Text("No notes are saved for \(sessionKey): its review hasn't finished, or failed."))
                }
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 720, height: 680)
        .task { await load() }
        .sheet(item: $send, onDismiss: { Task { await load() } }) { AnalysisSendSheet(send: $0) }
    }

    private var header: some View {
        let notes = loaded?.notes
        return HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text(notes?.title ?? sessionKey).font(.title2.bold()).lineLimit(2)
                Text(sessionKey).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
            }
            Spacer()
            if let notes {
                if showsLabRun, let runID = notes.runID, let run = model.labRuns.first(where: { $0.id == runID }) {
                    Button(run.spec.kind == .review ? "Show Review Run" : "Show Run in Lab") {
                        model.revealLabRun = runID
                        model.section = .lab
                        dismiss()
                    }
                    .help("The Lab run that wrote these notes")
                }
                Button("Route Again…", systemImage: "arrow.triangle.branch") {
                    send = .route(notes, characters: loaded?.routeCharacters ?? 0)
                }
                .disabled(notes.accepted.isEmpty)
                .help("Route this session's accepted notes to modes once more (a model call; the cost first)")
            }
        }
        .controlSize(.small)
    }

    @ViewBuilder private func routes(_ notes: SessionNotes, modes: [Mode]) -> some View {
        let current = Matching.currentRoutes(notes)
        let accepted = notes.accepted.filter { $0.source == .model }
        if !accepted.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("Routes").font(.title3.bold())
                ForEach(accepted) { note in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(note.id).monospaced().fontWeight(.semibold)
                        Image(systemName: "arrow.turn.down.right").foregroundStyle(.secondary)
                        if let route = current[note.id] {
                            Text(route.modeID.map { id in modes.first { $0.id == id }?.name ?? id } ?? "None fits").fontWeight(.medium)
                            Text(routeState(route)).foregroundStyle(.secondary).monospacedDigit()
                        } else {
                            Text("Not routed yet").foregroundStyle(.secondary)
                        }
                    }
                    .font(.callout)
                }
            }
            .textSelection(.enabled)
        }
    }

    /// "confidence 0.92", "· waits for you on the Review tab", "· accepted by you".
    private func routeState(_ route: Route) -> String {
        if route.by == .human { return "moved by you" }
        var text = String(format: "confidence %.2f", route.confidence)
        switch route.review {
        case .accepted?: text += " · accepted by you"
        case .rejected?: text += " · rejected by you"
        case nil where route.confidence < Matching.lowConfidence: text += " · waits for you on the Review tab"
        case nil: break
        }
        return text
    }

    @ViewBuilder private func signals(_ loaded: Loaded) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Signals").font(.title3.bold())
            Text("Counted by code from the transcript, here on this Mac: the cheap signals a batch sample is stratified by.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let signals = loaded.signals {
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 3) {
                    row("Interrupted", "\(signals.interrupts)", raised: signals.interrupts > 0)
                    row("Pushbacks", "\(signals.pushbacks)", raised: signals.pushbacks > 0)
                    row("Tool errors", "\(signals.toolErrors)", raised: signals.toolErrors > 0)
                    row("Repeated calls", "\(signals.repeatedCalls)", raised: signals.repeatedCalls > 0)
                    row("Done with no check", signals.unverifiedDone ? "yes" : "no", raised: signals.unverifiedDone)
                    row("User turns", "\(signals.userTurns)", raised: false)
                    row("Steps", "\(signals.steps)", raised: false)
                }
                .font(.callout)
                .monospacedDigit()
            } else if let error = loaded.signalsError {
                Text(error).font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    private func row(_ name: String, _ value: String, raised: Bool) -> some View {
        GridRow {
            Text(name).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
            Text(value).fontWeight(raised ? .semibold : .regular).foregroundStyle(raised ? .orange : .primary)
        }
    }

    private func load() async {
        let key = sessionKey, env = analysis.env
        loaded = await Task.detached { await Self.read(key, env: env) }.value
    }

    nonisolated private static func read(_ key: String, env: HarnessEnvironment) async -> Loaded {
        var loaded = Loaded()
        guard let notes = NotesStore(env: env).load(key) else { return loaded }
        loaded.notes = notes
        let store = ModeStore(env: env)
        loaded.modes = (try? await store.list()) ?? []
        var characters = notes.accepted.map { $0.description.count + $0.quote.count + 40 }.reduce(0, +)
        for mode in Matching.routable(loaded.modes) {
            characters += ([mode.name, mode.definition] + mode.include + mode.exclude).map(\.count).reduce(0, +) + 40
            characters += ((try? store.exemplars(of: mode.id)) ?? []).map { $0.quote.count + 20 }.reduce(0, +)
        }
        loaded.routeCharacters = characters
        let summary = NotesPipeline.Target(harness: SessionKey.harness(of: key), file: URL(filePath: notes.transcript)).summary
        do {
            loaded.signals = SignalScanner.signals(of: try SessionReader.transcript(of: summary).items)
        } catch {
            loaded.signalsError = "The transcript can't be read: \(error.localizedDescription)"
        }
        return loaded
    }
}

extension AnalysisSend {
    /// `akit analysis route SESSION`: the session's accepted notes routed to modes once more.
    static func route(_ notes: SessionNotes, characters: Int) -> AnalysisSend {
        let key = notes.sessionKey
        return AnalysisSend(
            title: "Route Again",
            detail: "Sends the \(AnalysisText.notes(notes.accepted.count)) of this session the verifier accepted (descriptions, steps and quotes) with the list of modes and their exemplars, so matching routes each to a mode. Routes you reviewed are kept. When the notes, the verifier, the matching model and the list of modes are as at the last routing, nothing is sent.",
            characters: characters
        ) { agent, gate, env in
            guard let notes = NotesStore(env: env).load(key) else { throw AnalysisFailure("No notes for \(key); review it first.") }
            let store = ModeStore(env: env)
            let modes = try await store.list()
            var exemplars: [String: [Exemplar]] = [:]
            for mode in Matching.routable(modes) { exemplars[mode.id] = try store.exemplars(of: mode.id) }
            let routed = try await Matching.route(notes, modes: modes, exemplars: exemplars, agent: agent, gate: gate, origin: notes.origin,
                                                  runID: nil, workFolder: AnalysisModel.workFolder(env), env: env)
            guard routed != notes else {
                return "Nothing was sent: the notes, the verifier, the matching model and the list of modes are as at the last routing."
            }
            let routes = Matching.currentRoutes(routed).values
            let waiting = routes.filter { $0.review == nil && $0.by != .human && $0.confidence < Matching.lowConfidence }.count
            return "Routed \(AnalysisText.notes(routes.count)); \(waiting) \(waiting == 1 ? "waits" : "wait") for you on the Review tab."
        }
    }
}
