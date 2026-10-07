import AKitFoundation
import AKitInsights
import AKitModel
import AKitSessions
import AppKit
import SwiftUI

/// Sessions screen: saved conversations of every installed harness, newest first.
/// Read-only: AKit never changes session files.
struct SessionsView: View {
    @Environment(AppModel.self) private var model
    @State private var selection: SessionSummary.ID?
    @State private var query = ""
    /// nil = all harnesses.
    @State private var harness: HarnessID? = DebugSnapshot.options?.harness.map { HarnessID($0, displayName: $0) }
    @State private var project = SessionProjectFilter.all

    var body: some View {
        let names = SessionProjects.names(of: model.sessionProjects.values)
        return HSplitView {
            list(names)
                .frame(minWidth: 260, idealWidth: 320, maxWidth: 480)
            Group {
                if let session = model.sessions.first(where: { $0.id == selection }) {
                    SessionDetailView(session: session, projectID: projectID(of: session))
                } else {
                    ContentUnavailableView("Select a session", systemImage: "bubble.left.and.bubble.right")
                }
            }
            .frame(minWidth: 380, maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle("Sessions")
        .navigationSubtitle(subtitle)
        .searchable(text: $query, placement: .toolbar, prompt: "Title or project")
        .toolbar {
            ToolbarItem {
                Picker("Project", selection: $project) {
                    Text("All projects").tag(SessionProjectFilter.all)
                    ForEach(projects(names), id: \.id) { item in
                        Text("\(item.name)  (\(item.count))").tag(SessionProjectFilter.project(item.id))
                    }
                    if unboundCount > 0 || project == .none {
                        Divider()
                        Text("No project  (\(unboundCount))").tag(SessionProjectFilter.none)
                    }
                }
                .help("Show sessions of one project: its main folder and all its worktrees")
            }
            ToolbarItem {
                Picker("Harness", selection: $harness) {
                    Text("All harnesses").tag(HarnessID?.none)
                    ForEach(harnesses, id: \.self) { id in
                        Text(id.displayName).tag(HarnessID?.some(id))
                    }
                }
                .help("Show sessions of one harness")
            }
            ToolbarItem {
                Button("Refresh", systemImage: "arrow.clockwise") { Task { await model.refresh() } }
                    .disabled(model.isScanning)
                    .help("Rescan sessions (⌘R)")
            }
        }
        .onAppear { selection = selection ?? filtered.first?.id }
        .onChange(of: model.sessions) { if selection.flatMap({ id in model.sessions.first { $0.id == id } }) == nil { selection = filtered.first?.id } }
        .onChange(of: project) { keepSelectionListed() }
        .onChange(of: harness) { keepSelectionListed() }
        .onChange(of: model.sessionProjects, initial: true) {
            // `--project <name>` in snapshot mode picks that project once the projects are known.
            if project == .all, let name = DebugSnapshot.options?.project,
               let id = names.first(where: { $0.value.caseInsensitiveCompare(name) == .orderedSame })?.key {
                project = .project(id)
                selection = filtered.first?.id
            } else if case .project(let id) = project, names[id] == nil {
                // The chosen project has no sessions any more.
                project = .all
            }
        }
    }

    private func list(_ names: [String: String]) -> some View {
        List(filtered, selection: $selection) { session in
            SessionRow(session: session, projectName: projectID(of: session).flatMap { names[$0] },
                       ratings: model.ratings[session.file.path] ?? [])
                .tag(session.id)
                .contextMenu {
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([session.file]) }
                    if let project = session.project {
                        Button("Show Project in Finder") { NSWorkspace.shared.activateFileViewerSelecting([project]) }
                    }
                }
        }
        .overlay {
            if !query.isEmpty && filtered.isEmpty {
                ContentUnavailableView.search(text: query)
            } else if model.sessions.isEmpty && !model.isScanning {
                ContentUnavailableView("No sessions found", systemImage: "bubble.left.and.bubble.right")
            }
        }
    }

    /// Harnesses that have at least one session.
    private var harnesses: [HarnessID] {
        var seen = Set<HarnessID>()
        return model.sessions.map(\.harness).filter { seen.insert($0).inserted }.sorted()
    }

    /// After a filter change the detail never shows a session the list hides.
    private func keepSelectionListed() {
        let listed = filtered
        if !listed.contains(where: { $0.id == selection }) { selection = listed.first?.id }
    }

    private func projectID(of session: SessionSummary) -> String? {
        session.project.flatMap { model.sessionProjects[$0.path] }
    }

    /// Projects that have at least one session, by name, with their session count.
    private func projects(_ names: [String: String]) -> [(id: String, name: String, count: Int)] {
        var counts: [String: Int] = [:]
        for session in model.sessions {
            if let id = projectID(of: session) { counts[id, default: 0] += 1 }
        }
        return counts.map { (id: $0.key, name: names[$0.key] ?? $0.key, count: $0.value) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Sessions outside every project: the home folder, temporary folders, deleted folders nobody knows.
    private var unboundCount: Int {
        model.sessions.count { projectID(of: $0) == nil }
    }

    private var subtitle: String {
        filtered.count == model.sessions.count ? "\(model.sessions.count) sessions" : "\(filtered.count) of \(model.sessions.count)"
    }

    private var filtered: [SessionSummary] {
        let q = query.trimmingCharacters(in: .whitespaces)
        return model.sessions.filter { session in
            let id = projectID(of: session)
            return (harness == nil || session.harness == harness)
                && project.matches(id)
                && (q.isEmpty || session.title.localizedCaseInsensitiveContains(q)
                    || (session.project?.path.localizedCaseInsensitiveContains(q) ?? false)
                    || (id?.localizedCaseInsensitiveContains(q) ?? false))
        }
    }
}

/// Which sessions the Sessions screen lists, by project.
private enum SessionProjectFilter: Hashable {
    case all
    /// Sessions bound to this project id: its main folder and its worktrees.
    case project(String)
    /// Sessions outside every project.
    case none

    func matches(_ id: String?) -> Bool {
        switch self {
        case .all: true
        case .project(let chosen): id == chosen
        case .none: id == nil
        }
    }
}

private struct SessionRow: View {
    let session: SessionSummary
    /// Short name of the session's project, if it has one.
    let projectName: String?
    let ratings: [Ratings.Rating]

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(session.title).fontWeight(.medium).lineLimit(2)
                Spacer()
                if !ratings.isEmpty {
                    Text(RatingText.counts(ratings)).font(.caption)
                        .help(RatingText.list(ratings))
                }
                HarnessBadge(harness: session.harness)
            }
            HStack(spacing: 6) {
                if let project = session.project {
                    // A worktree shows its project first: "akit · bowhead".
                    let folder = project.lastPathComponent
                    let isOwnFolder = projectName.map { $0.caseInsensitiveCompare(folder) == .orderedSame } ?? true
                    Label(isOwnFolder ? folder : "\(projectName ?? "") · \(folder)", systemImage: "folder")
                        .help(project.tildePath)
                }
                Spacer()
                Text(session.modified, format: .relative(presentation: .named))
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
        .padding(.vertical, 2)
    }
}

enum SessionDetailTab: String, CaseIterable, Identifiable {
    case conversation
    case usage
    case analysis
    case prompt
    var id: Self { self }

    var title: String {
        switch self {
        case .conversation: "Conversation"
        case .usage: "Usage"
        case .analysis: "Analysis"
        case .prompt: "System Prompt"
        }
    }

    /// Lab analysis reads Claude Code transcripts only.
    static func available(for harness: HarnessID) -> [SessionDetailTab] {
        allCases.filter { $0 != .analysis || harness == .claudeCode }
    }
}

private struct SessionDetailView: View {
    @Environment(AppModel.self) private var model
    let session: SessionSummary
    /// The project the session's folder belongs to, if any.
    let projectID: String?
    @State private var transcript: SessionTranscript?
    @State private var error: String?
    @State private var copied = false
    @State private var showReview = false
    @State private var tab = DebugSnapshot.options?.tab.flatMap(SessionDetailTab.init(rawValue:)) ?? .conversation

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(20)
            Divider()
            switch tab {
            case .conversation: content
            case .usage: usage
            case .analysis:
                if session.harness == .claudeCode {
                    SessionAnalysisView(session: session)
                } else {
                    content
                }
            case .prompt: SessionPromptView(session: session)
            }
        }
        .sheet(isPresented: $showReview) {
            NewLabRunSheet(session: session) { _ in model.section = .lab }
        }
        // Reload on selection change and after every rescan (⌘R).
        .task(id: "\(session.id)|\(session.modified.timeIntervalSince1970)") {
            transcript = nil
            error = nil
            do {
                let loaded = try await model.transcript(of: session)
                guard !Task.isCancelled else { return }
                transcript = loaded
            } catch {
                guard !Task.isCancelled else { return }
                self.error = error.localizedDescription
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(session.title).font(.title2.bold()).textSelection(.enabled).lineLimit(3)
                Spacer()
                HarnessBadge(harness: session.harness)
                if session.harness == .claudeCode {
                    Button("Review in Terminal…", systemImage: "flask") { showReview = true }
                        .labelStyle(.iconOnly)
                        .help("Lab: an agent reviews this session in a terminal tab and writes what to change")
                }
                copyMenu
                if ExternalEditor.appURL != nil {
                    Button("Open in \(ExternalEditor.name)", systemImage: "square.and.pencil") {
                        ExternalEditor.open(session.file)
                    }
                    .labelStyle(.iconOnly)
                    .help("Open the raw session file in \(ExternalEditor.name)")
                }
                Button("Show in Finder", systemImage: "folder") {
                    NSWorkspace.shared.activateFileViewerSelecting([session.file])
                }
                .labelStyle(.iconOnly)
                .help("Show the session file in Finder")
            }
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 4) {
                if let projectID {
                    row("Project", projectID)
                }
                if let project = session.project {
                    row("Folder", project.tildePath, monospaced: true)
                }
                if let started = session.started {
                    row("Started", started.formatted(date: .abbreviated, time: .shortened))
                }
                row("Last change", session.modified.formatted(date: .abbreviated, time: .shortened))
                if let models = transcript?.models, !models.isEmpty {
                    row("Model", models.joined(separator: ", "))
                }
                if let usage = transcript?.usage, usage.hasTokens {
                    row("Tokens", UsageText.summary(usage))
                }
                row("File", "\(session.file.tildePath) · \(session.size.formatted(.byteCount(style: .file)))", monospaced: true)
                if let version = session.harnessVersion {
                    row("Version", version)
                }
                if let ratings = model.ratings[session.file.path], !ratings.isEmpty {
                    GridRow {
                        Text("Ratings").foregroundStyle(.secondary).gridColumnAlignment(.trailing)
                        Text(RatingText.list(ratings)).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .font(.callout)
            .textSelection(.enabled)

            Picker("View", selection: $tab) {
                ForEach(SessionDetailTab.available(for: session.harness)) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
        }
    }

    /// The whole conversation, secrets masked as shown, for other agents and evals.
    private var copyMenu: some View {
        Menu {
            Button("Copy as Markdown") { copy(SessionExport.markdown) }
            Button("Copy as JSON") { copy(SessionExport.json) }
            Divider()
            Button("Copy Usage Only") { copy(SessionExport.usageMarkdown) }
                .disabled(!(transcript?.usage.hasTokens ?? false))
        } label: {
            Label(copied ? "Copied" : "Copy Session", systemImage: copied ? "checkmark" : "doc.on.doc")
        } primaryAction: {
            copy(SessionExport.markdown)
        }
        .menuStyle(.button)
        .fixedSize()
        .disabled(transcript?.items.isEmpty ?? true)
        .help("Copy the whole conversation as Markdown; the arrow also offers JSON. Secrets stay masked.")
    }

    private func copy(_ format: (SessionSummary, SessionTranscript) -> String) {
        guard let transcript else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(format(session, transcript), forType: .string)
        copied = true
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            copied = false
        }
    }

    private func row(_ label: String, _ value: String, monospaced: Bool = false) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
            Text(value).monospaced(monospaced).lineLimit(2).truncationMode(.middle)
        }
    }

