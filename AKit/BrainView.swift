import AKitCore
import AppKit
import SwiftUI

/// Brain screen: layers and the skill library of the brain repo. Read-only.
struct BrainView: View {
    @Environment(AppModel.self) private var model
    @State private var selection: Item?
    @State private var query = DebugSnapshot.options?.query ?? ""
    @State private var importing = false
    @State private var settingUp = false
    @State private var creatingLayer = false
    @State private var pendingRemoval: Removal?
    @State private var removalMessage: (title: String, text: String)?

    /// Something the user asked to remove, waiting for confirmation.
    enum Removal: Identifiable {
        var isFromLayer: Bool { if case .skillFromLayer = self { true } else { false } }

        case layer(String)
        case skill(String)
        case skillFromLayer(skill: String, layer: String)

        var id: String {
            switch self {
            case .layer(let name): "layer:\(name)"
            case .skill(let name): "skill:\(name)"
            case .skillFromLayer(let skill, let layer): "\(layer):\(skill)"
            }
        }
    }
    @State private var creating = false
    @State private var createError: String?

    enum Item: Hashable {
        case layer(String)
        case skill(String)
    }

    var body: some View {
        Group {
            if let brain = model.brain {
                content(brain)
            } else {
                ContentUnavailableView {
                    Label("No brain repo", systemImage: "brain")
                } description: {
                    Text("AKit looks for it in \(model.brainPath). Create one there, or pick another folder in Settings (⌘,).")
                } actions: {
                    Button(creating ? "Creating…" : "Create Brain Repo", action: create)
                        .disabled(creating)
                        .help("Creates skills/, layers/core, projects/ and machines/ and makes a first git commit")
                }
            }
        }
        .alert("Couldn't create the brain", isPresented: Binding(get: { createError != nil }, set: { if !$0 { createError = nil } })) {
            Button("OK") {}
        } message: {
            Text(createError ?? "")
        }
        .sheet(isPresented: $importing) { BrainImportSheet() }
        .sheet(isPresented: $settingUp) { ProjectSetupSheet() }
        .sheet(isPresented: $creatingLayer) { NewLayerSheet() }
        // Snapshot `--add`: open the import sheet once the brain is loaded.
        .onChange(of: model.brain?.root) {
            guard model.brain != nil, let options = DebugSnapshot.options else { return }
            if options.tab == "setup" { settingUp = true } else if options.tab == "layer" { creatingLayer = true } else if options.add { importing = true }
        }
        .confirmationDialog(removalTitle, isPresented: Binding(get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } }),
                            titleVisibility: .visible, presenting: pendingRemoval) { removal in
            if removalBlocker(removal) == nil {
                Button(removal.isFromLayer ? "Remove from Layer" : "Move to Trash", role: .destructive) { remove(removal) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { removal in
            Text(removalBlocker(removal) ?? removalDetails(removal))
        }
        .alert(removalMessage?.title ?? "", isPresented: Binding(get: { removalMessage != nil }, set: { if !$0 { removalMessage = nil } })) {
            Button("OK") {}
        } message: {
            Text(removalMessage?.text ?? "")
        }
        .navigationTitle("Brain")
        .navigationSubtitle(subtitle)
        .toolbar {
            ToolbarItem {
                Button("New Layer…", systemImage: "plus") { creatingLayer = true }
                    .labelStyle(.titleAndIcon)
                    .disabled(model.brain == nil)
                    .help("Create a layer: skills and an AGENTS.md section for projects")
            }
            ToolbarItem {
                Button("Import Skills…", systemImage: "square.and.arrow.down") { importing = true }
                    .labelStyle(.titleAndIcon)
                    .disabled(model.brain == nil)
                    .help("Copy global skills from ~/.agents/skills into the brain and the core layer")
            }
            ToolbarItem {
                Button("Set Up Project…", systemImage: "folder.badge.gearshape") { settingUp = true }
                    .labelStyle(.titleAndIcon)
                    .disabled(model.brain == nil)
                    .help("Render layers from the brain into a project")
            }
            ToolbarItem {
                Button("Refresh", systemImage: "arrow.clockwise") { Task { await model.refresh() } }
                    .disabled(model.isScanning)
                    .help("Read the brain repo again (⌘R)")
            }
        }
    }

    private var removalTitle: String {
        switch pendingRemoval {
        case .layer(let name): "Remove layer “\(name)”?"
        case .skill(let name): "Remove skill “\(name)”?"
        case .skillFromLayer(let skill, let layer): "Remove “\(skill)” from \(layer)?"
        case nil: ""
        }
    }

    /// Why this can't be removed now, or nil.
    private func removalBlocker(_ removal: Removal) -> String? {
        guard let brain = model.brain else { return "The brain is not loaded." }
        switch removal {
        case .layer(let name):
            let requiredBy = BrainRemove.layerImpact(name, in: brain).requiredBy
            return requiredBy.isEmpty ? nil : "It is required by \(requiredBy.joined(separator: ", ")). Remove it from their requires first."
        case .skill(let name):
            let users = BrainRemove.skillUsers(name, in: brain)
            return users.isEmpty ? nil : "It is used by \(users.joined(separator: ", ")). Remove it from \(users.count == 1 ? "that layer" : "those layers") first (right-click the skill in the layer)."
        case .skillFromLayer(let skill, let layer):
            guard let found = brain.layers.first(where: { $0.name == layer }) else { return "The layer is gone." }
            do { _ = try BrainRemove.layerWithoutSkill(skill, in: found) } catch { return error.localizedDescription }
            return nil
        }
    }

    private func removalDetails(_ removal: Removal) -> String {
        switch removal {
        case .layer(let name):
            let projects = model.brain.map { BrainRemove.layerImpact(name, in: $0).projects } ?? []
            return "layers/\(name) goes to the Trash and the brain gets a commit."
                + (projects.isEmpty ? "" : " It is dropped from the saved answers of \(projects.joined(separator: ", ")); set those projects up again to take its files out.")
        case .skill(let name):
            return "skills/\(name) goes to the Trash and the brain gets a commit. Copies already rendered into projects stay until they are set up again."
        case .skillFromLayer(let skill, let layer):
            return "\(skill) is taken out of layers/\(layer)/layer.yaml (committed). "
                + (layer == "core" ? "Run akit apply --home to take it out of your home folder." : "Projects using \(layer) lose it when they are set up again.")
        }
    }

    private func remove(_ removal: Removal) {
        Task {
            do {
                switch removal {
                case .layer(let name):
                    let projects = try await model.removeLayer(name)
                    if !projects.isEmpty {
                        removalMessage = ("Layer removed", "Set these projects up again to take its files out: \(projects.joined(separator: ", ")).")
                    }
                case .skill(let name):
                    try await model.removeSkill(name)
                case .skillFromLayer(let skill, let layer):
                    try await model.removeSkill(skill, fromLayer: layer)
                }
            } catch {
                removalMessage = ("Couldn't remove it", error.localizedDescription)
            }
        }
    }

    private func create() {
        creating = true
        Task {
            defer { creating = false }
            do {
                try await model.createBrain()
            } catch {
                createError = error.localizedDescription
            }
        }
    }

    private func content(_ brain: Brain) -> some View {
        HSplitView {
            list(brain)
                .frame(minWidth: 240, idealWidth: 280, maxWidth: 420)
            Group {
                switch selection {
                case .layer(let name):
                    if let layer = brain.layers.first(where: { $0.name == name }) {
                        LayerDetailView(layer: layer, problems: brain.problems(of: name).map(\.message),
                                        onRemoveSkill: { pendingRemoval = .skillFromLayer(skill: $0, layer: layer.name) },
                                        onRemove: layer.name == "core" ? nil : { pendingRemoval = .layer(layer.name) })
                    }
                case .skill(let name):
                    if let skill = brain.skills.first(where: { $0.name == name }) {
                        BrainSkillDetailView(skill: skill, usedBy: usage(of: name, in: brain),
                                             onRemove: { pendingRemoval = .skill(skill.name) })
                    }
                case nil:
                    ContentUnavailableView("Select a layer or skill", systemImage: "square.stack.3d.up")
                }
            }
            .frame(minWidth: 380, maxWidth: .infinity, maxHeight: .infinity)
        }
        .searchable(text: $query, placement: .toolbar, prompt: "Layer or skill")
        .onAppear { selection = selection ?? first(in: brain) }
        .onChange(of: model.lastScan) {
            if !exists(selection, in: brain) { selection = first(in: brain) }
        }
    }

    private func list(_ brain: Brain) -> some View {
        List(selection: $selection) {
            let general = brain.problems.filter { $0.layer == nil }
            if !general.isEmpty {
                Section("Problems") {
                    ForEach(general, id: \.self) { problem in
                        Label(problem.message, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .font(.callout)
                            .selectionDisabled()
                    }
                }
            }
            if !layers(brain).isEmpty { Section {
                ForEach(layers(brain)) { layer in
                    LayerRow(layer: layer, problemCount: brain.problems(of: layer.name).count)
                        .tag(Item.layer(layer.name))
                        .contextMenu {
                            fileMenu(layer.folder, reveal: layer.manifest)
                            Divider()
                            Button("Move to Trash…", role: .destructive) { pendingRemoval = .layer(layer.name) }
                                .disabled(layer.name == "core")
                        }
                }
            } header: {
                Text("Layers")
            } footer: {
                if brain.layers.allSatisfy({ $0.name == "core" }) {
                    Text("core is for the home folder. For projects, create a layer with New Layer… (after Import Skills…, so it can pick skills).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } }
            if !skills(brain).isEmpty { Section("Skills") {
                ForEach(skills(brain)) { skill in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(skill.name).fontWeight(.medium)
                        if !skill.description.isEmpty {
                            Text(skill.description).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        }
                    }
                    .padding(.vertical, 2)
                    .tag(Item.skill(skill.name))
                    .contextMenu {
                        fileMenu(skill.folder, reveal: skill.file)
                        Divider()
                        Button("Move to Trash…", role: .destructive) { pendingRemoval = .skill(skill.name) }
                    }
                }
            } }
        }
        .overlay {
            if !query.isEmpty && layers(brain).isEmpty && skills(brain).isEmpty {
                ContentUnavailableView.search(text: query)
            } else if brain.layers.isEmpty && brain.skills.isEmpty {
                ContentUnavailableView("Empty brain", systemImage: "brain",
                                       description: Text("Add layers/<name>/layer.yaml and skills/<name>/SKILL.md."))
            }
        }
    }

    @ViewBuilder
    private func fileMenu(_ folder: URL, reveal file: URL) -> some View {
        if ExternalEditor.appURL != nil {
            Button("Open in \(ExternalEditor.name)") { ExternalEditor.open(folder) }
        }
        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([file]) }
    }

    private var trimmedQuery: String { query.trimmingCharacters(in: .whitespaces) }

    private func layers(_ brain: Brain) -> [Layer] {
        let q = trimmedQuery
        return q.isEmpty ? brain.layers : brain.layers.filter {
            $0.name.localizedCaseInsensitiveContains(q) || $0.description.localizedCaseInsensitiveContains(q)
        }
    }

    private func skills(_ brain: Brain) -> [Brain.Skill] {
        let q = trimmedQuery
        return q.isEmpty ? brain.skills : brain.skills.filter {
            $0.name.localizedCaseInsensitiveContains(q) || $0.description.localizedCaseInsensitiveContains(q)
        }
    }

    private func usage(of skill: String, in brain: Brain) -> [(layer: String, mode: LayerSkill.Mode)] {
        brain.layers.compactMap { layer in
            layer.skills.first { $0.name == skill }.map { (layer: layer.name, mode: $0.mode) }
        }
    }

    private func first(in brain: Brain) -> Item? {
        layers(brain).first.map { .layer($0.name) } ?? skills(brain).first.map { .skill($0.name) }
    }

    private func exists(_ item: Item?, in brain: Brain) -> Bool {
        switch item {
        case .layer(let name): brain.layers.contains { $0.name == name }
        case .skill(let name): brain.skills.contains { $0.name == name }
        case nil: false
        }
    }

    private var subtitle: String {
        guard let brain = model.brain else { return "" }
        let layers = brain.layers.count, skills = brain.skills.count
        return "\(layers) layer\(layers == 1 ? "" : "s") · \(skills) skill\(skills == 1 ? "" : "s") · \(brain.root.tildePath)"
    }
}

private struct LayerRow: View {
    let layer: Layer
    let problemCount: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(layer.name).fontWeight(.medium)
                if problemCount > 0 {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.caption)
                        .help("\(problemCount) problem\(problemCount == 1 ? "" : "s")")
                }
                Spacer()
                Text("\(count(layer.skills.count, "skill")) · \(count(layer.fields.count, "field"))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if !layer.description.isEmpty {
                Text(layer.description).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
        }
        .padding(.vertical, 2)
    }

    private func count(_ n: Int, _ noun: String) -> String { "\(n) \(noun)\(n == 1 ? "" : "s")" }
}

private struct LayerDetailView: View {
    @Environment(AppModel.self) private var model
    let layer: Layer
    let problems: [String]
    let onRemoveSkill: (String) -> Void
    /// nil for the core layer, which can't be removed.
    let onRemove: (() -> Void)?
    @State private var manifest: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                DetailHeader(title: layer.name, description: layer.description, folder: layer.folder, file: layer.manifest,
                             onRemove: onRemove)
                if !problems.isEmpty { ProblemList(problems: problems) }
                info
                if !layer.fields.isEmpty { fields }
                if !layer.skills.isEmpty { skills }
                if !layer.files.isEmpty { files }
                if let manifest {
                    Collapsible(title: "layer.yaml", icon: "doc.text", tint: .secondary, text: manifest, monospaced: true)
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task(id: "\(layer.name)|\(model.lastScan?.timeIntervalSince1970 ?? 0)") {
            let file = layer.manifest
            let text = await Task.detached { try? String(contentsOf: file, encoding: .utf8) }.value
            guard !Task.isCancelled else { return }
            manifest = text
        }
    }

    private var info: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 6) {
            GridRow {
                GridLabel("Requires")
                Text(layer.requires.isEmpty ? "—" : layer.requires.joined(separator: ", "))
            }
            GridRow {
                GridLabel("Conflicts")
                Text(layer.conflicts.isEmpty ? "—" : layer.conflicts.joined(separator: ", "))
            }
            GridRow {
                GridLabel("Folder")
                Text(layer.folder.tildePath).monospaced()
            }
        }
        .font(.callout)
        .textSelection(.enabled)
    }

    private var fields: some View {
        GroupBox("Fields (\(layer.fields.count))") {
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 8) {
                ForEach(layer.fields) { field in
                    GridRow {
                        Text(field.id).monospaced().fontWeight(.medium)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(field.prompt)
                            HStack(spacing: 6) {
                                Tag(text: field.kind.rawValue, tint: .secondary)
                                if field.required { Tag(text: "required", tint: .orange) }
                                if let value = field.defaultValue {
                                    Text("default: \(value.display)").foregroundStyle(.secondary)
                                }
                                if !field.options.isEmpty {
                                    Text("options: \(field.options.joined(separator: ", "))").foregroundStyle(.secondary)
                                }
                            }
                            .font(.caption)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .padding(4)
        }
        .font(.callout)
        .textSelection(.enabled)
    }

    private var skills: some View {
        GroupBox("Skills (\(layer.skills.count))") {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(layer.skills, id: \.name) { skill in
                    HStack(spacing: 8) {
                        Button("Remove from Layer…", systemImage: "minus.circle") { onRemoveSkill(skill.name) }
                            .labelStyle(.iconOnly)
                            .buttonStyle(.borderless)
                            .foregroundStyle(.secondary)
                            .help("Remove \(skill.name) from \(layer.name)")
                        Text(skill.name).fontWeight(.medium)
                        ModeTag(mode: skill.mode)
                        if skill.override { Tag(text: "override", tint: .purple) }
                        WhenText(conditions: skill.when)
                        Spacer()
                    }
                }
            }
            .padding(4)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.callout)
    }

    private var files: some View {
        GroupBox("Files (\(layer.files.count))") {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(layer.files.enumerated()), id: \.offset) { _, file in
                    HStack(spacing: 8) {
                        Text(file.template).monospaced()
                        Image(systemName: "arrow.right").foregroundStyle(.secondary).font(.caption)
                        Text(file.to).monospaced().fontWeight(.medium)
                        if file.override { Tag(text: "override", tint: .purple) }
                        WhenText(conditions: file.when)
                        Spacer()
                    }
                }
            }
            .padding(4)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.callout)
        .textSelection(.enabled)
    }
}

