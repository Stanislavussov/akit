import MeetingsCore
import MeetingsUI
import SwiftUI

/// Meetings on its own (docs/design/meetings.md, M1): the same screen AKit shows in Work →
/// Meetings, with the plain Markdown editor. Settings, key and folder are shared with AKit.
@main
struct MeetingsApp: App {
    @State private var model = MeetingsModel()

    var body: some Scene {
        Window("Meetings", id: "meetings") {
            NavigationStack {
                MeetingsView(model: model)
            }
            .frame(minWidth: 820, minHeight: 520)
        }
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}