    @ViewBuilder private var usage: some View {
        if let error {
            ContentUnavailableView("Couldn't read the session", systemImage: "exclamationmark.triangle",
                                   description: Text(error))
        } else if let transcript {
            SessionUsageView(usage: transcript.usage)
        } else {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder private var content: some View {
        if let error {
            ContentUnavailableView("Couldn't read the session", systemImage: "exclamationmark.triangle",
                                   description: Text(error))
        } else if let transcript {
            if transcript.items.isEmpty {
                ContentUnavailableView("No messages", systemImage: "bubble.left")
            } else {
                TranscriptView(items: transcript.items)
            }
        } else {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// The system prompt of one session: saved in it (Claude Code) or caught now (Pi).
private struct SessionPromptView: View {
    @Environment(AppModel.self) private var model
    let session: SessionSummary
    @State private var prompt: PromptSnapshot?
    @State private var isLoading = true
    @State private var error: String?

    var body: some View {
        switch model.promptAccess(session.harness) {
        case .recorded: recorded
        case .captured:
            let project = session.project ?? HarnessEnvironment.current.homeDirectory
            CapturedPromptView(harness: session.harness, project: project)
                .id(project)
        case .unavailable:
            ContentUnavailableView("Not available", systemImage: "doc.plaintext",
                                   description: Text("AKit can't read the system prompt of \(session.harness.displayName)."))
        }
    }

    private var recorded: some View {
        Group {
            if let prompt {
                PromptSnapshotView(snapshot: prompt) {
                    Text("As saved by \(session.harness.displayName) in this session: the latest version, reused until the conversation is compacted.")
                }
            } else if isLoading {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView("No saved system prompt", systemImage: "doc.plaintext",
                                       description: Text(error ?? "This session was written by a version that doesn't save it (Claude Code saves it since 2.1.265)."))
            }
        }
        .task(id: "\(session.id)|\(session.modified.timeIntervalSince1970)") {
            // Never show the previous session's prompt while this one loads.
            prompt = nil
            isLoading = true
            error = nil
            do {
                let loaded = try await model.recordedPrompt(in: session)
                guard !Task.isCancelled else { return }
                prompt = loaded
            } catch {
                guard !Task.isCancelled else { return }
                self.error = error.localizedDescription
            }
            isLoading = false
        }
    }
}

/// The conversation, top to bottom. Thinking, tool calls and results start collapsed.
struct TranscriptView: View {
    let items: [TranscriptItem]

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                ForEach(items) { item in
                    TranscriptRow(item: item)
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct TranscriptRow: View {
    let item: TranscriptItem

    var body: some View {
        switch item.kind {
        case .user:
            LongText(text: item.text)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
        case .assistant:
            LongText(text: item.text)
                .padding(.horizontal, 10)
        case .thinking:
            Collapsible(title: "Thinking", icon: "brain", tint: .secondary, text: item.text, monospaced: false)
        case .toolCall(let name):
            Collapsible(title: name, icon: "wrench.and.screwdriver", tint: .teal, text: item.text, monospaced: true)
        case .toolResult(let name, let isError):
            Collapsible(title: isError ? "\(name ?? "Tool") failed" : "\(name ?? "Tool") result",
                        icon: isError ? "xmark.octagon" : "arrow.turn.down.right",
                        tint: isError ? .red : .secondary, text: item.text, monospaced: true)
        case .event(let title):
            Collapsible(title: title, icon: "info.circle", tint: .orange, text: item.text, monospaced: false,
                        startsExpanded: item.text.count < 200)
        }
    }
}

/// Ratings of a session's runs, as the Pi extension shows them: 👍 good, 👎 bad, the comment in «».
enum RatingText {
    /// `👍 2  👎 1`.
    static func counts(_ ratings: [Ratings.Rating]) -> String {
        let good = ratings.filter(\.isGood).count, bad = ratings.count - good
        return [good > 0 ? "👍 \(good)" : nil, bad > 0 ? "👎 \(bad)" : nil].compactMap { $0 }.joined(separator: "  ")
    }

    /// One line per rating: time, face and comment.
    static func list(_ ratings: [Ratings.Rating]) -> String {
        ratings.map { rating in
            "\(rating.date.formatted(date: .omitted, time: .shortened))  \(rating.isGood ? "👍" : "👎")"
                + (rating.text.map { " «\($0)»" } ?? "")
        }
        .joined(separator: "\n")
    }
}
