import AKitBrain
import AKitFoundation
import SwiftUI

/// The strip above the skill list when the brain lacks one of AKit's own skills, or has an
/// older copy. A brain gets them from `akit init` only, so an older brain needs this.
struct BuiltInSkillsBanner: View {
    let plan: BuiltInSkills.Plan
    let onOpen: () -> Void

    var body: some View {
        let missing = plan.items.filter { $0.state == .missing || !$0.inCore }.map { "/" + $0.name }
        let outdated = plan.items.filter { $0.state == .outdated }.map { "/" + $0.name }
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "sparkles").foregroundStyle(.tint)
            Text([missing.isEmpty ? nil : "Not in your brain: \(missing.joined(separator: ", ")).",
                  outdated.isEmpty ? nil : "Older copy: \(outdated.joined(separator: ", "))."]
                .compactMap { $0 }.joined(separator: " "))
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            Button("AKit Skills…", action: onOpen)
                .help("Add AKit's own skills to the brain's core layer, or update them to this AKit's version")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(.tint.opacity(0.08))
    }
}

/// AKit Skills…: pick which of AKit's own skills to add to core or update, with their mode and
/// a preview of each file, then one brain commit. The home folder changes on Update Home Folder.
struct BuiltInSkillsSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let plan: BuiltInSkills.Plan
    /// Called after the commit: the screen opens Update Home Folder….
    let onDone: () -> Void
    @State private var chosen: Set<String> = []
    @State private var modes: [String: LayerSkill.Mode] = [:]
    @State private var shown: String?
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("AKit Skills").font(.title2.bold())
            Text("AKit's own skills: /akit sets AKit up, /akit-context lets an agent read the knowledge base and the notebook. A new brain gets them; an older one gets them here. The chosen ones go into the brain's skills/ and the core layer, in one commit. Then Update Home Folder puts them where your harnesses read skills.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                ForEach(plan.items) { item in
                    GridRow {
                        Toggle(isOn: Binding(get: { chosen.contains(item.name) },
                                             set: { if $0 { chosen.insert(item.name) } else { chosen.remove(item.name) } })) {
                            Text("/" + item.name).fontWeight(.medium)
                        }
                        .disabled(!item.needsWork || busy)
                        Text(status(item)).foregroundStyle(item.needsWork ? .primary : .secondary)
                        if item.inCore {
                            Text(item.mode.rawValue).foregroundStyle(.secondary)
                                .help("Its mode in core. Change it with Model invocation on the skill.")
                        } else {
                            Picker("Mode", selection: Binding(get: { modes[item.name] ?? item.mode }, set: { modes[item.name] = $0 })) {
                                Text("auto").tag(LayerSkill.Mode.auto)
                                Text("manual").tag(LayerSkill.Mode.manual)
                            }
                            .labelsHidden()
                            .pickerStyle(.segmented)
                            .fixedSize()
                            .disabled(busy)
                            .help("auto: the agent loads it when the task fits. manual: only when you type /\(item.name).")
                        }
                        Button("Show") { shown = item.name }
                            .buttonStyle(.link)
                            .disabled(item.state == .current)
                    }
                }
            }
            preview
            HStack {
                if let error {
                    Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).lineLimit(3)
                        .textSelection(.enabled)
                }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(busy ? "Saving…" : "Add to Brain", action: apply)
                    .keyboardShortcut(.defaultAction)
                    .disabled(chosen.isEmpty || busy)
                    .help("Write the chosen skills into the brain and commit; then Update Home Folder opens")
            }
        }
        .padding(16)
        .frame(width: 640, height: 560)
        .onAppear {
            chosen = Set(plan.items.filter(\.needsWork).map(\.name))
            shown = plan.items.first { $0.state != .current }?.name
        }
    }

    private func status(_ item: BuiltInSkills.Item) -> String {
        switch (item.state, item.inCore) {
        case (.missing, _): "not in the brain: added to core"
        case (.outdated, true): "older copy: updated"
        case (.outdated, false): "older copy, not in core: updated and added"
        case (.current, false): "in the brain, not in core: added"
        case (.current, true): "up to date"
        }
    }

    @ViewBuilder private var preview: some View {
        if let item = plan.items.first(where: { $0.name == shown }) {
            VStack(alignment: .leading, spacing: 6) {
                Text("skills/\(item.name)/SKILL.md").font(.headline)
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        if let before = item.before {
                            DiffPreview(diff: TextDiff.lines(from: before, to: item.template))
                        } else {
                            Text(item.template)
                        }
                    }
                    .font(.callout.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(6)
                }
                .background(.background.secondary, in: RoundedRectangle(cornerRadius: 6))
            }
        } else {
            Spacer()
        }
    }

    private func apply() {
        busy = true
        error = nil
        Task {
            defer { busy = false }
            do {
                let names = plan.items.map(\.name).filter(chosen.contains)
                try await model.applyBuiltInSkills(plan, names: names, modes: modes)
                dismiss()
                onDone()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}
