import SwiftUI

/// App entry point.
@main
struct AKitApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup("AKit") {
            RootView()
                .environment(model)
                .frame(minWidth: 820, minHeight: 520)
                .task {
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
        }

        Settings {
            SettingsView()
                .environment(model)
        }
    }
}
