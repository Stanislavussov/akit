import SwiftUI

/// App entry point.
@main
struct AKitApp: App {
    @State private var model = AppModel()
    @State private var rebuild = SelfRebuild()

    var body: some Scene {
        WindowGroup("AKit") {
            RootView()
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
            }
        }

        Settings {
            SettingsView()
                .environment(model)
        }
    }
}
