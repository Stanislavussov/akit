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
/// A copy from a release zip (install.sh) has no source folder: it looks for a newer GitHub
/// Release instead, and Update downloads its AKit.zip, puts it in place and starts it.
@MainActor
@Observable
final class AppUpdate {
    private(set) var available: SourceUpdate.Available?
    /// A newer GitHub Release, for a copy from a release zip.
    private(set) var release: ReleaseUpdate.Release?
    private var lastCheck: Date?
    /// One check loop for the app, however many windows start it.
    private var watching = false
    /// Update is checking, pulling or building: a second click waits for it.
    private(set) var isUpdating = false

    /// The time between checks while AKit stays open; a release copy asks GitHub, which allows
    /// 60 unsigned calls an hour.
    private static let interval: Duration = .seconds(300)
    private static let releaseInterval: Duration = .seconds(900)
    /// The release Update installed last: never offered again, even when the zip's own tag differs.
    private static let installedKey = "AKitInstalledRelease"

    /// The copy came from a release zip: updates come from GitHub Releases.
    var fromRelease: Bool { BuildInfo.current.fromRelease }
    var isAvailable: Bool {
        fromRelease || (SelfRebuild.sourceRoot != nil && BuildInfo.current.commit != nil && BuildInfo.current.branch != nil)
    }
    /// Something to update to.
    var hasUpdate: Bool { available != nil || release != nil }

    /// Checks now and then every few minutes, until the task is cancelled.
    func watch() async {
        guard isAvailable, !watching else { return }
        watching = true
        defer { watching = false }
        while !Task.isCancelled {
            await check()
            try? await Task.sleep(for: fromRelease ? Self.releaseInterval : Self.interval)
        }
    }

    /// When AKit comes to the front: a merge made in a terminal shows up at once. GitHub allows
    /// 60 unsigned API calls an hour, so a release copy asks at most every 15 minutes.
    func checkSoon() async {
        if let lastCheck, Date.now.timeIntervalSince(lastCheck) < (fromRelease ? 900 : 20) { return }
        await check()
    }

    func check() async {
        let info = BuildInfo.current
        if info.fromRelease {
            lastCheck = .now
            switch await ReleaseUpdate.latest() {
            case .found(let latest):
                let installed = UserDefaults.standard.string(forKey: Self.installedKey)
                release = ReleaseUpdate.isNewer(latest, versionTag: info.versionTag, built: info.date, installed: installed) ? latest : nil
            case .none:
                release = nil
            case .failed:
                break   // offline or over GitHub's limit: keep what the last check found
            }
            return
        }
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
        if fromRelease {
            startRelease()
            return
        }
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

    /// Downloads the release's AKit.zip, puts AKit.app where this one is and akit into
    /// ~/.local/bin (as install.sh does), then starts the new app.
    private func startRelease() {
        guard let release, !isUpdating else { return }
        isUpdating = true
        Task {
            defer { isUpdating = false }
            let warning: String?
            do {
                let zip = try await ReleaseUpdate.download(release)
                defer { try? FileManager.default.removeItem(at: zip) }
                let command = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".local/bin/akit")
                warning = try await ReleaseUpdate.install(zip: zip, app: Bundle.main.bundleURL, command: command)
            } catch {
                showFailure("Couldn't update to \(release.version)", error.localizedDescription
                            + "\n\nYou can also run install.sh again, as for the first install.")
                return
            }
            UserDefaults.standard.set(release.tag, forKey: Self.installedKey)
            if let warning { showFailure("AKit \(release.version) is installed", warning) }
            if let problem = await SelfRebuild.relaunch(Bundle.main.bundleURL) {
                showFailure("AKit \(release.version) is installed", "It couldn't be started: \(problem)\n\nQuit AKit and open it again.")
            }
        }
    }

    private func showFailure(_ title: String, _ text: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.addButton(withTitle: "OK")
        alert.runModal()
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
        if let release { return "Update to \(release.version)" }
        guard let available else { return "Update AKit" }
        return "Update to \(available.version)"
    }

    /// The caption under the button.
    var caption: String {
        if release != nil { return "New release on GitHub" }
        guard let available else { return "" }
        return "\(available.commits) new commit\(available.commits == 1 ? "" : "s")"
    }

    /// "3 new commits" and their summary lines, for the tooltip.
    var details: String {
        if let release {
            var lines = ["\(release.title)", "Published \(release.published.formatted(date: .abbreviated, time: .shortened)) on GitHub."]
            let notes = release.notes.split(whereSeparator: \.isNewline).prefix(8).map(String.init)
            if !notes.isEmpty { lines += [""] + notes }
            lines.append("")
            lines.append("Update downloads its AKit.zip, puts AKit.app here and akit into ~/.local/bin (as install.sh does), moves the old app to the Trash and restarts AKit.")
            return lines.joined(separator: "\n")
        }
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
        if update.hasUpdate {
            VStack(alignment: .leading, spacing: 4) {
                Button { update.start(rebuild) } label: {
                    Label(update.title, systemImage: "arrow.down.circle.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(rebuild.state == .building || update.isUpdating)
                Text(update.isUpdating && update.fromRelease ? "Updating…" : update.caption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .help(update.details)
        }
    }
}
