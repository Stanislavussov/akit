import AKitBrain
import AKitFoundation
import AKitLab
import AKitSessions
import AppKit
import SwiftUI

extension Notification.Name {
    /// Posted after a sheet saved `~/.akit/lab/settings.json`, so an open Settings window shows it.
    static let labSettingsSaved = Notification.Name("AKitLabSettingsSaved")
}

/// Under a review sheet's agent fields: what will stop the review, known from the sending
/// policy settings alone (a destination the policy refuses, such as Pi for a Claude Code
/// session with no Pi account allowed), with the button that fixes it here instead of a
/// failed run. Nothing shows when nothing is known
/// to stop it; the run still checks the account itself.
struct SendBlockerNote: View {
    let agent: LabAgent
    /// The session under review; nil = the policy's origin check is left to the run.
    var reviewing: SessionSummary? = nil
    /// Where the session's answers came from; read once per session (a Pi file is parsed whole).
    @State private var origin: SendOrigin?
    @State private var blocker: SendAccounts.Blocker?
    @State private var editor: PolicyEntryEditor?
    @State private var error: String?
    /// Bumped to check again: after a save here, and when a window becomes key (the settings
    /// or this Mac's role may have changed elsewhere).
    @State private var checks = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let blocker {
                HStack(alignment: .firstTextBaseline) {
                    Label(text(blocker), systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    if let entry = entry(blocker) {
                        Button("Add Destination…") { editor = entry }
                            .help("Allow this account to receive session data; for Pi, also its Pi account")
                    }
                }
                .font(.callout)
            }
            if let error {
                Text(error).foregroundStyle(.red).font(.caption)
            }
        }
        .task(id: reviewing?.file.path) {
            origin = nil
            guard let file = reviewing?.file, let harness = reviewing?.harness else { return }
            let found = await Task.detached { SendOrigin.of(harness: harness, sessionFile: file) }.value
            guard !Task.isCancelled else { return }
            origin = found
        }
        // Settings files only: cheap enough for every change of the fields.
        .task(id: "\(agent.harness.rawValue)|\(agent.model)|\(String(describing: origin))|\(checks)") {
            let env = HarnessEnvironment.current
            blocker = SendAccounts.blocker(of: agent, origin: origin, isWork: MachineProfile.load(home: env.homeDirectory).isWork, env: env)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in checks += 1 }
        .sheet(item: $editor) { request in
            PolicyEntrySheet(request: request) { entry in
                do {
                    _ = try LabSettings.update(env: .current) { $0.save(entry, for: request.kind) }
                    error = nil
                    NotificationCenter.default.post(name: .labSettingsSaved, object: nil)
                } catch {
                    self.error = "Couldn't save ~/.akit/lab/settings.json: \(error.localizedDescription)"
                }
                checks += 1
            }
        }
    }

    private func text(_ blocker: SendAccounts.Blocker) -> String {
        switch blocker {
        case .noPiProvider:
            "Which Pi provider? Pick a model as provider/model (Pi has no default provider set)."
        case .policy(let reason, _):
            "Not allowed: \(reason)"
        case .settings(let reason):
            reason
        }
    }

    /// The entry to fill in, with what is already known; nil = nothing to add here.
    private func entry(_ blocker: SendAccounts.Blocker) -> PolicyEntryEditor? {
        switch blocker {
        case .policy(_, let destination?):
            PolicyEntryEditor(kind: .destination, entry: destination)
        case .policy(_, nil):
            .newDestination
        case .noPiProvider, .settings:
            nil
        }
    }
}
