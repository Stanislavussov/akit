import Foundation
import MeetingsCore
import MeetingsUI
import SwiftUI

/// Work → Meetings in AKit: the package's screen with the Crepe editor and the Guide button, and
/// the snapshot states the guide's screenshots need (`--select <HHmm>`, `--tab meetings-transcript`,
/// `meetings-settings`, `meetings-new-tab`).
struct MeetingsScreen: View {
    let model: MeetingsModel

    var body: some View {
        MeetingsView(model: model, editor: .crepe, extraToolbar: AnyView(GuideButton(guide: .meetings)))
            .task {
                guard let options = DebugSnapshot.options, options.section == .meetings else { return }
                await model.load()
                if let select = options.select, let meeting = model.meetings.first(where: { $0.id.hasSuffix(select) }) {
                    model.select(meeting.id)
                }
                switch options.tab {
                case "meetings-transcript": model.show(tab: MeetingsModel.transcriptTab)
                case "meetings-tab": if let tab = model.selected?.tabs.first { model.show(tab: tab) }
                case "meetings-settings": model.showSettings = true
                case "meetings-new-tab": model.tabNameRequest = .init(old: nil)
                default: break
                }
            }
    }

    /// The model AKit keeps for the window. A demo (screenshots) has its own Keychain item; the
    /// model list still comes from OpenRouter's API, like everywhere else.
    @MainActor static func makeModel() -> MeetingsModel {
        guard DebugSnapshot.options?.demo == true else { return MeetingsModel() }
        return MeetingsModel(keyStore: KeyStore(service: "Meetings OpenRouter (AKit demo)"))
    }
}
