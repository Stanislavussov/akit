import AKitBrain
import AKitFoundation
import AKitProjectSetup
import SwiftUI

/// Move to Global…: a project's skill into the core layer, so every session on this Mac gets it,
/// then out of the projects (docs/design/layers.md, "Move a skill to a project", the reverse).
/// The plan by place, with the layer.yaml diff → Move → the outcome.
struct MoveToGlobalSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let name: String
    /// The projects it leaves; nil: every project whose answers list it.
    let from: [String]?

    @State private var plan: SkillMove.GlobalPlan?
    @State private var mode: LayerSkill.Mode?
    @State private var selected: String?
    @State private var comparison: SkillMove.Edit?
    @State private var isWorking = false
    @State private var error: String?
    @State private var outcome: SkillMove.GlobalOutcome?
    @State private var failure: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if outcome != nil || failure != nil { done } else { preview }
        }
        .padding(16)
        .frame(width: 780, height: 600)
        .task(id: mode) { await replan() }
    }

    /// One line of the preview.
    private struct Item: Identifiable {
        let id: String
        let title: String
        let detail: String
        let tint: Color
        var old = ""
        var new = ""
        var hasDiff = false
    }

    private func sections(_ plan: SkillMove.GlobalPlan) -> [(title: String, items: [Item])] {
        let home = HarnessEnvironment.current.homeDirectory
        var sections: [(String, [Item])] = []
        if let source = plan.importSource {
            sections.append(("Brain", [Item(id: "brain", title: "skills/\(name)", detail: "copied from \(SkillMove.shown(source.folder, home: home)), in no layer", tint: .green)]))
        }
        if let edit = plan.coreEdit {
            sections.append(("Core layer", [Item(id: "core", title: "layers/core/layer.yaml", detail: "\(name) added (\(plan.mode.rawValue)), committed first",
                                                 tint: .green, old: edit.before, new: edit.after, hasDiff: true)]))
        }
        let homeChanges = plan.home?.changes.filter { plan.homePaths.contains($0.path) } ?? []
        sections.append(("Home folder", homeChanges.isEmpty
            ? [Item(id: "home", title: "nothing to write", detail: "the home folder has it already", tint: .secondary)]
            : homeChanges.map { Item(id: "home:\($0.path)", title: "~/\($0.path)", detail: "new", tint: .green, new: $0.newText ?? "", hasDiff: $0.newText != nil) }))
        for part in plan.parts {
            var items: [Item] = []
            switch part.state {
            case .answers:
                items.append(Item(id: "\(part.id):answers", title: "answers", detail: "\(name) leaves them", tint: .blue))
                for path in part.paths.sorted() { items.append(Item(id: "\(part.id):\(path)", title: path, detail: "to the Trash", tint: .red)) }
                if !part.worktrees.isEmpty {
                    items.append(Item(id: "\(part.id):worktrees", title: "links in \(part.worktrees.count) worktree\(part.worktrees.count == 1 ? "" : "s")",
                                      detail: "removed with the sync", tint: .secondary))
                }
            case .answersOnly:
                items.append(Item(id: "\(part.id):answers", title: "answers only", detail: "not on this Mac: Set Up Project on its Mac takes \(name) out", tint: .secondary))
            case .ownCopy:
                items.append(Item(id: "\(part.id):own", title: part.own.map { SkillMove.shown($0.folder, home: home) } ?? name,
                                  detail: "its own copy, to the Trash last", tint: .red))
            case .blocked(let reason):
                items.append(Item(id: "\(part.id):blocked", title: "blocked", detail: reason, tint: .red))
            }
            sections.append(("Project \(part.id)", items))
        }
        return sections.map { (title: $0.0, items: $0.1) }
    }

    private var preview: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Move “\(name)” to Global").font(.title2.bold())
            Text("The skill joins the core layer and this Mac's home folder first, so every session gets it; only then does it leave the projects (their copies go to the Trash, a local-only project's worktree links too).")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let plan {
                let sections = sections(plan)
                HSplitView {
                    List(selection: $selected) {
                        ForEach(sections, id: \.title) { section in
                            Section(section.title) {
                                ForEach(section.items) { item in
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(item.title).font(.callout.monospaced()).lineLimit(1).truncationMode(.middle)
                                        Text(item.detail).font(.caption).foregroundStyle(item.tint).lineLimit(3)
                                    }
                                    .tag(item.id)
                                }
                            }
                        }
                    }
                    .listStyle(.bordered)
                    .frame(minWidth: 300, idealWidth: 340, maxHeight: .infinity)
                    diff(sections.flatMap(\.items).first { $0.id == selected })
                        .frame(minWidth: 300, maxWidth: .infinity, maxHeight: .infinity)
                }
                .frame(maxHeight: .infinity)
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(plan.blockers, id: \.self) { Label($0, systemImage: "xmark.octagon.fill").foregroundStyle(.red) }
                    ForEach(plan.edits, id: \.path) { edit in
                        Button("Show Edits: \(edit.path)") { comparison = edit; selected = nil }.buttonStyle(.link)
                    }
                    ForEach(plan.warnings, id: \.self) { Label($0, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange) }
                    ForEach(plan.notes, id: \.self) { Label($0, systemImage: "info.circle").foregroundStyle(.secondary) }
                }
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            } else {
                ProgressView("Planning…").frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            HStack {
                Picker("Mode", selection: Binding(get: { mode ?? plan?.mode ?? .auto }, set: { mode = $0 })) {
                    Text("auto").tag(LayerSkill.Mode.auto)
                    Text("manual").tag(LayerSkill.Mode.manual)
                }
                .pickerStyle(.segmented)
                .fixedSize()
                .help("How the core layer brings it: auto (the agent sees it) or manual (only /\(name))")
                if let error { Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).lineLimit(2) }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction).disabled(isWorking)
                Button(isWorking ? "Moving…" : "Move", action: apply)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!(plan?.canApply ?? false) || isWorking)
            }
        }
    }

    @ViewBuilder
    private func diff(_ item: Item?) -> some View {
        if let item, item.hasDiff {
            diffView(old: item.old, new: item.new)
        } else if let comparison {
            diffView(old: comparison.brainText ?? "", new: comparison.copyText ?? "")
        } else if let item {
            ContentUnavailableView(item.title, systemImage: "info.circle", description: Text(item.detail))
        } else {
            ContentUnavailableView("Select a change", systemImage: "doc.text")
        }
    }

    private func diffView(old: String, new: String) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                DiffPreview(diff: TextDiff.lines(from: old, to: new))
            }
            .font(.callout.monospaced())
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(6)
        }
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 6))
    }

    private var done: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let failure {
                Label("The move stopped", systemImage: "exclamationmark.triangle.fill").font(.title2.bold()).foregroundStyle(.orange)
                Text(failure).textSelection(.enabled)
            } else {
                Label("\(name) is global", systemImage: "checkmark.circle.fill").font(.title2.bold()).foregroundStyle(.green)
            }
            if let outcome {
                VStack(alignment: .leading, spacing: 6) {
                    if outcome.imported { Label("Brain: copied into skills/\(name)", systemImage: "brain") }
                    if outcome.coreChanged { Label("Core layer: \(name) added", systemImage: "square.stack.3d.up") }
                    if let home = outcome.home { Label("Home folder: \(home.written.count) file\(home.written.count == 1 ? "" : "s") written", systemImage: "house") }
                    ForEach(outcome.projects, id: \.id) { project in
                        Label("\(project.id): \(project.outcome.removed.count) to the Trash", systemImage: "folder")
                    }
                    if !outcome.answersSaved.isEmpty { Label("Answers only (other Macs): \(outcome.answersSaved.joined(separator: ", "))", systemImage: "doc.text") }
                    if !outcome.trashed.isEmpty { Label("To the Trash: \(outcome.trashed.joined(separator: ", "))", systemImage: "trash") }
                }
                .textSelection(.enabled)
            }
            if failure == nil {
                Text("On your other Macs, Brain → Sync offers Update Home Folder, which adds \(name) there.").foregroundStyle(.secondary)
            }
            Spacer()
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
    }

    private func replan() async {
        isWorking = true
        defer { isWorking = false }
        guard let made = await model.moveToGlobalPlan(name: name, from: from, mode: mode) else {
            error = "The brain is not loaded."
            return
        }
        plan = made
        if selected == nil { selected = made.coreEdit == nil ? nil : "core" }
    }

    private func apply() {
        guard let plan else { return }
        isWorking = true
        error = nil
        Task {
            defer { isWorking = false }
            do {
                outcome = try await model.moveToGlobal(plan)
            } catch let stopped as SkillMove.GlobalFailure {
                outcome = stopped.outcome
                failure = stopped.message
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}
