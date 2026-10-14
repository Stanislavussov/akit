import AKitFoundation
import AKitHarnesses
import AKitInstructions
import AKitLab
import AKitModel
import AKitProjectSetup
import AKitSkills
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
    @State private var duplicatesOnly = DebugSnapshot.options?.tab == "duplicates" || DebugSnapshot.options?.tab == "remove-copy"
    /// Remove This Copy…: the planned change in its sheet, and why one couldn't be planned.
    @State private var removal: SectionRemoval?
    @State private var removalError: String?
    /// Import to Brain… of a section (its sheet).
    @State private var importing: SectionImport?
    /// Edit… and Rewrite with Skill… of a file (their sheets).
    @State private var editing: InstructionEntry?
    @State private var rewriting: InstructionEntry?
    /// Move to Global… / Move to Project… of a section (their sheets).
    @State private var movingUp: SectionImport?
    @State private var movingDown: SectionImport?
    /// Read the files again after a change made here.
    @State private var reload = 0
    /// Files AKit rendered from the brain into a project (their sections change in the brain);
    /// read from the brain projects' locks with each scan.
    @State private var rendered: Set<String> = []

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
                                          duplicates: duplicates.filter { $0.places.contains { $0.file == entry.file } },
                                          rendered: rendered, canImport: model.brain != nil,
                                          onRemove: { planRemoval(of: $0, in: entry) },
                                          onImport: { importing = SectionImport(section: $0, file: entry.file, level: entry.level, project: project) },
                                          onEdit: { editing = entry }, onRewrite: { rewriting = entry },
                                          onMove: { section in
                                              let request = SectionImport(section: section, file: entry.file, level: entry.level, project: project)
                                              if entry.level == .global { movingDown = request } else { movingUp = request }
                                          })
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
        // The filter on: a selected file it hides gives way to the first one it shows.
        .onChange(of: duplicatesOnly) {
            if duplicatesOnly, let view, !(view.entries.first { $0.id == selection }.map(hasDuplicate) ?? false) {
                selection = view.entries.first(where: hasDuplicate)?.id
            }
        }
        .onChange(of: harnesses, initial: true) {
            if harness.map({ !harnesses.contains($0) }) ?? true { harness = harnesses.first }
        }
        .sheet(item: $removal) { request in
            SectionRemovalSheet(request: request) { reload += 1 }
        }
        .sheet(item: $importing) { request in
            SectionImportSheet(request: request, rendered: rendered) { reload += 1 }
        }
        .sheet(item: $editing) { entry in
            EditInstructionSheet(entry: entry, rendered: rendered) { reload += 1 }
        }
        .sheet(item: $rewriting) { entry in
            RewriteInstructionSheet(entry: entry, rendered: rendered) { reload += 1 }
        }
        .sheet(item: $movingUp) { request in
            MoveToGlobalSectionSheet(request: request, rendered: rendered) { reload += 1 }
        }
        .sheet(item: $movingDown) { request in
            MoveToProjectSectionSheet(request: request, rendered: rendered) { reload += 1 }
        }
        .alert("Can't remove the section", isPresented: Binding(get: { removalError != nil }, set: { if !$0 { removalError = nil } })) {
            Button("OK") {}
        } message: {
            Text(removalError ?? "")
        }
        .task(id: "\(project?.path ?? "-")|\(harness?.rawValue ?? "-")|\(model.lastScan?.timeIntervalSince1970 ?? 0)|\(reload)") {
            guard let harness else { return }
            let project = project, env = HarnessEnvironment.current
            let folders = model.brainProjectFolders, store = model.projectStore
            let (made, groups, written) = await Task.detached {
                let view = InstructionScanner.view(harness: harness, project: project, env: env)
                return (view, view.duplicates, InstructionEdit.renderedFiles(projects: folders, store: store))
            }.value
            guard !Task.isCancelled else { return }
            view = made
            duplicates = groups
            rendered = written
            // Snapshots: `--tab move-up` / `move-down` open Move to Global… / Move to Project… for the
            // selected file's first section.
            if let tab = DebugSnapshot.options?.tab, tab == "move-up" || tab == "move-down", movingUp == nil, movingDown == nil, reload == 0,
               let entry = made.entries.first(where: { $0.id == selection }),
               let section = InstructionText.units(entry.text).first(where: { !$0.isAKitBlock && $0.heading != nil }) {
                let request = SectionImport(section: section, file: entry.file, level: entry.level, project: project)
                if tab == "move-up" { movingUp = request } else { movingDown = request }
            }
            // Snapshots: `--tab edit` / `rewrite` open Edit… / Rewrite with Skill… for the selected file.
            if let tab = DebugSnapshot.options?.tab, tab == "edit" || tab == "rewrite", editing == nil, rewriting == nil, reload == 0,
               let entry = made.entries.first(where: { $0.id == selection }) {
                if tab == "edit" { editing = entry } else { rewriting = entry }
            }
            // Snapshots: `--tab import` opens Import to Brain… for the selected file's first section.
            if DebugSnapshot.options?.tab == "import", importing == nil, reload == 0,
               let entry = made.entries.first(where: { $0.id == selection }),
               let section = InstructionText.units(entry.text).first(where: { !$0.isAKitBlock && $0.heading != nil }) {
                importing = SectionImport(section: section, file: entry.file, level: entry.level, project: project)
            }
            // Snapshots: `--tab remove-copy` opens Remove This Copy… for the selected file's first repeated section.
            if DebugSnapshot.options?.tab == "remove-copy", removal == nil, reload == 0,
               let entry = made.entries.first(where: { $0.id == selection }),
               let place = groups.lazy.flatMap(\.places).first(where: { $0.file == entry.file }) {
                planRemoval(of: place.section, in: entry)
            }
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
                                           repeated: Set(duplicates.flatMap(\.places).filter { $0.file == entry.file }.map(\.section.line)).count)
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

    private func planRemoval(of section: InstructionSection, in entry: InstructionEntry) {
        let rendered = rendered, env = HarnessEnvironment.current, file = entry.file
        let group = duplicates.first { $0.places.contains { $0.file == file && $0.section.line == section.line } }
        let others = group?.places.filter { !($0.file == file && $0.section.line == section.line) } ?? []
        let shown = harness, project = project, level = entry.level
        Task {
            let result = await Task.detached { () -> Result<(InstructionEdit.Plan, [HarnessID]), InstructionEdit.Failure> in
                Result { () throws(InstructionEdit.Failure) in
                    let plan = try InstructionEdit.removing(section, from: file, others: others.map(\.file), rendered: rendered, env: env)
                    // The other harnesses that read this same file in this session lose the section too.
                    let readers = InstructionScanner.harnesses.filter { $0 != shown }.filter { harness in
                        InstructionScanner.view(harness: harness, project: project, env: env).loaded
                            .contains { InstructionEdit.isSameFile($0.file, file) }
                    }
                    return (plan, readers)
                }
            }.value
            switch result {
            case .success(let (plan, readers)):
                removal = SectionRemoval(plan: plan, others: others, differs: group?.kind == .differs, level: level, readers: readers)
            case .failure(let error): removalError = error.message
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
                        .help("\(repeated) section\(repeated == 1 ? "" : "s") of this file the model also gets from another place, or in another version")
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
    /// Files AKit rendered (their sections can't be removed here).
    let rendered: Set<String>
    /// A brain is loaded: Import to Brain… is offered.
    let canImport: Bool
    let onRemove: (InstructionSection) -> Void
    let onImport: (InstructionSection) -> Void
    let onEdit: () -> Void
    let onRewrite: () -> Void
    /// Move to Global… (a project's or an above file) or Move to Project… (a global file).
    let onMove: (InstructionSection) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .firstTextBaseline) {
                    Text(entry.file.lastPathComponent).font(.title2.bold())
                    Spacer()
                    if !rendered.contains(InstructionEdit.realPath(entry.file)) {
                        Button("Edit…", systemImage: "pencil", action: onEdit)
                            .help("Edit the file here: a diff before it is saved, and a backup")
                        Button("Rewrite with Skill…", systemImage: "wand.and.stars", action: onRewrite)
                            .help("Let a model rewrite the file by a skill's guidance (a writing skill, say); you see the diff before anything is written")
                    }
                    if ExternalEditor.appURL != nil {
                        Button("Open in \(ExternalEditor.name)", systemImage: "square.and.pencil") { ExternalEditor.open(entry.file) }
                            .labelStyle(.iconOnly)
                            .help("Open in \(ExternalEditor.name)")
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
                                HStack(spacing: 6) {
                                    if !repeats(of: section).isEmpty, entry.status.isLoaded {
                                        let reason = InstructionEdit.unavailable(section, in: entry.file, rendered: rendered)
                                        Button("Remove This Copy…") { onRemove(section) }
                                            .disabled(reason != nil)
                                            .help(reason ?? "Take this section out of \(entry.file.lastPathComponent): a diff first, then a backup. The model keeps the other places.")
                                    }
                                    if canImport, entry.status.isLoaded, !section.isAKitBlock, section.heading != nil,
                                       !rendered.contains(InstructionEdit.realPath(entry.file)) {
                                        Button("Import to Brain…") { onImport(section) }
                                            .help("Add this section to a brain layer's AGENTS.md text (a commit), so the layer brings it to every place it renders")
                                    }
                                    if entry.status.isLoaded, !section.isAKitBlock, section.heading != nil,
                                       !rendered.contains(InstructionEdit.realPath(entry.file)), entry.level == .global || canImport {
                                        Button(entry.level == .global ? "Move to Project…" : "Move to Global…") { onMove(section) }
                                            .help(entry.level == .global
                                                  ? "Put this section into the projects that need it (their own AGENTS.md or CLAUDE.md), then take it out of this global file"
                                                  : "Put this section into the core layer, update the global files' core block, then take it out of this file")
                                    }
                                }
                                .controlSize(.small)
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
            // For "differs", only the places whose text is not this one's (the same ones say "Also in").
            let own = InstructionText.normalized(section)
            let others = group.places.filter { !($0.file == entry.file && $0.section.line == section.line) }
                .filter { group.kind == .same || InstructionText.normalized($0.section) != own }
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

/// Remove This Copy… waiting in its sheet: the change, and where the model still gets the section.
struct SectionRemoval: Identifiable {
    let id = UUID()
    let plan: InstructionEdit.Plan
    let others: [InstructionDuplicate.Place]
    /// The other places hold other versions (same heading, other text).
    let differs: Bool
    let level: InstructionLevel
    /// Other harnesses that read this same file in the session.
    let readers: [HarnessID]
}

/// The removal as a diff, with Apply and Cancel.
private struct SectionRemovalSheet: View {
    @Environment(\.dismiss) private var dismiss
    let request: SectionRemoval
    let onDone: () -> Void
    @State private var error: String?
    @State private var done = false

    private var plan: InstructionEdit.Plan { request.plan }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Remove \(plan.heading.map { "“\($0)”" } ?? "the section") from \(plan.file.lastPathComponent)").font(.title2.bold())
            Text(summary).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Text(plan.file.tildePath).fontWeight(.medium).padding(.bottom, 2)
                    DiffPreview(diff: plan.diff)
                }
                .font(.callout.monospaced())
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(6)
            }
            .frame(height: 240)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
            ForEach(plan.notes, id: \.self) { note in
                Text(note).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if let error {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red).font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Apply") {
                    do {
                        try InstructionEdit.apply(plan, env: .current)
                        onDone()
                        dismiss()
                    } catch {
                        self.error = error.localizedDescription
                        done = true
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(done)
                .help("Back up \(plan.file.tildePath), then write it without the section. Refused if the file changed since this preview.")
            }
        }
        .padding(20)
        .frame(width: 600)
    }

    private var summary: String {
        let kept = request.others.map { "\($0.file.tildePath):\($0.section.line)" }.joined(separator: ", ")
        var parts = [kept.isEmpty ? "The section leaves this file."
                     : request.differs ? "This version leaves the file; no other place has this text. Other versions stay in \(kept)."
                     : "The section leaves this file; in this session the model still gets it from \(kept)."]
        switch request.level {
        case .global: parts.append("This is a global file: every session of this harness, in every project, loses it here.")
        case .above(let folder): parts.append("Every session in a folder under \(folder.tildePath) loses it here.")
        case .project: break
        }
        if !request.readers.isEmpty {
            parts.append("\(request.readers.map(\.displayName).joined(separator: ", ")) also read\(request.readers.count == 1 ? "s" : "") this file here and lose\(request.readers.count == 1 ? "s" : "") it too, unless they get it from another file.")
        }
        return parts.joined(separator: " ")
    }
}

/// Import to Brain… waiting in its sheet: the section and where it is.
struct SectionImport: Identifiable {
    let id = UUID()
    let section: InstructionSection
    let file: URL
    let level: InstructionLevel
    let project: URL?
}

/// The layer to import into, whether the file loses the section, the layer's text as a diff.
private struct SectionImportSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let request: SectionImport
    let rendered: Set<String>
    let onDone: () -> Void
    @State private var layer = ""
    @State private var removeHere = false
    @State private var plan: InstructionImport.Plan?
    @State private var problem: String?
    @State private var busy = false
    @State private var failed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Import \(request.section.heading.map { "“\($0)”" } ?? "the section") to the Brain").font(.title2.bold())
            Text("The section joins a layer's AGENTS.md text (the text Edit Layer… changes), in one commit in the brain.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Picker("Layer", selection: $layer) {
                    ForEach(model.brain?.layers.map(\.name) ?? [], id: \.self) { Text($0).tag($0) }
                }
                .fixedSize()
                Toggle("Also remove it from \(request.file.lastPathComponent)", isOn: $removeHere)
                    .help("Off: the file keeps its copy until the layer's next render; then Remove This Copy… takes it out. On: it leaves the file now, and sessions miss it until that render.")
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    if let plan {
                        VStack(alignment: .leading, spacing: 0) {
                            Text("layers/\(plan.layer) · AGENTS.md text (brain)").fontWeight(.medium).padding(.bottom, 2)
                            DiffPreview(diff: plan.diff)
                        }
                        if let removal = plan.removal {
                            VStack(alignment: .leading, spacing: 0) {
                                Text(removal.file.tildePath).fontWeight(.medium).padding(.bottom, 2)
                                DiffPreview(diff: removal.diff)
                            }
                        }
                    } else if let problem {
                        Label(problem, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                    }
                }
                .font(.callout.monospaced())
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(6)
            }
            .frame(height: 260)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
            ForEach(plan?.notes ?? [], id: \.self) { note in
                Text(note).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Apply", action: apply)
                    .keyboardShortcut(.defaultAction)
                    .disabled(plan == nil || busy || failed)
                    .help("Commit the layer's new AGENTS.md text in the brain, then (when asked) back up and rewrite the file. Refused if either changed since this preview.")
            }
        }
        .padding(20)
        .frame(width: 640)
        .onAppear {
            if layer.isEmpty, let brain = model.brain {
                layer = InstructionImport.suggestedLayer(for: request.level, project: request.project, brain: brain, projects: model.brainProjectFolders)
            }
        }
        .task(id: "\(layer)|\(removeHere)|\(model.lastScan?.timeIntervalSince1970 ?? 0)") { await replan() }
    }

    private func replan() async {
        // The old plan never stays applicable while a new one is made.
        plan = nil
        failed = false
        guard !layer.isEmpty, let brain = model.brain else { return }
        let request = request, layer = layer, removeHere = removeHere, rendered = rendered, env = HarnessEnvironment.current
        let result = await Task.detached {
            Result { () throws(InstructionImport.Failure) in
                try InstructionImport.plan(request.section, from: request.file, into: layer, removeHere: removeHere,
                                           brain: brain, rendered: rendered, env: env)
            }
        }.value
        guard !Task.isCancelled else { return }
        switch result {
        case .success(let made): plan = made; problem = nil
        case .failure(let error): plan = nil; problem = error.message
        }
    }

    private func apply() {
        guard let plan else { return }
        busy = true
        Task {
            do {
                try await model.applyInstructionImport(plan)
                onDone()
                dismiss()
            } catch {
                problem = error.localizedDescription
                self.plan = nil
                failed = true
            }
            busy = false
        }
    }
}

