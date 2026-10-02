import AKitErrorAnalysis
import AKitFoundation
import AKitLab
import AKitSessions
import AppKit
import SwiftUI

/// Lab screen: the queue and past runs. Runs happen in a terminal tab (Orca, herdr) or in
/// the background; this screen reads their folders in `~/.akit/lab` every two seconds.
struct LabView: View {
    enum Page: String, CaseIterable {
        case runs, sends
        var title: String { self == .runs ? "Runs" : "Sends" }
    }

    @Environment(AppModel.self) private var model
    @State private var selection: LabRun.ID? = DebugSnapshot.options?.select
    @State private var showNewRun = DebugSnapshot.options?.add == true
    @State private var problem: String?
    /// Snapshots: `--tab sends`.
    @State private var page = DebugSnapshot.options?.tab.flatMap(Page.init(rawValue:)) ?? .runs

    var body: some View {
        Group {
            switch page {
            case .runs: runs
            case .sends: LabSendsView()
            }
        }
        .navigationTitle("Lab")
        .navigationSubtitle(subtitle)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Picker("Show", selection: $page) {
                    ForEach(Page.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .fixedSize()
                .help("Runs: reviews, replays, error analysis batches and control cells. Sends: every model call that sent session data or code out.")
            }
            ToolbarItem {
                Button("New Run…", systemImage: "plus") { showNewRun = true }
                    .help("Review a session, replay a commit under different setups, or run an error analysis batch")
            }
        }
        .sheet(isPresented: $showNewRun) {
            NewLabRunSheet(session: nil) { run in
                page = .runs
                selection = run.id
            }
        }
    }

    private var runs: some View {
        HSplitView {
            list
                .frame(minWidth: 280, idealWidth: 340, maxWidth: 480)
            Group {
                if let run = model.labRuns.first(where: { $0.id == selection }) {
                    LabRunDetail(run: run) { selection = $0.id }
                        .id(run.id)
                } else {
                    ContentUnavailableView {
                        Label("Lab", systemImage: "flask")
                    } description: {
                        Text("Measure agent sessions: an agent reviews a recorded session, or redoes a commit under different setups while hidden tests judge it. Numbers come from the transcript and git, never from the agent.")
                    } actions: {
                        Button("New Run…") { showNewRun = true }
                    }
                }
            }
            .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            if let problem {
                Label(problem, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.orange.opacity(0.15))
            }
        }
        .task {
            // The app watches ~/.akit/lab all the time (RootView); this only picks a first run.
            await model.reloadLab()
            if let reveal = model.revealLabRun {
                selection = reveal
                model.revealLabRun = nil
            }
            if selection == nil { selection = model.labRuns.first?.id }
            problem = await model.labProblem()
        }
    }

    private var subtitle: String {
        let running = model.labRuns.filter { $0.status == .running }.count
        let queued = model.labRuns.filter { $0.status == .queued }.count
        var parts = ["\(model.labRuns.count) runs"]
        if running > 0 { parts.append("\(running) running") }
        if queued > 0 { parts.append("\(queued) queued") }
        return parts.joined(separator: " · ")
    }

    private var list: some View {
        List(model.labRuns, selection: $selection) { run in
            LabRunRow(run: run).tag(run.id)
        }
        .overlay {
            if model.labRuns.isEmpty {
                ContentUnavailableView("No runs yet", systemImage: "flask",
                                       description: Text("Sessions → a Claude Code session → Review in Terminal…, or New Run…"))
            }
        }
    }
}

