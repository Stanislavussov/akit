import AKitCore
import AppKit
import SwiftUI

/// AKit settings (⌘,). Stored on this machine only.
struct SettingsView: View {
    @Environment(AppModel.self) private var model

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
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .frame(minHeight: 260)
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

    private func remove(_ root: String) {
        apply(model.projectRoots.filter { $0 != root })
    }

    private func apply(_ roots: [String]) {
        model.projectRoots = roots
        Task { await model.refresh() }
    }
}