private struct BrainSkillDetailView: View {
    @Environment(AppModel.self) private var model
    let skill: Brain.Skill
    let usedBy: [(layer: String, mode: LayerSkill.Mode)]
    let onRemove: () -> Void
    @State private var text: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                DetailHeader(title: skill.name, description: skill.description, folder: skill.folder, file: skill.file,
                             onRemove: onRemove)
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 6) {
                    GridRow {
                        GridLabel("Location")
                        Text(skill.file.tildePath).monospaced()
                    }
                    GridRow {
                        GridLabel("Used by")
                        if usedBy.isEmpty {
                            Text("No layer").foregroundStyle(.secondary)
                        } else {
                            HStack(spacing: 10) {
                                ForEach(usedBy, id: \.layer) { use in
                                    HStack(spacing: 4) {
                                        Text(use.layer)
                                        ModeTag(mode: use.mode)
                                    }
                                }
                            }
                        }
                    }
                }
                .font(.callout)
                .textSelection(.enabled)
                GroupBox("SKILL.md") {
                    Text(text ?? "")
                        .font(.system(.callout, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(4)
                        .textSelection(.enabled)
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task(id: "\(skill.name)|\(model.lastScan?.timeIntervalSince1970 ?? 0)") {
            let file = skill.file
            let loaded = await Task.detached { try? String(contentsOf: file, encoding: .utf8) }.value
            guard !Task.isCancelled else { return }
            text = loaded
        }
    }
}

// MARK: - Small pieces

private struct DetailHeader: View {
    let title: String
    let description: String
    let folder: URL
    let file: URL
    var onRemove: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.title2.bold()).textSelection(.enabled)
                Spacer()
                if ExternalEditor.appURL != nil {
                    Button("Open in \(ExternalEditor.name)", systemImage: "square.and.pencil") { ExternalEditor.open(folder) }
                }
                Button("Show in Finder", systemImage: "folder") { NSWorkspace.shared.activateFileViewerSelecting([file]) }
                    .labelStyle(.iconOnly)
                    .help("Show in Finder")
                if let onRemove {
                    Button("Move to Trash…", systemImage: "trash", role: .destructive, action: onRemove)
                        .labelStyle(.iconOnly)
                        .help("Remove from the brain")
                }
            }
            if !description.isEmpty {
                Text(description).foregroundStyle(.secondary).textSelection(.enabled)
            }
        }
    }
}

private struct ProblemList: View {
    let problems: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(problems, id: \.self) { problem in
                Label(problem, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.callout)
                    .textSelection(.enabled)
            }
        }
    }
}

private struct GridLabel: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
    }
}

private struct Tag: View {
    let text: String
    let tint: Color

    var body: some View {
        Text(text)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .foregroundStyle(tint)
            .background(tint.opacity(0.12), in: Capsule())
    }
}

private struct ModeTag: View {
    let mode: LayerSkill.Mode

    var body: some View {
        switch mode {
        case .auto: Tag(text: "auto", tint: .green).help("In the agent's context; the agent may invoke it")
        case .manual: Tag(text: "manual", tint: .blue).help("Runs only on an explicit /name")
        case .off: Tag(text: "off", tint: .secondary).help("Not rendered")
        }
    }
}

private struct WhenText: View {
    let conditions: [Condition]

    var body: some View {
        if !conditions.isEmpty {
            Text("when \(conditions.map(\.description).joined(separator: " and "))")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