private struct LabRunRow: View {
    let run: LabRun

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(run.spec.title).fontWeight(.medium).lineLimit(2)
                Spacer()
                LabStatusBadge(run: run)
            }
            HStack(spacing: 6) {
                Label(run.spec.environment.title, systemImage: run.spec.environment.icon)
                if let agent = run.spec.agent, agent.harness != .claudeCode {
                    Text(agent.harness.title)
                }
                if let tests = run.result?.tests {
                    Image(systemName: tests.status == .passed ? "checkmark.seal" : "xmark.seal")
                        .foregroundStyle(tests.status == .passed ? .green : .red)
                }
                if let control = run.result?.control {
                    Image(systemName: control.flagged ? "flag" : control.passed ? "checkmark.seal" : "xmark.seal")
                        .foregroundStyle(control.flagged ? .orange : control.passed ? .green : .red)
                }
                if let batch = run.result?.batch {
                    Text("\(batch.done)/\(batch.total) done" + (batch.failed > 0 ? ", \(batch.failed) failed" : ""))
                }
                if let metrics = run.result?.metrics {
                    Text("\(UsageText.short(metrics.freshTokens)) fresh · \(metrics.calls) \(metrics.calls == 1 ? "call" : "calls")")
                }
                Spacer()
                Text(run.spec.createdAt, format: .relative(presentation: .named))
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
        .padding(.vertical, 2)
    }
}

struct LabStatusBadge: View {
    let run: LabRun

    var body: some View {
        Label(title, systemImage: icon)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(color.opacity(0.2), in: Capsule())
            .foregroundStyle(color)
            .help(run.message ?? title)
    }

    private var title: String {
        switch run.status {
        case .queued: run.launch == nil ? "Queued" : "Starting"
        case .running: run.state?.phase?.title ?? "Running"
        case .finished: "Finished"
        case .cancelled: "Cancelled"
        case .error: "Error"
        }
    }

    private var icon: String {
        switch run.status {
        case .queued: "clock"
        case .running: "play.circle"
        case .finished: "checkmark.circle"
        case .cancelled: "stop.circle"
        case .error: "exclamationmark.triangle"
        }
    }

    private var color: Color {
        switch run.status {
        case .queued: .secondary
        case .running: .blue
        case .finished: .green
        case .cancelled: .secondary
        case .error: .red
        }
    }
}

extension RunSpec.Kind {
    var title: String {
        switch self {
        case .review: "Session review"
        case .replay: "Replay task"
        case .analysis: "Error analysis batch"
        case .control: "Control cell"
        }
    }
}

extension LabEnvironment {
    var icon: String {
        switch self {
        case .orca: "terminal"
        case .herdr: "rectangle.split.3x1"
        case .background: "gearshape.2"
        }
    }
}

/// One run: what it is, where it runs, and what came out.
private struct LabRunDetail: View {
    @Environment(AppModel.self) private var model
    let run: LabRun
    /// Selects another run (a re-check just queued, the review that replaced these notes).
    let select: (LabRun) -> Void
    @State private var error: String?
    @State private var confirmRemove = false
    /// The review's notes file, when this run wrote the one saved for its session.
    @State private var notes: SessionNotes?
    /// The run whose review replaced this one's notes.
    @State private var replacedBy: String?
    /// Snapshots: `--tab recheck` opens the Re-check sheet.
    @State private var showRecheck = DebugSnapshot.options?.tab == "recheck"

    var body: some View {
        ScrollViewReader { proxy in
            scroll
                .task(id: notes) {
                    // Snapshots: `--tab notes` scrolls to the review's notes.
                    guard notes != nil, DebugSnapshot.options?.tab == "notes" else { return }
                    try? await Task.sleep(for: .milliseconds(300))
                    proxy.scrollTo("notes", anchor: .top)
                }
        }
        .task(id: run) { await loadNotes() }
        .sheet(isPresented: $showRecheck) {
            RecheckSheet(run: run) { select($0) }
        }
        .confirmationDialog("Move this run to the Trash?", isPresented: $confirmRemove) {
            Button("Move to Trash", role: .destructive) { act { try await model.remove(run) } }
        } message: {
            Text("Its folder \(run.folder.tildePath) goes to the Trash, with everything the agent wrote there.")
        }
    }

