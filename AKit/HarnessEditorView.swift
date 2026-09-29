import AKitFoundation
import AKitHarnesses
import AppKit
import SwiftUI

/// Form for describing a harness AKit doesn't know yet (Add Harness… / Edit…).
/// Every path can be typed or picked with Choose…; `~` keeps it portable between Macs.
struct HarnessEditorView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var draft: CustomHarness
    @State private var saveError: String?
    @State private var confirmRemove = false
    private let isNew: Bool

    init(harness: CustomHarness? = nil) {
        _draft = State(initialValue: harness ?? CustomHarness(skillFolders: [""]))
        isNew = harness == nil
    }

    private var problems: [String] {
        draft.validate(against: model.customHarnesses, reservedNames: model.builtInNames, isNew: isNew)
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    TextField("Name", text: $draft.name, prompt: Text("Goose"))
                    TextField("Command", text: $draft.command, prompt: Text("goose"))
                    PathField(title: "Config folder", text: $draft.configRoot, prompt: "~/.config/goose", pickFolders: true)
                } footer: {
                    Text("AKit shows the harness when the command is found in PATH or the config folder exists.")
                        .foregroundStyle(.secondary)
                }

                Section("Files") {
                    PathField(title: "Settings file", text: $draft.settingsFile, prompt: "config.yaml", pickFolders: false)
                    PathField(title: "MCP servers file", text: $draft.mcpFile, prompt: "optional", pickFolders: false)
                    PathField(title: "Instructions", text: $draft.instructionsFile, prompt: "AGENTS.md", pickFolders: false)
                    PathField(title: "Agents folder", text: $draft.agentsFolder, prompt: "optional", pickFolders: true)
                }

                Section {
                    ForEach(draft.skillFolders.indices, id: \.self) { index in
                        HStack {
                            PathField(title: "Skill folder", text: skillFolder(at: index), prompt: "skills", pickFolders: true)
                            Button("Remove", systemImage: "minus.circle") { if index < draft.skillFolders.count { draft.skillFolders.remove(at: index) } }
                                .labelStyle(.iconOnly)
                                .buttonStyle(.borderless)
                        }
                    }
                    Button("Add Skill Folder", systemImage: "plus") { draft.skillFolders.append("") }
                    TextField("In each project", text: $draft.projectSkillFolder, prompt: Text(".goose/skills"))
                } header: {
                    Text("Skills")
                } footer: {
                    Text("Relative paths are inside the config folder (which must start with / or ~/). Folders are searched for <name>/SKILL.md at any depth. Use ~/.agents/skills to share the skills Claude and Pi already use.")
                        .foregroundStyle(.secondary)
                }

                if !problems.isEmpty && !draft.name.isEmpty {
                    Section {
                        ForEach(problems, id: \.self) { Label($0, systemImage: "exclamationmark.circle").foregroundStyle(.orange) }
                    }
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                if !isNew {
                    Button("Remove…", role: .destructive) { confirmRemove = true }
                }
                Text("Saved to ~/.akit/harnesses.json").font(.caption).foregroundStyle(.secondary)
                if ExternalEditor.appURL != nil {
                    let file = CustomHarnessStore.url(in: .current)
                    Button {
                        ExternalEditor.open(file)
                    } label: {
                        Image(systemName: "square.and.pencil")
                    }
                    .buttonStyle(.borderless)
                    .disabled(!FileManager.default.fileExists(atPath: file.path))
                    .help("Open ~/.akit/harnesses.json in \(ExternalEditor.name)")
                }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(isNew ? "Add" : "Save", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!problems.isEmpty)
            }
            .padding(12)
        }
        .frame(width: 560, height: 640)
        .confirmationDialog("Remove “\(draft.name)” from AKit?", isPresented: $confirmRemove, titleVisibility: .visible) {
            Button("Remove", role: .destructive, action: remove)
        } message: {
            Text("Only its description in ~/.akit/harnesses.json is removed. The harness and its files stay untouched.")
        }
        .alert("Couldn't save", isPresented: Binding(get: { saveError != nil }, set: { if !$0 { saveError = nil } })) {
            Button("OK") {}
        } message: {
            Text(saveError ?? "")
        }
    }

    /// Index-checked binding: removing a row must not crash a field that is still on screen.
    private func skillFolder(at index: Int) -> Binding<String> {
        Binding(
            get: { index < draft.skillFolders.count ? draft.skillFolders[index] : "" },
            set: { if index < draft.skillFolders.count { draft.skillFolders[index] = $0 } }
        )
    }

    private func remove() {
        do {
            try model.removeCustomHarness(draft)
            dismiss()
        } catch {
            saveError = error.localizedDescription
        }
    }

    private func save() {
        var harness = draft
        harness.name = harness.name.trimmingCharacters(in: .whitespaces)
        if isNew { harness.id = CustomHarness.slug(harness.name) }
        harness.skillFolders = harness.skillFolders.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        do {
            try model.saveCustomHarness(harness)
            dismiss()
        } catch {
            saveError = error.localizedDescription
        }
    }
}

/// Text field with a Choose… button that opens a file/folder picker.
private struct PathField: View {
    let title: String
    @Binding var text: String
    let prompt: String
    let pickFolders: Bool

    var body: some View {
        HStack {
            TextField(title, text: $text, prompt: Text(prompt))
                .font(.system(.body, design: .monospaced))
            Button("Choose…", action: choose)
        }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = pickFolders
        panel.canChooseFiles = !pickFolders
        panel.showsHiddenFiles = true
        panel.treatsFilePackagesAsDirectories = true
        let current = HarnessEnvironment.current.homeDirectory
        panel.directoryURL = text.hasPrefix("~/") ? current.appending(path: String(text.dropFirst(2))) : current
        guard panel.runModal() == .OK, let url = panel.url else { return }
        text = url.tildePath
    }
}