/// Move to Global… in two steps: the core layer's text and the file's removal as diffs →
/// Commit to Core; then the global files' core blocks as diffs → Apply (and, when every harness
/// that reads the section gets it there, the file's removal).
private struct MoveToGlobalSectionSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let request: SectionImport
    let rendered: Set<String>
    let onDone: () -> Void
    @State private var plan: InstructionMove.GlobalPlan?
    @State private var blocks: InstructionMove.Blocks?
    @State private var removeSource = true
    @State private var problem: String?
    @State private var busy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Move \(request.section.heading.map { "“\($0)”" } ?? "the section") to Global").font(.title2.bold())
            Text(blocks == nil
                 ? "Step 1 of 2: the section goes into the core layer (a commit in the brain). Nothing else changes yet."
                 : "Step 2 of 2: the core block in this Mac's global instruction files gets the section; then \(request.file.lastPathComponent) can lose it.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    if let blocks {
                        ForEach(blocks.diffs) { diff in
                            VStack(alignment: .leading, spacing: 0) {
                                Text(diff.path + " (AKit's block)").fontWeight(.medium).padding(.bottom, 2)
                                DiffPreview(diff: diff.lines)
                            }
                        }
                        if removeSource, let plan, blocks.canRemove {
                            VStack(alignment: .leading, spacing: 0) {
                                Text(plan.removal.file.tildePath).fontWeight(.medium).padding(.bottom, 2)
                                DiffPreview(diff: plan.removal.diff)
                            }
                        }
                    } else if let plan {
                        VStack(alignment: .leading, spacing: 0) {
                            Text("layers/core · AGENTS.md text (brain)").fontWeight(.medium).padding(.bottom, 2)
                            DiffPreview(diff: plan.core.diff)
                        }
                        VStack(alignment: .leading, spacing: 0) {
                            Text(plan.removal.file.tildePath + " (in step 2)").fontWeight(.medium).padding(.bottom, 2)
                            DiffPreview(diff: plan.removal.diff)
                        }
                    } else if problem == nil {
                        ProgressView()
                    }
                }
                .font(.callout.monospaced())
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(6)
            }
            .frame(height: 280)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
            if let blocks {
                if !blocks.uncovered.isEmpty {
                    Label("\(blocks.uncovered.map(\.displayName).joined(separator: ", ")) read\(blocks.uncovered.count == 1 ? "s" : "") the section here but get\(blocks.uncovered.count == 1 ? "s" : "") no core block on this Mac, so \(request.file.lastPathComponent) keeps it.",
                          systemImage: "exclamationmark.triangle").foregroundStyle(.orange).font(.callout).fixedSize(horizontal: false, vertical: true)
                }
                ForEach(blocks.warnings, id: \.self) { Text($0).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                Toggle("Then take it out of \(request.file.lastPathComponent)", isOn: $removeSource).disabled(!blocks.canRemove)
            } else {
                ForEach(plan?.notes ?? [], id: \.self) { note in
                    Text(note).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            if let problem {
                Label(problem, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).font(.callout).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button(blocks == nil ? "Cancel" : "Close") {
                    if blocks != nil { onDone() }
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                if blocks == nil {
                    Button("Commit to Core", action: commit)
                        .keyboardShortcut(.defaultAction)
                        .disabled(plan == nil || busy)
                        .help("Commit the section in the core layer. The global files and this file change only in step 2, after you see their diffs.")
                } else {
                    Button("Apply", action: finish)
                        .keyboardShortcut(.defaultAction)
                        .disabled(busy || blocks?.diffs.isEmpty != false)
                        .help("Back up and write the global files' core blocks, then (when ticked) this file without the section. Refused if a file changed since this preview.")
                }
            }
        }
        .padding(20)
        .frame(width: 660)
        .task {
            guard let brain = model.brain else { problem = "The brain is not loaded."; return }
            let request = request, rendered = rendered, env = HarnessEnvironment.current
            let result = await Task.detached {
                Result { () throws(InstructionMove.Failure) in
                    try InstructionMove.toGlobal(request.section, from: request.file, level: request.level, brain: brain, rendered: rendered, env: env)
                }
            }.value
            switch result {
            case .success(let made): plan = made
            case .failure(let error): problem = error.message
            }
        }
    }

    private func commit() {
        guard let plan else { return }
        busy = true
        problem = nil
        Task {
            do {
                let made = try await model.commitInstructionMoveToGlobal(plan, project: request.project)
                blocks = made
                removeSource = made.canRemove
                if made.diffs.isEmpty {
                    problem = "Core has the section (committed), but no global instruction file on this Mac takes the core block now. Brain → core → Update Home Folder… shows why; \(request.file.lastPathComponent) keeps the section."
                }
            } catch {
                problem = error.localizedDescription
                self.plan = nil
            }
            busy = false
        }
    }

    private func finish() {
        guard let plan, let blocks else { return }
        busy = true
        problem = nil
        Task {
            do {
                try await model.finishInstructionMoveToGlobal(plan, blocks: blocks, removeSource: removeSource && blocks.canRemove,
                                                              project: request.project)
                onDone()
                dismiss()
            } catch {
                problem = error.localizedDescription
                self.blocks = InstructionMove.Blocks.done
            }
            busy = false
        }
    }
}

/// Move to Project…: the projects to put the section into, then the diffs, with Apply.
private struct MoveToProjectSectionSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let request: SectionImport
    let rendered: Set<String>
    let onDone: () -> Void
    @State private var chosen: Set<URL> = []
    @State private var plan: InstructionMove.ProjectPlan?
    @State private var problem: String?
    @State private var busy = false
    /// Each project's file for the section, read off the main thread when the sheet opens.
    @State private var targets: [InstructionMove.Target] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Move \(request.section.heading.map { "“\($0)”" } ?? "the section") to Projects").font(.title2.bold())
            Text("The ticked projects get the section in their own instruction file; then it leaves \(request.file.tildePath), so other projects stop getting it.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack(alignment: .top, spacing: 12) {
                List {
                    ForEach(targets) { target in
                        VStack(alignment: .leading, spacing: 2) {
                            Toggle(isOn: Binding(get: { chosen.contains(target.project) },
                                                 set: { on in if on { chosen.insert(target.project) } else { chosen.remove(target.project) } })) {
                                Text(target.project.lastPathComponent)
                            }
                            .disabled(target.file == nil)
                            Text(target.file.map { "→ \($0.lastPathComponent)\(FileManager.default.fileExists(atPath: $0.path) ? "" : " (new)")" } ?? target.reason ?? "")
                                .font(.caption).foregroundStyle(target.file == nil ? Color.orange : Color.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .listStyle(.bordered)
                .frame(width: 230)
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        if let plan {
                            ForEach(plan.writes, id: \.file) { write in
                                VStack(alignment: .leading, spacing: 0) {
                                    Text(write.file.tildePath + (write.created ? " (new)" : "")).fontWeight(.medium).padding(.bottom, 2)
                                    DiffPreview(diff: write.diff)
                                }
                            }
                            VStack(alignment: .leading, spacing: 0) {
                                Text(plan.removal.file.tildePath).fontWeight(.medium).padding(.bottom, 2)
                                DiffPreview(diff: plan.removal.diff)
                            }
                        } else if let problem {
                            Label(problem, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                        } else {
                            Text("Tick the projects that need the section.").foregroundStyle(.secondary)
                        }
                    }
                    .font(.callout.monospaced())
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(6)
                }
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
            }
            .frame(height: 300)
            ForEach(plan?.notes ?? [], id: \.self) { note in
                Text(note).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Apply") {
                    guard let plan else { return }
                    busy = true
                    Task {
                        let result = await Task.detached { Result { () throws(InstructionMove.Failure) in try InstructionMove.apply(plan, env: .current) } }.value
                        busy = false
                        switch result {
                        case .success:
                            onDone()
                            dismiss()
                        case .failure(let error):
                            problem = error.message
                            self.plan = nil
                        }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(plan == nil || busy)
                .help("Back up and write each project's file, then the global file without the section. Nothing is written when a file changed since this preview.")
            }
        }
        .padding(20)
        .frame(width: 760)
        .task {
            var seen: Set<String> = []
            let projects = model.projects.filter { seen.insert($0.standardizedFileURL.path).inserted }
                .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            let source = request.file, rendered = rendered, env = HarnessEnvironment.current
            targets = await Task.detached { projects.map { InstructionMove.target($0, source: source, rendered: rendered, env: env) } }.value
            // Snapshots: `--query <folder name>` ticks that project.
            if let name = DebugSnapshot.options?.query, let target = targets.first(where: { $0.project.lastPathComponent == name && $0.file != nil }) {
                chosen = [target.project]
                return
            }
            // The common case: the session's project ticked at first.
            if let project = request.project, chosen.isEmpty,
               targets.contains(where: { $0.project.standardizedFileURL.path == project.standardizedFileURL.path && $0.file != nil }) {
                chosen = [targets.first { $0.project.standardizedFileURL.path == project.standardizedFileURL.path }!.project]
            }
        }
        .task(id: chosen) {
            plan = nil
            problem = nil
            guard !chosen.isEmpty else { return }
            let request = request, rendered = rendered, env = HarnessEnvironment.current, projects = chosen.sorted { $0.path < $1.path }
            let result = await Task.detached {
                Result { () throws(InstructionMove.Failure) in
                    try InstructionMove.toProjects(request.section, from: request.file, level: request.level, projects: projects,
                                                   rendered: rendered, env: env)
                }
            }.value
            guard !Task.isCancelled else { return }
            switch result {
            case .success(let made): plan = made
            case .failure(let error): problem = error.message
            }
        }
    }
}

/// The change of a whole file as a diff, with notes, Apply and Back.
private struct InstructionPlanReview: View {
    let plan: InstructionEdit.Plan
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Text(plan.file.tildePath).fontWeight(.medium).padding(.bottom, 2)
                    DiffPreview(diff: plan.diff)
                }
                .font(.callout.monospaced())
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(6)
            }
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
            ForEach(plan.notes, id: \.self) { Text($0).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
        }
    }
}

