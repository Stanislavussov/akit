import Foundation
import Testing
import AKitFoundation
@testable import AKitErrorAnalysis

/// The modes list in its own git repository, with the real `git` inside a temporary home.
struct ModeStoreTests {
    let home: URL
    let fm = FileManager.default

    init() throws {
        home = fm.temporaryDirectory.appending(path: "akit-modes-\(UUID().uuidString)")
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
    }

    var env: HarnessEnvironment {
        HarnessEnvironment(homeDirectory: home, variables: ["HOME": home.path], executableSearchPaths: [URL(filePath: "/usr/bin")])
    }

    var store: ModeStore { ModeStore(env: env) }
    var folder: URL { AnalysisPaths(env: env).folder }

    func git(_ arguments: String...) async throws -> String {
        let result = try #require(await ProcessRunner.run(URL(filePath: "/usr/bin/git"), arguments: ["-C", folder.path] + arguments,
                                                           environment: env.gitVariables, timeout: 30))
        #expect(result.succeeded, "git \(arguments): \(result.output)")
        return result.output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func commits() async throws -> Int { Int(try await git("rev-list", "--count", "HEAD")) ?? -1 }

    func mode(_ id: String, kind: Mode.Kind = .failure) -> Mode {
        Mode(id: id, name: "Name of \(id)", kind: kind, definition: "What \(id) means.", include: ["in"], exclude: ["out"])
    }

    @Test func theRepositoryTracksModesOnly() async throws {
        _ = try await store.list()
        let ignore = try String(contentsOf: folder.appending(path: ".gitignore"), encoding: .utf8)
        #expect(ignore == "/*\n!/modes/\n!/.gitignore\n")
        try fm.createDirectory(at: folder.appending(path: "notes"), withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: folder.appending(path: "notes/claude_x.json"))
        try UnclearNotes(env: env).add(.init(sessionKey: "claude:x", noteID: "n1", text: "?"))
        #expect(try await git("status", "--porcelain") == "")
        #expect(try await git("ls-files") == ".gitignore\nmodes/modes.json")
    }

    @Test func seedsAreInstalledOnce() async throws {
        let modes = try await store.list()
        #expect(modes.map(\.id) == ["false-premise", "intent-misread", "large-file-read-whole", "long-session-not-reset",
                                    "overclaiming-completion", "repeated-steps", "scope-overreach", "user-constraint-violated",
                                    "weakening-tests"])
        #expect(modes.allSatisfy { $0.status == .seedInactive && $0.version == 1 && !$0.include.isEmpty && !$0.exclude.isEmpty })
        #expect(modes.filter { $0.origin == .seedPrior }.map(\.id) == ["large-file-read-whole", "long-session-not-reset"])
        #expect(modes.filter { $0.kind == .efficiency }.count == 2)
        #expect(ModeStore.seeds.first?.name == "Overclaiming completion")
        #expect(try await commits() == 2)
        #expect(try await store.history(limit: 5).map(\.message) == ["Add seed modes", "Start the modes repository"])

        // A rejected or merged seed stays as it is; a new store doesn't add it again.
        try await store.reject("scope-overreach", reason: "too broad")
        try await store.merge(["repeated-steps"], into: "false-premise")
        let again = try await ModeStore(env: env).list()
        #expect(again.count == 9)
        #expect(again.first { $0.id == "scope-overreach" }?.status == .rejected)
        #expect(again.first { $0.id == "repeated-steps" }?.mergedInto == "false-premise")
        #expect(try await commits() == 4)
    }

    /// One more commit than `count`, with `message` when given.
    func expectCommit(after count: inout Int, _ message: String? = nil) async throws {
        count += 1
        #expect(try await commits() == count)
        if let message { #expect(try await store.history(limit: 1).first?.message == message) }
    }

    @Test func everyChangeIsACommit() async throws {
        _ = try await store.list()
        var count = try await commits()
        try await store.create(mode("a"))
        try await expectCommit(after: &count, "Add mode a: \"Name of a\"")
        try await store.rename("a", to: "Full read of a 34 KB file")
        try await expectCommit(after: &count, "Rename mode a: \"Name of a\" → \"Full read of a 34 KB file\"")
        try await store.edit("a", definition: "New meaning.")
        try await expectCommit(after: &count, "Edit mode a: definition (v2)")
        try await store.setScope("a", .project("akit"))
        try await expectCommit(after: &count, "Set scope of mode a: general → project:akit")
        try await store.create(mode("b"))
        try await expectCommit(after: &count)
        try await store.merge(["b"], into: "a")
        try await expectCommit(after: &count, "Merge modes b into a (v3)")
        try await store.split("a", into: [mode("c"), mode("d")])
        try await expectCommit(after: &count, "Split mode a into c, d")
        try await store.reject("c", reason: "not a pattern")
        try await expectCommit(after: &count, "Reject mode c: not a pattern")
        try await store.restore("c")
        try await expectCommit(after: &count, "Restore mode c")
        try await store.confirm("c")
        try await expectCommit(after: &count, "Confirm mode c")
        try await store.recordBatchMatch("c", runID: "run-1")
        try await expectCommit(after: &count)
        try await store.setFix("c", .draft)
        try await expectCommit(after: &count, "Set fix of mode c: draft")
        let exemplar = Exemplar(modeID: "c", sessionKey: "claude:s1", step: 4, quote: "cat big.json")
        try await store.addExemplar(exemplar, testSessions: [])
        try await expectCommit(after: &count, "Add exemplar to mode c: claude:s1 #4")
        try await store.removeExemplar(exemplar)
        try await expectCommit(after: &count)

        // No change, no commit.
        try await store.rename("c", to: "Name of c")
        try await store.setScope("c", .general)
        try await store.recordBatchMatch("c", runID: "run-1")
        #expect(try await commits() == count)
        #expect(try await git("status", "--porcelain") == "")
    }

    @Test func renameKeepsTheIDAndEditBumpsTheVersion() async throws {
        try await store.create(mode("a"))
        let renamed = try await store.rename("a", to: "Another name")
        #expect(renamed.id == "a" && renamed.version == 1)
        await #expect(throws: ModeStore.Failure.self) { try await store.rename("a", to: " ") }
        await #expect(throws: ModeStore.Failure.self) { try await store.create(mode("a")) }
        await #expect(throws: ModeStore.Failure.self) { try await store.create(mode("Not A Slug")) }

        let edited = try await store.edit("a", include: ["one", "two"], kind: .efficiency)
        #expect(edited.modes.first?.version == 2)
        #expect(edited.invalidations == [Invalidation(modeID: "a", version: 2, reason: "edited include, kind")])
        let layerOnly = try await store.edit("a", faultLayer: .harness)
        #expect(layerOnly.modes.first?.version == 2 && layerOnly.modes.first?.faultLayer == .harness)
        #expect(layerOnly.invalidations.isEmpty)
        let stored = try #require(try await store.mode("a"))
        #expect(stored.include == ["one", "two"] && stored.kind == .efficiency && stored.version == 2)
    }

    @Test func emergentModesStartAsCandidates() async throws {
        var proposed = mode("a")
        proposed.status = .active
        #expect(try await store.create(proposed).status == .candidate)
        let confirmed = try await store.confirm("a", at: Date(timeIntervalSince1970: 1_000))
        #expect(confirmed.status == .active && confirmed.confirmedAt == Date(timeIntervalSince1970: 1_000))
        await #expect(throws: ModeStore.Failure.self) { try await store.confirm("a") }
        let seed = try await store.confirm("intent-misread")
        #expect(seed.status == .active)
    }

    @Test func mergeSetsMergedIntoAndResolveFollowsIt() async throws {
        for id in ["a", "b", "c"] { try await store.create(mode(id)) }
        let change = try await store.merge(["a"], into: "b")
        #expect(change.modes.map(\.id) == ["b", "a"])
        #expect(change.modes[0].version == 2 && change.invalidations.map(\.modeID) == ["b"])
        try await store.merge(["b"], into: "c")
        let modes = try await store.list()
        #expect(modes.first { $0.id == "a" }?.mergedInto == "b")
        #expect(!modes.contains { ["a", "b"].contains($0.id) && $0.isCurrent })
        #expect(try await store.resolve("a") == "c")
        #expect(try await store.resolve("c") == "c")
        #expect(try await store.resolve("unknown") == "unknown")
        await #expect(throws: ModeStore.Failure.self) { try await store.merge(["c"], into: "a") }
        await #expect(throws: ModeStore.Failure.self) { try await store.merge(["c"], into: "c") }

        // A cycle can't come from merge, but a hand-edited file mustn't hang resolve.
        var cycle = [mode("x"), mode("y")]
        cycle[0].mergedInto = "y"
        cycle[1].mergedInto = "x"
        #expect(ModeStore.resolve("x", in: cycle) == "y")
    }

    @Test func splitMakesNewModesAndRejectsTheOld() async throws {
        try await store.split("overclaiming-completion", into: [mode("done-without-check"), mode("error-left-out")])
        let modes = try await store.list()
        let old = try #require(modes.first { $0.id == "overclaiming-completion" })
        #expect(old.status == .rejected && old.rejectedReason == "split into done-without-check, error-left-out")
        #expect(old.version == 2 && old.mergedInto == nil)
        let parts = modes.filter { ["done-without-check", "error-left-out"].contains($0.id) }
        #expect(parts.count == 2 && parts.allSatisfy { $0.version == 1 && $0.origin == .seedLiterature })
        await #expect(throws: ModeStore.Failure.self) { try await store.split("false-premise", into: [mode("only-one")]) }
    }

    @Test func rejectKeepsTheReasonAndRestoreBringsItBack() async throws {
        try await store.create(mode("a"))
        try await store.confirm("a")
        let rejected = try await store.reject("a", reason: "the same as false-premise")
        #expect(rejected.status == .rejected && rejected.rejectedReason == "the same as false-premise")
        #expect(try await store.rejectedNames() == ["Name of a"])
        await #expect(throws: ModeStore.Failure.self) { try await store.reject("b", reason: "x") }
        await #expect(throws: ModeStore.Failure.self) { try await store.reject("intent-misread", reason: "  ") }

        let restored = try await store.restore("a")
        #expect(restored.status == .active && restored.rejectedReason == nil)
        try await store.reject("weakening-tests", reason: "never seen")
        #expect(try await store.restore("weakening-tests").status == .seedInactive)
        #expect(try await store.rejectedNames().isEmpty)
        await #expect(throws: ModeStore.Failure.self) { try await store.restore("a") }
    }

    @Test func aSeedActivatesAfterTwoDistinctBatchRuns() async throws {
        #expect(try await store.recordBatchMatch("repeated-steps", runID: "run-1").status == .seedInactive)
        #expect(try await store.recordBatchMatch("repeated-steps", runID: "run-1").status == .seedInactive)
        let active = try await store.recordBatchMatch("repeated-steps", runID: "run-2")
        #expect(active.status == .active && active.batchMatches == ["run-1", "run-2"] && active.confirmedAt == nil)
    }

    @Test func exemplarsSkipTestSessionsAndStopAtThree() async throws {
        let exemplar = { (session: String) in Exemplar(modeID: "false-premise", sessionKey: session, step: 3, quote: "q", noteID: "n1") }
        await #expect(throws: ModeStore.Failure.self) {
            try await store.addExemplar(exemplar("claude:test"), testSessions: ["claude:test"])
        }
        for session in ["claude:1", "claude:2", "claude:3"] { try await store.addExemplar(exemplar(session), testSessions: ["claude:test"]) }
        await #expect(throws: ModeStore.Failure.self) { try await store.addExemplar(exemplar("claude:4"), testSessions: []) }
        await #expect(throws: ModeStore.Failure.self) {
            try await store.addExemplar(Exemplar(modeID: "nope", sessionKey: "claude:5", step: 1, quote: "q"), testSessions: [])
        }
        #expect(try store.exemplars(of: "false-premise").map(\.sessionKey) == ["claude:1", "claude:2", "claude:3"])
        #expect(try await git("ls-files", "modes/exemplars") == "modes/exemplars/false-premise.json")

        let left = try await store.removeExemplar(exemplar("claude:1"))
        #expect(left.map(\.sessionKey) == ["claude:2", "claude:3"])
        try await store.addExemplar(exemplar("claude:4"), testSessions: [])
        #expect(try store.exemplars(of: "false-premise").count == 3)
    }

    @Test func fixesApplyToFailureAndEfficiencyModesOnly() async throws {
        try await store.create(mode("context-first", kind: .success))
        await #expect(throws: ModeStore.Failure.self) { try await store.setFix("context-first", .draft) }
        let t = Date(timeIntervalSince1970: 2_000)
        let applied = try await store.setFix("large-file-read-whole", .applied, at: t)
        #expect(applied.fix == .applied && applied.fixAppliedAt == t)
        await #expect(throws: ModeStore.Failure.self) { try await store.setFix("large-file-read-whole", .rejected) }
        let rejected = try await store.setFix("large-file-read-whole", .rejected, reason: "made it worse")
        #expect(rejected.fix == .rejected && rejected.fixReason == "made it worse" && rejected.fixAppliedAt == t)
    }

    @Test func theUnclearBucketRoundTrips() throws {
        let bucket = UnclearNotes(env: env)
        #expect(bucket.all().isEmpty)
        try bucket.add(.init(sessionKey: "claude:a", noteID: "n1", text: "odd pause"))
        try bucket.add(.init(sessionKey: "claude:a", noteID: "n1", text: "again"))
        try bucket.add(.init(sessionKey: "pi:b", noteID: "h2", text: "unclear"))
        #expect(UnclearNotes(env: env).all().map(\.text) == ["odd pause", "unclear"])
        #expect(try bucket.remove(sessionKey: "claude:a", noteID: "n1").map(\.noteID) == ["h2"])
        #expect(fm.fileExists(atPath: AnalysisPaths(env: env).labels.appending(path: "unclear.json").path))
    }

    @Test func gitIdentityIsLocalToTheRepository() async throws {
        try await store.create(mode("a"))
        #expect(try await git("config", "--local", "user.name") == "AKit")
        #expect(try await git("config", "--local", "user.email") == "akit@localhost")
        #expect(try await git("log", "-1", "--format=%an <%ae> / %cn <%ce>") == "AKit <akit@localhost> / AKit <akit@localhost>")
        // HOME is the fake home: nothing was written to a global config.
        #expect(!fm.fileExists(atPath: home.appending(path: ".gitconfig").path))
        #expect(!fm.fileExists(atPath: home.appending(path: ".config/git").path))
    }

    @Test func scopesAndStatusesCodeAsStrings() throws {
        var value = mode("a")
        value.scope = .project("akit")
        value.fix = .didntHelp
        value.createdAt = Date(timeIntervalSince1970: 0)
        let text = String(decoding: try AnalysisJSON.encoder.encode(value), as: UTF8.self)
        #expect(text.contains("\"scope\" : \"project:akit\"") && text.contains("\"didnt-help\"") && text.contains("\"candidate\""))
        #expect(try AnalysisJSON.decoder.decode(Mode.self, from: Data(text.utf8)) == value)
        #expect(throws: (any Error).self) { try Mode.Scope(parsing: "team:x") }
        #expect(Mode.Status.seedInactive.title == "seed, inactive")
    }
}
