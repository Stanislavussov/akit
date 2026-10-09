import SwiftUI

/// App entry point.
@main
struct AKitApp: App {
    @State private var model = AppModel()
    @State private var rebuild = SelfRebuild()
    @State private var guides = GuideNavigator()

    var body: some Scene {
        WindowGroup("AKit") {
            Group {
                // The Settings and Guide windows can't be captured; `--settings` and `--guide <section>`
                // show their views in the main one.
                if DebugSnapshot.options?.settings == true {
                    SettingsView()
                } else if DebugSnapshot.options?.guide != nil {
                    GuideView()
                } else {
                    RootView()
                }
            }
                .environment(model)
                .environment(rebuild)
                .environment(guides)
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
            // The standard panel would show MARKETING_VERSION; AKit is versioned by date tags.
            CommandGroup(replacing: .appInfo) {
                Button("About AKit") {
                    NSApplication.shared.orderFrontStandardAboutPanel(options: [
                        .applicationVersion: BuildInfo.current.version ?? "unknown",
                        .version: "",
                    ])
                }
            }
            CommandGroup(after: .toolbar) {
                Button("Refresh") { Task { await model.refresh() } }
                    .keyboardShortcut("r")
            }
            CommandGroup(replacing: .help) {
                GuideMenuItems(navigator: guides)
                Divider()
                Button("Copy Diagnostics") {
                    Task {
                        let report = await model.diagnostics()
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(report, forType: .string)
                        model.showDiagnosticsNotice("Diagnostics copied: what AKit sees on this Mac, without secrets")
                    }
                }
                .help("Copy a read-only report of AKit, the brain, the harnesses and the projects (the same as akit doctor)")
            }
            CommandMenu("Develop") {
                Button(rebuild.state == .building ? "Rebuilding…" : "Rebuild and Relaunch") {
                    Task { await rebuild.rebuildAndRelaunch() }
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(!rebuild.isAvailable || rebuild.state == .building)
                Divider()
                Text("\(BuildInfo.current.isProduction ? "Production" : "Development") \(BuildInfo.current.version ?? "")")
                if let revision = BuildInfo.current.revision {
                    Text("Branch \(revision)")
                }
                if let path = BuildInfo.current.sourceURL?.tildePath {
                    Text("Built from \(path)")
                }
            }
        }

        Settings {
            SettingsView()
                .environment(model)
                .environment(guides)
        }

        Window("Guide", id: GuideView.windowID) {
            GuideView()
                .environment(guides)
        }
        .defaultSize(width: 760, height: 820)
    }
}
