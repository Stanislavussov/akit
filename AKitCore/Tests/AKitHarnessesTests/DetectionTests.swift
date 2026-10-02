import Foundation
import Testing
@testable import AKitFoundation
@testable import AKitHarnesses

/// All tests run in a temporary fake home folder and never touch the real one.
struct DetectionTests {
    let home: URL
    let fm = FileManager.default

    init() throws {
        home = fm.temporaryDirectory.appending(path: "akit-tests-\(UUID().uuidString)")
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
    }

    var env: HarnessEnvironment { HarnessEnvironment(homeDirectory: home) }

    func mkdir(_ path: String) throws {
        try fm.createDirectory(at: home.appending(path: path), withIntermediateDirectories: true)
    }

    func touch(_ path: String, _ text: String = "{}") throws {
        try Data(text.utf8).write(to: home.appending(path: path))
    }

    @Test func nothingInstalledMeansNothingDetected() {
        #expect(HarnessCatalog.detectAll(in: env).isEmpty)
    }

    @Test func claudeDetectedByConfigFolder() throws {
        try mkdir(".claude/skills")
        try touch(".claude/settings.json")

        let found = try #require(ClaudeCodeAdapter().detect(in: env))
        #expect(found.executableURL == nil)
        let byTitle = Dictionary(uniqueKeysWithValues: found.locations.map { ($0.title, $0) })
        #expect(byTitle["Settings"]?.exists == true)
        #expect(byTitle["Skills"]?.exists == true)
        #expect(byTitle["Subagents"]?.exists == false)
        #expect(HarnessCatalog.detectAll(in: env).map(\.id) == [.claudeCode])
    }

    @Test func claudeDetectedByExecutableOnly() throws {
        try mkdir("bin")
        let exe = home.appending(path: "bin/claude")
        try touch("bin/claude", "#!/bin/sh\necho 1.0.0\n")
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: exe.path)

        var e = env
        e.executableSearchPaths = [home.appending(path: "bin")]
        let found = try #require(ClaudeCodeAdapter().detect(in: e))
        #expect(found.executableURL?.lastPathComponent == "claude")
    }

    @Test func piRespectsCustomConfigDir() throws {
        try mkdir("custom-pi")
        var e = env
        e.variables["PI_CODING_AGENT_DIR"] = "~/custom-pi"
        let found = try #require(PiAdapter().detect(in: e))
        #expect(found.configRoot.lastPathComponent == "custom-pi")
    }

    @Test func sharedSkillsSymlinkIsReported() throws {
        try mkdir(".agents/skills")
        try mkdir(".pi/agent")
        try fm.createSymbolicLink(atPath: home.appending(path: ".pi/agent/skills").path,
                                  withDestinationPath: "../../.agents/skills")

        let found = try #require(PiAdapter().detect(in: env))
        let skills = try #require(found.locations.first { $0.title == "Skills" })
        #expect(skills.exists)
        #expect(skills.symlinkDestination?.resolvingSymlinksInPath().path
                == home.appending(path: ".agents/skills").resolvingSymlinksInPath().path)
    }

    @Test func brokenSymlinkCountsAsMissing() throws {
        try mkdir(".claude")
        try fm.createSymbolicLink(atPath: home.appending(path: ".claude/skills").path,
                                  withDestinationPath: "../nowhere")
        let found = try #require(ClaudeCodeAdapter().detect(in: env))
        let skills = try #require(found.locations.first { $0.title == "Skills" })
        #expect(!skills.exists)
        #expect(skills.symlinkDestination != nil)
    }

    @Test func versionProbeReadsFirstLine() async throws {
        try mkdir("bin")
        let exe = home.appending(path: "bin/tool")
        try touch("bin/tool", "#!/bin/sh\necho '2.1.0 (Tool)'\necho second\n")
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: exe.path)
        #expect(await VersionProbe.version(of: exe, in: env) == "2.1.0 (Tool)")
    }
}

struct VersionProbeTests {
    func script(_ body: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "akit-probe-\(UUID().uuidString)")
        try Data("#!/bin/sh\n\(body)\n".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    var env: HarnessEnvironment { HarnessEnvironment(homeDirectory: FileManager.default.temporaryDirectory) }

    @Test func largeOutputDoesNotHang() async throws {
        // 200 KB of banner before the version — more than the pipe buffer (64 KB).
        let exe = try script("head -c 200000 /dev/zero | tr '\\\\0' 'x'; echo; echo 'v3.0.1'")
        let start = Date()
        // A hang would last the whole timeout; the bound leaves room for a busy parallel test run.
        let version = await VersionProbe.version(of: exe, in: env, timeout: 20)
        #expect(Date().timeIntervalSince(start) < 10)
        #expect(version == "v3.0.1")
    }

    @Test func versionOnStderrIsRead() async throws {
        let exe = try script("echo '1.2.3' >&2")
        #expect(await VersionProbe.version(of: exe, in: env) == "1.2.3")
    }

    @Test func hangingProgramTimesOut() async throws {
        let exe = try script("sleep 30")
        let start = Date()
        #expect(await VersionProbe.version(of: exe, in: env, timeout: 1) == nil)
        // Far below the 30 s sleep; generous because the full suite runs in parallel.
        #expect(Date().timeIntervalSince(start) < 6)
    }

    @Test func failingProgramGivesNil() async throws {
        let exe = try script("echo 'error 42'; exit 1")
        #expect(await VersionProbe.version(of: exe, in: env) == nil)
    }
}
