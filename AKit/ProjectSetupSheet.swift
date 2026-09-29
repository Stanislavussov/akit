import AKitBrain
import AKitFoundation
import AKitProjectSetup
import AppKit
import SwiftUI

/// Set up a project from brain layers: form → preview with diffs → apply.
struct ProjectSetupSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    /// Opened for this project (from the Brain's project list).
    var initialProject: URL?
    /// Ticked on top of the project's saved answers (Apply to Project on a layer).
    var initialLayers: [String] = []

    private enum Page { case form, preview, done }

    @State private var page = Page.form
    @State private var project: URL?
    @State private var projectID: String?
    @State private var answers = ProjectAnswers()
    @State private var plan: ProjectSetup.Plan?
    @State private var excluded: Set<String> = []
    @State private var selectedChange: String?
    @State private var outcome: ProjectSetup.Outcome?
    @State private var isWorking = false
    @State private var error: String?
    @State private var creatingLayer = false
    @State private var skillQuery = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            switch page {
            case .form: form
            case .preview: preview
            case .done: done
            }
        }
        .padding(16)
        .frame(width: 760, height: 640)
        .sheet(isPresented: $creatingLayer) { NewLayerSheet() }
        .task {
            if project == nil, let initialProject { await choose(initialProject) }
            // Snapshot: `--project <folder>` picks it, `--query a,b` ticks layers, `--capture` opens the preview.
            if project == nil, let options = DebugSnapshot.options, let name = options.project,
               let match = model.projects.first(where: { $0.lastPathComponent == name }) {
                await choose(match)
                if let layers = options.query { answers.layers = layers.split(separator: ",").map(String.init) }
                if options.capture { makePlan() }
            }
        }
    }

    // MARK: - Form

    private var brain: Brain? { model.brain }

    /// Layers the form offers: every layer except core, which is for the home folder.
    private var offered: [Layer] { brain?.layers.filter { $0.name != "core" } ?? [] }

    private var bundle: ProjectBundle? {
        guard let brain, let project else { return nil }
        return ProjectBundle.resolve(answers, brain: brain, projectName: project.lastPathComponent)
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(initialLayers.isEmpty ? "Set Up a Project" : "Apply \(initialLayers.joined(separator: ", ")) to a Project").font(.title2.bold())
            projectPicker
            if project != nil {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        targetsBox
                        layersBox
                        skillsBox
                        fieldsBox
                        messages
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                ContentUnavailableView("Pick a project", systemImage: "folder",
                                       description: Text("AKit renders AGENTS.md and skills from the brain into it."))
            }
            HStack {
                if let error { Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).lineLimit(3) }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(isWorking ? "Preparing…" : "Preview Changes", action: makePlan)
                    .keyboardShortcut(.defaultAction)
                    .disabled(project == nil || projectID == nil || (answers.layers.isEmpty && answers.skills.isEmpty) || isWorking)
            }
        }
    }

    private var projectPicker: some View {
        HStack {
            Picker("Project", selection: Binding(get: { project }, set: { url in Task { await choose(url) } })) {
                Text("Choose…").tag(URL?.none)
                ForEach(model.projects.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }, id: \.self) { url in
                    Text(url.lastPathComponent).tag(Optional(url))
                }
                if let project, !model.projects.contains(project) {
                    Text(project.lastPathComponent).tag(Optional(project))
                }
            }
            .frame(maxWidth: 320)
            Button("Other Folder…", action: chooseFolder)
            Spacer()
            if let project {
                Text(projectID ?? "…").font(.caption.monospaced()).foregroundStyle(.secondary)
                    .help("\(project.tildePath)\nAnswers are kept \(model.projectStore.isLocal ? "on this Mac only, in" : "in the brain under") \(model.projectStore.describe(id: projectID ?? "…"))")
            }
        }
    }

    private var targetsBox: some View {
        GroupBox("Harnesses") {
            HStack(spacing: 16) {
                ForEach(ProjectAnswers.knownTargets, id: \.self) { target in
                    Toggle(target, isOn: Binding(get: { answers.targets.contains(target) },
                                                 set: { on in answers.targets = ProjectAnswers.knownTargets.filter { $0 == target ? on : answers.targets.contains($0) } }))
                }
                Spacer()
            }
            .padding(4)
        }
    }

    private var layersBox: some View {
        GroupBox("Layers") {
            VStack(alignment: .leading, spacing: 6) {
                if offered.isEmpty {
                    Text("No layers for projects yet (core is for the home folder).").foregroundStyle(.secondary)
                }
                let pulledIn = Set(bundle?.layers ?? []).subtracting(answers.layers)
                ForEach(offered) { layer in
                    Toggle(isOn: Binding(get: { answers.layers.contains(layer.name) || pulledIn.contains(layer.name) },
                                         set: { on in
                                             if on { answers.layers.append(layer.name) } else { answers.layers.removeAll { $0 == layer.name } }
                                         })) {
                        HStack(spacing: 6) {
                            Text(layer.name).fontWeight(.medium)
                            if pulledIn.contains(layer.name) {
                                Text("required").font(.caption).foregroundStyle(.secondary)
                            }
                            Text(layer.description).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    .disabled(pulledIn.contains(layer.name))
                }
                Button("New Layer…", systemImage: "plus") { creatingLayer = true }
                    .help("Create a layer; it shows up here right away")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(4)
        }
    }

    /// Skills the picked layers bring (as the render sees them: `when`, `override`, `off`).
    private var layerSkills: [String: (layer: String, mode: LayerSkill.Mode)] {
        guard let brain, let project else { return [:] }
        var layersOnly = answers
        layersOnly.skills = []
        let skills = ProjectBundle.resolve(layersOnly, brain: brain, projectName: project.lastPathComponent).skills
        return Dictionary(skills.map { ($0.name, (layer: $0.source, mode: $0.mode)) }, uniquingKeysWith: { _, last in last })
    }

    private var skillsBox: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 6) {
                let fromLayers = layerSkills
                // The ones in use (from a layer or picked) first.
                let inUse = Set(fromLayers.keys).union(answers.skills.map(\.name))
                let shown = (brain?.skills ?? []).filter { skillQuery.isEmpty || $0.name.localizedCaseInsensitiveContains(skillQuery) }
                    .sorted { inUse.contains($0.name) && !inUse.contains($1.name) }
                // Picked for the project but gone from the brain: can only be taken out.
                let missing = answers.skills.filter { picked in !(brain?.skills ?? []).contains { $0.name == picked.name } }
                List {
                    ForEach(missing, id: \.name) { picked in
                        HStack {
                            Label("\(picked.name) is no longer in the brain", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                            Spacer()
                            Button("Remove") { answers.skills.removeAll { $0.name == picked.name } }
                        }
                    }
                    ForEach(shown) { skill in
                        skillRow(skill, layer: fromLayers[skill.name])
                    }
                }
                .listStyle(.bordered)
                .frame(height: 190)
                Text("Skills for this project only, or a different mode for one a layer brings. The project's own skills (in .agents/skills) are kept as they are; manage them on the project's page.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(4)
        } label: {
            HStack {
                Text("Skills")
                Spacer()
                TextField("Filter", text: $skillQuery).frame(width: 160)
            }
        }
    }

    private func skillRow(_ skill: Brain.Skill, layer: (layer: String, mode: LayerSkill.Mode)?) -> some View {
        let chosen = answers.skills.first { $0.name == skill.name }?.mode
        let mode = chosen ?? layer?.mode
        return HStack(spacing: 8) {
            Toggle(isOn: Binding(get: { mode != nil && mode != .off },
                                 set: { on in setSkill(skill.name, on ? layer.map { $0.mode == .off ? .auto : $0.mode } ?? .auto : .off, layer: layer?.mode) })) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(skill.name).fontWeight(.medium)
                    Text(skill.description).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer()
            if let layer {
                Text(chosen == nil ? "from \(layer.layer)" : "changed for this project").font(.caption).foregroundStyle(chosen == nil ? Color.secondary : .orange)
            }
            if let mode, mode != .off {
                Picker("", selection: Binding(get: { mode }, set: { setSkill(skill.name, $0, layer: layer?.mode) })) {
                    Text("auto").tag(LayerSkill.Mode.auto)
                    Text("manual").tag(LayerSkill.Mode.manual)
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .fixedSize()
                .help("auto: the agent sees it and may use it; manual: only on /\(skill.name)")
            }
        }
    }

    /// Keeps only what differs from the layers: an added skill or a changed mode.
    private func setSkill(_ name: String, _ mode: LayerSkill.Mode, layer: LayerSkill.Mode?) {
        let differs = layer.map { $0 != mode } ?? (mode != .off)
        if let index = answers.skills.firstIndex(where: { $0.name == name }) {
            if differs { answers.skills[index].mode = mode } else { answers.skills.remove(at: index) }
        } else if differs {
            answers.skills.append(.init(name: name, mode: mode))
        }
    }

    @ViewBuilder
    private var fieldsBox: some View {
        let layers = (bundle?.layers ?? []).compactMap { name in brain?.layers.first { $0.name == name } }
        let fields = layers.flatMap(\.fields)
        if !fields.isEmpty {
            GroupBox("Fields") {
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 8) {
                    ForEach(fields) { field in
                        GridRow {
                            Text(field.prompt + (field.required ? " *" : ""))
                                .gridColumnAlignment(.trailing)
                                .help(field.id)
                            fieldInput(field)
                        }
                    }
                }
                .padding(4)
            }
        }
    }

    @ViewBuilder
    private func fieldInput(_ field: LayerField) -> some View {
        switch field.kind {
        case .text:
            TextField(field.defaultValue?.display ?? "", text: Binding(
                get: { if case .text(let text) = answers.values[field.id] { text } else { "" } },
                set: { answers.values[field.id] = $0.isEmpty ? nil : .text($0) }))
        case .bool:
            Toggle("", isOn: Binding(
                get: { if case .bool(let flag) = answers.values[field.id] ?? field.defaultValue { flag } else { false } },
                set: { answers.values[field.id] = .bool($0) }))
                .labelsHidden()
        case .choice:
            Picker("", selection: Binding(
                get: { if case .text(let text) = answers.values[field.id] ?? field.defaultValue { text } else { "" } },
                set: { answers.values[field.id] = .text($0) })) {
                Text("—").tag("")
                ForEach(field.options, id: \.self) { Text($0).tag($0) }
            }
            .labelsHidden()
            .fixedSize()
        case .multi:
            HStack {
                ForEach(field.options, id: \.self) { option in
                    Toggle(option, isOn: Binding(
                        get: { if case .list(let items) = answers.values[field.id] ?? field.defaultValue { items.contains(option) } else { false } },
                        set: { on in
                            var items: [String] = []
                            if case .list(let current) = answers.values[field.id] ?? field.defaultValue { items = current }
                            items = field.options.filter { $0 == option ? on : items.contains($0) }
                            answers.values[field.id] = .list(items)
                        }))
                }
            }
        }
    }

    @ViewBuilder
    private var messages: some View {
        if let bundle, !answers.layers.isEmpty || !answers.skills.isEmpty {
            let check = ProjectSetup.check(bundle)
            VStack(alignment: .leading, spacing: 4) {
                ForEach(check.errors, id: \.self) { Label($0, systemImage: "xmark.octagon.fill").foregroundStyle(.red) }
                ForEach(check.warnings, id: \.self) { Label($0, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange) }
            }
            .font(.callout)
            .textSelection(.enabled)
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Choose"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await choose(url) }
    }

    /// Picks the project and prefills the form from its saved answers.
    private func choose(_ url: URL?) async {
        project = url
        projectID = nil
        error = nil
        guard let url, brain != nil else { return }
        let id = await model.projectID(for: url)
        guard project == url else { return }
        projectID = id
        answers = ProjectRecords.savedAnswers(id: id, in: model.projectStore)
            ?? ProjectAnswers(layers: [], values: [:], targets: model.installedTargets)
        for name in initialLayers where !answers.layers.contains(name) { answers.layers.append(name) }
    }

    private func makePlan() {
        guard let project, let projectID else { return }
        isWorking = true
        error = nil
        Task {
            defer { isWorking = false }
            guard let made = await model.projectPlan(project: project, id: projectID, answers: answers) else {
                error = "The brain is not loaded."
                return
            }
            plan = made
            // Files AKit didn't write, or edited by hand since, and the layers' version of the
            // project's own files are left out until you tick them.
            excluded = Set(made.changes.filter { change in
                change.kind == .update && (change.replacesUnmanaged || change.editedSinceRender) || change.kind == .suggest || change.kind == .own
            }.map(\.path))
            selectedChange = made.changes.first { $0.kind != .same }?.path
            page = .preview
        }
    }

    // MARK: - Preview

    private var preview: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Changes in \(plan?.project.lastPathComponent ?? "")").font(.title2.bold())
            if let plan {
                ForEach(plan.render.errors + plan.blockers, id: \.self) {
                    Label($0, systemImage: "xmark.octagon.fill").foregroundStyle(.red).font(.callout).textSelection(.enabled)
                }
                ForEach(plan.render.warnings, id: \.self) {
                    Label($0, systemImage: "info.circle").foregroundStyle(.secondary).font(.callout).textSelection(.enabled)
                }
                HSplitView {
                    changeList(plan).frame(minWidth: 280, idealWidth: 320)
                    diff(plan).frame(minWidth: 300)
                }
            }
            HStack {
                if let error { Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).lineLimit(3).textSelection(.enabled) }
                Spacer()
                Button("Back") { page = .form; error = nil }.keyboardShortcut(.cancelAction)
                Button(isWorking ? "Applying…" : "Apply", action: apply)
                    .keyboardShortcut(.defaultAction)
                    // Only offers from the layers: Apply still records them as seen.
                    .disabled(!(plan?.canApply ?? false) || isWorking || (pending.isEmpty && !hasOffers))
            }
        }
    }

    /// Changes that Apply would carry out.
    private var pending: [ProjectSetup.Change] {
        (plan?.changes ?? []).filter { Self.writable.contains($0.kind) && !excluded.contains($0.path) }
    }

    private var hasOffers: Bool { plan?.changes.contains { $0.kind == .suggest } ?? false }

    /// Kinds Apply can carry out; the project's own files only when ticked.
    private static let writable: [ProjectSetup.Change.Kind] = [.create, .update, .remove, .suggest, .own]

    private func changeList(_ plan: ProjectSetup.Plan) -> some View {
        let unchanged = plan.changes.filter { $0.kind == .same }.count
        return List(selection: $selectedChange) {
            ForEach(plan.changes.filter { $0.kind != .same }) { change in
                HStack(spacing: 6) {
                    if Self.writable.contains(change.kind) {
                        Toggle("", isOn: Binding(get: { !excluded.contains(change.path) },
                                                 set: { if $0 { excluded.remove(change.path) } else { excluded.insert(change.path) } }))
                            .labelsHidden()
                    }
                    VStack(alignment: .leading, spacing: 1) {
                        Text(change.path).font(.callout.monospaced()).lineLimit(1).truncationMode(.middle)
                        HStack(spacing: 4) {
                            Text(label(change.kind)).foregroundStyle(tint(change.kind))
                            if change.replacesUnmanaged && change.kind == .update {
                                Text("· replaces a file AKit didn't write").foregroundStyle(.orange)
                            } else if change.editedSinceRender {
                                Text("· edited by hand since the last render").foregroundStyle(.orange)
                            } else if change.kind == .suggest || change.kind == .own {
                                Text("· tick to take the layers' version").foregroundStyle(.secondary)
                            }
                        }
                        .font(.caption)
                    }
                }
                .tag(change.path)
            }
            if unchanged > 0 {
                Text("\(unchanged) file\(unchanged == 1 ? "" : "s") unchanged").font(.caption).foregroundStyle(.secondary)
                    .selectionDisabled()
            }
        }
        .listStyle(.bordered)
    }

    @ViewBuilder
    private func diff(_ plan: ProjectSetup.Plan) -> some View {
        if let change = plan.changes.first(where: { $0.path == selectedChange }) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if change.oldText == nil && change.newText == nil {
                        Text("Binary file").foregroundStyle(.secondary)
                    } else {
                        DiffPreview(diff: TextDiff.lines(from: change.oldText ?? "", to: change.kind == .remove || change.kind == .keepEdited ? "" : change.newText ?? ""))
                    }
                }
                .font(.callout.monospaced())
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(6)
            }
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 6))
        } else {
            ContentUnavailableView("Select a file", systemImage: "doc.text")
        }
    }

    private func label(_ kind: ProjectSetup.Change.Kind) -> String {
        switch kind {
        case .create: "new"
        case .update: "changed"
        case .same: "unchanged"
        case .remove: "removed (to the Trash)"
        case .keepEdited: "no longer rendered, but edited by hand: kept"
        case .suggest: "the project's own · layers changed"
        case .own: "the project's own"
        }
    }

    private func tint(_ kind: ProjectSetup.Change.Kind) -> Color {
        switch kind {
        case .create: .green
        case .update: .blue
        case .remove: .red
        case .suggest: .orange
        case .same, .keepEdited, .own: .secondary
        }
    }

    private func apply() {
        guard let plan else { return }
        isWorking = true
        error = nil
        Task {
            defer { isWorking = false }
            do {
                let taken = Set(plan.changes.filter { ($0.kind == .suggest || $0.kind == .own) && !excluded.contains($0.path) }.map(\.path))
                outcome = try await model.applyProject(plan, excluding: excluded, accepting: taken)
                page = .done
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    // MARK: - Done

    private var done: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("\(plan?.project.lastPathComponent ?? "Project") is set up", systemImage: "checkmark.circle.fill")
                .font(.title2.bold())
                .foregroundStyle(.green)
            if let outcome {
                Text("Written: \(outcome.written.count) · moved to the Trash: \(outcome.removed.count)")
                if let backup = outcome.backup {
                    Text("Replaced files are backed up in \(backup.tildePath)").font(.callout.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                }
                ForEach(outcome.notes, id: \.self) { Label($0, systemImage: "info.circle") }
            }
            if let plan {
                Text("Answers are saved \(plan.store.isLocal ? "on this Mac only, in" : "in the brain under") \(plan.store.describe(id: plan.id)). Review and commit the new harness files in the project yourself.")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            HStack {
                if let project = plan?.project {
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([project]) }
                }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
    }
}
