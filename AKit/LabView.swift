import AKitFoundation
import AKitLab
import AKitSessions
import AppKit
import SwiftUI

/// Lab screen: the queue and past runs. Runs happen in a terminal tab (Orca, herdr) or in
/// the background; this screen reads their folders in `~/.akit/lab` every two seconds.
struct LabView: View {
    @Environment(AppModel.self) private var model
    @State private var selection: LabRun.ID? = DebugSnapshot.options?.select
    @State private var showNewRun = DebugSnapshot.options?.add == true
    @State private var problem: String?

    var body: some View {
        HSplitView {
            list
                .frame(minWidth: 280, idealWidth: 340, maxWidth: 480)
            Group {
                if let run = model.labRuns.first(where: { $0.id == selection }) {
                    LabRunDetail(run: run)
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
        .navigationTitle("Lab")
        .navigationSubtitle(subtitle)
        .toolbar {
            ToolbarItem {
                Button("New Run…", systemImage: "plus") { showNewRun = true }
                    .help("Queue a review of a session")
            }
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
        .sheet(isPresented: $showNewRun) {
            NewLabRunSheet(session: nil) { run in selection = run.id }
        }
        .task {
            await model.reloadLab()
            if selection == nil { selection = model.labRuns.first?.id }
            problem = await model.labProblem()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                await model.reloadLab()
            }
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
                if let metrics = run.result?.metrics {
                    Text("\(UsageText.short(metrics.freshTokens)) fresh · \(metrics.calls) calls")
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
    @State private var error: String?
    @State private var confirmRemove = false

    var body: some View {
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
                if run.spec.kind == .review { review }
                if let metrics = run.result?.metrics {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("The run's own agent session").font(.title3.bold())
                        MetricsView(metrics: metrics)
                    }
                } else if run.status == .finished {
                    Text("Claude Code wrote no transcript for this run, so there are no numbers.")
                        .foregroundStyle(.secondary)
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .confirmationDialog("Move this run to the Trash?", isPresented: $confirmRemove) {
            Button("Move to Trash", role: .destructive) { act { try await model.remove(run) } }
        } message: {
            Text("Its folder \(run.folder.tildePath) goes to the Trash, with everything the agent wrote there.")
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
                row("Kind", run.spec.kind == .review ? "Session review" : "Replay task")
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
                        .help("Start the next queued run if nothing is running")
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
        if let summary = run.summary {
            VStack(alignment: .leading, spacing: 8) {
                Text("Summary").font(.title3.bold())
                MarkdownLines(text: summary)
            }
        }
        if let review = run.review, !review.findings.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("Findings").font(.title3.bold())
                ForEach(Array(review.findings.enumerated()), id: \.offset) { index, finding in
                    VStack(alignment: .leading, spacing: 3) {
                        Text("\(index + 1). \(finding.title)").fontWeight(.semibold)
                        Text(finding.detail).foregroundStyle(.secondary)
                    }
                    .textSelection(.enabled)
                }
            }
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

/// Queue a run. From a session (Review in Terminal…) the session is already chosen.
struct NewLabRunSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let session: SessionSummary?
    let onQueued: (LabRun) -> Void

    @State private var chosen: SessionSummary.ID?
    @State private var query = ""
    /// nil = the one suggested for the folder.
    @State private var environment: LabEnvironment?
    @State private var suggested: LabEnvironment?
    @State private var error: String?
    @State private var busy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("New Lab Run").font(.title2.bold())
            Text("An agent reads the session (secrets masked) and AKit's numbers for it, then writes a review: where it lost time or tokens and what to change. It runs headless with Claude Code; nothing in your projects changes.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if session == nil { picker } else if let target { Text("Session: \(target.title)").fontWeight(.medium) }
            Picker("Open in", selection: $environment) {
                Text(suggested.map { "Automatic (\($0.title))" } ?? "Automatic").tag(LabEnvironment?.none)
                ForEach(model.labEnvironments, id: \.self) { Text($0.title).tag(LabEnvironment?.some($0)) }
            }
            .frame(maxWidth: 320)
            if let folder = target?.project {
                Text("The tab opens in \(folder.tildePath). One run at a time: it waits in the queue while another runs.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let error {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red).font(.callout)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Queue and Start") { queue() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(target == nil || busy)
            }
        }
        .padding(20)
        .frame(width: 560, height: session == nil ? 560 : 300)
        .task(id: target?.id) {
            suggested = nil
            guard let folder = target?.project else { return }
            suggested = await model.suggestedEnvironment(for: folder)
        }
    }

    private var claudeSessions: [SessionSummary] {
        let q = query.trimmingCharacters(in: .whitespaces)
        return model.sessions.filter { $0.harness == .claudeCode }
            .filter { q.isEmpty || $0.title.localizedCaseInsensitiveContains(q) || ($0.project?.path.localizedCaseInsensitiveContains(q) ?? false) }
    }

    private var target: SessionSummary? {
        session ?? model.sessions.first { $0.id == chosen }
    }

    private var picker: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("Search sessions", text: $query)
                .textFieldStyle(.roundedBorder)
            List(claudeSessions, selection: $chosen) { session in
                HStack {
                    Text(session.title).lineLimit(1)
                    Spacer()
                    Text(session.project?.lastPathComponent ?? "").foregroundStyle(.secondary)
                    Text(session.modified, format: .relative(presentation: .named)).foregroundStyle(.secondary)
                }
                .font(.callout)
                .tag(session.id)
            }
            .frame(minHeight: 220)
        }
    }

    private func queue() {
        guard let target else { return }
        busy = true
        error = nil
        Task {
            do {
                let run = try await model.queueReview(of: target, environment: environment)
                onQueued(run)
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
            busy = false
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

    private func inline(_ line: String) -> AttributedString {
        (try? AttributedString(markdown: line, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(line)
    }
}
