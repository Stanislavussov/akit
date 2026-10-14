import AKitFoundation
import AKitHarnesses
import AKitInstructions
import AKitModel
import AppKit
import SwiftUI

/// Instructions screen: the instruction files (AGENTS.md, CLAUDE.md, …) one harness loads for a
/// session in one project, in the order the model gets them, with their size and sections, and
/// the files it skips with the reason (docs/design/instructions.md, step 1). Reads only.
struct InstructionsView: View {
    @Environment(AppModel.self) private var model
    /// nil: only the global files.
    @State private var project: URL? = InstructionsView.initialProject
    @State private var harness: HarnessID?
    @State private var view: InstructionView?
    @State private var selection: InstructionEntry.ID?
    /// Sections the model gets twice or in two versions, made with the view.
    @State private var duplicates: [InstructionDuplicate] = []
    /// Show only files with such a section.
    @State private var duplicatesOnly = DebugSnapshot.options?.tab == "duplicates"

    /// Snapshots: `--project <folder name>` under ~/Projects.
    static var initialProject: URL? {
        DebugSnapshot.options?.project.map { HarnessEnvironment.current.homeDirectory.appending(path: "Projects/\($0)") }
    }

    var body: some View {
        HSplitView {
            list
                .frame(minWidth: 320, idealWidth: 400, maxWidth: 560)
            Group {
                if let entry = view?.entries.first(where: { $0.id == selection }) {
                    InstructionDetailView(entry: entry, home: HarnessEnvironment.current.homeDirectory,
                                          duplicates: duplicates.filter { $0.places.contains { $0.file == entry.file } })
                } else {
                    ContentUnavailableView("Select a file", systemImage: "doc.text")
                }
            }
            .frame(minWidth: 380, maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle("Instructions")
        .navigationSubtitle(subtitle)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Menu {
                    Picker("Session in", selection: $project) {
                        Text("Global Files Only").tag(URL?.none)
                        Divider()
                        ForEach(projects, id: \.self) { url in
                            Text(url.lastPathComponent).tag(Optional(url))
                        }
                    }
                    .pickerStyle(.inline)
                } label: {
                    Label(project?.lastPathComponent ?? "Global Files Only", systemImage: project == nil ? "globe" : "folder")
                        .labelStyle(.titleAndIcon)
                }
                .fixedSize()
                .help(project.map { "What a session started in \($0.tildePath) gets" } ?? "Only each harness's global files")
            }
            ToolbarItem(placement: .navigation) {
                Picker("Harness", selection: $harness) {
                    ForEach(harnesses, id: \.self) { Text($0.displayName).tag(Optional($0)) }
                }
                .pickerStyle(.segmented)
                .fixedSize()
                .help("Each harness has its own rules for which files it reads")
            }
            if !duplicates.isEmpty || duplicatesOnly {
                ToolbarItem(placement: .navigation) {
                    Toggle(isOn: $duplicatesOnly) {
                        Label("Duplicates (\(duplicates.count))", systemImage: "doc.on.doc").labelStyle(.titleAndIcon)
                    }
                    .help("Show only files with a section the model gets twice (the same text in two places) or in two versions (the same ## heading, other text)")
                }
            }
        }
        // The picker shows installed harnesses; the choice follows when the list changes.
        .onChange(of: harnesses, initial: true) {
            if harness.map({ !harnesses.contains($0) }) ?? true { harness = harnesses.first }
        }
        .task(id: "\(project?.path ?? "-")|\(harness?.rawValue ?? "-")|\(model.lastScan?.timeIntervalSince1970 ?? 0)") {
            guard let harness else { return }
            let project = project, env = HarnessEnvironment.current
            let (made, groups) = await Task.detached {
                let view = InstructionScanner.view(harness: harness, project: project, env: env)
                return (view, view.duplicates)
            }.value
            guard !Task.isCancelled else { return }
            view = made
            duplicates = groups
            if made.entries.first(where: { $0.id == selection }) == nil {
                // Snapshots: `--select <file name>` picks the first file of that name.
                let named = DebugSnapshot.options?.select.flatMap { name in made.entries.first { $0.file.lastPathComponent == name } }
                selection = named?.id ?? made.entries.first(where: { $0.level == .project && $0.status.isLoaded })?.id ?? made.entries.first?.id
            }
        }
    }

    /// The installed harnesses this screen knows, in its order.
    private var harnesses: [HarnessID] {
        let installed = Set(model.installations.map(\.id))
        let known = InstructionScanner.harnesses.filter(installed.contains)
        return known.isEmpty ? InstructionScanner.harnesses : known
    }