    private var scroll: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                if let message = run.message, run.status == .error || run.status == .cancelled {
                    Label(message, systemImage: run.status == .error ? "exclamationmark.triangle" : "stop.circle")
                        .foregroundStyle(run.status == .error ? .red : .secondary)
                        .textSelection(.enabled)
                }
                if let error {
                    Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                }
                switch run.spec.kind {
                case .review: review
                case .replay: replay
                case .analysis: LabBatchSection(run: run, select: select)
                case .control: LabControlSection(run: run)
                }
                if let metrics = run.result?.metrics {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("The run's own agent session").font(.title3.bold())
                        MetricsView(metrics: metrics)
                    }
                } else if run.status == .finished, run.spec.kind != .analysis {
                    Text(run.spec.agent?.harness == .pi ? "AKit doesn't measure Pi sessions yet, so there are no numbers."
                         : "Claude Code wrote no transcript for this run, so there are no numbers.")
                        .foregroundStyle(.secondary)
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(run.spec.title).font(.title2.bold()).textSelection(.enabled).lineLimit(3)
                Spacer()
                LabStatusBadge(run: run)
            }
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 4) {
                row("Kind", run.spec.kind.title)
                if let agent = run.spec.agent { row("Agent", agent.label) }
                if let language = run.spec.language, language != .english { row("Language", language.name) }
                row("Opens in", "\(run.spec.environment.title) · \(URL(filePath: run.spec.folder).tildePath)")
                if let setup = run.spec.setup { row("Setup", setup.label) }
                row("Queued", run.spec.createdAt.formatted(date: .abbreviated, time: .shortened))
                if let started = run.state?.startedAt {
                    row("Started", started.formatted(date: .abbreviated, time: .shortened))
                }
                if run.status == .finished || run.status == .cancelled || run.status == .error, let state = run.state {
                    row("Ended", state.updatedAt.formatted(date: .abbreviated, time: .shortened))
                }
                row("Folder", run.folder.tildePath, monospaced: true)
            }
            .font(.callout)
            .textSelection(.enabled)
            HStack {
                if run.launch != nil, run.spec.environment != .background {
                    Button("Show in \(run.spec.environment.title)", systemImage: "arrow.up.forward.app") {
                        act { try await model.showTab(of: run) }
                    }
                    .help("Bring the run's terminal tab forward")
                }
                if run.status == .running || run.status == .queued {
                    Button("Cancel", systemImage: "stop.circle") { act { try await model.cancel(run) } }
                        .help(run.status == .running ? "Stop the agent and its tests; the tab stays open" : "Drop it from the queue")
                }
                if run.status == .queued, run.launch == nil {
                    Button("Start", systemImage: "play") { act { try await model.startLabQueue() } }
                        .help(model.labAutoStartPaused ? "The last start failed; start the next queued run again"
                              : "Start the next queued run if nothing is running")
                }
                if run.spec.kind == .review, run.status == .finished, run.spec.reviewedTranscript != nil {
                    Button("Re-check with Another Model…", systemImage: "arrow.triangle.2.circlepath") { showRecheck = true }
                        .help("Review the same session again with another model, for hard sessions")
                }
                Button("Show in Finder", systemImage: "folder") {
                    NSWorkspace.shared.activateFileViewerSelecting([run.folder])
                }
                if run.status != .running {
                    Button("Remove…", systemImage: "trash", role: .destructive) { confirmRemove = true }
                }
            }
            .controlSize(.small)
        }
    }

    @ViewBuilder private var review: some View {
        if let transcript = run.spec.reviewedTranscript {
            let session = model.sessions.first { $0.file.path == transcript }
            HStack {
                Text("Reviewed session: \(run.spec.reviewedTitle ?? URL(filePath: transcript).lastPathComponent)")
                    .foregroundStyle(.secondary)
                if session != nil {
                    Button("Show Session") { model.section = .sessions }
                        .controlSize(.small)
                        .help("Open the Sessions screen")
                }
            }
        }
        if let status = run.result?.review, status != .ok {
            Label(status == .missing ? "The agent wrote no review.json." : "The agent's review.json isn't readable.",
                  systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)
        }
        if let error = run.result?.agentError {
            Text("The agent stopped with an error: \(error)")
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        if let replacedBy {
            HStack {
                Label("A later review of this session replaced its notes; here are this run's paragraph and improvements.",
                      systemImage: "info.circle")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let later = model.labRuns.first(where: { $0.id == replacedBy }) {
                    Button("Show Review") { select(later) }.controlSize(.small)
                }
            }
        }
        if let notes {
            ReviewNotesView(notes: notes)
        } else {
            legacyReview
        }
    }

    /// The paragraph and the improvements as the run wrote them: agent-mode reviews, and
    /// reviews whose notes a later one replaced.
    @ViewBuilder private var legacyReview: some View {
        if let summary = run.summary {
            MarkdownLines(text: summary.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        if let review = run.review {
            VStack(alignment: .leading, spacing: 10) {
                Text("What to Improve").font(.title3.bold())
                if review.findings.isEmpty {
                    Text("Nothing worth changing.").foregroundStyle(.secondary)
                }
                ForEach(Array(review.findings.enumerated()), id: \.offset) { index, finding in
                    VStack(alignment: .leading, spacing: 3) {
                        Text("\(index + 1). \(finding.title)").fontWeight(.semibold)
                        if let evidence = finding.evidence {
                            Text("Evidence: \(evidence)").foregroundStyle(.secondary)
                        }
                        Text(finding.detail).foregroundStyle(.secondary)
                    }
                    .textSelection(.enabled)
                }
            }
        }
    }

    @ViewBuilder private var replay: some View {
        if let commit = run.spec.commit {
            let task = model.labTasks[commit]
            VStack(alignment: .leading, spacing: 4) {
                Text("\(commit.prefix(7)) \(task?.subject ?? "")").fontWeight(.medium).textSelection(.enabled)
                if let task {
                    Text("From \(task.base.prefix(7)) · \(task.failToPass.count) fail-to-pass, \(task.passToPass.count) pass-to-pass tests")
                        .foregroundStyle(.secondary)
                    ForEach(task.notes, id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary) }
                }
                if run.spec.keep {
                    Text("The clone is kept: \(run.folder.appending(path: "work").tildePath)").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        if let leaks = run.result?.leaks, !leaks.isEmpty {
            Label("Left out of comparisons: the agent's tool calls mention \(leaks.joined(separator: " and ")).",
                  systemImage: "eye.trianglebadge.exclamationmark")
                .foregroundStyle(.orange)
        }
        if let error = run.result?.agentError {
            Text("The agent stopped with an error: \(error)")
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        if let tests = run.result?.tests {
            VStack(alignment: .leading, spacing: 6) {
                Text("Hidden tests").font(.title3.bold())
                Label(tests.status == .passed ? "Passed" : tests.status == .failed ? "Failed" : "Not run",
                      systemImage: tests.status == .passed ? "checkmark.seal" : "xmark.seal")
                    .foregroundStyle(tests.status == .passed ? .green : .red)
                    .font(.headline)
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 4) {
                    row("Fail-to-pass", "\(tests.failToPass.passed) of \(tests.failToPass.total) pass now")
                    row("Pass-to-pass", "\(tests.passToPass.passed) of \(tests.passToPass.total) still pass")
                    if tests.timeouts > 0 { row("Timed out", "\(tests.timeouts) (30 s each)") }
                }
                if let note = tests.note { Text(note).foregroundStyle(.orange) }
                if !tests.failed.isEmpty {
                    Text("Failed: " + tests.failed.joined(separator: ", ")).font(.callout.monospaced()).foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
        }
        if let commit = run.spec.commit {
            let comparison = LabComparison.compare(commit: commit, runs: model.labRuns)
            if comparison.rows.count > 1 || (comparison.rows.first?.runs ?? 0) > 1 {
                ComparisonView(comparison: comparison)
            }
        }
    }

    /// The notes saved for the reviewed session, read off the main thread once the run is
    /// finished. A session keeps one notes file, so a later review's file isn't this run's.
    private func loadNotes() async {
        guard run.spec.kind == .review, run.status == .finished, let transcript = run.spec.reviewedTranscript else {
            notes = nil
            replacedBy = nil
            return
        }
        let target = NotesPipeline.Target(harness: run.spec.reviewedHarness, file: URL(filePath: transcript), title: run.spec.reviewedTitle)
        let env = HarnessEnvironment.current
        let found = await Task.detached { SessionKey.of(target.summary).flatMap { NotesStore(env: env).load($0.description) } }.value
        if let found, found.runID == nil || found.runID == run.id {
            notes = found
            replacedBy = nil
        } else {
            notes = nil
            replacedBy = run.spec.agent?.mode == .call ? found?.runID : nil
        }
    }

    private func row(_ label: String, _ value: String, monospaced: Bool = false) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
            Text(value).monospaced(monospaced).lineLimit(2).truncationMode(.middle)
        }
    }

    private func act(_ work: @escaping () async throws -> Void) {
        error = nil
        Task {
            do { try await work() } catch { self.error = error.localizedDescription }
        }
    }
}

/// Markdown an agent wrote: headings as bold lines, inline styles (bold, code, links) kept.
struct MarkdownLines: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(text.split(separator: "\n", omittingEmptySubsequences: false).enumerated()), id: \.offset) { _, line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("#") {
                    Text(inline(trimmed.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces))).fontWeight(.semibold)
                } else if trimmed.isEmpty {
                    Spacer().frame(height: 2)
                } else {
                    Text(inline(String(line)))
                }
            }
        }
        .textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)
    }

    /// Links an agent wrote stay clickable only for http and https (no file:// or app schemes).
    private func inline(_ line: String) -> AttributedString {
        guard var text = try? AttributedString(markdown: line, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))
        else { return AttributedString(line) }
        for run in text.runs {
            if let link = run.link, !["http", "https"].contains(link.scheme?.lowercased() ?? "") { text[run.range].link = nil }
        }
        return text
    }
}

