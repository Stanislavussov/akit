import Foundation
import Testing
import AKitBrain
import AKitFoundation
@testable import AKitKnowledge

/// The text copy of the bases and meetings in the brain at sync, in a temporary fake home.
final class BrainBackupTests {
    deinit { try? FileManager.default.removeItem(at: home) }

    let home: URL
    let brain: URL
    let fm = FileManager.default

    init() throws {
        home = try FakeHome.make("akit-backup")
        brain = home.appending(path: ".akit/registry")
    }

    var env: HarnessEnvironment { FakeHome.env(home) }

    func write(_ url: URL, _ text: String) throws {
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    func exists(_ path: String) -> Bool { fm.fileExists(atPath: brain.appending(path: path).path) }

    func commits() async throws -> Int { Int(try await FakeHome.git(["rev-list", "--count", "HEAD"], in: brain, env: env)) ?? 0 }

    /// A brain repo with one commit, a personal base with notes, a map, a picture, the index and
    /// an inbox draft, and one meeting with audio.
    func setUp() async throws -> URL {
        try write(brain.appending(path: "README.md"), "brain\n")
        for args in [["init", "--quiet"], ["config", "user.name", "Test"], ["config", "user.email", "t@example.com"],
                     ["config", "commit.gpgsign", "false"], ["add", "."], ["commit", "--quiet", "-m", "start"]] {
            _ = try await FakeHome.git(args, in: brain, env: env)
        }
        let base = try await KnowledgeBase.create(world: "personal", env: env).root
        try write(base.appending(path: "areas/work/orders.md"), "# Orders\n")
        try write(base.appending(path: "areas/work/maps/overview.excalidraw"), "{}\n")
        try write(base.appending(path: "areas/work/photo.png"), "png")
        try write(base.appending(path: ".spaces.json"), "{\"spaces\": [\"work\"]}\n")
        try write(base.appending(path: ".akit-index.sqlite"), "index")
        try write(base.appending(path: ".akit-misses.log"), "miss")
        try write(base.appending(path: ".obsidian/app.json"), "{}")
        try write(base.appending(path: "inbox/draft.md"), "draft")
        try write(base.appending(path: "notebook/Inbox.md"), "- [ ] task\n")
        try write(base.appending(path: "notebook/assets/a.png"), "png")
        try write(base.appending(path: "worklog/2026-11-07.md"), "- 10:00 #code x\n")
        let meeting = home.appending(path: "Meetings/2026-11-07/1033")
        try write(meeting.appending(path: "meeting.json"), "{}\n")
        try write(meeting.appending(path: "summary.md"), "Summary\n")
        try write(meeting.appending(path: "transcript.md"), "Me: hi\n")
        try write(meeting.appending(path: "tabs/Notes.md"), "notes\n")
        try write(meeting.appending(path: "tabs/pic.png"), "png")
        try write(meeting.appending(path: "audio/part-1.m4a"), "audio")
        try write(meeting.appending(path: ".processing.lock"), "")
        return base
    }

    @Test func copiesAllowListedTextOnlyInOneCommit() async throws {
        _ = try await setUp()
        let outcome = await BrainBackup.run(env: env, brain: brain)
        #expect(outcome.lines.first?.hasPrefix("Backed up knowledge and meetings") == true, "\(outcome.lines)")
        for path in ["knowledge/personal/areas/work/orders.md", "knowledge/personal/areas/work/maps/overview.excalidraw",
                     "knowledge/personal/.spaces.json", "knowledge/personal/kb.yaml", "knowledge/personal/notebook/Inbox.md", "knowledge/personal/worklog/2026-11-07.md",
                     "meetings/2026-11-07/1033/meeting.json", "meetings/2026-11-07/1033/summary.md",
                     "meetings/2026-11-07/1033/transcript.md", "meetings/2026-11-07/1033/tabs/Notes.md"] {
            #expect(exists(path), "\(path)")
        }
        for path in ["knowledge/personal/areas/work/photo.png", "knowledge/personal/.akit-index.sqlite",
                     "knowledge/personal/.akit-misses.log", "knowledge/personal/.obsidian", "knowledge/personal/inbox",
                     "knowledge/personal/.git", "knowledge/personal/notebook/assets", "meetings/2026-11-07/1033/audio",
                     "meetings/2026-11-07/1033/tabs/pic.png", "meetings/2026-11-07/1033/.processing.lock"] {
            #expect(!exists(path), "\(path)")
        }
        #expect(try await commits() == 2)
        #expect(try await FakeHome.git(["log", "-1", "--format=%s"], in: brain, env: env) == BrainBackup.commitMessage)
        #expect(try await FakeHome.git(["status", "--porcelain"], in: brain, env: env).isEmpty)
    }

    @Test func noCommitWhenUnchanged() async throws {
        _ = try await setUp()
        _ = await BrainBackup.run(env: env, brain: brain)
        let second = await BrainBackup.run(env: env, brain: brain)
        #expect(second.committed.isEmpty)
        #expect(second.lines.isEmpty)
        #expect(try await commits() == 2)
    }

    @Test func mirrorsDeletions() async throws {
        let base = try await setUp()
        _ = await BrainBackup.run(env: env, brain: brain)
        try fm.removeItem(at: base.appending(path: "areas/work/orders.md"))
        try fm.removeItem(at: home.appending(path: "Meetings/2026-11-07"))
        let outcome = await BrainBackup.run(env: env, brain: brain)
        #expect(Set(outcome.committed) == ["knowledge/personal/areas/work/orders.md", "meetings/2026-11-07/1033/meeting.json",
                                           "meetings/2026-11-07/1033/summary.md", "meetings/2026-11-07/1033/transcript.md",
                                           "meetings/2026-11-07/1033/tabs/Notes.md"])
        #expect(!exists("knowledge/personal/areas/work/orders.md"))
        #expect(!exists("meetings/2026-11-07"))
        #expect(exists("knowledge/personal/areas/work/maps/overview.excalidraw"))
        #expect(try await commits() == 3)
    }

    @Test func refusesOnAWorkMac() async throws {
        _ = try await setUp()
        try MachineProfile(kind: .work, name: "work").save(home: home)
        let outcome = await BrainBackup.run(env: env, brain: brain)
        #expect(outcome.lines == [BrainBackup.workRefusal])
        #expect(!exists("knowledge"))
        #expect(!exists("meetings"))
        #expect(try await commits() == 1)
    }

    @Test func refusesWithABrokenMachineFile() async throws {
        _ = try await setUp()
        try write(MachineProfile.file(home: home), "{ not json")
        let outcome = await BrainBackup.run(env: env, brain: brain)
        #expect(outcome.lines == [BrainBackup.workRefusal])
        #expect(!exists("knowledge"))
        #expect(try await commits() == 1)
    }

    @Test func toggleOffDoesNothing() async throws {
        _ = try await setUp()
        #expect(BrainBackup.isEnabled(home: home))
        try BrainBackup.setEnabled(false, home: home)
        #expect(!BrainBackup.isEnabled(home: home))
        let outcome = await BrainBackup.run(env: env, brain: brain)
        #expect(outcome == BrainBackup.Outcome())
        #expect(!exists("knowledge"))
        #expect(try await commits() == 1)
    }

    @Test func missingMeetingsFolderIsFine() async throws {
        _ = try await setUp()
        try fm.removeItem(at: home.appending(path: "Meetings"))
        let outcome = await BrainBackup.run(env: env, brain: brain)
        #expect(exists("knowledge/personal/areas/work/orders.md"))
        #expect(!exists("meetings"))
        #expect(!outcome.committed.isEmpty)
    }

    @Test func meetingsFolderFromSettingsAndSecretsSkipped() async throws {
        let base = try await setUp()
        try write(home.appending(path: "Library/Application Support/Meetings/settings.json"), "{\"rootPath\": \"~/Elsewhere\"}")
        try write(home.appending(path: "Elsewhere/2026-11-01/0900/summary.md"), "Other\n")
        try write(base.appending(path: "areas/work/keys.md"), "token " + "ghp" + "_" + String(repeating: "x", count: 36) + "\n")
        let outcome = await BrainBackup.run(env: env, brain: brain)
        #expect(exists("meetings/2026-11-01/0900/summary.md"))
        #expect(!exists("meetings/2026-11-07"))
        #expect(!exists("knowledge/personal/areas/work/keys.md"))
        #expect(outcome.lines.contains { $0.contains("keys.md (looks like it holds a secret)") })
    }

    @Test func skipsTheSampleBase() async throws {
        _ = try await setUp()
        _ = try await KnowledgeSeed.seed(env: env)
        _ = await BrainBackup.run(env: env, brain: brain)
        #expect(!exists("knowledge/\(KnowledgeSeed.world)"))
        #expect(exists("knowledge/personal"))
    }
}