    private var projects: [URL] {
        var seen: Set<String> = []
        return (model.projects + (project.map { [$0] } ?? []))
            .filter { seen.insert($0.standardizedFileURL.path).inserted }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    private var subtitle: String {
        guard let view else { return "" }
        let loaded = view.loaded.count
        return "\(loaded) file\(loaded == 1 ? "" : "s") · \(Self.size(view.loadedBytes)) in every request"
    }

    static func size(_ bytes: Int) -> String {
        let kb = bytes < 1024 ? "\(bytes) B" : String(format: "%.1f KB", Double(bytes) / 1024)
        return "\(kb) ≈ \((bytes / 4).formatted()) tokens"
    }

    // MARK: - List

    private var list: some View {
        List(selection: $selection) {
            if let view {
                ForEach(groups(view), id: \.title) { group in
                    Section {
                        ForEach(group.entries) { entry in
                            InstructionRow(entry: entry, home: HarnessEnvironment.current.homeDirectory,
                                           repeated: duplicates.filter { $0.places.contains { $0.file == entry.file } }.count)
                                .tag(entry.id)
                                .contextMenu {
                                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([entry.file]) }
                                    if ExternalEditor.appURL != nil {
                                        Button("Open in \(ExternalEditor.name)") { ExternalEditor.open(entry.file) }
                                    }
                                }
                        }
                    } header: {
                        Text(group.title).help(group.help)
                    }
                }
            }
        }
        .overlay {
            if let view, view.entries.isEmpty {
                ContentUnavailableView("No instruction files", systemImage: "doc.text",
                                       description: Text("\(view.harness.displayName) loads no AGENTS.md or CLAUDE.md for this session."))
            } else if view == nil {
                ProgressView()
            }
        }
    }

    private func hasDuplicate(_ entry: InstructionEntry) -> Bool {
        entry.status.isLoaded && duplicates.contains { $0.places.contains { $0.file == entry.file } }
    }

    private struct FileGroup { let title: String; let help: String; let entries: [InstructionEntry] }

    /// Loaded files in the model's order, split where the level changes; skipped files last.
    private func groups(_ view: InstructionView) -> [FileGroup] {
        var result: [FileGroup] = []
        for entry in view.loaded {
            let (title, help) = Self.levelTitle(entry.level)
            if result.last?.title == title {
                result[result.count - 1] = FileGroup(title: title, help: help, entries: result[result.count - 1].entries + [entry])
            } else {
                result.append(FileGroup(title: title, help: help, entries: [entry]))
            }
        }
        let later = view.entries.filter { if case .onDemand = $0.status { true } else { false } }
        if !later.isEmpty {
            result.append(FileGroup(title: "Loads Later", help: "Read only in some sessions: when the agent works on a matching file", entries: later))
        }
        let skipped = view.entries.filter { if case .skipped = $0.status { true } else { false } }
        if !skipped.isEmpty {
            result.append(FileGroup(title: "Not Loaded", help: "Found, but \(view.harness.displayName) doesn't read it here; each says why", entries: skipped))
        }
        // The Duplicates filter: only files with a repeated section, and no empty group.
        guard duplicatesOnly else { return result }
        return result.map { FileGroup(title: $0.title, help: $0.help, entries: $0.entries.filter(hasDuplicate)) }.filter { !$0.entries.isEmpty }
    }

    static func levelTitle(_ level: InstructionLevel) -> (String, String) {
        switch level {
        case .global: ("Global", "The harness's own files: every session gets them")
        case .above: ("Above the Project", "Files in folders above the project: every session below them gets them")
        case .project: ("Project", "Files in the project folder")
        }
    }
}

private struct InstructionRow: View {
    let entry: InstructionEntry
    let home: URL
    /// Duplicate groups with a section of this file.
    let repeated: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(entry.file.lastPathComponent).fontWeight(.medium).lineLimit(1)
                if case .imported(let by) = entry.status {
                    Text("@ from \(by.lastPathComponent)").font(.caption2).foregroundStyle(.secondary)
                        .help("Claude Code reads it because \(by.tildePath) imports it with @")
                }
                if repeated > 0 {
                    Image(systemName: "doc.on.doc.fill").font(.caption).foregroundStyle(.orange)
                        .help("\(repeated) section\(repeated == 1 ? "" : "s") of this file the model also gets from another place (or in another version)")
                }
                if entry.note != nil {
                    Image(systemName: "scissors").font(.caption).foregroundStyle(.orange).help(entry.note ?? "")
                }
                Spacer()
                if case .skipped = entry.status {} else {
                    Text(InstructionsView.size(entry.sentBytes)).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
            }
            Text(FileWalk.tilde(entry.file.deletingLastPathComponent(), home: home)).font(.caption).foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.middle)
            if case .skipped(let reason) = entry.status {
                Text(reason).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            } else if case .onDemand(let when) = entry.status {
                Text(when).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 2)
        .opacity(entry.status.isLoaded ? 1 : 0.75)
    }
}

