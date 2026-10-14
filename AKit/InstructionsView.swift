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
                    InstructionDetailView(entry: entry, home: HarnessEnvironment.current.homeDirectory)
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
        }
        .task(id: "\(project?.path ?? "-")|\(harness?.rawValue ?? "-")|\(model.lastScan?.timeIntervalSince1970 ?? 0)") {
            if harness == nil { harness = harnesses.first }
            guard let harness else { return }
            let project = project, env = HarnessEnvironment.current
            let made = await Task.detached { InstructionScanner.view(harness: harness, project: project, env: env) }.value
            guard !Task.isCancelled else { return }
            view = made
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
                            InstructionRow(entry: entry, home: HarnessEnvironment.current.homeDirectory).tag(entry.id)
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
        let skipped = view.entries.filter { !$0.status.isLoaded }
        if !skipped.isEmpty {
            result.append(FileGroup(title: "Not Loaded", help: "Found, but \(view.harness.displayName) doesn't read it here; each says why", entries: skipped))
        }
        return result
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

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(entry.file.lastPathComponent).fontWeight(.medium).lineLimit(1)
                if case .imported(let by) = entry.status {
                    Text("@ from \(by.lastPathComponent)").font(.caption2).foregroundStyle(.secondary)
                        .help("Claude Code reads it because \(by.tildePath) imports it with @")
                }
                if entry.note != nil {
                    Image(systemName: "scissors").font(.caption).foregroundStyle(.orange).help(entry.note ?? "")
                }
                Spacer()
                if entry.status.isLoaded {
                    Text(InstructionsView.size(entry.bytes)).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
            }
            Text(FileWalk.tilde(entry.file.deletingLastPathComponent(), home: home)).font(.caption).foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.middle)
            if case .skipped(let reason) = entry.status {
                Text(reason).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
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
                        Text(InstructionsView.size(entry.bytes))
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

    private var sections: [InstructionSection] { entry.sections }

    private var status: String {
        switch entry.status {
        case .loaded: "Loaded in every request"
        case .imported(let by): "Loaded: \(by.tildePath) imports it (@\(entry.file.lastPathComponent))"
        case .skipped(let reason): "Not loaded. " + reason
        }
    }

    private func title(_ section: InstructionSection) -> String {
        if section.isAKitBlock { return "AKit block" }
        if let heading = section.heading { return heading }
        return section.text.split(separator: "\n").first.map { String($0).trimmingCharacters(in: CharacterSet(charactersIn: "# ")) }.flatMap { $0.isEmpty ? nil : $0 } ?? "Lead"
    }

    private func label(_ text: String) -> some View {
        Text(text).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
    }
}
