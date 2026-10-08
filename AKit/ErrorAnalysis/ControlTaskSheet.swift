import AKitErrorAnalysis
import AKitFoundation
import AKitInsights
import AKitSessions
import AppKit
import SwiftUI

/// `akit analysis control task new`: a task from a reviewed session or an exemplar (its first
/// user turn at HEAD of its start), or a minimal reproduction the user writes. The oracle is
/// the project's test command or a mode's code check on the cell's transcript.
struct NewControlTaskSheet: View {
    enum OracleKind: String, CaseIterable {
        case tests, assertion
        var title: String { self == .tests ? "Test command" : "Mode's code check" }
    }

    /// A session to make the task from.
    struct Source: Hashable {
        var key: String
        var title: String
        var transcript: String?
        var project: String?
        /// Modes it is an exemplar of.
        var exemplarOf: [String]
    }

    @Environment(AnalysisModel.self) private var analysis
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let fromSession: Bool
    /// A session picked elsewhere (Sessions → Add to Layer Set…), listed and selected.
    let preset: Source?
    @State private var gitRepositories: [URL] = []
    @State private var query = ""
    @State private var source: String?

    init(fromSession: Bool, preset: Source? = nil) {
        self.fromSession = fromSession
        self.preset = preset
        _source = State(initialValue: preset?.key)
    }
    @State private var repo: URL?
    @State private var base = ""
    @State private var prompt = ""
    @State private var modeID: String?
    @State private var oracle = OracleKind.tests
    @State private var command = ""
    @State private var assertMode = CodeChecks.all.first?.modeID ?? ""
    @State private var reference = ""
    @State private var layerSet: String?
    @State private var error: String?
    @State private var busy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(fromSession ? "New Control Task from a Session" : "New Reproduction").font(.title2.bold())
            Text(fromSession
                 ? "The session's first user turn, verbatim, at the HEAD the capture hook recorded at its start, in the repository it ran in. A session that started with uncommitted changes can't become one: write a reproduction instead."
                 : "The simplest request that triggers the mode, at a commit of a repository.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if fromSession { sessions } else { reproduction }
            Form {
                Picker("Mode", selection: $modeID) {
                    Text("None").tag(String?.none)
                    ForEach(analysis.data.current, id: \.id) { Text($0.name).tag(String?.some($0.id)) }
                }
                .help("The mode the task is about")
                Picker("Oracle", selection: $oracle) {
                    ForEach(OracleKind.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                switch oracle {
                case .tests:
                    TextField("Test command", text: $command, prompt: Text("make test"))
                        .help("Runs in the clone with /bin/sh; exit 0 passes")
                    TextField("Reference commit", text: $reference, prompt: Text("optional: a commit where the tests pass"))
                case .assertion:
                    Picker("Code check", selection: $assertMode) {
                        ForEach(CodeChecks.all, id: \.modeID) { check in
                            Text(analysis.data.mode(check.modeID)?.name ?? check.modeID).tag(check.modeID)
                        }
                    }
                    .help("The cell passes when the mode doesn't show (a success mode: when it does)")
                }
                LayerSetPicker(layer: $layerSet)
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
            .frame(height: oracle == .tests ? 240 : 200)
            if let error {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red).font(.callout)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                if busy { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save Task", action: save).keyboardShortcut(.defaultAction).disabled(busy || !canSave)
            }
        }
        .padding(20)
        .frame(width: 640)
        .task {
            // Opened from the Sessions screen: the modes may not be read yet, and the task is
            // meant for a set.
            if !analysis.loaded { await analysis.reload() }
            if preset != nil, layerSet == nil { layerSet = model.evaluableLayers.first }
        }
    }

    private var canSave: Bool {
        let oracleReady = oracle == .assertion ? !assertMode.isEmpty : !command.trimmingCharacters(in: .whitespaces).isEmpty
        if fromSession { return oracleReady && source != nil }
        return oracleReady && repo != nil && !base.trimmingCharacters(in: .whitespaces).isEmpty
            && !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: From a session

    /// Reviewed sessions and exemplars, exemplars first.
    private var sources: [Source] {
        let data = analysis.data
        var exemplarOf: [String: [String]] = [:]
        for (mode, list) in data.exemplars { for exemplar in list { exemplarOf[exemplar.sessionKey, default: []].append(data.mode(mode)?.name ?? mode) } }
        var list = data.pool.map { Source(key: $0.sessionKey, title: $0.title ?? $0.sessionKey, transcript: $0.transcript, project: $0.project,
                                          exemplarOf: exemplarOf[$0.sessionKey] ?? []) }
        let known = Set(list.map(\.key))
        list += exemplarOf.keys.filter { !known.contains($0) }.sorted().map {
            Source(key: $0, title: $0, transcript: nil, project: nil, exemplarOf: exemplarOf[$0] ?? [])
        }
        if let preset, !list.contains(where: { $0.key == preset.key }) { list.append(preset) }
        let q = query.trimmingCharacters(in: .whitespaces)
        return list.filter { q.isEmpty || $0.title.localizedCaseInsensitiveContains(q) || $0.key.contains(q) }
            .sorted { ($0.exemplarOf.isEmpty ? 1 : 0, $0.title) < ($1.exemplarOf.isEmpty ? 1 : 0, $1.title) }
    }

    @ViewBuilder private var sessions: some View {
        TextField("Search reviewed sessions", text: $query).textFieldStyle(.roundedBorder)
        List(sources, id: \.key, selection: $source) { source in
            HStack {
                Text(source.title).lineLimit(1)
                Spacer()
                if !source.exemplarOf.isEmpty {
                    Text("exemplar of \(source.exemplarOf.joined(separator: ", "))").font(.caption).foregroundStyle(.orange).lineLimit(1)
                }
                Text(source.project.map { URL(filePath: $0).lastPathComponent } ?? "").font(.caption).foregroundStyle(.secondary)
            }
            .tag(source.key)
        }
        .frame(height: 200)
    }

    // MARK: Reproduction

    @ViewBuilder private var reproduction: some View {
        Form {
            HStack {
                Picker("Repository", selection: $repo) {
                    Text("Choose…").tag(URL?.none)
                    ForEach(repositories, id: \.self) { Text($0.lastPathComponent).tag(URL?.some($0)) }
                }
                Button("Other…", action: chooseRepository)
            }
            TextField("Base commit", text: $base, prompt: Text("a sha or ref, e.g. HEAD~3"))
            LabeledContent("Prompt") {
                TextEditor(text: $prompt)
                    .font(.body)
                    .frame(height: 90)
                    .scrollContentBackground(.hidden)
                    .background(.background, in: RoundedRectangle(cornerRadius: 4))
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
        .frame(height: 230)
        .task(id: model.projects) {
            // Which projects are repositories: file checks, off the main thread.
            let projects = model.projects
            gitRepositories = await Task.detached {
                projects.filter { FileManager.default.fileExists(atPath: $0.appending(path: ".git").path) }
            }.value
        }
    }

    private var repositories: [URL] {
        var list = gitRepositories
        if let repo, !list.contains(repo) { list.append(repo) }
        return list.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    private func chooseRepository() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Choose"
        panel.message = "The git repository the reproduction runs in"
        if panel.runModal() == .OK, let url = panel.url { repo = url }
    }

    // MARK: Save

    private func save() {
        busy = true
        error = nil
        let oracle: ControlTask.Oracle = self.oracle == .tests
            ? .tests(command: command.trimmingCharacters(in: .whitespaces)) : .assertion(modeID: assertMode)
        let modeID = modeID ?? (self.oracle == .assertion ? assertMode : nil)
        let success = self.oracle == .assertion && analysis.data.mode(assertMode)?.kind == .success
        let reference = reference.trimmingCharacters(in: .whitespaces).isEmpty ? nil : reference.trimmingCharacters(in: .whitespaces)
        let chosen = sources.first { $0.key == source }
        let fromSession = fromSession, repo = repo, base = base.trimmingCharacters(in: .whitespaces), prompt = prompt, layerSet = layerSet
        Task {
            do {
                try await analysis.run { env in
                    let task: ControlTask
                    if fromSession {
                        guard let chosen else { throw AnalysisFailure("Pick a session.") }
                        task = try await ControlTasks.fromSession(try Self.summary(of: chosen, env: env), modeID: modeID, oracle: oracle,
                                                                  successMode: success, reference: reference, env: env)
                    } else {
                        guard let repo else { throw AnalysisFailure("Pick the repository.") }
                        task = try await ControlTasks.reproduction(repo: repo, base: base, prompt: prompt, modeID: modeID, oracle: oracle,
                                                                   successMode: success, reference: reference, env: env)
                    }
                    try ControlTasks.save(task, env: env)
                    return try LayerSetPicker.add(task, to: layerSet, saved: "Saved control task \(task.id): \(task.title).", env: env)
                }
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
            busy = false
        }
    }

    /// The session as the index knows it (its folder), else from its notes.
    nonisolated static func summary(of source: Source, env: HarnessEnvironment) throws -> SessionSummary {
        if let database = try AnalysisIndex.open(env: env), let indexed = try AnalysisIndex.sessions(database).first(where: { $0.key == source.key }),
           let summary = IndexedSessions.summary(indexed) {
            return summary
        }
        guard let transcript = source.transcript else {
            throw AnalysisFailure("\(source.key) isn't in the session index. Import sessions with akit sessions import first.")
        }
        return NotesPipeline.Target(harness: SessionKey.harness(of: source.key), file: URL(filePath: transcript), title: source.title,
                                    project: source.project.map { URL(filePath: $0, directoryHint: .isDirectory) }).summary
    }
}