/// One file: where it is, how the harness treats it, its sections and its text.
private struct InstructionDetailView: View {
    let entry: InstructionEntry
    let home: URL
    /// The duplicate groups with a section of this file.
    let duplicates: [InstructionDuplicate]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .firstTextBaseline) {
                    Text(entry.file.lastPathComponent).font(.title2.bold())
                    Spacer()
                    if ExternalEditor.appURL != nil {
                        Button("Open in \(ExternalEditor.name)", systemImage: "square.and.pencil") { ExternalEditor.open(entry.file) }
                    }
                    Button("Show in Finder", systemImage: "folder") { NSWorkspace.shared.activateFileViewerSelecting([entry.file]) }
                        .labelStyle(.iconOnly)
                        .help("Show in Finder")
                }
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 6) {
                    GridRow {
                        label("Location")
                        Text(entry.file.tildePath).monospaced().textSelection(.enabled)
                    }
                    GridRow {
                        label("Status")
                        Text(status).foregroundStyle(entry.status.isLoaded ? Color.primary : Color.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    GridRow {
                        label("Size")
                        Text(entry.limit == nil ? InstructionsView.size(entry.bytes)
                             : "\(InstructionsView.size(entry.sentBytes)) of \(InstructionsView.size(entry.bytes))")
                    }
                    if let note = entry.note {
                        GridRow {
                            label("Limit")
                            Text(note).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                if !sections.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Sections").font(.headline)
                        ForEach(Array(sections.enumerated()), id: \.offset) { _, section in
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Text(title(section)).lineLimit(1)
                                    if section.isAKitBlock {
                                        Text("brain · core").font(.caption2).padding(.horizontal, 5).padding(.vertical, 1)
                                            .background(.purple.opacity(0.15), in: Capsule()).foregroundStyle(.purple)
                                            .help("AKit's block of the core layer: it changes in the brain (Brain → core)")
                                    }
                                    Spacer()
                                    Text("line \(section.line) · \(InstructionsView.size(section.bytes))").font(.caption).foregroundStyle(.secondary)
                                        .monospacedDigit()
                                }
                                ForEach(repeats(of: section), id: \.self) { line in
                                    Label(line, systemImage: "doc.on.doc").font(.caption).foregroundStyle(.orange)
                                }
                            }
                        }
                    }
                }
                Text(entry.text)
                    .font(.callout.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(.background.secondary, in: RoundedRectangle(cornerRadius: 6))
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// The file's parts as duplicates compare them: AKit's block split into its `##` parts.
    private var sections: [InstructionSection] { InstructionText.units(entry.text) }

    /// "Also in …" / "Differs from …" for each group this section is in.
    private func repeats(of section: InstructionSection) -> [String] {
        duplicates.compactMap { group in
            guard group.places.contains(where: { $0.file == entry.file && $0.section.line == section.line }) else { return nil }
            let others = group.places.filter { !($0.file == entry.file && $0.section.line == section.line) }
                .map { "\($0.file.tildePath):\($0.section.line)" }.joined(separator: ", ")
            return group.kind == .same ? "Also in \(others)" : "Same heading, other text in \(others)"
        }
    }

    private var status: String {
        switch entry.status {
        case .loaded: "Loaded in every request"
        case .imported(let by): "Loaded: \(by.tildePath) imports it (@\(entry.file.lastPathComponent))"
        case .onDemand(let when): "Loaded in some sessions only. " + when
        case .skipped(let reason): "Not loaded. " + reason
        }
    }

    private func title(_ section: InstructionSection) -> String {
        if let heading = section.heading { return heading }
        if section.isAKitBlock { return "AKit block" }
        return section.text.split(separator: "\n").first.map { String($0).trimmingCharacters(in: CharacterSet(charactersIn: "# ")) }.flatMap { $0.isEmpty ? nil : $0 } ?? "Lead"
    }

    private func label(_ text: String) -> some View {
        Text(text).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
    }
}
