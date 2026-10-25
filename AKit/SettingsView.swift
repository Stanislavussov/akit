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
    @State private var brainName = ""
    @State private var brainEmail = ""
    @State private var brainIdentityError: String?
    @State private var lab = LabSettings.load(env: .current)
    @State private var labError: String?
    @AppStorage(AskAKitModel.confirmKey) private var askConfirms = true

    var body: some View {
        ScrollViewReader { proxy in
            form
                .task {
                    // Snapshots: `--tab lab` scrolls to the Lab and sending policy sections,
                    // `--tab scrub` to the scrub patterns and the monthly limit, `--tab knowledge`
                    // to the knowledge base folders, `--tab knowledge-check` to the knowledge check model.
                    guard let tab = DebugSnapshot.options?.tab, ["lab", "scrub", "knowledge", "knowledge-check"].contains(tab) else {
                        // The first text field takes the focus when the window opens and the form
                        // scrolls down to it: start at the top instead.
                        try? await Task.sleep(for: .milliseconds(100))
                        proxy.scrollTo("top", anchor: .top)
                        return
                    }
                    try? await Task.sleep(for: .milliseconds(300))
                    proxy.scrollTo(tab, anchor: .top)
                }
        }
    }

    private var form: some View {
        Form {
            Section {
                ForEach(model.projectRoots, id: \.self) { root in
                    HStack {
                        Image(systemName: "folder")
                        Text(root).font(.system(.body, design: .monospaced))
                        Spacer()
                        Button("Remove", systemImage: "minus.circle") { remove(root) }
                            .labelStyle(.iconOnly)
                            .help("Remove this folder")
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
                Text("Project folders").id("top")
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
                if let identity = model.brainIdentity {
                    TextField("Commit name", text: $brainName, prompt: Text("Your name"))
                        .onSubmit(saveBrainIdentity)
                        .onChange(of: brainName) { brainIdentityError = nil }
                    TextField("Commit email", text: $brainEmail, prompt: Text("your personal email"))
                        .onSubmit(saveBrainIdentity)
                        .onChange(of: brainEmail) { brainIdentityError = nil }
                    HStack {
                        if let brainIdentityError {
                            Label(brainIdentityError, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
                        } else if model.brainIdentityMissing {
                            Label("This work Mac can't commit in the brain until both are set.", systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                        } else if identity.isComplete {
                            Label("Saved in the brain's git settings.", systemImage: "checkmark.circle").foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Save", action: saveBrainIdentity)
                            .disabled(typedIdentity.name == nil || typedIdentity.email == nil || typedIdentity == identity)
                    }
                }
            } header: {
                Text("Brain repo")
            } footer: {
                Text("Your git repo with the skill library and layers. No harness reads this folder; AKit renders from it."
                     + (model.brainIdentity == nil ? "" : " Commit name and email go into the commits AKit makes in the brain. They are kept in the brain's own git settings on this Mac. "
                        + (model.machine.isWork
                           ? "A work Mac needs them, so the work name and email of your global git settings never reach the brain's remote."
                           : "Without them a personal Mac uses your global git name and email.")))
                    .foregroundStyle(.secondary)
            }
            // Not .task: it would run again when the section scrolls back into view and drop typed text.
            .onChange(of: model.brainIdentity, initial: true) { showBrainIdentity() }
            KnowledgeSettingsSection(brainPath: model.brainPath)
            KnowledgeCheckModelSection(lab: $lab)
            Section {
                Picker("Review language", selection: $lab.reportLanguage) {
                    ForEach(LabLanguage.allCases, id: \.self) { Text($0.name).tag($0) }
                }
                if let labError {
                    Label(labError, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
                }
            } header: {
                Text("Lab").id("lab")
            } footer: {
                Text("The language of new session reviews: the paragraph and the improvements. Kept in ~/.akit/lab/settings.json, so akit lab new review uses it too (--language overrides).")
                    .foregroundStyle(.secondary)
            }
            // `akit lab policy` may change the file while the form is open: only the form's own
            // edit is applied, onto what is on disk now, and the form then shows the result.
            .onAppear { lab = LabSettings.load(env: .current) }
            // A review sheet added a Pi account or a destination.
            .onReceive(NotificationCenter.default.publisher(for: .labSettingsSaved)) { _ in lab = LabSettings.load(env: .current) }
            .onChange(of: lab) { old, new in
                do {
                    let saved = try LabSettings.update(env: .current) { $0.apply(from: old, to: new) }
                    if saved != new { lab = saved }
                    labError = nil
                } catch {
                    labError = "Couldn't save ~/.akit/lab/settings.json: \(error.localizedDescription)"
                }
            }
            TranslationModelSection(lab: $lab)
            SendingPolicySections(lab: $lab)
            Section {
                Toggle("Ask before Ask AKit sends", isOn: Binding(get: { askConfirms }, set: { on in
                    askConfirms = on
                    // On again: Don't ask again is undone for every destination, and so is this
                    // launch's Send.
                    if on {
                        let defaults = UserDefaults.standard
                        defaults.removeObject(forKey: AskAKitModel.skipConfirmKey)
                        defaults.set(defaults.integer(forKey: AskAKitModel.confirmResetKey) + 1, forKey: AskAKitModel.confirmResetKey)
                    }
                }))
            } header: {
                Text("Ask AKit")
            } footer: {
                let skipped = UserDefaults.standard.stringArray(forKey: AskAKitModel.skipConfirmKey) ?? []
                Text("Before the first question of a launch to a harness and provider, Ask AKit says what it sends and where. "
                     + (skipped.isEmpty ? "" : "Not asked for (Don't ask again): \(skipped.map { $0.replacingOccurrences(of: "|", with: " · ") }.joined(separator: ", ")). Turn the switch off and on to ask for them again."))
                    .foregroundStyle(.secondary)
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

    /// What the fields hold, trimmed as it would be saved; nil for an empty one.
    private var typedIdentity: BrainGit.Identity {
        let name = brainName.trimmingCharacters(in: .whitespacesAndNewlines), email = brainEmail.trimmingCharacters(in: .whitespacesAndNewlines)
        return BrainGit.Identity(name: name.isEmpty ? nil : name, email: email.isEmpty ? nil : email)
    }

    private func showBrainIdentity() {
        brainName = model.brainIdentity?.name ?? ""
        brainEmail = model.brainIdentity?.email ?? ""
        brainIdentityError = nil
    }

    private func saveBrainIdentity() {
        guard typedIdentity.isComplete else { return }
        Task {
            do {
                try await model.setBrainIdentity(name: brainName, email: brainEmail)
                showBrainIdentity()
            } catch {
                brainIdentityError = error.localizedDescription
            }
        }
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
