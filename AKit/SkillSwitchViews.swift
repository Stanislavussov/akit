import AKitFoundation
import AKitModel
import AKitSkills
import SwiftUI

/// A skill switch change waiting in its sheet.
struct SkillSwitchRequest: Identifiable {
    let id = UUID()
    let plan: SkillSwitches.Plan
}

/// Skill detail: one picker per harness that sees the skill, showing its state there.
/// Choosing another state opens the change as a diff with Apply.
struct SkillSwitchControls: View {
    @Environment(AppModel.self) private var model
    let skill: Skill

    var body: some View {
        ForEach(SkillSwitches.harnesses, id: \.self) { harness in
            if let options = SkillSwitches.options(for: skill, harness: harness, in: .current) {
                GridRow {
                    Text(harness.displayName).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
                    if let reason = options.unavailable {
                        Text("No switch").foregroundStyle(.secondary).help(reason)
                    } else if case .unknown(let reason)? = model.skillStates[skill.id]?[harness] {
                        Label("Unknown", systemImage: "questionmark.circle").foregroundStyle(.orange)
                            .help("\(reason) \(SkillSwitchText.help(options, home: HarnessEnvironment.current.homeDirectory))")
                    } else {
                        Picker(harness.displayName, selection: Binding(
                            get: { model.skillStates[skill.id]?[harness]?.state ?? SkillSwitches.defaultState(of: skill, harness: harness) },
                            set: { model.requestSkillSwitch(skill, harness: harness, to: $0) }
                        )) {
                            ForEach(options.states, id: \.self) { Text($0.title).tag($0) }
                        }
                        .labelsHidden()
                        .fixedSize()
                        .help(SkillSwitchText.help(options, home: HarnessEnvironment.current.homeDirectory))
                    }
                }
            }
        }
    }
}

/// Context menus (Skills list, Insights → Skills): a submenu per harness with its states.
struct SkillSwitchMenu: View {
    @Environment(AppModel.self) private var model
    let skill: Skill

    var body: some View {
        ForEach(SkillSwitches.harnesses, id: \.self) { harness in
            if let options = SkillSwitches.options(for: skill, harness: harness, in: .current) {
                if options.unavailable != nil {
                    Button("\(harness.displayName): No Switch") {}.disabled(true)
                } else if model.skillStates[skill.id]?[harness]?.state == nil {
                    Button("\(harness.displayName): Unknown") {}.disabled(true)
                } else {
                    let current = model.skillStates[skill.id]?[harness]?.state ?? .on
                    Menu("\(harness.displayName): \(current.title)") {
                        ForEach(options.states, id: \.self) { state in
                            Button {
                                model.requestSkillSwitch(skill, harness: harness, to: state)
                            } label: {
                                if state == current { Label(state.title, systemImage: "checkmark") } else { Text(state.title) }
                            }
                            .disabled(state == current)
                        }
                    }
                    .help(SkillSwitchText.help(options, home: HarnessEnvironment.current.homeDirectory))
                }
            }
        }
    }
}

/// Skills list: a small mark per harness where a switch changed the skill's state (a skill that
/// is Manual by its own SKILL.md gets none).
struct SkillSwitchMarks: View {
    @Environment(AppModel.self) private var model
    let skill: Skill

    var body: some View {
        let marks = SkillSwitches.harnesses.compactMap { harness -> (harness: HarnessID, state: SkillSwitchState)? in
            guard let state = model.skillStates[skill.id]?[harness]?.state, state != SkillSwitches.defaultState(of: skill, harness: harness) else { return nil }
            return (harness, state)
        }
        if !marks.isEmpty {
            HStack(spacing: 4) {
                ForEach(marks, id: \.harness) { mark in
                    let tint = mark.state == .off ? Color.red : Color.orange
                    Text("\(mark.harness.displayName) · \(mark.state.title.lowercased())")
                        .font(.caption2.weight(.medium))
                        .lineLimit(1)
                        .fixedSize()
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .foregroundStyle(tint)
                        .background(tint.opacity(0.12), in: Capsule())
                        .help("\(mark.harness.displayName): \(SkillSwitchText.meaning(mark.state)) Set in \(SkillSwitches.settingsFile(for: skill, harness: mark.harness, in: .current)?.tildePath ?? "its settings").")
                }
            }
        }
    }
}

enum SkillSwitchText {
    /// What a state does, in one sentence.
    static func meaning(_ state: SkillSwitchState) -> String {
        switch state {
        case .on: "Listed to the model with its description; /name runs it."
        case .nameOnly: "Listed to the model by name only, without the description; /name runs it."
        case .manual: "Hidden from the model; only /name runs it."
        case .off: "Hidden from the model and from the / menu."
        }
    }

    static func help(_ options: SkillSwitches.Options, home: URL) -> String {
        "Writes \(options.key) in \(FileWalk.tilde(options.file, home: home)) (backup first, only that entry). " + (options.note ?? "")
    }
}

/// The change as a diff, with Apply and Cancel.
struct SkillSwitchSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let request: SkillSwitchRequest
    @State private var busy = false
    @State private var error: String?

    private var plan: SkillSwitches.Plan { request.plan }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Set \(plan.skill) to \(plan.to.title) in \(plan.harness.displayName)").font(.title2.bold())
            Text("\(SkillSwitchText.meaning(plan.to)) Now: \(plan.from.title). The skill's files stay as they are; this changes \(plan.file.tildePath).")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    DiffPreview(diff: plan.diff)
                }
                .font(.callout.monospaced())
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(6)
            }
            .frame(height: 220)
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
                    .help("Back up \(plan.file.tildePath), then write the change. Refused if the file changed since this preview.")
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
                _ = try await model.applySkillSwitch(plan)
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
            busy = false
        }
    }
}

extension View {
    /// The switch sheet and its error alert, for a screen with switch controls.
    func skillSwitchSheet(_ model: AppModel) -> some View {
        @Bindable var model = model
        return self
            .sheet(item: $model.skillSwitchRequest) { SkillSwitchSheet(request: $0) }
            .alert("Can't change the switch", isPresented: Binding(get: { model.skillSwitchError != nil },
                                                                   set: { if !$0 { model.skillSwitchError = nil } })) {
                Button("OK") {}
            } message: {
                Text(model.skillSwitchError ?? "")
            }
    }
}
