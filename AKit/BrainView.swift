import AKitBrain
import AKitFoundation
import AKitInsights
import AKitProjectSetup
import AppKit
import SwiftUI

/// Brain screen: layers and the skill library of the brain repo. Layers are created,
/// edited (skills, modes, description, requires, AGENTS.md) and removed here.
struct BrainView: View {
    @Environment(AppModel.self) private var model
    /// Snapshot `--select <layer>` picks that layer, `--select project:<id>` that project.
    @State private var selection: Item? = DebugSnapshot.options?.select.map {
        $0.hasPrefix("project:") ? .project(String($0.dropFirst("project:".count))) : .layer($0)
    }
    @State private var query = DebugSnapshot.options?.query ?? ""
    @State private var importing = false
    /// Set Up Project is open; it may come preset with a project or a layer.
    @State private var setup: SetupRequest?
    @State private var creatingLayer = false
    @State private var pendingRemoval: Removal?
    @State private var editing: LayerEdit?
    /// Result of a removal or a sync, shown in an alert.
    @State private var message: (title: String, text: String)?
    /// The alert also offers Update Home Folder… (the core layer changed).
    @State private var offerHome = false
    /// Forget Project… asked; waits for confirmation.
    @State private var forgetting: ForgetRequest?
    @State private var isForgetting = false

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

    /// A layer sheet: Edit… (description, requires, AGENTS.md) or Add Skills….
    enum LayerEdit: Identifiable {
        case details(Layer)
        case skills(Layer)

        var id: String {
            switch self {
            case .details(let layer): "details:\(layer.name)"
            case .skills(let layer): "skills:\(layer.name)"
            }
        }
    }

    enum Item: Hashable {
        case layer(String)
        case project(String)
        case skill(String)
    }

    struct SetupRequest: Identifiable {
        let id = UUID()
        var project: URL?
        var layers: [String] = []
        /// This Mac's home folder with the core layer, instead of a project.
        var home = false
    }

    struct ForgetRequest {
        let name: String
        let preview: ProjectForget.Preview
    }

    var body: some View {
        dialogs(screen)
            .navigationTitle("Brain")
    }

