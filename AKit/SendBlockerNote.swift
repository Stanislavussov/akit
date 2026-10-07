import AKitLab
import AKitSessions
import SwiftUI

/// Under a review sheet's agent fields: what will stop the review, known from the sending
/// policy settings alone (a missing Pi account, a destination the policy refuses), with the
/// button that fixes it here instead of a failed run. Nothing shows when nothing is known
/// to stop it; the run still checks the account itself.
struct SendBlockerNote: View {
    @Environment(AppModel.self) private var model
    let agent: LabAgent
    /// The session under review; nil = the policy's origin check is left to the run.
    var reviewing: SessionSummary? = nil
    @State private var blocker: SendAccounts.Blocker?
    @State private var editor: PolicyEntryEditor?
    @State private var error: String?
    /// Bumped after a save, to check again.
    @State private var saves = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let blocker {
                HStack(alignment: .firstTextBaseline) {
                    Label(text(blocker), systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button(button(blocker)) { editor = entry(blocker) }
                }
                .font(.callout)
            }
            if let error {
                Text(error).foregroundStyle(.red).font(.caption)
            }
        }
        .task(id: "\(agent.harness.rawValue)|\(agent.model)|\(reviewing?.file.path ?? "")|\(saves)") {
            let agent = agent, file = reviewing?.file, harness = reviewing?.harness, isWork = model.machine.isWork
            let found = await Task.detached {
                let origin = file.flatMap { file in harness.map { SendOrigin.of(harness: $0, sessionFile: file) } }
                return SendAccounts.blocker(of: agent, origin: origin, settings: LabSettings.load(env: .current), isWork: isWork, env: .current)
            }.value
            guard !Task.isCancelled else { return }
            blocker = found
        }
        .sheet(item: $editor) { request in
            PolicyEntrySheet(request: request) { entry in
                do {
                    _ = try LabSettings.update(env: .current) { $0.save(entry, for: request.kind) }
                    error = nil
                } catch {
                    self.error = "Couldn't save ~/.akit/lab/settings.json: \(error.localizedDescription)"
                }
                saves += 1
            }
        }
    }

    private func text(_ blocker: SendAccounts.Blocker) -> String {
        switch blocker {
        case .piAccount(let provider):
            "Pi has no account entered for \(provider), so the review would be refused. Enter your login and the plan or org behind it."
        case .policy(let reason):
            "Not allowed: \(reason)"
        }
    }

    private func button(_ blocker: SendAccounts.Blocker) -> String {
        switch blocker {
        case .piAccount: "Add Pi Account…"
        case .policy: "Add Destination…"
        }
    }

    /// The entry to fill in, with what is already known.
    private func entry(_ blocker: SendAccounts.Blocker) -> PolicyEntryEditor {
        switch blocker {
        case .piAccount(let provider):
            return PolicyEntryEditor(kind: .piAccount(index: nil), entry: SendDestination(harness: .pi, provider: provider, account: "", org: ""))
        case .policy:
            guard agent.harness == .pi else { return .newDestination }
            let settings = LabSettings.load(env: .current)
            let provider = agent.model.firstIndex(of: "/").map { String(agent.model[..<$0]) } ?? ""
            let account = settings.piAccounts.first { $0.provider.caseInsensitiveCompare(provider) == .orderedSame }
            return PolicyEntryEditor(kind: .destination, entry: SendDestination(harness: .pi, provider: account?.provider ?? provider,
                                                                                account: account?.account ?? "", org: account?.org ?? ""))
        }
    }
}
