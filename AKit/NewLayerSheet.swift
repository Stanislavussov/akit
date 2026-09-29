import AKitBrain
import SwiftUI

/// Create a layer in the brain: name, what it requires, skills with their mode, and
/// the section it adds to a project's AGENTS.md. Fields are added in layer.yaml by hand.
struct NewLayerSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    /// Snapshot `--tab layer --query <name>` fills the name.
    @State private var name = DebugSnapshot.options?.tab == "layer" ? DebugSnapshot.options?.query ?? "" : ""
    @State private var description = ""
    @State private var requires: [String] = []
    @State private var modes: [String: LayerSkill.Mode] = [:]
    @State private var skillQuery = ""
    @State private var agentsSection = ""
    @State private var isWorking = false
    @State private var error: String?

    private var brain: Brain? { model.brain }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("New Layer").font(.title2.bold())
            Form {
                TextField("Name", text: $name, prompt: Text("take-home"))
                if let problem = nameProblem, !name.isEmpty {
                    Text(problem).font(.caption).foregroundStyle(.orange)
                }
                TextField("Description", text: $description, prompt: Text("What kind of project it is for"))
                if let others = brain?.layers.map(\.name), !others.isEmpty {
                    LabeledContent("Requires") {
                        HStack {
                            ForEach(others, id: \.self) { other in
                                Toggle(other, isOn: Binding(get: { requires.contains(other) },
                                                            set: { on in requires = others.filter { $0 == other ? on : requires.contains($0) } }))
                            }
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .frame(height: 170)

            skills
            VStack(alignment: .leading, spacing: 4) {
                Text("AGENTS.md section").font(.headline)
                Text("Added to the project's AGENTS.md, after the sections of the layers it requires. {{project_name}} and field names are filled in.")
                    .font(.caption).foregroundStyle(.secondary)
                TextEditor(text: $agentsSection)
                    .font(.callout.monospaced())
                    .frame(height: 110)
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(.quaternary))
            }
            HStack {
                if let error { Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).lineLimit(3) }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(isWorking ? "Creating…" : "Create Layer", action: create)
                    .keyboardShortcut(.defaultAction)
                    .disabled(nameProblem != nil || isWorking)
            }
        }
        .padding(16)
        .frame(width: 640, height: 680)
    }

    private var nameProblem: String? {
        guard let brain else { return "The brain is not loaded." }
        return LayerWriter.nameProblem(name, in: brain)
    }

    private var skills: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Skills").font(.headline)
                Text("\(modes.count) chosen").font(.caption).foregroundStyle(.secondary)
                Spacer()
                TextField("Filter", text: $skillQuery).frame(width: 180)
            }
            let all = (brain?.skills ?? []).filter { skillQuery.isEmpty || $0.name.localizedCaseInsensitiveContains(skillQuery) }
            List(all) { skill in
                HStack {
                    Toggle(isOn: Binding(get: { modes[skill.name] != nil },
                                         set: { modes[skill.name] = $0 ? .auto : nil })) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(skill.name).fontWeight(.medium)
                            Text(skill.description).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    Spacer()
                    if let mode = modes[skill.name] {
                        Picker("", selection: Binding(get: { mode }, set: { modes[skill.name] = $0 })) {
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
            .listStyle(.bordered)
            .overlay {
                if brain?.skills.isEmpty ?? true {
                    ContentUnavailableView("No skills in the brain", systemImage: "book.closed",
                                           description: Text("Use Import Skills… first."))
                }
            }
        }
    }

    private func create() {
        let chosen = (brain?.skills ?? []).compactMap { skill in modes[skill.name].map { (name: skill.name, mode: $0) } }
        let draft = LayerWriter.Draft(name: name, description: description, requires: requires,
                                      skills: chosen, agentsSection: agentsSection)
        isWorking = true
        error = nil
        Task {
            defer { isWorking = false }
            do {
                try await model.createLayer(draft)
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}
