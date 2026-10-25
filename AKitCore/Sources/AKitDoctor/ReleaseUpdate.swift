import AKitFoundation
import Foundation

/// The Update button of an AKit installed from a release zip (`install.sh`): such a copy has no
/// source folder, so a new version is a newer GitHub Release. Update downloads its `AKit.zip`
/// and puts AKit.app and the `akit` command where they are, like `install.sh` does; the old app
/// goes to the Trash.
public enum ReleaseUpdate {
    /// The GitHub repository of AKit's releases.
    public static let defaultRepository = "Stanislavussov/akit"

    public struct Release: Sendable, Equatable {
        /// `v2026.10.25-5`.
        public let tag: String
        public let title: String
        public let published: Date
        /// The release's `AKit.zip`.
        public let zip: URL
        public let page: URL?
        /// The release notes, at most 2,000 characters.
        public let notes: String

        /// "2026.10.25-5".
        public var version: String { tag.hasPrefix("v") ? String(tag.dropFirst()) : tag }
    }

    public enum Check: Sendable, Equatable {
        case found(Release)
        /// GitHub answered: no release with an AKit.zip.
        case none
        /// GitHub couldn't be asked (offline, the hourly limit, a timeout).
        case failed
    }

    public struct Failure: Error, LocalizedError {
        public let message: String
        public var errorDescription: String? { message }
    }

