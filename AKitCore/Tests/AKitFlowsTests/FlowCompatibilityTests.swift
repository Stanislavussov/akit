import Foundation
import Testing
import AKitFoundation
@testable import AKitFlows

private let repoRoot = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent()

/// F20: the probe's capabilities, `testedPi`, and the 14-day run worktree cleanup.
struct FlowCompatibilityTests {
    @Test func testedPiMatchesTheRunnerTemplate() throws {
        let text = try String(contentsOf: repoRoot.appending(path: "AKitCore/Sources/AKitRender/Resources/flows/flow-core.ts"), encoding: .utf8)
        #expect(text.contains("export const TESTED_PI = \"\(Flow.testedPi)\";"))
    }

    @Test func capabilitiesFromVersionAndHelp() throws {
        let help = "Usage: pi [options]\n  --mode <mode>\n  --session-dir <dir>\n  --no-extensions, -ne\n  --no-skills, -ns\n  --skill <name>\n"
        let found = FlowPiProbe.capabilities(version: "pi 1.0.4\n", help: help)
        #expect(found.version == "1.0.4")
        #expect(found.features == ["mode-json", "session-dir", "no-extensions", "no-skills", "skill", "tool-call-block", "ui-confirm"])
        let old = FlowPiProbe.capabilities(version: "0.99.0", help: help)
        #expect(!old.features.contains("tool-call-block") && !old.features.contains("thinking"))
        let home = FileManager.default.temporaryDirectory.appending(path: "akit-flow-probe-\(UUID().uuidString)")
        let env = HarnessEnvironment(homeDirectory: home)
        try FlowPiProbe.write(found, env: env)
        #expect(FlowFile.capabilities(env: env) == found)
        let text = try String(contentsOf: FlowPiProbe.file(env: env), encoding: .utf8)
        #expect(!text.contains(home.path), "only a version and feature names")
    }

    /// A run worktree older than 14 days: the clean one goes, the dirty one is kept and flagged.
    @Test func aDirtyOldWorktreeIsNotDeleted() throws {
        let fm = FileManager.default
        let home = URL(filePath: FileWalk.realPath(fm.temporaryDirectory) ?? fm.temporaryDirectory.path).appending(path: "akit-flow-clean-\(UUID().uuidString)")
        let project = home.appending(path: "Projects/app")
        let env = HarnessEnvironment(homeDirectory: home, variables: ["HOME": home.path, "GIT_AUTHOR_NAME": "T", "GIT_AUTHOR_EMAIL": "t@example.com",
                                                                     "GIT_COMMITTER_NAME": "T", "GIT_COMMITTER_EMAIL": "t@example.com"])
        try fm.createDirectory(at: project, withIntermediateDirectories: true)
        func git(_ args: String..., in folder: URL = project) throws {
            let result = try #require(FlowWorktreeCleanup.git(args, in: folder, env: env))
            #expect(result.succeeded, "git \(args): \(result.output)")
        }
        try git("init", "-q", "-b", "main")
        try git("commit", "-q", "--allow-empty", "-m", "init")
        let root = FlowWorktreeCleanup.root(env: env)
        for run in ["20261001-0900-clean", "20261001-0900-dirty", "20261116-0900-fresh"] {
            try fm.createDirectory(at: root.appending(path: run), withIntermediateDirectories: true)
            try git("worktree", "add", "-q", "-b", "akit-flow/\(run)", root.appending(path: "\(run)/worktree").path)
        }
        try Data("draft".utf8).write(to: root.appending(path: "20261001-0900-dirty/worktree/notes.txt"))
        let now = Date.now.addingTimeInterval(15 * 86_400)
        // The fresh run was used "yesterday": its worktree's time is moved to now - 1 day.
        try fm.setAttributes([.modificationDate: now.addingTimeInterval(-86_400)], ofItemAtPath: root.appending(path: "20261116-0900-fresh/worktree").path)
        let old = FlowWorktreeCleanup.old(env: env, now: now)
        #expect(old.map(\.run).sorted() == ["20261001-0900-clean", "20261001-0900-dirty"])
        #expect(old.first { $0.run.hasSuffix("dirty") }?.dirty == true)
        #expect(old.first?.project?.standardizedFileURL.path == project.standardizedFileURL.path)
        let removed = FlowWorktreeCleanup.prune(env: env, now: now)
        #expect(removed.map(\.run) == ["20261001-0900-clean"])
        #expect(!fm.fileExists(atPath: root.appending(path: "20261001-0900-clean/worktree").path))
        #expect(fm.fileExists(atPath: root.appending(path: "20261001-0900-dirty/worktree/notes.txt").path), "a dirty worktree is kept")
        #expect(fm.fileExists(atPath: root.appending(path: "20261116-0900-fresh/worktree/.git").path))
    }

    @Test func aLiveLockKeepsTheWorktree() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "akit-flow-lock-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("\(ProcessInfo.processInfo.processIdentifier)\n".utf8).write(to: folder.appending(path: "lock"))
        #expect(FlowRunSummary.lockAlive(folder))
        try Data("999999\n".utf8).write(to: folder.appending(path: "lock"))
        #expect(!FlowRunSummary.lockAlive(folder))
    }
}