/// Replays of one commit per setup: passed, fresh tokens, calls and wall time as median and range.
struct ComparisonView: View {
    let comparison: LabComparison

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Setups compared").font(.title3.bold())
            Grid(alignment: .trailing, horizontalSpacing: 16, verticalSpacing: 6) {
                GridRow {
                    Text("Setup").gridColumnAlignment(.leading)
                    Text("Passed")
                    Text("Fresh tokens")
                    Text("Calls")
                    Text("Wall time")
                    Text("").gridColumnAlignment(.leading)
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                Divider()
                ForEach(comparison.rows) { row in
                    GridRow {
                        Text(row.setup)
                        Text("\(row.passed)/\(row.runs)")
                        Text(spread(row.freshTokens, UsageText.short))
                        Text(spread(row.calls) { "\($0)" })
                        Text(spread(row.wallSeconds) { UsageText.duration(TimeInterval($0)) })
                        Text(extra(row)).foregroundStyle(.secondary)
                    }
                }
            }
            .monospacedDigit()
            .textSelection(.enabled)
            Text("Median, then the range in brackets. Runs that saw the answer, stopped or are still waiting don't count. LLM runs vary: compare at least 3 runs per setup.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func spread(_ value: LabComparison.Spread?, _ format: (Int) -> String) -> String {
        guard let value else { return "–" }
        return value.min == value.max ? format(value.median) : "\(format(value.median)) (\(format(value.min))–\(format(value.max)))"
    }

    private func extra(_ row: LabComparison.Row) -> String {
        var parts: [String] = []
        if row.pending > 0 { parts.append("\(row.pending) to run") }
        if row.failed > 0 { parts.append("\(row.failed) stopped") }
        if row.leaked > 0 { parts.append("\(row.leaked) saw the answer") }
        return parts.joined(separator: " · ")
    }
}
