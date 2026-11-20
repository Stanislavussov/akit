import Foundation
import Testing
import AKitFoundation
import AKitLab
import AKitMCP
import AKitModel
import AKitReview
@testable import AKitAttention

/// A made-up home: every test writes the files a screen would write and reads them back.
struct AttentionHome {
    let url = FileManager.default.temporaryDirectory.appending(path: "akit-attention-\(UUID().uuidString)", directoryHint: .isDirectory)
    var env: HarnessEnvironment { HarnessEnvironment(homeDirectory: url) }

    func write(_ path: String, _ text: String) {
        let file = url.appending(path: path)
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data(text.utf8).write(to: file)
    }

    func labRun(_ id: String, kind: RunSpec.Kind, title: String, status: RunState.Status, created: Date = .now,
                message: String? = nil, result: RunResult? = nil, findings: [Review.Finding] = []) throws {
        let spec = RunSpec(id: id, kind: kind, title: title, createdAt: created, folder: "/tmp", environment: .background, akit: "/a")
        let run = try LabStore.create(spec, env: env)
        try LabStore.encoder.encode(RunState(status: status, updatedAt: created, message: message))
            .write(to: run.folder.appending(path: "state.json"))
        if let result { try LabStore.encoder.encode(result).write(to: run.folder.appending(path: "result.json")) }
        if !findings.isEmpty { try AKitLab.ReviewRun.write(summary: "Summary", findings: findings, to: run.folder) }
    }
}

func items(_ home: AttentionHome, now: Date = .now) -> [AttentionItem] {
    Attention.collect(env: home.env, brain: nil, projects: [], now: now)
}

struct AttentionLabTests {
    @Test func aFailedRunIsAProblemAndAFinishedReviewIsReady() throws {
        let home = AttentionHome()
        try home.labRun("20261119-100000-aaaa", kind: .replay, title: "Replay abc", status: .error, message: "No credit left.\nmore")
        try home.labRun("20261119-110000-bbbb", kind: .review, title: "Review: login bug", status: .finished,
                        result: RunResult(review: .ok), findings: [.init(title: "Read the test log first", detail: "d")])
        let found = items(home)
        #expect(found.map(\.level) == [.problem, .ready])
        #expect(found[0].title == "Lab run failed: Replay abc")
        #expect(found[0].detail == "No credit left.")
        #expect(found[0].link == AttentionLink(screen: "lab", item: "20261119-100000-aaaa"))
        #expect(found[1].title == "Session review ready: Review: login bug")
        #expect(found[1].detail == "1 improvement. First: Read the test log first")
    }

    @Test func oldRunsAreLeftOutAndFailedControlCellsAreOneItem() throws {
        let home = AttentionHome()
        try home.labRun("old", kind: .replay, title: "Old", status: .error, created: .now.addingTimeInterval(-30 * 86_400))
        try home.labRun("c1", kind: .control, title: "Cell 1", status: .error, created: .now.addingTimeInterval(-60))
        try home.labRun("c2", kind: .control, title: "Cell 2", status: .error, message: "Clone failed")
        let found = items(home)
        #expect(found.count == 1)
        #expect(found[0].id == "lab:control-errors")
        #expect(found[0].title == "2 control cells failed")
        #expect(found[0].detail == "Latest: Cell 2. Clone failed")
    }
}

struct AttentionReviewTests {
    func run(_ home: AttentionHome, id: String, iid: Int, age: Double = 0, stage: ReviewRunStatus.Stage, requests: String) throws {
        let catalog = ReviewCatalog.load(home: home.url, brain: nil)
        let ref = MergeRequestRef(host: "https://gitlab.example.com", projectPath: "team/orders", iid: iid)
        var spec = try ReviewResolver.resolve(catalog: catalog, profile: nil, choices: ReviewRunChoices(scenario: "bugfix"),
                                              mergeRequest: ref, id: id).spec
        spec.title = "Fix the refund rounding"
        spec.created = .now.addingTimeInterval(-age)
        let folder = ReviewPaths(home: home.url).run(id)
        try ReviewJSON.write(spec, to: folder.appending(path: "run.json"))
        try ReviewRuns.setStatus(stage, message: stage == .failed ? "Pi wasn't found." : nil, folder: folder)
        home.write(".akit/local/review/runs/\(id)/requests.json", """
        {"created": "2026-11-20T10:00:00Z", "findingsVersion": 1, "placements": [], "requests": [\(requests)]}
        """)
    }

    @Test func pendingCommentsAreAReadyReviewAndAFailedSendIsAProblem() throws {
        let home = AttentionHome()
        let pending = #"{"id": "r1", "kind": "create", "proposed": "Round half up", "decision": "pending", "movedByUser": false}"#
        let failed = #"{"id": "r2", "kind": "create", "proposed": "x", "decision": "approved", "movedByUser": false, "sent": {"date": "2026-11-20T10:00:00Z", "error": "403"}}"#
        try run(home, id: "20261120-100000-orders-12", iid: 12, stage: .planned, requests: pending)
        try run(home, id: "20261120-110000-orders-13", iid: 13, stage: .planned, requests: [pending, failed].joined(separator: ","))
        try run(home, id: "20261120-120000-orders-14", iid: 14, stage: .failed, requests: "")
        let found = items(home).filter { $0.source == .review }
        #expect(found.map(\.level) == [.problem, .problem, .ready])
        #expect(found.map(\.title).contains("Comments not sent: Fix the refund rounding"))
        #expect(found.map(\.title).contains("Review failed: Fix the refund rounding"))
        #expect(found[2].title == "Code review ready: Fix the refund rounding")
        #expect(found[2].detail == "1 comment waits for your approval · team/orders!12")
        #expect(found[2].link.url.absoluteString == "akit://review?item=20261120-100000-orders-12")
    }

