import AppKit
import Foundation
import MeetingsCore
import MeetingsUI
import SwiftUI

/// Work → Meetings in AKit: the package's screen with the Crepe editor and the Guide button, and
/// the snapshot states the guide's screenshots need (`--select <HHmm>`, `--tab meetings-transcript`,
/// `meetings-settings`, `meetings-local-settings`, `meetings-local-run`, `meetings-progress`, `meetings-new-tab`, `meetings-ask`, `meetings-tasks`; `--query` fills the search field).
struct MeetingsScreen: View {
    let model: MeetingsModel
    @Environment(KnowledgeModel.self) private var knowledge
    @Environment(WorkLogModel.self) private var worklog

    var body: some View {
        MeetingsView(model: model, editor: .crepe, extraToolbar: AnyView(GuideButton(guide: .meetings)))
            .task {
                // M25: Notebook, Work Log and the knowledge base of this window.
                model.links = MeetingsAKitLinks.make(knowledge: knowledge, worklog: worklog)
                guard let options = DebugSnapshot.options, options.section == .meetings else { return }
                await model.load()
                if let select = options.select, let meeting = model.meetings.first(where: { $0.id.hasSuffix(select) }) {
                    model.select(meeting.id)
                }
                if let query = options.query { model.searchText = query }
                switch options.tab {
                case "meetings-transcript": model.show(tab: MeetingsModel.transcriptTab)
                case "meetings-tab": if let tab = model.selected?.tabs.first { model.show(tab: tab) }
                case "meetings-settings": model.showSettings = true
                case "meetings-local-settings":
                    // M26, M28: Local + Pi in memory only, after load(), so nothing starts.
                    model.showMadeUpSettings { $0.transcription = .local; $0.summarizer = .pi }
                    model.showSettings = true
                case "meetings-progress":
                    // M32: a made-up local run at work on piece 3 of 12; nothing runs.
                    if let id = model.selectedID { model.showMadeUpLocalRun(id, LocalStatus(phase: .transcribing, piece: 3, pieces: 12)) }
                case "meetings-local-run":
                    // M27: a made-up local run on the chosen meeting, paused while the Mac is hot; nothing runs.
                    if let id = model.selectedID { model.showMadeUpLocalRun(id, LocalStatus(phase: .paused(.hot), piece: 3, pieces: 12)) }
                case "meetings-costs": model.showCosts = true
                case "meetings-ask": model.openAsk()
                case "meetings-tasks": model.tasksRequest = true
                case "meetings-new-tab": model.tabNameRequest = .init(old: nil)
                default: break
                }
            }
    }

    /// H1: one model for the app, not per window, so closing the window neither drops a running
    /// recording nor lets a new window take it for a crashed one. AKit loads it at launch.
    @MainActor static let shared: MeetingsModel = {
        guard DebugSnapshot.options?.demo == true else { return MeetingsModel() }
        // A demo (screenshots) has its own Keychain item; the model list still comes from
        // OpenRouter's API, like everywhere else.
        return MeetingsModel(keyStore: KeyStore(service: "Meetings OpenRouter (AKit demo)"))
    }()

    /// `akit://meetings/record` · `/stop` · `/toggle` from Raycast or a hotkey app: done without
    /// switching AKit's screen, then the app that was in front gets the focus back, so nothing
    /// of AKit stays on a shared screen.
    @MainActor static func perform(_ action: String) async {
        let previous = FocusReturn.shared.previous
        await shared.perform(action)
        if let previous, previous != NSRunningApplication.current { previous.activate() }
    }
}

/// The last app in front before AKit, for `MeetingsScreen.perform`.
@MainActor final class FocusReturn {
    static let shared = FocusReturn()
    private(set) var previous: NSRunningApplication?
    private var observer: NSObjectProtocol?

    func start() {
        guard observer == nil else { return }
        previous = NSWorkspace.shared.frontmostApplication.flatMap { $0 == .current ? nil : $0 }
        observer = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didDeactivateApplicationNotification, object: nil, queue: .main) { note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication, app != .current else { return }
            MainActor.assumeIsolated { FocusReturn.shared.previous = app }
        }
    }
}
