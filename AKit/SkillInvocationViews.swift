import AKitFoundation
import AKitModel
import AKitProjectSetup
import AKitSkills
import SwiftUI

/// A model invocation change waiting in its sheet.
struct SkillInvocationRequest: Identifiable {
    let id = UUID()
    let plan: SkillInvocation.Plan
}

enum SkillInvocationText {
    static func title(manual: Bool) -> String { manual ? "Manual" : "Auto" }

    /// What a value does, in one sentence.
    static func meaning(manual: Bool) -> String {
        manual ? "Hidden from the agent; only /name runs it." : "The agent sees its description and may invoke it."
    }

    static let help = "Auto: \(meaning(manual: false)) Manual: \(meaning(manual: true)) Unlike the switches above, this is disable-model-invocation in the skill's own SKILL.md (for a copy from the brain, the layer's mode), so every harness follows it."
}

/// Skill detail: Auto or Manual, as the skill's SKILL.md says. Choosing the other value opens
/// the change as a diff with Apply.
struct SkillInvocationControl: View {
    @Environment(AppModel.self) private var model
    let skill: Skill

    var body: some View {
        let reason = SkillInvocation.unavailable(skill, link: model.brainLinks[skill.id], brain: model.brain)
        GridRow {
            Text("Model invocation").foregroundStyle(.secondary).gridColumnAlignment(.trailing)
            Picker("Model invocation", selection: Binding(
                get: { skill.disablesModelInvocation },
                set: { model.requestSkillInvocation(skill, manual: $0) }
            )) {
                ForEach([false, true], id: \.self) { Text(SkillInvocationText.title(manual: $0)).tag($0) }
            }
            .labelsHidden()
            .fixedSize()
            .disabled(reason != nil)
            .help(reason ?? SkillInvocationText.help)
        }
    }
}

/// Skills list context menu: Make Manual… or Make Auto…, by the current value; no item when
/// AKit can't change it (the detail row gives the reason; a menu item shows no tooltip).
struct SkillInvocationMenu: View {
    @Environment(AppModel.self) private var model
    let skill: Skill

    var body: some View {
        if SkillInvocation.unavailable(skill, link: model.brainLinks[skill.id], brain: model.brain) == nil {
            Button(skill.disablesModelInvocation ? "Make Auto…" : "Make Manual…") {
                model.requestSkillInvocation(skill, manual: !skill.disablesModelInvocation)
            }
        }
    }
}

/// The change as diffs, with Apply and Cancel.
struct SkillInvocationSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let request: SkillInvocationRequest
    @State private var busy = false
    @State private var error: String?

    private var plan: SkillInvocation.Plan { request.plan }

    private var summary: String {
        let meaning = SkillInvocationText.meaning(manual: plan.manual)
        if let layer = plan.layer {
            return "\(meaning) AKit rendered this copy from the brain, so the \(layer) layer's mode changes (a commit in the brain), then the home folder's copy in \(plan.file.tildePath)."
        }
        return "\(meaning) This \(plan.manual ? "adds" : "removes") disable-model-invocation in \(plan.file.tildePath); every harness that reads the skill follows it."
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Make \(plan.skill) \(SkillInvocationText.title(manual: plan.manual))").font(.title2.bold())
            Text(summary)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(plan.diffs) { diff in
                        VStack(alignment: .leading, spacing: 0) {
                            Text(diff.title).fontWeight(.medium).padding(.bottom, 2)
                            DiffPreview(diff: diff.lines)
                        }
                    }
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
                Button("Apply", action: apply)
                    .keyboardShortcut(.defaultAction)
                    .disabled(busy)
                    .help(plan.layer == nil
                          ? "Back up \(plan.file.tildePath), then write the change. Refused if the file changed since this preview."
                          : "Commit the layer's mode in the brain, then back up and rewrite the home folder's copy. Refused if a file changed since this preview.")
            }
        }
        .padding(20)
        .frame(width: 600)
    }

    private func apply() {
        busy = true
        error = nil
        Task {
            do {
                try await model.applySkillInvocation(plan)
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
            busy = false
        }
    }
}

extension View {
    /// The model invocation sheet and its error alert, for a screen with the control.
    func skillInvocationSheet(_ model: AppModel) -> some View {
        @Bindable var model = model
        return self
            .sheet(item: $model.skillInvocationRequest) { SkillInvocationSheet(request: $0) }
            .alert("Can't change model invocation", isPresented: Binding(get: { model.skillInvocationError != nil },
                                                                         set: { if !$0 { model.skillInvocationError = nil } })) {
                Button("OK") {}
            } message: {
                Text(model.skillInvocationError ?? "")
            }
    }
}
