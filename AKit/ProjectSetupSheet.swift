import AKitCore
import AppKit
import SwiftUI

/// Set up a project from brain layers: form → preview with diffs → apply.
struct ProjectSetupSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

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

    private var render: Render.Result? {
        guard let brain, let project else { return nil }
        return Render.render(answers, brain: brain, projectName: project.lastPathComponent)
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Set Up a Project").font(.title2.bold())
            projectPicker
            if project != nil {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        targetsBox
                        layersBox
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
                    .disabled(project == nil || projectID == nil || answers.layers.isEmpty || isWorking)
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
                let pulledIn = Set(render?.layers ?? []).subtracting(answers.layers)
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

    @ViewBuilder
    private var fieldsBox: some View {
        let layers = (render?.layers ?? []).compactMap { name in brain?.layers.first { $0.name == name } }
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
        if let render, !answers.layers.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(render.errors, id: \.self) { Label($0, systemImage: "xmark.octagon.fill").foregroundStyle(.red) }
                ForEach(render.warnings, id: \.self) { Label($0, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange) }
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
        answers = ProjectSetup.savedAnswers(id: id, in: model.projectStore)
            ?? ProjectAnswers(layers: [], values: [:], targets: model.installedTargets)
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
            // Files AKit didn't write, or edited by hand since, are left out until you tick them.
            excluded = Set(made.changes.filter { $0.kind == .update && ($0.replacesUnmanaged || $0.editedSinceRender) }.map(\.path))
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
                    .disabled(!(plan?.canApply ?? false) || isWorking || pending.isEmpty)
            }
        }
    }

    /// Changes that Apply would carry out.
    private var pending: [ProjectSetup.Change] {
        (plan?.changes ?? []).filter { [.create, .update, .remove].contains($0.kind) && !excluded.contains($0.path) }
    }

    private func changeList(_ plan: ProjectSetup.Plan) -> some View {
        let unchanged = plan.changes.filter { $0.kind == .same }.count
        return List(selection: $selectedChange) {
            ForEach(plan.changes.filter { $0.kind != .same }) { change in
                HStack(spacing: 6) {
                    if [.create, .update, .remove].contains(change.kind) {
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
        }
    }

    private func tint(_ kind: ProjectSetup.Change.Kind) -> Color {
        switch kind {
        case .create: .green
        case .update: .blue
        case .remove: .red
        case .same, .keepEdited: .secondary
        }
    }

    private func apply() {
        guard let plan else { return }
        isWorking = true
        error = nil
        Task {
            defer { isWorking = false }
            do {
                outcome = try await model.applyProject(plan, excluding: excluded)
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
