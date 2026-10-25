import Foundation
import Testing
import AKitFoundation
@testable import AKitDoctor

/// The Update button of a copy from a release zip: GitHub's latest release, then the zip put in place.
struct ReleaseUpdateTests {
    let home: URL
    let fm = FileManager.default

    init() throws {
        home = fm.temporaryDirectory.appending(path: "akit-release-\(UUID().uuidString)")
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
    }

    func answer(tag: String = "v2026.10.25-5", published: String = "2026-10-25T10:49:21Z", asset: String = "AKit.zip",
                url: String = "https://github.com/Stanislavussov/akit/releases/download/v2026.10.25-5/AKit.zip", draft: Bool = false) -> Data {
        Data("""
        {"tag_name":"\(tag)","name":"\(tag): Open the base in Obsidian","draft":\(draft),"prerelease":false,
         "published_at":"\(published)","html_url":"https://github.com/Stanislavussov/akit/releases/tag/\(tag)","body":"- Open the base",
         "assets":[{"name":"\(asset)","browser_download_url":"\(url)"}]}
        """.utf8)
    }

    @Test func readsTheLatestRelease() throws {
        let release = try #require(ReleaseUpdate.release(from: answer()))
        #expect(release.tag == "v2026.10.25-5" && release.version == "2026.10.25-5" && release.title.hasSuffix("Obsidian"))
        #expect(release.zip.lastPathComponent == "AKit.zip" && release.notes == "- Open the base")
        #expect(ReleaseUpdate.release(from: answer(asset: "Other.zip")) == nil, "no AKit.zip")
        #expect(ReleaseUpdate.release(from: answer(url: "http://example.com/AKit.zip")) == nil, "only https")
        #expect(ReleaseUpdate.release(from: answer(draft: true)) == nil)
        #expect(ReleaseUpdate.release(from: Data("{\"message\":\"Not Found\"}".utf8)) == nil)
    }

    @Test func newerIsAnotherTagPublishedAfterTheBuild() throws {
        let release = try #require(ReleaseUpdate.release(from: answer()))
        let before = try Date("2026-10-25T10:40:00Z", strategy: .iso8601)
        let after = try Date("2026-10-25T11:00:00Z", strategy: .iso8601)
        #expect(ReleaseUpdate.isNewer(release, versionTag: "v2026.10.25-4", built: before))
        #expect(!ReleaseUpdate.isNewer(release, versionTag: "v2026.10.25-5", built: before), "its own release")
        #expect(!ReleaseUpdate.isNewer(release, versionTag: "v2026.10.25-4", built: after), "a build made after the release")
        #expect(ReleaseUpdate.isNewer(release, versionTag: nil, built: nil))
        // A zip whose tag never matches its release: once installed, not offered again.
        #expect(!ReleaseUpdate.isNewer(release, versionTag: "v2026.10.25-4", built: before, installed: "v2026.10.25-5"))
    }