    @Test func aRerunReplacesTheRunBeforeIt() throws {
        let home = AttentionHome()
        let pending = #"{"id": "r1", "kind": "create", "proposed": "Round half up", "decision": "pending", "movedByUser": false}"#
        try run(home, id: "20261120-090000-orders-12", iid: 12, age: 3600, stage: .planned, requests: pending)
        try run(home, id: "20261120-100000-orders-12", iid: 12, stage: .planned, requests: "")
        #expect(items(home).isEmpty, "the latest run has nothing waiting")
    }
}

struct AttentionStateTests {
    @Test func mcpServersThatDidNotConnect() throws {
        let home = AttentionHome()
        try MCPCheckStore.save([
            MCPCheckResult(harness: .claudeCode, name: "github", folder: home.url.appending(path: "Projects/app").path, state: .failed,
                           detail: "spawn npx ENOENT", checkedAt: .now),
            MCPCheckResult(harness: .pi, name: "jira", folder: home.url.path, state: .needsSignIn, checkedAt: .now),
            MCPCheckResult(harness: .pi, name: "docs", folder: home.url.path, state: .connected, checkedAt: .now),
        ], home: home.url)
        let found = items(home)
        #expect(found.map(\.title) == ["MCP server github: Failed", "MCP server jira: Needs Sign-In"])
        #expect(found[0].detail == "Claude in ~/Projects/app. spawn npx ENOENT")
        #expect(found[1].level == .check)
    }

    @Test func proposalsInAKnowledgeInbox() {
        let home = AttentionHome()
        home.write(".akit/local/knowledge/work/areas/payments/orders.md", "# Orders\n")
        home.write(".akit/local/knowledge/work/.git/HEAD", "ref: refs/heads/main\n")
        home.write(".akit/local/knowledge/work/inbox/orders-retry.md", "---\nkind: note\n---\n")
        home.write(".akit/local/knowledge/work/inbox/orders-map.md", "---\nkind: map\n---\n")
        let found = items(home)
        #expect(found.count == 1)
        #expect(found[0].title == "2 proposals in the Knowledge Inbox")
        #expect(found[0].link.tab == "inbox")
    }
}

struct AttentionDismissalTests {
    @Test func aDismissedItemReturnsWhenItChanges() throws {
        let home = AttentionHome()
        try home.labRun("r1", kind: .replay, title: "Replay", status: .error, message: "first")
        let first = items(home)
        try AttentionDismissals.dismiss(first, current: first, home: home.url)
        #expect(first.allSatisfy(AttentionDismissals.load(home: home.url).hides))

        // The run fails again later: a new fingerprint.
        let run = LabPaths(env: home.env).run("r1")
        try LabStore.encoder.encode(RunState(status: .error, updatedAt: .now.addingTimeInterval(5), message: "second"))
            .write(to: run.appending(path: "state.json"))
        #expect(!items(home).contains(where: AttentionDismissals.load(home: home.url).hides))

        try AttentionDismissals.restore(first.map(\.id), home: home.url)
        #expect(AttentionDismissals.load(home: home.url).items.isEmpty)
    }

    @Test func dismissingDropsEntriesOfItemsNoLongerShown() throws {
        let home = AttentionHome()
        let link = AttentionLink(screen: "lab")
        let gone = AttentionItem(id: "gone", level: .ready, source: .lab, title: "t", detail: "", date: nil, link: link, fingerprint: "1")
        let kept = AttentionItem(id: "kept", level: .ready, source: .lab, title: "t", detail: "", date: nil, link: link, fingerprint: "1")
        try AttentionDismissals.dismiss([gone], current: [gone], home: home.url)
        try AttentionDismissals.dismiss([kept], current: [kept], home: home.url)
        #expect(AttentionDismissals.load(home: home.url).items == ["kept": "1"])
    }
}

struct AttentionLinkTests {
    @Test func aLinkRoundTripsThroughItsURL() {
        let link = AttentionLink(screen: "runs", item: "20261120-1", folder: "/Users/me/Projects/my app")
        #expect(link.url.absoluteString == "akit://runs?item=20261120-1&folder=/Users/me/Projects/my%20app")
        #expect(AttentionLink(url: link.url) == link)
        #expect(AttentionLink(url: URL(string: "akit://Analysis?tab=evals&item=swiftui")!) == AttentionLink(screen: "analysis", tab: "evals", item: "swiftui"))
        #expect(AttentionLink(url: URL(string: "https://example.com")!) == nil)
    }

    @Test func problemsComeFirstThenTheNewest() {
        let link = AttentionLink(screen: "lab")
        func item(_ id: String, _ level: AttentionItem.Level, _ age: Double?) -> AttentionItem {
            AttentionItem(id: id, level: level, source: .lab, title: id, detail: "", date: age.map { .now.addingTimeInterval(-$0) },
                          link: link, fingerprint: "")
        }
        let sorted = Attention.sorted([item("ready", .ready, 1), item("old", .problem, 100), item("new", .problem, 1), item("look", .check, nil)])
        #expect(sorted.map(\.id) == ["new", "old", "look", "ready"])
    }
}
