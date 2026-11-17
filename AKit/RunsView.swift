import AKitCorrections
import AKitFlows
import AKitFoundation
import AKitInsights
import AKitSessions
import SwiftUI

/// Activity → Runs (docs/design/flows.md F7, F16, F17): the flow runs Pi made in the projects,
/// read from `<project>/.pi/akit-flow/runs/`. Read only: the diagram with each step's state, time,
/// tokens and attempts; deviations with their quote; evidence and handoff per step; Stop writes
/// `STOP`. Nothing here copies or exports (child output may hold secrets).
struct RunsView: View {
    @Environment(AppModel.self) private var model
    @State private var runs: [FlowRunSummary] = []
    @State private var selection: String?
    @State private var expanded: String?
    @State private var confirmStop = false
    @State private var problem: String?
    @State private var labSession: SessionSummary?
    @State private var corrections: CorrectedSession?
    /// Run worktrees over 14 days old that the cleanup kept: uncommitted changes in them.
    @State private var keptDirty: Set<String> = []

    private var env: HarnessEnvironment { .current }
    private var selected: FlowRunSummary? { runs.first { $0.run.id == selection } ?? runs.first }

    var body: some View {
        HStack(spacing: 0) {
            list.frame(width: 260)
            Divider()
            if let run = selected {
                detail(run)
            } else {
                ContentUnavailableView("No Flow Runs", systemImage: "point.3.connected.trianglepath.dotted",
                                       description: Text("Runs appear here after /flow <name> <task> in Pi, in a project with a rendered flow."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: model.projects) {
            reload()
            let env = env
            let old = await Task.detached { () -> [FlowWorktreeCleanup.Worktree] in
                FlowWorktreeCleanup.prune(env: env)
                return FlowWorktreeCleanup.old(env: env)
            }.value
            keptDirty = Set(old.filter(\.dirty).map(\.run))
        }
        .toolbar {
            ToolbarItem {
                Button("Refresh", systemImage: "arrow.clockwise") { reload() }.help("Read the run folders again")
            }
        }
        .sheet(item: $labSession) { session in NewLabRunSheet(session: session) { _ in model.section = .lab } }
        .sheet(item: $corrections) { CorrectionsOfStep(corrected: $0) }
    }

    private func reload() {
        runs = FlowRunSummary.all(projects: model.projects, env: env)
        if selection == nil { selection = runs.first?.run.id }
        if let step = DebugSnapshot.options?.query, expanded == nil { expanded = step }
    }

    private var list: some View {
        List(runs, id: \.run.id, selection: $selection) { run in
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Image(systemName: Self.icon(run.status)).foregroundStyle(Self.color(run.status))
                    Text(run.run.flow ?? "?").font(.headline)
                    if run.deviationCount > 0 {
                        Label("\(run.deviationCount)", systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
                    }
                }
                Text(run.run.task ?? run.run.id).lineLimit(1).font(.callout)
                Text("\(run.run.project.map { URL(filePath: $0).lastPathComponent } ?? "") · \(run.run.id)")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .tag(run.run.id)
        }
        .listStyle(.sidebar)
    }

    static func icon(_ status: FlowRunSummary.Status) -> String {
        switch status {
        case .running: "play.circle.fill"
        case .halted: "pause.circle.fill"
        case .done: "checkmark.circle.fill"
        case .stopped: "stop.circle.fill"
        case .unknown: "questionmark.circle"
        }
    }

    static func color(_ status: FlowRunSummary.Status) -> Color {
        switch status {
        case .running: .blue
        case .halted: .orange
        case .done: .green
        case .stopped: .red
        case .unknown: .secondary
        }
    }

    // MARK: - Detail

    private func detail(_ run: FlowRunSummary) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                header(run)
                if let problem { Label(problem, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange) }
                ForEach(run.run.problems, id: \.self) { Label($0, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).font(.callout) }
                let flow = run.flow ?? Self.flow(of: run)
                FlowColumn(flow: flow) { index, step in card(step, index: index, flow: flow, run: run) }
                if run.flow == nil {
                    Text("The flow file \(run.run.flow ?? "") is not in this project's .pi/flows any more: the diagram shows the steps the run made, without routes.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(16)
            .frame(maxWidth: 820, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Without its flow file the diagram is the run's steps in the order they first ran.
    static func flow(of run: FlowRunSummary) -> Flow {
        var seen = Set<String>()
        let ids = run.attempts.map(\.step).filter { seen.insert($0).inserted }
        return Flow(name: run.run.flow ?? "?", steps: ids.map { FlowStep(id: $0, agent: "", model: "") })
    }

    private func header(_ run: FlowRunSummary) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(run.run.flow ?? "?").font(.title2.bold())
                Label(run.status.rawValue.capitalized + (run.stopReason.map { " (\($0))" } ?? ""), systemImage: Self.icon(run.status))
                    .foregroundStyle(Self.color(run.status))
                Spacer()
                Button("Stop…", systemImage: "stop.fill") { confirmStop = true }
                    .disabled(run.status == .done || run.status == .stopped || run.stopRequested || run.run.readOnly)
                    .help(run.stopRequested ? "STOP is written; the run halts before its next step"
                          : "Write STOP into the run folder: Pi halts the run before its next step; /flow resume goes on")
                    .confirmationDialog("Stop this run?", isPresented: $confirmStop) {
                        Button("Stop Before the Next Step", role: .destructive) { stop(run) }
                    } message: {
                        Text("AKit writes STOP into \(run.run.id). The step that runs now finishes; Pi then halts. /flow resume in Pi goes on.")
                    }
                GuideButton(guide: .flows)
            }
            if let task = run.run.task { Text(task).font(.callout) }
            Text(summaryLine(run)).font(.caption).foregroundStyle(.secondary)
            if keptDirty.contains(run.run.id) {
                Label("Worktree kept: uncommitted changes. It is over \(FlowWorktreeCleanup.defaultDays) days old; commit or discard the changes in \(run.run.worktree ?? "the run's worktree"), then the cleanup removes it.",
                      systemImage: "externaldrive.badge.exclamationmark")
                    .foregroundStyle(.orange).font(.callout)
            }
            if run.stopRequested { Label("STOP requested: the run halts before its next step.", systemImage: "hand.raised").foregroundStyle(.orange).font(.callout) }
        }
    }

    private func summaryLine(_ run: FlowRunSummary) -> String {
        let tokens = run.run.tokens
        var parts = ["\(run.attempts.count) step run\(run.attempts.count == 1 ? "" : "s")", Self.tokens(tokens)]
        if let cost = tokens.cost { parts.append(String(format: "$%.2f", cost)) }
        parts.append("\(run.deviationCount) deviation\(run.deviationCount == 1 ? "" : "s")")
        if let pi = run.run.piVersion { parts.append("Pi \(pi)") }
        if let project = run.run.project { parts.append(URL(filePath: project).lastPathComponent) }
        return parts.joined(separator: " · ")
    }

    static func tokens(_ tokens: FlowTokens?) -> String {
        guard let tokens, tokens.input != nil || tokens.output != nil else { return "tokens unknown" }
        let total = (tokens.input ?? 0) + (tokens.output ?? 0)
        return total >= 1000 ? String(format: "%.1fk tokens", Double(total) / 1000) : "\(total) tokens"
    }

    private func stop(_ run: FlowRunSummary) {
        do {
            try run.requestStop()
            problem = nil
        } catch {
            problem = "Couldn't write STOP: \(error.localizedDescription)"
        }
        reload()
    }

    // MARK: - Cards

    private func card(_ step: FlowStep, index: Int, flow: Flow, run: FlowRunSummary) -> some View {
        let attempts = run.attempts(of: step.id)
        let key = "\(run.run.id)/\(step.id)"
        let open = expanded == step.id || expanded == key
        let state = attempts.last?.state
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: open ? "chevron.down" : "chevron.right").foregroundStyle(.secondary).frame(width: 10)
                Image(systemName: Self.icon(state)).foregroundStyle(Self.color(state)).help(state?.rawValue ?? "not run")
                FlowStepLine(step: step, index: index, flow: flow)
            }
            HStack(spacing: 10) {
                Text(attempts.isEmpty ? "not run" : "\(attempts.count) attempt\(attempts.count == 1 ? "" : "s")")
                if !attempts.isEmpty {
                    Text(Self.seconds(attempts.compactMap(\.seconds).reduce(0, +)))
                    Text(Self.tokens(Self.sum(attempts.map(\.tokens))))
                    if let cost = Self.sum(attempts.map(\.tokens)).cost { Text(String(format: "$%.2f", cost)) }
                }
                let deviations = attempts.reduce(0) { $0 + $1.deviations.count }
                if deviations > 0 { Label("\(deviations)", systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
                if attempts.contains(where: { $0.forbiddenNext != nil }) {
                    Label("Off the routes", systemImage: "arrow.triangle.branch").foregroundStyle(.red)
                }
            }
            .font(.caption).foregroundStyle(.secondary).padding(.leading, 34)
            if open { ForEach(attempts, id: \.attempt) { attemptDetail($0, run: run) } }
        }
        .padding(8)
        .contentShape(Rectangle())
        .onTapGesture { expanded = open ? nil : key }
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(open ? Color.accentColor : .secondary.opacity(0.25)))
    }

    static func icon(_ state: FlowStepAttempt.State?) -> String {
        switch state {
        case .running: "circle.dotted"
        case .done: "checkmark.circle.fill"
        case .failed: "xmark.circle.fill"
        case .blocked: "pause.circle.fill"
        case .halted: "stop.circle"
        case nil: "circle"
        }
    }

    static func color(_ state: FlowStepAttempt.State?) -> Color {
        switch state {
        case .running: .blue
        case .done: .green
        case .failed: .orange
        case .blocked: .purple
        case .halted, nil: .secondary
        }
    }

    static func seconds(_ value: Double) -> String {
        value < 60 ? String(format: "%.0f s", value) : String(format: "%.0f min", value / 60)
    }

    static func sum(_ all: [FlowTokens?]) -> FlowTokens {
        let known = all.compactMap { $0 }
        func add<T: AdditiveArithmetic>(_ key: KeyPath<FlowTokens, T?>) -> T? {
            known.isEmpty ? nil : known.reduce(T.zero as T?) { total, next in total.flatMap { t in next[keyPath: key].map { t + $0 } } }
        }
        return FlowTokens(input: add(\.input), output: add(\.output), cacheRead: add(\.cacheRead), cost: add(\.cost))
    }

    private func attemptDetail(_ attempt: FlowStepAttempt, run: FlowRunSummary) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Divider()
            HStack {
                Text("Attempt \(attempt.attempt): \(attempt.state.rawValue)\(attempt.reason.flatMap { $0.isEmpty ? nil : " (\($0))" } ?? "")")
                    .font(.subheadline.bold())
                Spacer()
                if let file = attempt.sessionFile, let session = SessionScanner.flowSession(run.run.folder.appending(path: file)) {
                    Button("Open in Lab…", systemImage: "flask") { labSession = session }
                        .help("Lab: an agent reviews this step's session and writes what to change")
                    Button("Corrections", systemImage: "arrow.uturn.backward") { showCorrections(session) }
                        .help("Corrections in this step's session, counted by code: interrupts, pushbacks, refusals, bad ratings")
                    Button("Show in Sessions", systemImage: "bubble.left.and.bubble.right") {
                        model.revealSession = SessionReveal(path: session.file.path, step: 0)
                        model.section = .sessions
                    }
                    .help("Sessions with the flow filter on, this step's session selected (Tools tab, Usage, Conversation)")
                }
            }
            if let next = attempt.forbiddenNext {
                Label("Then the run went to \(next), which this step's routes do not allow.", systemImage: "arrow.triangle.branch")
                    .foregroundStyle(.red).font(.callout)
            }
            ForEach(Array(attempt.deviations.enumerated()), id: \.offset) { _, deviation in
                VStack(alignment: .leading, spacing: 2) {
                    Label(deviation.text("rule") ?? "deviation", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                    Text("\u{201C}\(FlowRunReport.describe(deviation))\u{201D}\(deviation.text("action").map { " · \($0)" } ?? "")")
                        .font(.callout.monospaced()).foregroundStyle(.secondary)
                }
            }
            if let handoff = attempt.handoff { handoffView(handoff) }
            if let evidence = attempt.evidence { evidenceView(run.run.folder.appending(path: evidence)) }
        }
        .padding(.leading, 34)
    }

