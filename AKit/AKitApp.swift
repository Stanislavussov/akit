import AKitDoctor
import SwiftUI

/// App entry point.
@main
struct AKitApp: App {
    @State private var model: AppModel
    @State private var rebuild = SelfRebuild()
    @State private var guides = GuideNavigator()
    @State private var ask: AskAKitModel

    init() {
        let model = AppModel()
        _model = State(initialValue: model)
        _ask = State(initialValue: AskAKitModel(app: model))
    }

    var body: some Scene {
        // One main window: the screen in view (AppModel.section) and Ask AKit's chat belong to
        // the app, so a second window would only mirror the first.
        Window("AKit", id: "main") {
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
                .environment(ask)
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
                Button(ask.isOpen ? "Hide Ask AKit" : "Ask AKit") { ask.toggle() }
                    .keyboardShortcut("/", modifiers: [.command, .option])
                    .help("A side panel that answers what something on the screen means, from AKit's guides")
                Divider()
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
                Divider()
                ForEach(IssueReport.allCases, id: \.self) { kind in
                    Button(kind.menuTitle) {
                        // Not operatingSystemVersionString: that one is in the user's language.
                        let os = ProcessInfo.processInfo.operatingSystemVersion
                        let system = "macOS \(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"
                        NSWorkspace.shared.open(kind.url(appVersion: BuildInfo.current.version, system: system))
                    }
                    .help("Open a new GitHub issue in the browser, with a template and the AKit version filled in")
                }
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
                .environment(model)
                .environment(guides)
        }
        .defaultSize(width: 820, height: 860)
    }
}
