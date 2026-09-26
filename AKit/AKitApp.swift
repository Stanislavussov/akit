import SwiftUI

/// App entry point.
@main
struct AKitApp: App {
    @State private var model = AppModel()
    @State private var rebuild = SelfRebuild()

    var body: some Scene {
        WindowGroup("AKit") {
            Group {
                // The Settings window can't be captured; `--settings` shows its view in the main one.
                if DebugSnapshot.options?.settings == true { SettingsView() } else { RootView() }
            }
                .environment(model)
                .environment(rebuild)
                .frame(minWidth: 820, minHeight: 520)
                .task {
                    if SelfRebuild.requestedAtLaunch {
                        await rebuild.rebuildAndRelaunch()
                    }
                    await model.refresh()
                    if let snapshot = DebugSnapshot.options {
                        await DebugSnapshot.captureAndQuit(snapshot)
                    }
                }
        }
        .commands {
            CommandGroup(after: .toolbar) {
                Button("Refresh") { Task { await model.refresh() } }
                    .keyboardShortcut("r")
            }
            CommandMenu("Develop") {
                Button(rebuild.state == .building ? "Rebuilding…" : "Rebuild and Relaunch") {
                    Task { await rebuild.rebuildAndRelaunch() }
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(!rebuild.isAvailable || rebuild.state == .building)
                Divider()
                if let revision = BuildInfo.current.revision {
                    Text("\(BuildInfo.current.isProduction ? "Production" : "Development"): \(revision)")
                }
                if let path = BuildInfo.current.sourceURL?.tildePath {
                    Text("Built from \(path)")
                }
            }
        }

        Settings {
            SettingsView()
                .environment(model)
        }
    }
}
