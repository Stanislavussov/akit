import AKitFoundation
import AKitLab
import AKitSessions
import AppKit
import SwiftUI

/// Queue Lab runs: a review of a session, or replays of a commit under one or more setups.
/// From a session (Review in Terminal…) the kind and the session are already chosen.
struct NewLabRunSheet: View {
    enum Kind: String, CaseIterable, Identifiable {
        case review, replay
        var id: Self { self }
        var title: String { self == .review ? "Review a Session" : "Replay a Commit" }
    }

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let session: SessionSummary?
    let onQueued: (LabRun) -> Void

    @State private var kind: Kind = DebugSnapshot.options?.tab.flatMap(Kind.init(rawValue:)) ?? .review
    /// nil = the one suggested for the folder.
    @State private var environment: LabEnvironment?
    @State private var suggested: LabEnvironment?
    @State private var error: String?
    @State private var busy = false

    // Review
    @State private var chosen: SessionSummary.ID?
    @State private var query = ""

    // Replay
    @State private var repo: URL?
    @State private var commit = ""
    @State private var candidates: [ReplayTasks.Candidate] = []
    @State private var draft: ReplayTasks.Draft?
    @State private var draftError: String?
    @State private var full = true
    @State private var lean = false
    @State private var modelName = ""
    @State private var effort = "high"
    @State private var repeats = 3
    @State private var keep = false
    /// The last line of a running task check.
    @State private var checking: String?
    @State private var checked: ReplayTask?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("New Lab Run").font(.title2.bold())
            if session == nil {
                Picker("Kind", selection: $kind) {
                    ForEach(Kind.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            switch kind {
            case .review: review
            case .replay: replay
            }
            Picker("Open in", selection: $environment) {
                Text(suggested.map { "Automatic (\($0.title))" } ?? "Automatic").tag(LabEnvironment?.none)
                ForEach(model.labEnvironments, id: \.self) { Text($0.title).tag(LabEnvironment?.some($0)) }
            }
            .frame(maxWidth: 320)
            if let folder = tabFolder {
                Text("The tab opens in \(folder.tildePath). One run at a time: new runs wait in the queue while another runs.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let error {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red).font(.callout)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(queueTitle) { queue() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canQueue || busy)
            }
        }
        .padding(20)
        .frame(width: 620, height: session == nil ? 700 : 300)
        .task(id: tabFolder) {
            suggested = nil
            guard let folder = tabFolder else { return }
            suggested = await model.suggestedEnvironment(for: folder)
        }
        .task {
            let defaults = model.defaultModelAndEffort
            if modelName.isEmpty { modelName = defaults.model }
            effort = LabRuns.efforts.contains(defaults.effort) ? defaults.effort : "high"
        }
        // Snapshots: --project picks the repository and --query the commit, once projects are scanned.
        .task(id: model.projects.count) {
            guard repo == nil, let name = DebugSnapshot.options?.project else { return }
            repo = model.projects.first { $0.lastPathComponent == name }
        }
        .onChange(of: candidates) {
            if commit.isEmpty, let query = DebugSnapshot.options?.query { commit = query }
        }
    }

    private var tabFolder: URL? {
        switch kind {
        case .review: target?.project
        case .replay: repo
        }
    }

    private var queueTitle: String {
        switch kind {
        case .review: "Queue and Start"
        case .replay: runCount == 1 ? "Queue 1 Run" : "Queue \(runCount) Runs"
        }
    }

    private var runCount: Int { repeats * setups.count }

    private var canQueue: Bool {
        switch kind {
        case .review: target != nil
        case .replay: repo != nil && draft != nil && checking == nil && !setups.isEmpty
            && !modelName.trimmingCharacters(in: .whitespaces).isEmpty
        }
    }

    // MARK: Review

    private var target: SessionSummary? {
        session ?? model.sessions.first { $0.id == chosen }
    }

    @ViewBuilder private var review: some View {
        Text("An agent reads the session (secrets masked) and AKit's numbers for it, then writes a review: where it lost time or tokens and what to change. It runs headless with Claude Code; nothing in your projects changes.")
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        if session == nil {
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
        } else if let target {
            Text("Session: \(target.title)").fontWeight(.medium)
        }
    }

    private var claudeSessions: [SessionSummary] {
        let q = query.trimmingCharacters(in: .whitespaces)
        return model.sessions.filter { $0.harness == .claudeCode }
            .filter { q.isEmpty || $0.title.localizedCaseInsensitiveContains(q) || ($0.project?.path.localizedCaseInsensitiveContains(q) ?? false) }
    }

    // MARK: Replay

    private var setups: [LabSetup] {
        let name = modelName.trimmingCharacters(in: .whitespaces)
        return [full ? LabSetup.Name.full : nil, lean ? .lean : nil].compactMap { $0 }
            .map { LabSetup(name: $0, model: name, effort: effort) }
    }

    @ViewBuilder private var replay: some View {
        Text("The agent redoes a commit from its parent in an isolated clone (no refs, no remote, not the answer). Then the commit's own tests judge it: those that failed before the commit must pass, the others must keep passing. The first run checks the task (two builds).")
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        Form {
            HStack {
                Picker("Repository", selection: $repo) {
                    Text("Choose…").tag(URL?.none)
                    ForEach(repositories, id: \.self) { Text($0.lastPathComponent).tag(URL?.some($0)) }
                }
                Button("Other…") { chooseRepository() }
            }
            HStack {
                TextField("Commit", text: $commit, prompt: Text("hash, e.g. 1c9cf65"))
                    .monospaced()
                Menu("Recent") {
                    ForEach(candidates) { candidate in
                        Button("\(candidate.commit.prefix(7))  \(candidate.subject)\(candidate.task == nil ? "" : "  ✓ checked")") {
                            commit = candidate.commit
                        }
                    }
                }
                .fixedSize()
                .disabled(candidates.isEmpty)
                .help("Recent commits that change tests")
            }
            if let draft {
                Text(draft.subject).foregroundStyle(.secondary)
            }
            if let draft {
                let cached = checked ?? ReplayTasks.cached(draft.commit, env: .current)
                LabeledContent("Tests") {
                    HStack {
                        Text(cached.map { "\($0.failToPass.count) fail-to-pass, \($0.passToPass.count) pass-to-pass (checked)" }
                             ?? "\(draft.tests.count) in \(draft.testFiles.map { URL(filePath: $0).lastPathComponent }.joined(separator: ", ")) (the first run checks them)")
                            .foregroundStyle(.secondary)
                        if cached == nil {
                            Button(checking == nil ? "Check Now" : "Checking…") { check(draft) }
                                .disabled(checking != nil)
                                .help("Run the tests on the parent and on the commit now (two builds, a few minutes)")
                        }
                    }
                }
                if let checking { Text(checking).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                if let draftError { Text(draftError).foregroundStyle(.orange).font(.callout) }
            } else if let draftError {
                Text(draftError).foregroundStyle(.orange).font(.callout)
            }
            LabeledContent("Setups") {
                HStack {
                    Toggle("Full", isOn: $full).help("Your normal setup: plugins, hooks, skills")
                    Toggle("Lean", isOn: $lean).help("--setting-sources project: no user plugins or hooks")
                }
            }
            TextField("Model", text: $modelName, prompt: Text("opus"))
            Picker("Effort", selection: $effort) {
                ForEach(LabRuns.efforts, id: \.self) { Text($0).tag($0) }
            }
            Stepper("Repeats: \(repeats) per setup", value: $repeats, in: 1...10)
            Toggle("Keep the clone (otherwise it goes to the Trash, build folder and all)", isOn: $keep)
        }
        .formStyle(.grouped)
        .task(id: repo) {
            candidates = []
            draft = nil
            commit = ""
            guard let repo else { return }
            candidates = await model.replayCandidates(in: repo)
        }
        .task(id: "\(repo?.path ?? "")|\(commit)") {
            draft = nil
            draftError = nil
            checked = nil
            let commit = commit.trimmingCharacters(in: .whitespaces)
            guard let repo, commit.count >= 4 else { return }
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            do {
                draft = try await model.replayDraft(commit: commit, repo: repo)
            } catch {
                draftError = error.localizedDescription
            }
        }
    }

    private func check(_ draft: ReplayTasks.Draft) {
        checking = "Starting…"
        draftError = nil
        Task {
            do {
                checked = try await model.checkTask(draft) { checking = $0 }
            } catch {
                draftError = error.localizedDescription
            }
            checking = nil
        }
    }

    /// Known projects that are git repositories, by name.
    private var repositories: [URL] {
        var list = model.projects.filter { FileManager.default.fileExists(atPath: $0.appending(path: ".git").path) }
        if let repo, !list.contains(repo) { list.append(repo) }
        return list.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    private func chooseRepository() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Choose"
        panel.message = "A git repository (or one of its worktrees)"
        if panel.runModal() == .OK, let url = panel.url { repo = url }
    }

    private func queue() {
        busy = true
        error = nil
        Task {
            do {
                switch kind {
                case .review:
                    guard let target else { break }
                    onQueued(try await model.queueReview(of: target, environment: environment))
                case .replay:
                    guard let repo, let draft else { break }
                    let runs = try await model.queueReplays(commit: draft.commit, repo: repo, setups: setups, repeats: repeats,
                                                            environment: environment, keep: keep)
                    if let first = runs.first { onQueued(first) }
                }
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
            busy = false
        }
    }
}