    /// A release from GitHub's `releases/latest` answer; nil without an `AKit.zip`, for a draft
    /// or a pre-release.
    public static func release(from data: Data) -> Release? {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let tag = object["tag_name"] as? String, !tag.isEmpty,
              object["draft"] as? Bool != true, object["prerelease"] as? Bool != true,
              let publishedText = object["published_at"] as? String,
              let published = try? Date(publishedText, strategy: .iso8601) else { return nil }
        let assets = object["assets"] as? [[String: Any]] ?? []
        guard let zip = assets.first(where: { $0["name"] as? String == "AKit.zip" })
                .flatMap({ $0["browser_download_url"] as? String }).flatMap(URL.init(string:)),
              zip.scheme == "https" else { return nil }
        let title = (object["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? tag
        return Release(tag: tag, title: title, published: published, zip: zip,
                       page: (object["html_url"] as? String).flatMap(URL.init(string:)),
                       notes: String((object["body"] as? String ?? "").prefix(2000)))
    }

    /// The latest release of `repository`.
    public static func latest(repository: String = defaultRepository) async -> Check {
        guard let url = URL(string: "https://api.github.com/repos/\(repository)/releases/latest") else { return .failed }
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let status = (response as? HTTPURLResponse)?.statusCode else { return .failed }
        if status == 404 { return .none }
        guard status == 200 else { return .failed }
        return release(from: data).map(Check.found) ?? .none
    }

    /// Whether `release` is newer than this build: another tag than the build's and than the
    /// release last installed by Update, published after the build was made. `make release`
    /// builds only at a tag, so a zip's own release has its tag; `installed` stops a loop when
    /// a zip was built some other way (its tag would never match).
    public static func isNewer(_ release: Release, versionTag: String?, built: Date?, installed: String? = nil) -> Bool {
        guard release.tag != versionTag, release.tag != installed else { return false }
        guard let built else { return true }
        return release.published > built
    }

    /// Downloads a release's zip (https; a file in tests) into a temporary file.
    public static func download(_ release: Release) async throws -> URL {
        let target = FileManager.default.temporaryDirectory.appending(path: "akit-update-\(UUID().uuidString).zip")
        if release.zip.isFileURL {
            try FileManager.default.copyItem(at: release.zip, to: target)
            return target
        }
        do {
            let (file, response) = try await URLSession.shared.download(from: release.zip)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                throw Failure(message: "GitHub answered \((response as? HTTPURLResponse)?.statusCode ?? 0) for \(release.zip.lastPathComponent).")
            }
            try FileManager.default.moveItem(at: file, to: target)
            return target
        } catch let failure as Failure {
            throw failure
        } catch {
            throw Failure(message: "Couldn't download \(release.tag): \(error.localizedDescription)")
        }
    }

    /// Puts the zip's AKit.app at `app` (the old one goes to the Trash) and its `akit` at
    /// `command`, like `install.sh`. Nothing changes when the zip is damaged or the app can't be
    /// swapped; the old app is put back. Returns a warning when only `akit` couldn't be
    /// updated: the new app is in place then. `trash` moves the old app away (tests give their own).
    @discardableResult
    public static func install(zip: URL, app: URL, command: URL, bundleID: String = "dev.ussov.akit",
                               trash: (URL) throws -> Void = { _ = try Trash.move($0) }) async throws -> String? {
        let fm = FileManager.default
        let unpacked = fm.temporaryDirectory.appending(path: "akit-update-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: unpacked) }
        try fm.createDirectory(at: unpacked, withIntermediateDirectories: true)
        let ditto = await ProcessRunner.run(URL(filePath: "/usr/bin/ditto"), arguments: ["-x", "-k", zip.path, unpacked.path], environment: ProcessInfo.processInfo.environment, timeout: 300)
        let newApp = unpacked.appending(path: "AKit/AKit.app")
        let newCommand = unpacked.appending(path: "AKit/akit")
        let info = (try? Data(contentsOf: newApp.appending(path: "Contents/Info.plist")))
            .flatMap { try? PropertyListSerialization.propertyList(from: $0, format: nil) as? [String: Any] }
        let executable = info?["CFBundleExecutable"] as? String ?? "AKit"
        guard ditto?.succeeded == true, info?["CFBundleIdentifier"] as? String == bundleID,
              fm.isExecutableFile(atPath: newApp.appending(path: "Contents/MacOS/\(executable)").path),
              fm.fileExists(atPath: newCommand.path) else {
            throw Failure(message: "The downloaded AKit.zip is damaged: nothing was changed. Try Update again.")
        }
        // The new app goes next to the old one first: the swap is then renames on one volume.
        let parent = app.deletingLastPathComponent()
        try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        // Left by an update that crashed half way.
        for name in (try? fm.contentsOfDirectory(atPath: parent.path)) ?? [] where name.hasPrefix(".AKit-update-") || name.hasPrefix(".AKit-old-") {
            try? fm.removeItem(at: parent.appending(path: name))
        }
        let staged = parent.appending(path: ".AKit-update-\(UUID().uuidString).app")
        let old = parent.appending(path: ".AKit-old-\(UUID().uuidString).app")
        do {
            try fm.copyItem(at: newApp, to: staged)
        } catch {
            try? fm.removeItem(at: staged)
            throw Failure(message: "Couldn't put the new AKit.app into \(parent.path): \(error.localizedDescription)")
        }
        let hadOld = fm.fileExists(atPath: app.path)
        do {
            if hadOld { try fm.moveItem(at: app, to: old) }
            try fm.moveItem(at: staged, to: app)
        } catch {
            if hadOld, !fm.fileExists(atPath: app.path) { try? fm.moveItem(at: old, to: app) }
            try? fm.removeItem(at: staged)
            throw Failure(message: "Couldn't put the new AKit.app in place: \(error.localizedDescription). The old one stays.")
        }
        // In place: the old app goes to the Trash (deleted when the Trash can't take it).
        if hadOld, (try? trash(old)) == nil { try? fm.removeItem(at: old) }
        var warning: String?
        do {
            try fm.createDirectory(at: command.deletingLastPathComponent(), withIntermediateDirectories: true)
            let stagedCommand = command.deletingLastPathComponent().appending(path: ".akit-update-\(UUID().uuidString)")
            try fm.copyItem(at: newCommand, to: stagedCommand)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stagedCommand.path)
            if fm.fileExists(atPath: command.path) { try fm.removeItem(at: command) }
            try fm.moveItem(at: stagedCommand, to: command)
        } catch {
            warning = "The akit command in \(command.deletingLastPathComponent().path) couldn't be updated: \(error.localizedDescription). "
                + "If that folder is owned by root: sudo chown -R \"$USER\" ~/.local, then run install.sh again."
        }
        _ = await ProcessRunner.run(URL(filePath: "/usr/bin/xattr"), arguments: ["-dr", "com.apple.quarantine", app.path, command.path], environment: ProcessInfo.processInfo.environment, timeout: 60)
        return warning
    }
}
