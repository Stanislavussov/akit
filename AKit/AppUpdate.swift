import AKitDoctor
import AKitFoundation
import AppKit
import Observation
import SwiftUI

/// A newer AKit in the source folder this copy was built from (new commits on its branch,
/// e.g. a feature merged into master): the Update button at the bottom of the sidebar and
/// AKit → Update AKit build it and start it. Checked at launch, every few minutes and when
/// AKit comes to the front; only reading git commands run.
@MainActor
@Observable
final class AppUpdate {
    private(set) var available: SourceUpdate.Available?
    /// The update waits for a yes: the source folder has uncommitted changes.
    var confirmingUncommitted = false
    private var lastCheck: Date?

    /// The time between checks while AKit stays open.
    private static let interval: Duration = .seconds(300)

    var isAvailable: Bool { SelfRebuild.sourceRoot != nil && BuildInfo.current.commit != nil && BuildInfo.current.branch != nil }

    /// Checks now and then every few minutes, until the task is cancelled.
    func watch() async {
        guard isAvailable else { return }
        while !Task.isCancelled {
            await check()
            try? await Task.sleep(for: Self.interval)
        }
    }

    /// When AKit comes to the front: a merge made in a terminal shows up at once.
    func checkSoon() async {
        if let lastCheck, Date.now.timeIntervalSince(lastCheck) < 20 { return }
        await check()
    }

    func check() async {
        let info = BuildInfo.current
        guard let source = SelfRebuild.sourceRoot, let branch = info.branch, let commit = info.commit else { return }
        lastCheck = .now
        if case .available(let update) = await SourceUpdate.check(source: source, branch: branch, commit: commit,
                                                                 env: .current) {
            available = update
        } else {
            available = nil
        }
    }

    /// Update now, or ask first when the source folder has uncommitted changes.
    func start(_ rebuild: SelfRebuild) {
        guard let available, rebuild.state != .building else { return }
        if available.hasUncommittedChanges {
            confirmingUncommitted = true
        } else {
            Task { await rebuild.rebuildAndRelaunch(SelfRebuild.updateTarget) }
        }
    }

    var title: String {
        guard let available else { return "Update AKit" }
        return "Update to \(available.version)"
    }

    /// "3 new commits" and their summary lines, for the tooltip.
    var details: String {
        guard let available else { return "" }
        var lines = ["\(available.commits) new commit\(available.commits == 1 ? "" : "s") in \(SelfRebuild.sourceRoot?.tildePath ?? "the source folder"):"]
        lines += available.subjects.map { "• \($0)" }
        if available.commits > available.subjects.count { lines.append("…") }
        lines.append(SelfRebuild.updateTarget == .install
                     ? "Update runs make install there and restarts AKit."
                     : "Update runs make build there and restarts AKit.")
        return lines.joined(separator: "\n")
    }
}

/// Bottom of the sidebar, above the build badge: shown only while an update is available.
struct UpdateButton: View {
    @Environment(AppUpdate.self) private var update
    @Environment(SelfRebuild.self) private var rebuild

    var body: some View {
        if let available = update.available {
            VStack(alignment: .leading, spacing: 4) {
                Button { update.start(rebuild) } label: {
                    Label(update.title, systemImage: "arrow.down.circle.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(rebuild.state == .building)
                Text("\(available.commits) new commit\(available.commits == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .help(update.details)
        }
    }
}

extension View {
    /// Asks before an update that would build uncommitted changes of the source folder.
    func updateConfirmation(_ update: AppUpdate, rebuild: SelfRebuild) -> some View {
        @Bindable var update = update
        return confirmationDialog("Update with uncommitted changes?", isPresented: $update.confirmingUncommitted) {
            Button("Update Anyway") { Task { await rebuild.rebuildAndRelaunch(SelfRebuild.updateTarget) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("\(SelfRebuild.sourceRoot?.tildePath ?? "The source folder") has uncommitted changes. They go into the new build too. If an agent is working there now, wait until it commits.")
        }
    }
}
