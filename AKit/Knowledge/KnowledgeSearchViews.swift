import AKitFoundation
import AKitKnowledge
import AppKit
import SwiftUI

/// The toolbar search's hits (`akit kb search`): the note, the section and a snippet; a click opens
/// the note at that section.
struct SearchResultsList: View {
    @Environment(KnowledgeModel.self) private var model

    var body: some View {
        List {
            if let answer = model.searchAnswer {
                Section("\(answer.results.count) hit\(answer.results.count == 1 ? "" : "s")" + (answer.stale ? " (index updating)" : "")) {
                    ForEach(Array(answer.results.enumerated()), id: \.offset) { _, hit in
                        Button {
                            Task { await model.open(hit: hit) }
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(hit.note).fontWeight(.medium).lineLimit(1)
                                if let heading = hit.heading {
                                    Text("## \(heading)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                                Text(hit.snippet).font(.callout).foregroundStyle(.secondary).lineLimit(3)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .padding(.vertical, 2)
                        .help("Open \(hit.note)" + (hit.heading.map { " at ## \($0)" } ?? ""))
                    }
                }
            }
        }
        .overlay {
            if let answer = model.searchAnswer, answer.results.isEmpty {
                ContentUnavailableView("No hits", systemImage: "magnifyingglass",
                                       description: Text("No section of a note has every word of “\(model.searchText)”."))
            }
        }
    }
}

/// Under the spaces: the index's size, "stale" while another process updates it, Reindex, and the
/// number of proposals waiting in `inbox/`.
struct IndexStatusLine: View {
    @Environment(KnowledgeModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                if model.indexing {
                    ProgressView().controlSize(.mini)
                    Text("Indexing…")
                } else if let status = model.indexStatus {
                    Text("Index: \(status.notes) notes, \(status.chunks) sections")
                        .help("The search index of this base (.akit-index.sqlite): \(status.notes) notes, \(status.maps) maps, \(status.chunks) sections. It follows your edits and Obsidian's on its own.")
                    if status.stale {
                        Text("stale").foregroundStyle(.orange)
                            .help("Another process is updating the index: searches show its last state")
                    }
                }
                Spacer(minLength: 0)
                Button("Reindex", systemImage: "arrow.clockwise") { Task { await model.refreshIndex(rebuild: true) } }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .disabled(model.indexing)
                    .help("Build the search index again from the files (akit kb index --rebuild)")
            }
            Label("Inbox: \(model.inboxCount)", systemImage: "tray")
                .help("Files in inbox/: notes and maps agents propose. Only Accept or Reject changes them in git.")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }
}

/// A project folder: one of AKit's projects, or Other Folder….
struct KnowledgeProjectPicker: View {
    @Environment(AppModel.self) private var app
    @Binding var folder: URL?

    var body: some View {
        HStack {
            Picker(selection: $folder) {
                Text("Choose…").tag(URL?.none)
                ForEach(Self.sorted(app.projects), id: \.self) { url in
                    Text(url.lastPathComponent).tag(Optional(url))
                }
                if let folder, !app.projects.contains(folder) {
                    Text(folder.lastPathComponent).tag(Optional(folder))
                }
            } label: { RequiredLabel("Project") }
            .frame(maxWidth: 340)
            Button("Other Folder…") {
                let panel = NSOpenPanel()
                panel.canChooseDirectories = true
                panel.canChooseFiles = false
                panel.prompt = "Choose"
                if panel.runModal() == .OK, let url = panel.url { folder = url }
            }
        }
    }

    static func sorted(_ projects: [URL]) -> [URL] {
        projects.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    /// The first folder to show: snapshots' `--project <folder name>` (one of AKit's projects, else
    /// that folder in the projects root), else nil.
    static func initial(_ projects: [URL], projectsRoot: URL) -> URL? {
        guard let name = DebugSnapshot.options?.project else { return nil }
        if let found = sorted(projects).first(where: { $0.lastPathComponent == name }) { return found }
        let folder = projectsRoot.appending(path: name, directoryHint: .isDirectory)
        return FileWalk.isDirectory(folder) ? folder : nil
    }
}

/// Focus…: the space a project's agents start from (`akit kb focus FOLDER --set AREA | --clear`),
/// kept in ~/.akit/local/knowledge/focus.json on this Mac.
struct FocusSheet: View {
    @Environment(KnowledgeModel.self) private var model
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var folder: URL?
    @State private var area = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Focus").font(.title3.bold())
            Text("The space an agent's knowledge card starts from when it works in a project. Without a choice here, the space whose Area Settings name the project, or whose note has its repo:, is the focus.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Form {
                KnowledgeProjectPicker(folder: $folder)
                if let info = model.focusInfo, info.folder == folder {
                    LabeledContent("Now") {
                        Text(info.choice.area.map { "\($0) (\(Self.describe(info.choice.source)))" } ?? "none: no space names this project")
                            .textSelection(.enabled)
                    }
                    .help("Project id \(info.project)")
                    Picker("Focus", selection: $area) {
                        Text("None (Area Settings and repo: decide)").tag("")
                        ForEach(model.areas, id: \.name) { Text($0.name).tag($0.name) }
                    }
                    .help("Your choice wins over Area Settings and repo:; None clears it")
                }
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Save") {
                    Task { if await model.saveFocus(area: area.isEmpty ? nil : area, projectsRoot: app.projectsRoot) { dismiss() } }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(model.focusInfo == nil || model.focusInfo?.folder != folder)
            }
        }
        .padding(20)
        .frame(width: 540)
        .onChange(of: app.projects, initial: true) { folder = folder ?? KnowledgeProjectPicker.initial(app.projects, projectsRoot: app.projectsRoot) }
        .task(id: folder) {
            guard let folder else { return }
            await model.loadFocus(folder: folder, projectsRoot: app.projectsRoot)
            let choice = model.focusInfo?.choice
            area = choice?.source == .override ? choice?.area ?? "" : ""
        }
    }

    static func describe(_ source: KnowledgeBase.FocusChoice.Source?) -> String {
        switch source {
        case .override: "your choice"
        case .areaSettings: "Area Settings"
        case .repo: "a note's repo:"
        case nil: "-"
        }
    }
}

/// Preview Agent Context…: exactly what `akit kb context FOLDER` gives an agent (the card, its
/// tokens of the 4000 cap), and `akit kb neighbors` of the note in view.
struct AgentContextSheet: View {
    @Environment(KnowledgeModel.self) private var model
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var folder: URL?
    @State private var showJSON = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Agent Context").font(.title3.bold())
            Text("What an agent reads at the start of a task in this project: the notes of its focus space, the arrows between them and their neighbours in other spaces, cut to \(Budget.defaultTokens) tokens.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Form {
                KnowledgeProjectPicker(folder: $folder)
                Picker("Show", selection: $showJSON) {
                    Text("List").tag(false)
                    Text("JSON").tag(true)
                }
                .pickerStyle(.segmented)
                .fixedSize()
                .help("JSON is exactly what akit kb context --json prints")
            }
            if let context = model.agentContext, context.folder == folder {
                card(context)
            } else if folder != nil {
                ProgressView().frame(maxWidth: .infinity, minHeight: 200)
            } else {
                ContentUnavailableView("No project", systemImage: "folder", description: Text("Pick a project to see its card."))
                    .frame(minHeight: 200)
            }
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 640, height: 600)
        .onAppear {
            showJSON = DebugSnapshot.options?.query == "json"
        }
        .onChange(of: app.projects, initial: true) { folder = folder ?? KnowledgeProjectPicker.initial(app.projects, projectsRoot: app.projectsRoot) }
        // The note in view's neighbors follow it.
        .task(id: [folder?.path, model.note]) {
            guard let folder else { return }
            await model.loadContext(folder: folder, projectsRoot: app.projectsRoot)
        }
    }

    @ViewBuilder
    private func card(_ context: KnowledgeModel.AgentContext) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let problem = context.problem {
                Label(problem, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).textSelection(.enabled)
            }
            if let answer = context.answer {
                HStack {
                    Text("Focus: " + (answer.focus.map { "\($0) (\(FocusSheet.describe(context.choice.source)))" } ?? "none"))
                        .fontWeight(.medium)
                    Spacer()
                    Text("\(answer.tokens) of \(Budget.defaultTokens) tokens" + (answer.truncated ? ", cut" : ""))
                        .foregroundStyle(answer.truncated ? .orange : .secondary)
                        .monospacedDigit()
                }
                .help("Base \(context.base?.root.tildePath ?? "-"), project id \(context.project)")
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        if showJSON {
                            Text(Budget.json(answer)).font(.callout.monospaced()).textSelection(.enabled)
                        } else if answer.focus == nil {
                            Text("No space names this project (its remote or folder): the agent gets an empty card. Focus… or Area Settings… set one.")
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(answer.systems, id: \.note) { system in
                                HStack(alignment: .firstTextBaseline, spacing: 8) {
                                    Text(system.note).fontWeight(.semibold)
                                    Text(system.title + (system.line.isEmpty ? "" : ": \(system.line)"))
                                    if let local = system.local {
                                        Text(local).foregroundStyle(.secondary).help("This system's folder on this Mac: the agent reads its code or documents there")
                                    }
                                }
                            }
                            if !answer.relations.isEmpty {
                                Text("Relations").font(.caption.bold()).foregroundStyle(.secondary).padding(.top, 6)
                                ForEach(Array(answer.relations.enumerated()), id: \.offset) { _, relation in
                                    Text("\(relation.from) → \(relation.to)" + (relation.kind.map { "  “\($0)”" } ?? ""))
                                }
                            }
                        }
                        if let neighbors = context.neighbors {
                            Divider().padding(.vertical, 6)
                            Text("Neighbors of \(neighbors.note) (akit kb neighbors, \(neighbors.tokens) tokens)")
                                .font(.caption.bold()).foregroundStyle(.secondary)
                            if showJSON {
                                Text(Budget.json(neighbors)).font(.callout.monospaced()).textSelection(.enabled)
                            } else if neighbors.edges.isEmpty {
                                Text("No map has an arrow to or from it.").foregroundStyle(.secondary)
                            } else {
                                ForEach(Array(neighbors.edges.enumerated()), id: \.offset) { _, edge in
                                    Text("\(edge.from) → \(edge.to)" + (edge.kind.map { "  “\($0)”" } ?? "") + "  (\(edge.map))")
                                }
                            }
                        }
                    }
                    .font(.callout)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                }
                .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 6))
            }
        }
    }
}
