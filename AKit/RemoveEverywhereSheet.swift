import AKitBrain
import AKitFoundation
import AKitModel
import AKitProjectSetup
import AKitSkills
import SwiftUI

/// Remove Everywhere…: every place a harness on this Mac loads the skill from, each with its
/// action and a checkbox, so the skill stops reaching any context (docs/design/layers.md,
/// "Remove a skill everywhere"). Places → Remove → the outcome.
struct RemoveEverywhereSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    /// The skill's folder name, as Claude Code and the brain call it.
    let name: String

    @State private var plan: SkillRemoval.Plan?
    @State private var selected: String?
    @State private var isWorking = false
    @State private var error: String?
    @State private var outcome: SkillRemoval.Outcome?
    @State private var failure: String?
    @State private var comparison: SkillMove.Edit?
    @State private var pluginPlan: PluginSwitch.Plan?
    @State private var piSwitch: SkillSwitches.Plan?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if outcome != nil || failure != nil { done } else { places }
        }
        .padding(16)
        .frame(width: 820, height: 640)
        // Again after each rescan (the first one, or a switch or plugin change made here).
        .task(id: model.lastScan) { await replan(leaving: plan?.leaving) }
        .modifier(DisablePluginAlert(plan: $pluginPlan, problem: $error) { Task { await replan(leaving: plan?.leaving) } })
        .alert("Turn \(name) Off in Pi?", isPresented: Binding(get: { piSwitch != nil }, set: { if !$0 { piSwitch = nil } }),
               presenting: piSwitch) { plan in
            Button("Turn Off") { switchOff(plan) }
            Button("Cancel", role: .cancel) {}
        } message: { plan in
            Text("\(plan.file.tildePath) changes (a backup is made first):\n" + Self.diffText(plan.diff))
        }
    }

    // MARK: - Places

    private var places: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Remove “\(name)” Everywhere").font(.title2.bold())
            Text("Every place Claude Code, Pi and the other harnesses on this Mac load \(name) from. Ticked places are removed: own copies go to the Trash, brain layers and project answers lose its entry (committed) and AKit's copies leave with their Apply. Untick what should stay.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let plan {
                HSplitView {
                    List(selection: $selected) {
                        ForEach(groups(plan), id: \.self) { group in
                            Section(group) {
                                ForEach(plan.places.filter { $0.group == group }) { place in
                                    row(place).tag(place.id)
                                }
                            }
                        }
                    }
                    .listStyle(.bordered)
                    .frame(minWidth: 420, idealWidth: 480, maxHeight: .infinity)
                    detail(plan.places.first { $0.id == selected })
                        .frame(minWidth: 260, maxWidth: .infinity, maxHeight: .infinity)
                }
                .frame(maxHeight: .infinity)
                footer(plan)
            } else {
                ProgressView("Looking for every copy of \(name)…").frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            HStack {
                if let error { Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).lineLimit(3) }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction).disabled(isWorking)
                Button(isWorking ? "Removing…" : "Remove", role: .destructive, action: remove)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!(plan?.canApply ?? false) || isWorking)
            }
        }
    }

    private func groups(_ plan: SkillRemoval.Plan) -> [String] {
        var seen: [String] = []
        for place in plan.places where !seen.contains(place.group) { seen.append(place.group) }
        return seen
    }

    @ViewBuilder
    private func row(_ place: SkillRemoval.Place) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                if place.canSelect {
                    Toggle(isOn: Binding(get: { place.selected }, set: { toggle(place, on: $0) })) {
                        Text(place.title).font(.callout.monospaced()).lineLimit(1).truncationMode(.middle)
                    }
                    .disabled(isWorking)
                } else {
                    Image(systemName: place.selected ? "checkmark.circle" : "minus.circle").foregroundStyle(.secondary)
                    Text(place.title).font(.callout.monospaced()).lineLimit(1).truncationMode(.middle)
                }
                if place.isLink {
                    Text("link").font(.caption2).foregroundStyle(.secondary)
                        .help("A link of its own to the skill's folder: only the link goes to the Trash")
                }
                if place.byHeader {
                    Text("maybe the same skill").font(.caption2).foregroundStyle(.orange)
                        .help("Its folder has another name, but its header says \(name)")
                }
            }
            if !place.via.isEmpty {
                Text("Also reached as " + place.via.joined(separator: ", ") + " (a folder that is a link)")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Text(Self.actionText(place)).font(.caption).foregroundStyle(place.reason == nil ? Color.secondary : Color.orange)
                .lineLimit(3).fixedSize(horizontal: false, vertical: true)
            if !place.harnesses.isEmpty {
                Text("Loaded by " + place.harnesses.map(\.displayName).joined(separator: ", ")).font(.caption2).foregroundStyle(.tertiary)
            }
            alternatives(place)
        }
        .padding(.vertical, 2)
    }

    /// What to do instead where AKit can't remove the skill.
    @ViewBuilder
    private func alternatives(_ place: SkillRemoval.Place) -> some View {
        if let plugin = place.plugin {
            Button("Disable Plugin…") {
                do { pluginPlan = try model.pluginPlan(plugin) } catch { self.error = error.localizedDescription }
            }
            .help("Turn the whole plugin \(plugin) off in Claude Code (enabledPlugins); every skill of it goes")
        } else if place.reason != nil, let skill = place.skill, case .project = skill.scope, skill.visibleTo.contains(.pi),
                  let options = SkillSwitches.options(for: skill, harness: .pi, in: .current), options.unavailable == nil {
            Button("Pi: Off…") {
                do { piSwitch = try SkillSwitches.plan(skill, harness: .pi, to: .off, in: .current) } catch { self.error = error.localizedDescription }
            }
            .help("Turn it off for Pi in this project only (the project's .pi/settings.json); the files stay")
        }
    }

    @ViewBuilder
    private func detail(_ place: SkillRemoval.Place?) -> some View {
        if let place, let before = place.before, let after = place.after {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    DiffPreview(diff: TextDiff.lines(from: before, to: after))
                }
                .font(.callout.monospaced())
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(6)
            }
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 6))
        } else if let comparison {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    DiffPreview(diff: TextDiff.lines(from: comparison.brainText ?? "", to: comparison.copyText ?? ""))
                }
                .font(.callout.monospaced())
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(6)
            }
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 6))
        } else if let place {
            ContentUnavailableView(place.title, systemImage: "info.circle", description: Text(place.reason ?? Self.actionText(place)))
        } else {
            ContentUnavailableView("Select a place", systemImage: "doc.text", description: Text("A brain entry shows its change here."))
        }
    }

    private func footer(_ plan: SkillRemoval.Plan) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(plan.blockers, id: \.self) { Label($0, systemImage: "xmark.octagon.fill").foregroundStyle(.red) }
            ForEach(plan.edits, id: \.path) { edit in
                Button("Show Edits: \(edit.path)") { comparison = edit; selected = nil }.buttonStyle(.link)
            }
            ForEach(plan.notes, id: \.self) { Label($0, systemImage: "info.circle").foregroundStyle(.secondary) }
            Label(plan.summary, systemImage: plan.remaining.isEmpty ? "checkmark.circle" : "exclamationmark.circle")
                .foregroundStyle(plan.remaining.isEmpty ? .green : .orange)
                .textSelection(.enabled)
        }
        .font(.callout)
        .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Done

    private var done: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let failure {
                Label("Removing stopped", systemImage: "exclamationmark.triangle.fill").font(.title2.bold()).foregroundStyle(.orange)
                Text(failure).textSelection(.enabled)
            } else {
                Label("\(name) is removed", systemImage: "checkmark.circle.fill").font(.title2.bold()).foregroundStyle(.green)
                if let plan { Text(plan.summary).foregroundStyle(.secondary) }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(outcome?.done ?? [], id: \.self) { Label($0, systemImage: "checkmark") }
                    ForEach(outcome?.notes ?? [], id: \.self) { Label($0, systemImage: "info.circle").foregroundStyle(.secondary) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
            }
            Text("Running sessions keep their skill list until they reload it (e.g. /reload-skills).").foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
    }

    // MARK: - Work

    private func replan(leaving: Set<String>?) async {
        isWorking = true
        defer { isWorking = false }
        let made = await model.removalPlan(name: name, leaving: leaving)
        plan = made
        if selected == nil { selected = made.places.first { $0.before != nil }?.id }
    }

    private func toggle(_ place: SkillRemoval.Place, on: Bool) {
        guard let plan else { return }
        var leaving = plan.leaving
        if on { leaving.remove(place.id) } else { leaving.insert(place.id) }
        Task { await replan(leaving: leaving) }
    }

    private func remove() {
        guard let plan else { return }
        isWorking = true
        error = nil
        Task {
            defer { isWorking = false }
            do {
                outcome = try await model.removeEverywhere(plan)
            } catch let stopped as SkillRemoval.Failure {
                outcome = stopped.outcome
                failure = stopped.message
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    private func switchOff(_ plan: SkillSwitches.Plan) {
        Task {
            do {
                _ = try await model.applySkillSwitch(plan)
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    // MARK: - Text

    static func actionText(_ place: SkillRemoval.Place) -> String {
        if let reason = place.reason { return reason }
        switch place.action {
        case .trash: return place.selected ? "To the Trash" : "Stays (not ticked)"
        case .layer(let layer): return place.selected ? "Out of layer \(layer), committed" : "Stays in layer \(layer)"
        case .answers(let id): return place.selected ? "Out of \(id)'s answers" : "Stays in \(id)'s answers"
        case .claudeOff: return place.selected ? "Claude switch Off (skillOverrides)" : "A claude.ai skill: tick to turn it off in Claude Code"
        case .rendered: return place.selected ? "AKit's copy: to the Trash with its Apply" : "AKit's copy: stays while its brain entry stays"
        case .library: return place.selected ? "Out of the brain library, committed (its git history stays)" : "Stays in the brain library (tick to delete it there too)"
        case .keep: return "Stays"
        }
    }

    static func diffText(_ diff: [TextDiff.Line]) -> String {
        diff.compactMap { line -> String? in
            switch line {
            case .added(let text): "+ " + text
            case .removed(let text): "- " + text
            case .same: nil
            }
        }.joined(separator: "\n")
    }
}

/// Disable Plugin…: the confirmation naming the exact `enabledPlugins` keys, the skills and MCP
/// servers that go with the plugin, and the projects whose own settings keep it on.
struct DisablePluginAlert: ViewModifier {
    @Environment(AppModel.self) private var model
    @Binding var plan: PluginSwitch.Plan?
    @Binding var problem: String?
    var onDone: () -> Void = {}

    func body(content: Content) -> some View {
        content.alert("Disable the Plugin \(plan?.plugin ?? "")?", isPresented: Binding(get: { plan != nil }, set: { if !$0 { plan = nil } }),
                      presenting: plan) { plan in
            Button("Disable Plugin", role: .destructive) {
                Task {
                    do {
                        try await model.disablePlugin(plan)
                        onDone()
                    } catch {
                        problem = error.localizedDescription
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: { plan in
            Text("Claude Code turns the whole plugin off; a backup is made first.\n" + plan.summary)
        }
    }
}