    private func handoffView(_ handoff: FlowHandoff) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text("Handoff").font(.caption.bold()).foregroundStyle(.secondary)
                if handoff.fallback { Text("fallback (no flow_handoff)").font(.caption2).foregroundStyle(.orange) }
            }
            if let goal = handoff.goal { Text("Goal: \(goal)").font(.callout) }
            ForEach(handoff.done, id: \.self) { Text("✓ \($0)").font(.callout) }
            ForEach(handoff.files, id: \.path) { Text("\($0.change) \($0.path)").font(.callout.monospaced()) }
            ForEach(handoff.openQuestions, id: \.self) { Text("? \($0)").font(.callout) }
            if let notes = handoff.notes, !notes.isEmpty { Text(notes).font(.callout).foregroundStyle(.secondary) }
        }
    }

    private func evidenceView(_ file: URL) -> some View {
        let checks = FlowEvidence.read(file)
        return VStack(alignment: .leading, spacing: 3) {
            Text("Check evidence").font(.caption.bold()).foregroundStyle(.secondary)
            if checks.isEmpty { Text("Can't read \(file.lastPathComponent)").font(.callout).foregroundStyle(.secondary) }
            ForEach(Array(checks.enumerated()), id: \.offset) { _, check in
                Label("\(check.command) → exit \(check.exit.map(String.init) ?? "?")",
                      systemImage: check.exit == 0 ? "checkmark.circle" : "xmark.circle")
                    .foregroundStyle(check.exit == 0 ? .green : .red).font(.callout.monospaced())
                Text(check.tail.suffix(5).joined(separator: "\n")).font(.caption.monospaced()).foregroundStyle(.secondary)
            }
        }
    }

    private func showCorrections(_ session: SessionSummary) {
        do {
            corrections = try CorrectedSession.of(session)
        } catch {
            problem = "Couldn't read the step's session: \(error.localizedDescription)"
        }
    }
}

/// Runs → a step's Corrections: the counts of that one session.
private struct CorrectionsOfStep: View {
    let corrected: CorrectedSession
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Corrections in this step").font(.headline)
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
                GridRow { Text("Interrupts"); Text("\(corrected.interrupts)") }
                GridRow { Text("Pushbacks"); Text("\(corrected.pushbacks)") }
                GridRow { Text("Your refusals"); Text("\(corrected.refusals)") }
                GridRow { Text("Bad ratings"); Text("\(corrected.badRatings)") }
            }
            Text(corrected.corrections == 0 ? "No corrections: a step's child runs without you." : "\(corrected.corrections) correction(s).")
                .font(.callout).foregroundStyle(.secondary)
            HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) }
        }
        .padding(20)
        .frame(width: 320)
    }
}

