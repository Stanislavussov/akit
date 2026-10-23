import AKitDoctor
import AKitFoundation
import AppKit
import Observation
import SwiftUI

/// A newer AKit in the source folder this copy was built from (new commits on its branch, e.g.
/// a feature merged into master) or on that branch's upstream (`origin/master`, a release pushed
/// from another Mac): the Update button at the bottom of the sidebar and AKit → Update AKit pull
/// it (fast-forward only), build it and start it. Checked at launch, every few minutes and when
/// AKit comes to the front; the check fetches the upstream branch, never changes the files.
@MainActor
@Observable
final class AppUpdate {
    private(set) var available: SourceUpdate.Available?
    private var lastCheck: Date?
    /// One check loop for the app, however many windows start it.
    private var watching = false
    /// Update is checking, pulling or building: a second click waits for it.
    private(set) var isUpdating = false

    /// The time between checks while AKit stays open.
    private static let interval: Duration = .seconds(300)

    var isAvailable: Bool { SelfRebuild.sourceRoot != nil && BuildInfo.current.commit != nil && BuildInfo.current.branch != nil }

    /// Checks now and then every few minutes, until the task is cancelled.
    func watch() async {
        guard isAvailable, !watching else { return }
        watching = true
        defer { watching = false }
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
                                                                 env: .current, fetch: true) {
            available = update
        } else {
            available = nil
        }
    }

    /// Update now, or ask first when the source folder has uncommitted changes. The folder is
    /// checked again first: an agent may have started editing or switched branches since.
    func start(_ rebuild: SelfRebuild) {
        guard available != nil, rebuild.state != .building, !isUpdating else { return }
        isUpdating = true
        Task {
            defer { isUpdating = false }
            await check()
            guard let available else { return }
            if available.hasUncommittedChanges, !confirmUncommitted() { return }
            // A release pushed from elsewhere: bring it into the folder first, fast-forward only.
            if available.needsPull, let source = SelfRebuild.sourceRoot {
                if let problem = await SourceUpdate.pull(source: source, env: .current) {
                    showPullFailure(problem)
                    return
                }
            }
            await rebuild.rebuildAndRelaunch(SelfRebuild.updateTarget)
        }
    }

    private func showPullFailure(_ problem: String) {
        let alert = NSAlert()
        alert.messageText = "Couldn't bring the new version into the source folder"
        alert.informativeText = problem + "\n\nAKit pulls only when the folder has no commits of its own on top. Merge or pull there yourself, then Update again."
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    /// An alert, not a sheet: AKit → Update to … works with the main window closed too.
    private func confirmUncommitted() -> Bool {
        let alert = NSAlert()
        alert.messageText = "Update with uncommitted changes?"
        alert.informativeText = "\(SelfRebuild.sourceRoot?.tildePath ?? "The source folder") has uncommitted changes. They go into the new build too. If an agent is working there now, wait until it commits."
        alert.addButton(withTitle: "Update Anyway")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    var title: String {
        guard let available else { return "Update AKit" }
        return "Update to \(available.version)"
    }

    /// "3 new commits" and their summary lines, for the tooltip.
    var details: String {
        guard let available else { return "" }
        var lines = ["\(available.commits) new commit\(available.commits == 1 ? "" : "s") "
                     + (available.needsPull ? "in \(available.upstream ?? "the upstream branch"), not yet in " : "in ")
                     + "\(SelfRebuild.sourceRoot?.tildePath ?? "the source folder"):"]
        lines += available.subjects.map { "• \($0)" }
        if available.commits > available.subjects.count { lines.append("…") }
        if available.upstreamAhead > 0 {
            lines.append("\(available.upstream ?? "The upstream branch") also has \(available.upstreamAhead) new commit\(available.upstreamAhead == 1 ? "" : "s"): "
                         + "the folder has commits of its own, so merge it there by hand.")
        }
        let pull = available.needsPull ? "git pull --ff-only, then " : ""
        lines.append(SelfRebuild.updateTarget == .install
                     ? "Update runs \(pull)make install there and restarts AKit."
                     : "Update runs \(pull)make build there and restarts AKit.")
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
                .disabled(rebuild.state == .building || update.isUpdating)
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