    /// A zip like `make release` makes: AKit/AKit.app and AKit/akit.
    func zip(version: String) async throws -> URL {
        let folder = home.appending(path: "zip-\(version)/AKit")
        try fm.createDirectory(at: folder.appending(path: "AKit.app/Contents/MacOS"), withIntermediateDirectories: true)
        let info: [String: Any] = ["CFBundleIdentifier": "dev.ussov.akit", "CFBundleExecutable": "AKit", "Version": version]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: folder.appending(path: "AKit.app/Contents/Info.plist"))
        let binary = folder.appending(path: "AKit.app/Contents/MacOS/AKit")
        try Data("#!/bin/sh\n".utf8).write(to: binary)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path)
        try Data("#!/bin/sh\necho \(version)\n".utf8).write(to: folder.appending(path: "akit"))
        let zip = home.appending(path: "AKit-\(version).zip")
        let result = await ProcessRunner.run(URL(filePath: "/usr/bin/ditto"), arguments: ["-c", "-k", "--keepParent", folder.path, zip.path],
                                             environment: [:], timeout: 60)
        #expect(result?.succeeded == true)
        return zip
    }

    /// The test's own Trash, never the Mac's.
    func trash(_ url: URL) throws {
        let folder = home.appending(path: ".Trash")
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        try fm.moveItem(at: url, to: folder.appending(path: UUID().uuidString))
    }

    @Test func installsTheZipWhereTheAppIs() async throws {
        let app = home.appending(path: "Applications/AKit.app")
        let command = home.appending(path: ".local/bin/akit")
        try await ReleaseUpdate.install(zip: try await zip(version: "one"), app: app, command: command, trash: trash)
        #expect(try String(contentsOf: app.appending(path: "Contents/Info.plist"), encoding: .utf8).contains("one"))
        #expect(try String(contentsOf: command, encoding: .utf8).contains("echo one"))
        #expect(fm.isExecutableFile(atPath: command.path))

        try await ReleaseUpdate.install(zip: try await zip(version: "two"), app: app, command: command, trash: trash)
        #expect(try String(contentsOf: app.appending(path: "Contents/Info.plist"), encoding: .utf8).contains("two"))
        #expect(try String(contentsOf: command, encoding: .utf8).contains("echo two"))
        #expect(try fm.contentsOfDirectory(atPath: app.deletingLastPathComponent().path) == ["AKit.app"], "nothing staged is left")
        #expect(try fm.contentsOfDirectory(atPath: home.appending(path: ".Trash").path).count == 1, "the old app is in the Trash")

        // Another app's zip changes nothing.
        let other = try await zip(version: "other")
        let unpacked = home.appending(path: "zip-other/AKit/AKit.app/Contents/Info.plist")
        try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "com.example.other", "CFBundleExecutable": "AKit"], format: .xml, options: 0).write(to: unpacked)
        try fm.removeItem(at: other)
        _ = await ProcessRunner.run(URL(filePath: "/usr/bin/ditto"), arguments: ["-c", "-k", "--keepParent", home.appending(path: "zip-other/AKit").path, other.path],
                                    environment: [:], timeout: 60)
        await #expect(throws: ReleaseUpdate.Failure.self) { try await ReleaseUpdate.install(zip: other, app: app, command: command, trash: trash) }

        // Only akit can't be written: the app is in place, a warning says why.
        let readOnly = home.appending(path: "ro")
        try fm.createDirectory(at: readOnly, withIntermediateDirectories: true)
        try fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: readOnly.path)
        defer { try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: readOnly.path) }
        let warning = try await ReleaseUpdate.install(zip: try await zip(version: "three"), app: app, command: readOnly.appending(path: "akit"), trash: trash)
        #expect(warning?.contains("couldn't be updated") == true)
        #expect(try String(contentsOf: app.appending(path: "Contents/Info.plist"), encoding: .utf8).contains("three"))

        // A damaged zip changes nothing.
        let broken = home.appending(path: "broken.zip")
        try Data("not a zip".utf8).write(to: broken)
        await #expect(throws: ReleaseUpdate.Failure.self) { try await ReleaseUpdate.install(zip: broken, app: app, command: command, trash: trash) }
        #expect(try String(contentsOf: app.appending(path: "Contents/Info.plist"), encoding: .utf8).contains("three"))
    }

    @Test func downloadsAFileReleaseToo() async throws {
        let source = try await zip(version: "local")
        #expect(ReleaseUpdate.release(from: answer(url: source.absoluteString)) == nil, "GitHub's answer: https only")
        let release = ReleaseUpdate.Release(tag: "v1", title: "v1", published: .now, zip: source, page: nil, notes: "")
        let file = try await ReleaseUpdate.download(release)
        defer { try? fm.removeItem(at: file) }
        #expect(fm.contentsEqual(atPath: file.path, andPath: source.path))
    }
}
