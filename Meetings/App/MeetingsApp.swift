import AppKit
import MeetingsCore
import MeetingsUI
import SwiftUI

/// Meetings on its own (docs/design/meetings.md, M1): the same screen AKit shows in Work →
/// Meetings, with the plain Markdown editor. Settings, key and folder are shared with AKit.
@main
struct MeetingsApp: App {
    @NSApplicationDelegateAdaptor(MeetingsAppDelegate.self) private var delegate

    var body: some Scene {
        Window("Meetings", id: "meetings") {
            NavigationStack {
                MeetingsView(model: MeetingsAppDelegate.model)
            }
            .frame(minWidth: 820, minHeight: 520)
        }
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}

/// One model for the app; a running recording is stopped and mixed before the app quits.
final class MeetingsAppDelegate: NSObject, NSApplicationDelegate {
    @MainActor static let model = MeetingsModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in await Self.model.load() }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Task { @MainActor in
            if Self.model.isRecording { await Self.model.stop() }
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