/// Edit…: the file's text in an editor → Review Changes (the diff) → Save (backup first).
private struct EditInstructionSheet: View {
    @Environment(\.dismiss) private var dismiss
    let entry: InstructionEntry
    let rendered: Set<String>
    let onDone: () -> Void
    @State private var text = ""
    @State private var plan: InstructionEdit.Plan?
    @State private var problem: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Edit \(entry.file.lastPathComponent)").font(.title2.bold())
            Text(entry.file.tildePath).font(.callout).foregroundStyle(.secondary)
            if let plan {
                InstructionPlanReview(plan: plan)
            } else {
                TextEditor(text: $text)
                    .font(.callout.monospaced())
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
            }
            if let problem {
                Label(problem, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).font(.callout).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                if plan != nil { Button("Back") { plan = nil } }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                if let plan {
                    Button("Save") {
                        do {
                            try InstructionEdit.apply(plan, env: .current)
                            onDone()
                            dismiss()
                        } catch {
                            problem = error.localizedDescription
                        }
                    }
                    .keyboardShortcut(.defaultAction)
                    .help("Back up \(entry.file.tildePath), then write it. Refused if the file changed since you opened it.")
                } else {
                    Button("Review Changes") {
                        problem = nil
                        do {
                            plan = try InstructionEdit.editing(entry.file, to: text, rendered: rendered, env: .current)
                        } catch {
                            problem = error.localizedDescription
                        }
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(20)
        .frame(width: 720, height: 560)
        .onAppear { text = (try? String(contentsOf: entry.file, encoding: .utf8)) ?? entry.text }
    }
}

/// Rewrite with Skill…: a skill, the harness that runs the call, a request → the model's
/// rewrite as a diff → Apply (backup first). Nothing is written before Apply.
private struct RewriteInstructionSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let entry: InstructionEntry
    let rendered: Set<String>
    let onDone: () -> Void
    @State private var skillID: Skill.ID?
    @State private var harness: LabHarness = .claudeCode
    @State private var request = "Make it clearer and shorter; keep every rule."
    @State private var plan: InstructionEdit.Plan?
    @State private var problem: String?
    @State private var busy = false

    private var skills: [Skill] {
        var seen: Set<String> = []
        return model.skills.filter { seen.insert($0.name).inserted }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private var harnesses: [LabHarness] {
        let installed = Set(model.installations.map(\.id))
        let known = LabHarness.allCases.filter { installed.contains($0 == .claudeCode ? .claudeCode : .pi) }
        return known.isEmpty ? [.claudeCode] : known
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Rewrite \(entry.file.lastPathComponent) with a Skill").font(.title2.bold())
            Text("One model call through the harness's own sign-in rewrites the file by the skill's guidance. AKit's core block is not sent and stays as it is. You see the diff before anything is written.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 8) {
                GridRow {
                    Text("Skill").foregroundStyle(.secondary)
                    Picker("Skill", selection: $skillID) {
                        ForEach(skills) { Text($0.name).tag(Optional($0.id)) }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                GridRow {
                    Text("Run with").foregroundStyle(.secondary)
                    Picker("Run with", selection: $harness) {
                        ForEach(harnesses, id: \.self) { Text($0.title).tag($0) }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                GridRow {
                    Text("Request").foregroundStyle(.secondary)
                    TextField("What should change", text: $request)
                }
            }
            .disabled(busy || plan != nil)
            if let plan {
                InstructionPlanReview(plan: plan)
            } else if busy {
                ProgressView("Waiting for \(harness.title)…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Spacer()
            }
            if let problem {
                Label(problem, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).font(.callout).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                if plan != nil { Button("Rewrite Again") { plan = nil; run() } }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                if let plan {
                    Button("Apply") {
                        do {
                            try InstructionEdit.apply(plan, env: .current)
                            onDone()
                            dismiss()
                        } catch {
                            problem = error.localizedDescription
                        }
                    }
                    .keyboardShortcut(.defaultAction)
                    .help("Back up \(entry.file.tildePath), then write the rewrite. Refused if the file changed since the call.")
                } else {
                    Button("Rewrite", action: run)
                        .keyboardShortcut(.defaultAction)
                        .disabled(busy || skillID == nil)
                        .help("Send the file (without AKit's block) and the skill to \(harness.title) in one call; it shows in Lab → Sends")
                }
            }
        }
        .padding(20)
        .frame(width: 720, height: 560)
        .onAppear {
            if skillID == nil {
                // A writing skill when there is one, else the first.
                skillID = (skills.first { $0.name.localizedCaseInsensitiveContains("writ") } ?? skills.first)?.id
            }
            if !harnesses.contains(harness), let first = harnesses.first { harness = first }
        }
    }

    private func run() {
        guard let skill = model.skills.first(where: { $0.id == skillID }) else { return }
        busy = true
        problem = nil
        Task {
            do {
                plan = try await model.rewriteInstruction(entry.file, skill: skill, request: request, harness: harness, rendered: rendered)
            } catch {
                problem = error.localizedDescription
            }
            busy = false
        }
    }
}

