import AKitBrain
import AKitHarnesses
import AKitLab
import AppKit
import SwiftUI

/// AKit settings (⌘,). Stored on this machine only.
struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var machineName = ""
    @State private var machineError: String?
    @State private var machineNotes: [String] = []
    @State private var confirmPersonal = false
    @State private var lab = LabSettings.load(env: .current)
    @State private var labError: String?

    var body: some View {
        Form {
            Section {
                ForEach(model.projectRoots, id: \.self) { root in
                    HStack {
                        Image(systemName: "folder")
                        Text(root).font(.system(.body, design: .monospaced))
                        Spacer()
                        Button("Remove", systemImage: "minus.circle") { remove(root) }
                            .labelStyle(.iconOnly)
                            .buttonStyle(.borderless)
                    }
                }
                HStack {
                    Button("Add Folder…", action: addFolder)
                    Spacer()
                    Button("Reset to Default") { apply(ProjectFinder.defaultRoots) }
                        .disabled(model.projectRoots == ProjectFinder.defaultRoots)
                }
            } header: {
                Text("Project folders")
            } footer: {
                Text("AKit looks for projects two levels deep inside these folders. Folders Claude Code was started in are added automatically. This list is kept on this Mac only.")
                    .foregroundStyle(.secondary)
            }
            Section {
                Picker("This Mac is", selection: Binding(get: { model.machine.kind }, set: { kind in
                    // Leaving work mode starts sending project records to the brain: ask first.
                    if kind == .personal, model.machine.isWork { confirmPersonal = true } else { saveMachine(kind: kind) }
                })) {
                    Text("Personal").tag(MachineProfile.Kind.personal)
                    Text("Work").tag(MachineProfile.Kind.work)
                }
                .pickerStyle(.segmented)
                if model.machine.isWork {
                    TextField("Name of this Mac", text: $machineName, prompt: Text("work"))
                        .onSubmit { saveMachine(kind: .work) }
                }
                if let problem = model.machine.problem {
                    Label(problem, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
                ForEach(machineNotes, id: \.self) { note in
                    Label(note, systemImage: "info.circle").font(.callout).textSelection(.enabled)
                }
                if let machineError {
                    Label(machineError, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
                }
            } header: {
                Text("This Mac")
            } footer: {
                Text(model.machine.isWork
                     ? "Work Mac: answers and locks of projects stay in \(model.projectStore.root.tildePath) and never go into the brain, so nothing about work projects reaches its remote. Records saved in the brain before stay there; remove work ones by hand. Same setting as akit machine."
                     : "Personal Mac: answers and locks of projects are saved and committed in the brain under projects/. Choose Work on a computer whose projects must not reach your brain's remote.")
                    .foregroundStyle(.secondary)
            }
            .onAppear { machineName = model.machine.name ?? "" }
            .confirmationDialog("Make this a personal Mac?", isPresented: $confirmPersonal) {
                Button("Make Personal", role: .destructive) { saveMachine(kind: .personal) }
            } message: {
                Text("From now on project ids, answers and locks from this Mac are committed in the brain and reach its remote on the next sync. Records kept on this Mac so far are no longer read.")
            }
            Section {
                HStack {
                    Image(systemName: "brain")
                    Text(model.brainPath).font(.system(.body, design: .monospaced))
                    Spacer()
                    Button("Choose…", action: chooseBrain)
                    Button("Reset to Default") { applyBrain(AppModel.defaultBrainPath) }
                        .disabled(model.brainPath == AppModel.defaultBrainPath)
                }
            } header: {
                Text("Brain repo")
            } footer: {
                Text("Your git repo with the skill library and layers. No harness reads this folder; AKit renders from it.")
                    .foregroundStyle(.secondary)
            }
            Section {
                Picker("Review language", selection: $lab.reportLanguage) {
                    ForEach(LabLanguage.allCases, id: \.self) { Text($0.name).tag($0) }
                }
                if let labError {
                    Label(labError, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
                }
            } header: {
                Text("Lab")
            } footer: {
                Text("The language of new session reviews: the paragraph and the improvements. Kept in ~/.akit/lab/settings.json, so akit lab new review uses it too (--language overrides).")
                    .foregroundStyle(.secondary)
            }
            .onChange(of: lab) {
                do {
                    try lab.save(env: .current)
                    labError = nil
                } catch {
                    labError = "Couldn't save ~/.akit/lab/settings.json: \(error.localizedDescription)"
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .frame(minHeight: 340)
    }

    private func saveMachine(kind: MachineProfile.Kind) {
        let name = machineName.trimmingCharacters(in: .whitespaces)
        do {
            machineNotes = try model.setMachine(MachineProfile(kind: kind, name: kind == .work ? (name.isEmpty ? "work" : name) : nil))
            machineError = nil
        } catch {
            machineError = "Couldn't save ~/.akit/machine.json: \(error.localizedDescription)"
        }
    }

    private func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Add"
        guard panel.runModal() == .OK else { return }
        let added = panel.urls.map(\.tildePath).filter { !model.projectRoots.contains($0) }
        apply(model.projectRoots + added)
    }

    private func chooseBrain() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Use as Brain"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        applyBrain(url.tildePath)
    }

    private func applyBrain(_ path: String) {
        model.brainPath = path
        Task { await model.refresh() }
    }

    private func remove(_ root: String) {
        apply(model.projectRoots.filter { $0 != root })
    }

    private func apply(_ roots: [String]) {
        model.projectRoots = roots
        Task { await model.refresh() }
    }
}