    private var screen: some View {
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
        .sheet(item: $setup) { ProjectSetupSheet(initialProject: $0.project, initialLayers: $0.layers, forHome: $0.home) }
        .sheet(isPresented: $creatingLayer) { NewLayerSheet() }
        .sheet(item: $editing) { edit in
            switch edit {
            case .details(let layer): EditLayerSheet(layer: layer)
            case .skills(let layer): AddLayerSkillsSheet(layer: layer)
            }
        }
        // Snapshot `--add`: open the import sheet once the brain is loaded.
        .onChange(of: model.brain?.root) {
            guard model.brain != nil, let options = DebugSnapshot.options else { return }
            if options.tab == "setup" { setup = SetupRequest() } else if options.tab == "home" { setup = SetupRequest(home: true) } else if options.tab == "layer" { creatingLayer = true } else if options.add { importing = true }
            // `--select <layer> --tab edit|add-skills` opens that layer's sheet.
            if let name = options.select, let layer = model.brain?.layers.first(where: { $0.name == name }) {
                if options.tab == "edit" { editing = .details(layer) } else if options.tab == "add-skills" { editing = .skills(layer) }
            }
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
        .navigationSubtitle(subtitle)
        .task(id: model.brain?.root) { await model.fetchBrainSync() }
        .toolbar {
            ToolbarItem {
                Button(syncTitle, systemImage: "arrow.triangle.2.circlepath", action: sync)
                    .labelStyle(.titleAndIcon)
                    .disabled(model.brainSync?.hasRemote != true && model.brainSync?.problem == nil || model.isSyncingBrain)
                    .help(syncHelp)
            }
            ToolbarItem {
                Button("New Layer…", systemImage: "plus") { creatingLayer = true }
                    .labelStyle(.titleAndIcon)
                    .disabled(model.brain == nil || model.isSyncingBrain)
                    .help("Create a layer: skills and an AGENTS.md section for projects")
            }
            ToolbarItem {
                Button("Import Skills…", systemImage: "square.and.arrow.down") { importing = true }
                    .labelStyle(.titleAndIcon)
                    .disabled(model.brain == nil || model.isSyncingBrain)
                    .help("Copy global skills from ~/.agents/skills into the brain and the core layer")
            }
            ToolbarItem {
                Button("Set Up Project…", systemImage: "folder.badge.gearshape") { setup = SetupRequest() }
                    .labelStyle(.titleAndIcon)
                    .disabled(model.brain == nil || model.isSyncingBrain)
                    .help("Render layers from the brain into a project")
            }
            ToolbarItem {
                Button("Refresh", systemImage: "arrow.clockwise") { Task { await model.refresh() } }
                    .disabled(model.isScanning || model.isSyncingBrain)
                    .help("Read the brain repo again (⌘R)")
            }
        }
    }

    /// Forget Project's confirmation and the result alert (with Update Home Folder… when the
    /// core layer changed).
    private func dialogs(_ screen: some View) -> some View {
        screen
            .confirmationDialog("Forget “\(forgetting?.name ?? "")”?", isPresented: Binding(get: { forgetting != nil }, set: { if !$0 { forgetting = nil } }),
                                titleVisibility: .visible, presenting: forgetting) { request in
                // The first button is the one Return picks: never the one that trashes files.
                let preview = request.preview
                let touchesFiles = !preview.removals.isEmpty || !preview.keysTakenOut.isEmpty
                if !preview.ownRecord {
                    if touchesFiles {
                        Button("Trash Files", role: .destructive) { forget(request, keepFiles: false) }
                    }
                } else if !touchesFiles {
                    Button("Forget", role: .destructive) { forget(request, keepFiles: true) }
                } else {
                    Button("Forget, Keep Files") { forget(request, keepFiles: true) }
                    Button("Forget and Trash Files", role: .destructive) { forget(request, keepFiles: false) }
                }
                Button("Cancel", role: .cancel) {}
            } message: { request in
                Text(forgetDetails(request.preview))
            }
            .alert(message?.title ?? "", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil; offerHome = false } })) {
                if offerHome {
                    Button("Update Home Folder…") { setup = SetupRequest(home: true) }
                    Button("Later", role: .cancel) {}
                } else {
                    Button("OK") {}
                }
            } message: {
                Text(message?.text ?? "")
            }
    }

    private var syncTitle: String {
        guard let status = model.brainSync else { return "Sync" }
        if model.isSyncingBrain { return "Syncing…" }
        if status.problem != nil { return "Sync ⚠︎" }
        let counts = [status.ahead > 0 ? "↑\(status.ahead)" : nil, status.behind > 0 ? "↓\(status.behind)" : nil].compactMap(\.self)
        return counts.isEmpty ? "Sync" : "Sync \(counts.joined(separator: " "))"
    }

    private var syncHelp: String {
        guard let status = model.brainSync else { return model.brain == nil ? "No brain yet." : "The brain is not a git repo, so there is nothing to sync." }
        if let problem = status.problem { return problem }
        guard status.hasRemote else { return "The brain has no remote. Add one: git remote add origin <url>, then git push -u origin HEAD." }
        var parts = ["Pull the other Macs' changes to the brain and push this Mac's."]
        if status.ahead > 0 { parts.append("\(status.ahead) commit\(status.ahead == 1 ? "" : "s") to push.") }
        if status.behind > 0 { parts.append("\(status.behind) commit\(status.behind == 1 ? "" : "s") to pull.") }
        if status.isInSync { parts.append("Up to date.") }
        if !status.changed.isEmpty { parts.append("Not committed, so not synced: \(status.changed.joined(separator: ", ")).") }
        return parts.joined(separator: " ")
    }

    private func sync() {
        Task {
            do {
                let result = try await model.syncBrain()
                let outcome = result.sync
                var lines = result.published.lines
                if outcome.pulled > 0 { lines.append("Pulled \(outcome.pulled) commit\(outcome.pulled == 1 ? "" : "s").") }
                if outcome.pushed > 0 { lines.append("Pushed \(outcome.pushed) commit\(outcome.pushed == 1 ? "" : "s").") }
                let coreChanged = outcome.changesCore(in: model.brain)
                if coreChanged { lines.append("The core layer changed. Update this Mac's home folder to take it in.") }
                if outcome.pulled == 0, outcome.pushed == 0 { lines.append("Nothing new on either side.") }
                message = ("Brain synced", lines.joined(separator: "\n"))
                offerHome = coreChanged
            } catch {
                message = ("Couldn't sync the brain", error.localizedDescription)
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
            let requiredBy = BrainRemove.layerImpact(name, in: brain, home: HarnessEnvironment.current.homeDirectory).requiredBy
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
            let projects = model.brain.map { BrainRemove.layerImpact(name, in: $0, home: HarnessEnvironment.current.homeDirectory).projects } ?? []
            return "layers/\(name) goes to the Trash and the brain gets a commit."
                + (projects.isEmpty ? "" : " It is dropped from the saved answers of \(projects.joined(separator: ", ")); set those projects up again to take its files out.")
        case .skill(let name):
            let projects = model.brain.map { BrainRemove.skillProjects(name, in: $0, home: HarnessEnvironment.current.homeDirectory) } ?? []
            return "skills/\(name) goes to the Trash and the brain gets a commit. Copies already rendered into projects stay until they are set up again."
                + (projects.isEmpty ? "" : " It is dropped from the skills picked for \(projects.joined(separator: ", ")).")
        case .skillFromLayer(let skill, let layer):
            return "\(skill) is taken out of layers/\(layer)/layer.yaml (committed). "
                + (layer == "core" ? "Update the home folder afterwards to take it out of it." : "Projects using \(layer) lose it when they are set up again.")
        }
    }

    private func remove(_ removal: Removal) {
        Task {
            do {
                switch removal {
                case .layer(let name):
                    let projects = try await model.removeLayer(name)
                    if !projects.isEmpty {
                        message = ("Layer removed", "Set these projects up again to take its files out: \(projects.joined(separator: ", ")).")
                    }
                case .skill(let name):
                    try await model.removeSkill(name)
                case .skillFromLayer(let skill, let layer):
                    try await model.removeSkill(skill, fromLayer: layer)
                    if layer == "core", ProjectRecords.savedAnswers(id: ProjectRecords.homeID(machineName: model.machine.homeName), in: model.projectStore) != nil {
                        message = ("Removed from core", "\(skill) stays in this Mac's home folder until you update it.")
                        offerHome = true
                    }
                }
            } catch {
                message = ("Couldn't remove it", error.localizedDescription)
            }
        }
    }

    /// Reads what forgetting the project would trash, then asks.
    private func askForget(_ project: Brain.Project) {
        guard !isForgetting else { return }
        Task {
            if let preview = await model.forgetPreview(id: project.id, folder: model.brainProjectFolders[project.id], forHome: project.isHome) {
                forgetting = ForgetRequest(name: project.name, preview: preview)
            } else {
                message = ("Nothing to forget", "Nothing is saved for \(project.id).")
            }
        }
    }

    private func forgetDetails(_ preview: ProjectForget.Preview) -> String {
        var lines = [preview.ownRecord
            ? "\(preview.store.describe(id: preview.id)) goes to the Trash\(preview.store.isLocal ? "" : " and the brain gets a commit")."
            : "This work Mac has no record of its own for it. The brain's copy stays: other Macs use it."]
        let place = preview.plan.map { " in \($0.project.tildePath)" } ?? ""
        if preview.plan == nil {
            lines.append("Its folder is not among the project folders on this Mac, so its files stay where they are.")
        } else if preview.removals.isEmpty {
            if preview.keysTakenOut.isEmpty { lines.append("No files AKit wrote are left\(place).") }
        } else {
            let shown = preview.removals.prefix(8).joined(separator: ", ")
            let more = preview.removals.count > 8 ? " and \(preview.removals.count - 8) more" : ""
            lines.append("Files AKit wrote\(place) can go to the Trash\(preview.ownRecord ? " too" : ""): \(shown)\(more).")
        }
        if !preview.keysTakenOut.isEmpty {
            lines.append("The keys AKit added to \(preview.keysTakenOut.joined(separator: ", "))\(place) can come out; the project's own keys stay.")
        }
        if !preview.kept.isEmpty { lines.append("Kept (edited by hand): \(preview.kept.joined(separator: ", ")).") }
        return lines.joined(separator: "\n\n")
    }

    private func forget(_ request: ForgetRequest, keepFiles: Bool) {
        isForgetting = true
        Task {
            defer { isForgetting = false }
            do {
                try await model.forget(request.preview, keepFiles: keepFiles)
                let id = request.preview.id
                if request.preview.brainCopyLeft {
                    message = (request.preview.ownRecord ? "\(request.name) is forgotten on this Mac" : "Files moved to the Trash",
                               "The brain still has projects/\(id) from before this became a work Mac. Remove it by hand: git rm -r projects/\(id) in the brain, then commit.")
                }
            } catch {
                message = ("Couldn't forget \(request.name)", error.localizedDescription)
            }
        }
    }

    /// Runs a layer edit; a failure is shown in an alert.
    private func change(_ edit: @escaping () async throws -> Void) {
        Task {
            do {
                try await edit()
            } catch {
                message = ("Couldn't change the layer", error.localizedDescription)
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
                                        projects: brain.projects(using: name),
                                        onSelectProject: { selection = .project($0) },
                                        onApply: { setup = layer.name == "core" ? SetupRequest(home: true) : SetupRequest(layers: [layer.name]) },
                                        onRemoveSkill: { pendingRemoval = .skillFromLayer(skill: $0, layer: layer.name) },
                                        onSetMode: { skill, mode in change { try await model.setMode(mode, ofSkill: skill, inLayer: layer.name) } },
                                        onAddSkills: { editing = .skills(layer) },
                                        onEdit: { editing = .details(layer) },
                                        onRemove: layer.name == "core" ? nil : { pendingRemoval = .layer(layer.name) })
                    }
                case .project(let id):
                    if let project = brain.projects.first(where: { $0.id == id }) {
                        let folder = model.brainProjectFolders[id]
                        BrainProjectDetailView(project: project, layers: brain.layers(of: project), folder: folder,
                                               brainFolder: brain.root.appending(path: "projects/\(id)"),
                                               onSelectLayer: { selection = .layer($0) },
                                               onChange: folder.map { folder in { setup = project.isHome ? SetupRequest(home: true) : SetupRequest(project: folder) } },
                                               // Another Mac's home folder is forgotten on that Mac (akit remove project --home).
                                               onForget: project.isHome && folder == nil ? nil : { askForget(project) })
                    }
                case .skill(let name):
                    if let skill = brain.skills.first(where: { $0.name == name }) {
                        BrainSkillDetailView(skill: skill, usedBy: usage(of: name, in: brain),
                                             otherLayers: brain.layers.map(\.name).filter { layer in !usage(of: name, in: brain).contains { $0.layer == layer } },
                                             onAddToLayer: { layer, mode in change { try await model.addSkills([skill.name], mode: mode, toLayer: layer) } },
                                             onRemove: { pendingRemoval = .skill(skill.name) })
                    }
                case nil:
                    ContentUnavailableView("Select a layer, project or skill", systemImage: "square.stack.3d.up")
                }
            }
            .frame(minWidth: 380, maxWidth: .infinity, maxHeight: .infinity)
        }
        .searchable(text: $query, placement: .toolbar, prompt: "Layer, project or skill")
        .onAppear { if !reveal() { selection = selection ?? first(in: brain) } }
        .onChange(of: model.revealBrainSkill) { reveal() }
        .onChange(of: model.lastScan) {
            if !exists(selection, in: brain) { selection = first(in: brain) }
        }
    }

    /// Selects the brain skill another screen asked to show. Returns whether there was one.
    @discardableResult
    private func reveal() -> Bool {
        guard let name = model.revealBrainSkill else { return false }
        model.revealBrainSkill = nil
        query = ""
        selection = .skill(name)
        return true
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
                            Button("Edit…") { editing = .details(layer) }
                            Button("Add Skills…") { editing = .skills(layer) }
                            Divider()
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
            if !projects(brain).isEmpty { Section("Projects") {
                ForEach(projects(brain)) { project in
                    ProjectRow(project: project, layers: brain.layers(of: project), isOnThisMac: model.brainProjectFolders[project.id] != nil)
                        .tag(Item.project(project.id))
                        .contextMenu {
                            if let folder = model.brainProjectFolders[project.id] {
                                fileMenu(folder, reveal: folder)
                                Divider()
                            }
                            if !project.isHome || model.brainProjectFolders[project.id] != nil {
                                Button("Forget Project…", role: .destructive) { askForget(project) }
                            }
                        }
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
            if !query.isEmpty && layers(brain).isEmpty && projects(brain).isEmpty && skills(brain).isEmpty {
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

    private func projects(_ brain: Brain) -> [Brain.Project] {
        let q = trimmedQuery
        return q.isEmpty ? brain.projects : brain.projects.filter { project in
            project.id.localizedCaseInsensitiveContains(q) || brain.layers(of: project).contains { $0.localizedCaseInsensitiveContains(q) }
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
        case .project(let id): brain.projects.contains { $0.id == id }
        case .skill(let name): brain.skills.contains { $0.name == name }
        case nil: false
        }
    }

    private var subtitle: String {
        guard let brain = model.brain else { return "" }
        let layers = brain.layers.count, projects = brain.projects.count, skills = brain.skills.count
        return "\(layers) layer\(layers == 1 ? "" : "s") · \(projects) project\(projects == 1 ? "" : "s") · \(skills) skill\(skills == 1 ? "" : "s") · \(brain.root.tildePath)"
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

private struct ProjectRow: View {
    let project: Brain.Project
    let layers: [String]
    let isOnThisMac: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Image(systemName: project.isHome ? "house" : "folder").foregroundStyle(.secondary)
                Text(project.name).fontWeight(.medium)
                Spacer()
                if !isOnThisMac {
                    Text("not on this Mac").font(.caption).foregroundStyle(.secondary)
                }
            }
            Text(layers.isEmpty ? "No layers" : layers.joined(separator: " · "))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.vertical, 2)
        .help(project.id)
    }
}

private struct BrainProjectDetailView: View {
    @Environment(AppModel.self) private var model
    let project: Brain.Project
    /// Picked layers and the ones they require.
    let layers: [String]
    /// The project on this Mac; nil when it is not among the known projects.
    let folder: URL?
    /// `projects/<id>` in the brain: answers.json and lock.json.
    let brainFolder: URL
    let onSelectLayer: (String) -> Void
    /// Opens Set Up Project for it (Update Home Folder for this Mac's home); nil when the
    /// folder is not on this Mac.
    let onChange: (() -> Void)?
    /// nil for another Mac's home folder.
    let onForget: (() -> Void)?
    /// Skills in the project's .agents/skills that AKit didn't write.
    @State private var ownSkills: [ProjectSkills.Skill] = []
    @State private var creatingSkill = false
    @State private var pendingTrash: ProjectSkills.Skill?
    @State private var problem: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                info
                if let folder, !project.isHome {
                    skills(folder)
                    agents(folder)
                }
                if !project.answers.values.isEmpty { fields }
                note
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task(id: "\(project.id)|\(model.lastScan?.timeIntervalSince1970 ?? 0)") { loadOwnSkills() }
        .sheet(isPresented: $creatingSkill) {
            if let folder {
                NewProjectSkillSheet(project: folder) { file in
                    loadOwnSkills()
                    if ExternalEditor.appURL != nil { ExternalEditor.open(file) }
                }
            }
        }
        .confirmationDialog("Move “\(pendingTrash?.name ?? "")” to the Trash?", isPresented: Binding(get: { pendingTrash != nil }, set: { if !$0 { pendingTrash = nil } }),
                            titleVisibility: .visible, presenting: pendingTrash) { skill in
            Button("Move to Trash", role: .destructive) { trash(skill) }
            Button("Cancel", role: .cancel) {}
        } message: { skill in
            Text("\(ProjectBundle.skillsFolder)/\(skill.name) leaves the project (you can put it back from the Trash). Commit the removal in the project.")
        }
        .alert("Couldn't change the project", isPresented: Binding(get: { problem != nil }, set: { if !$0 { problem = nil } })) {
            Button("OK") {}
        } message: {
            Text(problem ?? "")
        }
    }

    private func loadOwnSkills() {
        guard let folder, !project.isHome else { ownSkills = []; return }
        ownSkills = ProjectSkills.list(in: folder, id: project.id, store: model.projectStore)
    }

    private func trash(_ skill: ProjectSkills.Skill) {
        guard let folder else { return }
        do {
            try ProjectSkills.remove(skill.name, in: folder, id: project.id, store: model.projectStore)
        } catch {
            problem = error.localizedDescription
        }
        loadOwnSkills()
    }

    /// Skills from the layers, the brain skills picked for this project, and its own.
    private func skills(_ folder: URL) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                let picked = project.answers.skills
                if picked.isEmpty && ownSkills.isEmpty {
                    Text("Only the layers' skills. Add brain skills for this project with Layers & Skills…, or write one that lives in the project with New Skill….")
                        .foregroundStyle(.secondary)
                }
                if !picked.isEmpty {
                    Text("From the brain, for this project").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    ForEach(picked, id: \.name) { skill in
                        HStack(spacing: 8) {
                            Text(skill.name).fontWeight(.medium)
                            ModeTag(mode: skill.mode)
                            Spacer()
                        }
                    }
                }
                if !ownSkills.isEmpty {
                    Text("The project's own (\(ProjectBundle.skillsFolder), never overwritten)").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    ForEach(ownSkills) { skill in
                        HStack(spacing: 8) {
                            Button("Move to Trash…", systemImage: "minus.circle") { pendingTrash = skill }
                                .labelStyle(.iconOnly)
                                .buttonStyle(.borderless)
                                .foregroundStyle(.secondary)
                                .help("Move \(skill.name) to the Trash")
                            VStack(alignment: .leading, spacing: 1) {
                                Text(skill.name).fontWeight(.medium)
                                if !skill.description.isEmpty {
                                    Text(skill.description).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                            }
                            Spacer()
                            if ExternalEditor.appURL != nil {
                                Button("Edit", systemImage: "square.and.pencil") { ExternalEditor.open(skill.file) }
                                    .buttonStyle(.borderless)
                                    .help("Open SKILL.md in \(ExternalEditor.name)")
                            }
                        }
                    }
                }
            }
            .padding(4)
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            HStack {
                Text("Skills")
                Spacer()
                if let onChange {
                    Button("Layers & Skills…", systemImage: "square.stack.3d.up", action: onChange)
                        .buttonStyle(.borderless)
                        .help("Pick brain skills for this project or change a layer skill's mode, then preview and apply")
                }
                Button("New Skill…", systemImage: "plus") { creatingSkill = true }
                    .buttonStyle(.borderless)
                    .help("Write a skill that lives only in this project")
            }
        }
        .font(.callout)
    }

    private func agents(_ folder: URL) -> some View {
        let file = folder.appending(path: "AGENTS.md")
        let exists = FileManager.default.fileExists(atPath: file.path)
        return GroupBox {
            HStack {
                Text(exists
                     ? "The project's own file. Edit it freely: the layers only started it, and later layer changes are offered in the preview, never written over your text."
                     : "No AGENTS.md yet. A layer with an AGENTS.md section writes the first version.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                if exists, ExternalEditor.appURL != nil {
                    Button("Edit AGENTS.md", systemImage: "square.and.pencil") { ExternalEditor.open(file) }
                }
            }
            .padding(4)
        } label: {
            Text("AGENTS.md")
        }
        .font(.callout)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Label(project.name, systemImage: project.isHome ? "house" : "folder")
                    .font(.title2.bold())
                    .textSelection(.enabled)
                Spacer()
                if let onChange {
                    if project.isHome {
                        Button("Update Home Folder…", systemImage: "house", action: onChange)
                            .buttonStyle(.borderedProminent)
                            .help("Render the core layer into the home folder: preview the changes, then apply")
                    } else {
                        Button("Layers & Skills…", systemImage: "square.stack.3d.up", action: onChange)
                            .buttonStyle(.borderedProminent)
                            .help("Pick layers and fields, preview the changes, apply")
                    }
                }
                if let folder {
                    if ExternalEditor.appURL != nil {
                        Button("Open in \(ExternalEditor.name)", systemImage: "square.and.pencil") { ExternalEditor.open(folder) }
                            .help("Open the project folder in \(ExternalEditor.name)")
                    }
                    Button("Show in Finder", systemImage: "folder") { NSWorkspace.shared.activateFileViewerSelecting([folder]) }
                        .labelStyle(.iconOnly)
                        .help("Show the project in Finder")
                }
                if let onForget {
                    Button("Forget Project…", systemImage: "trash", action: onForget)
                        .labelStyle(.iconOnly)
                        .help("Forget the project: its saved answers and, if you want, the files AKit wrote there go to the Trash")
                }
            }
            Text(project.id).font(.callout.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
        }
    }

    private var info: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 6) {
            GridRow {
                GridLabel("Layers")
                if layers.isEmpty {
                    Text("None").foregroundStyle(.secondary)
                } else {
                    HStack(spacing: 10) {
                        ForEach(layers, id: \.self) { name in
                            HStack(spacing: 4) {
                                Button(name) { onSelectLayer(name) }
                                    .buttonStyle(.link)
                                    .help("Show the layer")
                                if !project.answers.layers.contains(name) {
                                    Tag(text: "required", tint: .secondary).help("Pulled in by another layer's requires")
                                }
                            }
                        }
                    }
                }
            }
            GridRow {
                GridLabel("Harnesses")
                Text(project.answers.targets.isEmpty ? "—" : project.answers.targets.joined(separator: ", "))
            }
            GridRow {
                GridLabel("Folder")
                if let folder {
                    Text(folder.tildePath).monospaced()
                } else {
                    Text("Not on this Mac").foregroundStyle(.secondary)
                }
            }
            GridRow {
                GridLabel("Rendered from")
                Text(project.brainCommit.map { "brain commit \($0)" } ?? "—")
            }
            GridRow {
                GridLabel("Answers")
                Text(brainFolder.tildePath).monospaced()
            }
        }
        .font(.callout)
        .textSelection(.enabled)
    }

    private var fields: some View {
        GroupBox("Fields (\(project.answers.values.count))") {
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 6) {
                ForEach(project.answers.values.keys.sorted(), id: \.self) { key in
                    GridRow {
                        Text(key).monospaced().fontWeight(.medium)
                        Text(project.answers.values[key]?.display ?? "")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .padding(4)
        }
        .font(.callout)
        .textSelection(.enabled)
    }

    @ViewBuilder
    private var note: some View {
        if project.isHome {
            Text(folder == nil ? "Another Mac's home folder: it gets the core layer when it is updated on that Mac."
                 : "The home folder gets the core layer. After the core layer changes, update it here with the Update Home Folder button.")
                .font(.callout).foregroundStyle(.secondary)
        } else if folder == nil {
            Text("Set up on another Mac, or its folder is outside the project folders in Settings. To change it here, use Set Up Project… → Other Folder….")
                .font(.callout).foregroundStyle(.secondary)
        }
    }
}

private struct LayerDetailView: View {
    @Environment(AppModel.self) private var model
    let layer: Layer
    let problems: [String]
    /// Projects that get this layer, picked or through requires.
    let projects: [Brain.Project]
    let onSelectProject: (String) -> Void
    /// Opens Set Up Project with this layer ticked; for core, Update Home Folder.
    let onApply: () -> Void
    let onRemoveSkill: (String) -> Void
    let onSetMode: (String, LayerSkill.Mode) -> Void
    let onAddSkills: () -> Void
    let onEdit: () -> Void
    /// nil for the core layer, which can't be removed.
    let onRemove: (() -> Void)?
    @State private var manifest: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                DetailHeader(title: layer.name, description: layer.description, folder: layer.folder, file: layer.manifest,
                             onEdit: onEdit, onRemove: onRemove)
                if !problems.isEmpty { ProblemList(problems: problems) }
                info
                usedBy
                if !layer.fields.isEmpty { fields }
                skills
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

    private var usedBy: some View {
        GroupBox("Projects (\(projects.count))") {
            VStack(alignment: .leading, spacing: 6) {
                if projects.isEmpty {
                    Text(layer.name == "core" ? "No home folder has it yet." : "No project uses this layer yet.")
                        .foregroundStyle(.secondary)
                }
                ForEach(projects) { project in
                    HStack(spacing: 6) {
                        Image(systemName: project.isHome ? "house" : "folder").foregroundStyle(.secondary)
                        Button(project.name) { onSelectProject(project.id) }
                            .buttonStyle(.link)
                            .help("Show the project")
                        Text(project.id).font(.caption.monospaced()).foregroundStyle(.secondary)
                        if !project.answers.layers.contains(layer.name) {
                            Tag(text: "required", tint: .secondary).help("Pulled in by another layer's requires")
                        }
                        Spacer()
                    }
                }
                if layer.name == "core" {
                    Button("Update Home Folder…", systemImage: "house", action: onApply)
                        .buttonStyle(.borderedProminent)
                        .help("Render the core layer into this Mac's home folder: preview the changes, then apply")
                        .padding(.top, 2)
                } else {
                    Button("Apply to Project…", systemImage: "folder.badge.plus", action: onApply)
                        .buttonStyle(.borderedProminent)
                        .help("Pick a project; this layer is ticked on top of its current layers")
                        .padding(.top, 2)
                }
            }
            .padding(4)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.callout)
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
        GroupBox {
            VStack(alignment: .leading, spacing: 6) {
                if layer.skills.isEmpty {
                    Text("No skills yet.").foregroundStyle(.secondary)
                }
                ForEach(layer.skills, id: \.name) { skill in
                    HStack(spacing: 8) {
                        Button("Remove from Layer…", systemImage: "minus.circle") { onRemoveSkill(skill.name) }
                            .labelStyle(.iconOnly)
                            .buttonStyle(.borderless)
                            .foregroundStyle(.secondary)
                            .help("Remove \(skill.name) from \(layer.name)")
                        Text(skill.name).fontWeight(.medium)
                        Picker("Mode", selection: Binding(get: { skill.mode }, set: { onSetMode(skill.name, $0) })) {
                            Text("auto").tag(LayerSkill.Mode.auto)
                            Text("manual").tag(LayerSkill.Mode.manual)
                            Text("off").tag(LayerSkill.Mode.off)
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .fixedSize()
                        .help("auto: the agent sees it and may use it; manual: only on /\(skill.name); off: not rendered")
                        if skill.override { Tag(text: "override", tint: .purple) }
                        WhenText(conditions: skill.when)
                        Spacer()
                    }
                }
            }
            .padding(4)
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            HStack {
                Text("Skills (\(layer.skills.count))")
                Spacer()
                Button("Add Skills…", systemImage: "plus", action: onAddSkills)
                    .buttonStyle(.borderless)
                    .help("List skills from the brain in \(layer.name)")
            }
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
    /// Layers that don't list this skill yet.
    let otherLayers: [String]
    let onAddToLayer: (String, LayerSkill.Mode) -> Void
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
                        HStack(spacing: 10) {
                            if usedBy.isEmpty {
                                Text("No layer").foregroundStyle(.secondary)
                            }
                            ForEach(usedBy, id: \.layer) { use in
                                HStack(spacing: 4) {
                                    Text(use.layer)
                                    ModeTag(mode: use.mode)
                                }
                            }
                            if !otherLayers.isEmpty {
                                Menu("Add to Layer") {
                                    ForEach(otherLayers, id: \.self) { layer in
                                        Menu(layer) {
                                            Button("auto") { onAddToLayer(layer, .auto) }
                                            Button("manual") { onAddToLayer(layer, .manual) }
                                        }
                                    }
                                }
                                .fixedSize()
                                .help("List \(skill.name) in another layer")
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
    var onEdit: (() -> Void)? = nil
    var onRemove: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.title2.bold()).textSelection(.enabled)
                Spacer()
                if let onEdit {
                    Button("Edit…", systemImage: "slider.horizontal.3", action: onEdit)
                        .help("Change the description, requires and AGENTS.md section")
                }
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
