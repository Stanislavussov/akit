import AKitBrain
import SwiftUI

/// Edit an existing layer: description, what it requires and its AGENTS.md section.
/// Skills are added and their modes changed on the layer screen itself.
struct EditLayerSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    let layer: Layer
    @State private var details: LayerEditor.Details
    @State private var original: LayerEditor.Details
    @State private var isWorking = false
    @State private var error: String?

    init(layer: Layer) {
        self.layer = layer
        let details = LayerEditor.details(of: layer)
        _original = State(initialValue: details)
        _details = State(initialValue: details)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Edit Layer “\(layer.name)”").font(.title2.bold())
            Form {
                TextField("Description", text: $details.description, prompt: Text("What kind of project it is for"))
                if let brain = model.brain, brain.layers.count > 1 {
                    let allowed = LayerEditor.requirable(by: layer.name, in: brain)
                    LabeledContent("Requires") {
                        HStack {
                            ForEach(brain.layers.map(\.name).filter { $0 != layer.name }, id: \.self) { other in
                                Toggle(other, isOn: Binding(get: { details.requires.contains(other) },
                                                            set: { on in details.requires = brain.layers.map(\.name).filter { $0 == other ? on : details.requires.contains($0) } }))
                                    .disabled(!allowed.contains(other) && !details.requires.contains(other))
                                    .help(allowed.contains(other) ? "Render \(other) first and select it with \(layer.name)" : "\(other) already needs \(layer.name)")
                            }
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .frame(height: 130)

            VStack(alignment: .leading, spacing: 4) {
                Text("AGENTS.md section").font(.headline)
                if agentsLocked {
                    Text("This layer's AGENTS.md comes only from templates with a when: condition. Edit them in \(ExternalEditor.name).")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("Added to the project's AGENTS.md, after the sections of the layers it requires. {{project_name}} and field names are filled in. Empty adds nothing.")
                        .font(.caption).foregroundStyle(.secondary)
                    TextEditor(text: $details.agentsSection)
                        .font(.callout.monospaced())
                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(.quaternary))
                }
            }
            .frame(maxHeight: .infinity, alignment: .top)

            Text("Saved to layers/\(layer.name) and committed. Projects using \(layer.name) change when they are set up again\(layer.name == "core" ? "; the home folder with Update Home Folder… on the core layer" : "").")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                if let error { Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).lineLimit(3) }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(isWorking ? "Saving…" : "Save", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(isWorking || !hasChanges)
            }
        }
        .padding(16)
        .frame(width: 640, height: 560)
    }

    /// There are AGENTS.md templates, but all of them have a condition.
    private var agentsLocked: Bool {
        LayerEditor.agentsFile(of: layer) == nil && layer.files.contains { $0.to == "AGENTS.md" }
    }

    private var hasChanges: Bool {
        LayerEditor.oneLine(details.description) != LayerEditor.oneLine(original.description)
            || details.requires != original.requires
            || details.agentsSection.trimmingCharacters(in: .whitespacesAndNewlines) != original.agentsSection
    }

    private func save() {
        isWorking = true
        error = nil
        Task {
            defer { isWorking = false }
            do {
                try await model.updateLayer(layer.name, to: details)
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

/// Pick brain skills to list in a layer, all with one mode.
struct AddLayerSkillsSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    let layer: Layer
    @State private var chosen: Set<String> = []
    @State private var mode: LayerSkill.Mode = .auto
    @State private var query = ""
    @State private var isWorking = false
    @State private var error: String?

    /// Brain skills the layer doesn't list yet.
    private var candidates: [Brain.Skill] {
        (model.brain?.skills ?? []).filter { skill in !layer.skills.contains { $0.name == skill.name } }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add Skills to “\(layer.name)”").font(.title2.bold())
            HStack {
                Picker("Mode", selection: $mode) {
                    Text("auto").tag(LayerSkill.Mode.auto)
                    Text("manual").tag(LayerSkill.Mode.manual)
                }
                .pickerStyle(.segmented)
                .fixedSize()
                .help("auto: the agent sees it and may use it; manual: only on /name")
                Spacer()
                TextField("Filter", text: $query).frame(width: 180)
            }
            let shown = candidates.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) || $0.description.localizedCaseInsensitiveContains(query) }
            List(shown) { skill in
                Toggle(isOn: Binding(get: { chosen.contains(skill.name) },
                                     set: { if $0 { chosen.insert(skill.name) } else { chosen.remove(skill.name) } })) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(skill.name).fontWeight(.medium)
                        Text(skill.description).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            }
            .listStyle(.bordered)
            .overlay {
                if candidates.isEmpty {
                    ContentUnavailableView("Nothing to add", systemImage: "book.closed",
                                           description: Text("The layer lists every skill in the brain. Bring more in with Import Skills…"))
                }
            }
            HStack {
                if let error { Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).lineLimit(3) }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(isWorking ? "Adding…" : chosen.isEmpty ? "Add" : "Add \(chosen.count) Skill\(chosen.count == 1 ? "" : "s")", action: add)
                    .keyboardShortcut(.defaultAction)
                    .disabled(isWorking || chosen.isEmpty)
            }
        }
        .padding(16)
        .frame(width: 520, height: 520)
    }

    private func add() {
        // In the brain's order, so the layer lists them the way the sheet showed them.
        let names = candidates.map(\.name).filter(chosen.contains)
        isWorking = true
        error = nil
        Task {
            defer { isWorking = false }
            do {
                try await model.addSkills(names, mode: mode, toLayer: layer.name)
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}
