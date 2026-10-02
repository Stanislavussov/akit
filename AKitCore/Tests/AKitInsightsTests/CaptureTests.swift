import Foundation
import Testing
import AKitBrain
@testable import AKitCommandLine
@testable import AKitInsights
@testable import AKitProjectSetup
@testable import AKitFoundation

/// Session capture: the spool, `akit record-session`, apply events and their import. A
/// temporary fake home; the real ~/.akit, ~/.claude and ~/.pi are never touched.
struct CaptureTests {
    let home: URL
    let fm = FileManager.default

    init() throws {
        home = fm.temporaryDirectory.appending(path: "akit-capture-\(UUID().uuidString)")
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
    }

    var env: HarnessEnvironment {
        HarnessEnvironment(homeDirectory: home, variables: [
            "HOME": home.path, "GIT_CONFIG_NOSYSTEM": "1",
            "GIT_AUTHOR_NAME": "Test", "GIT_AUTHOR_EMAIL": "test@example.com",
            "GIT_COMMITTER_NAME": "Test", "GIT_COMMITTER_EMAIL": "test@example.com",
        ], executableSearchPaths: [URL(filePath: "/usr/bin")])
    }

    var paths: InsightsPaths { InsightsPaths(home: home) }

    /// 2026-09-20 00:00 UTC plus `days` and `hours`.
    static func day(_ days: Double, hours: Double = 10) -> Date {
        Date(timeIntervalSince1970: 1_789_862_400 + days * 86_400 + hours * 3_600)
    }

    func spoolFile(_ date: Date) -> URL { paths.spool.appending(path: Spool.fileName(for: date)) }

    func spoolLines(_ date: Date) throws -> [[String: Any]] {
        try String(contentsOf: spoolFile(date), encoding: .utf8).split(separator: "\n").map {
            try #require(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])
        }
    }

    func write(_ path: String, _ text: String) throws {
        let url = home.appending(path: path)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    func database() throws -> IndexDatabase { try IndexSchema.open(paths.database) }

    @discardableResult
    func runImport(_ importer: SessionImporter? = nil, now: Date, database: IndexDatabase? = nil) throws -> ImportReport {
        try (importer ?? SessionImporter(env: env)).run(database: try database ?? self.database(), now: now)
    }

    func count(_ sql: String, _ values: any SQLBindable...) throws -> Int {
        try database().rows(sql, values).first?.first?.int ?? 0
    }

    func sessionStart(_ id: String, at date: Date) {
        RecordSession.run(harness: "claude", stdin: Data(#"{"session_id":"\#(id)","cwd":"/work/app","source":"startup"}"#.utf8),
                          env: env, now: date)
    }

    // MARK: The akit binary

    /// The `akit` executable SwiftPM built next to the test bundle.
    static let akitBinary: URL? = {
        let fm = FileManager.default
        for bundle in Bundle.allBundles where bundle.bundlePath.hasSuffix(".xctest") {
            let candidate = bundle.bundleURL.deletingLastPathComponent().appending(path: "akit")
            if fm.isExecutableFile(atPath: candidate.path) { return candidate }
        }
        let package = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let debug = package.appending(path: ".build/debug/akit")
        return fm.isExecutableFile(atPath: debug.path) ? debug : nil
    }()

    /// Runs `akit record-session` as its own process with `input` on stdin and HOME = the
    /// fake home; the shell only pipes the input. Returns exit status and all output.
    func recordSessionProcess(_ input: String, home: URL? = nil) async throws -> ProcessRunner.Result {
        try await Self.recordSessionProcess(input, home: home ?? self.home)
    }

    static func recordSessionProcess(_ input: String, home: URL) async throws -> ProcessRunner.Result {
        let akit = try #require(akitBinary, "build the akit product first (swift build)")
        let result = await ProcessRunner.run(URL(filePath: "/bin/sh"),
                                             arguments: ["-c", #"printf '%s' "$AKIT_INPUT" | "$AKIT_BIN" record-session --harness claude"#],
                                             environment: ["HOME": home.path, "AKIT_INPUT": input, "AKIT_BIN": akit.path,
                                                           "PATH": "/usr/bin:/bin"],
                                             timeout: 20)
        return try #require(result)
    }

    // MARK: record-session

    @Test func recordSessionWritesOneLineAndNothingToStdout() async throws {
        let result = try await recordSessionProcess(#"{"session_id":"s1","cwd":"/work/app","transcript_path":"/t/s1.jsonl","source":"startup"}"#)
        #expect(result.succeeded && result.output.isEmpty, "\(result)")
        let files = try fm.contentsOfDirectory(atPath: paths.spool.path)
        #expect(files.count == 1 && files[0].hasSuffix(".jsonl"))
        let text = try String(contentsOf: paths.spool.appending(path: files[0]), encoding: .utf8)
        #expect(text.hasSuffix("\n") && text.filter { $0 == "\n" }.count == 1)
        let line = try #require(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        #expect(line["kind"] as? String == "session_start" && line["harness"] as? String == "claude")
        #expect(line["session_id"] as? String == "s1" && line["cwd"] as? String == "/work/app")
        #expect(line["transcript"] as? String == "/t/s1.jsonl" && line["source"] as? String == "startup")
        #expect(line["v"] as? Int == 1 && (line["ts"] as? Int ?? 0) > 1_700_000_000_000)
        let mode = try fm.attributesOfItem(atPath: paths.spool.appending(path: files[0]).path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
    }

    @Test func recordSessionAlwaysExitsZeroOnGarbageStdin() async throws {
        for input in ["", "not json", "[1,2]", #"{"cwd":"/work"}"#, #"{"session_id":42}"#, String(repeating: "{", count: 100_000)] {
            let result = try await recordSessionProcess(input)
            #expect(result.succeeded && result.output.isEmpty, "\(input.prefix(20)): \(result)")
        }
        #expect(!fm.fileExists(atPath: paths.spool.path))
        // A home it can't write to: still silent, still 0.
        let file = home.appending(path: "not-a-folder")
        try Data("x".utf8).write(to: file)
        let result = try await recordSessionProcess(#"{"session_id":"s1"}"#, home: file)
        #expect(result.succeeded && result.output.isEmpty, "\(result)")
    }

    @Test func resolvesWorktreeGitdirAndMainRemoteWithoutGit() throws {
        try write("repos/main/.git/config", """
            [core]
            \tbare = false
            [remote "upstream"]
            \turl = git@github.com:Other/Fork.git
            [remote "origin"]
            \turl = git@github.com:Owner/Repo.git
            \tfetch = +refs/heads/*:refs/remotes/origin/*
            """)
        try write("repos/main/.git/HEAD", "ref: refs/heads/main\n")
        try write("repos/main/.git/worktrees/feature/HEAD", "ref: refs/heads/feature-x\n")
        try write("repos/main/.git/worktrees/feature/commondir", "../..\n")
        try write("wt/feature/.git", "gitdir: ../../repos/main/.git/worktrees/feature\n")
        try fm.createDirectory(at: home.appending(path: "wt/feature/src/deep"), withIntermediateDirectories: true)
        let root = home.resolvingSymlinksInPath().path

        let worktree = try #require(RecordSession.repository(containing: root + "/wt/feature/src/deep"))
        #expect(worktree.gitdir == root + "/repos/main/.git/worktrees/feature")
        #expect(worktree.commonDir == root + "/repos/main/.git")
        #expect(worktree.remoteID == "github.com/owner/repo" && worktree.branch == "feature-x")
        let main = try #require(RecordSession.repository(containing: root + "/repos/main"))
        #expect(main.gitdir == main.commonDir && main.remoteID == "github.com/owner/repo" && main.branch == "main")
        #expect(RecordSession.repository(containing: "relative/path") == nil)
        // Detached HEAD: no branch.
        try write("repos/main/.git/HEAD", "0123456789abcdef0123456789abcdef01234567\n")
        #expect(RecordSession.repository(containing: root + "/repos/main")?.branch == nil)

        // Through the hook, with no executables at all: the same facts land in the line.
        let noTools = HarnessEnvironment(homeDirectory: home, executableSearchPaths: [])
        RecordSession.run(harness: "claude", stdin: Data(#"{"session_id":"w1","cwd":"\#(root)/wt/feature/src"}"#.utf8),
                          env: noTools, now: Self.day(0))
        let line = try #require(try spoolLines(Self.day(0)).first)
        #expect(line["remote_id"] as? String == "github.com/owner/repo" && line["branch"] as? String == "feature-x")
        #expect(line["common_dir"] as? String == root + "/repos/main/.git")
    }

    @Test func resolvesHeadFromGitFilesWithoutGit() throws {
        let commit = "0123456789abcdef0123456789abcdef01234567"
        let other = "89abcdef0123456789abcdef0123456789abcdef"
        try write("repos/main/.git/config", "[core]\n")
        try write("repos/main/.git/worktrees/feature/commondir", "../..\n")
        try write("wt/feature/.git", "gitdir: ../../repos/main/.git/worktrees/feature\n")
        let root = home.resolvingSymlinksInPath().path
        func head(_ folder: String) -> String? { RecordSession.repository(containing: root + "/" + folder)?.head }

        // Detached: the sha itself (any case, trimmed).
        try write("repos/main/.git/HEAD", commit.uppercased() + "\n")
        #expect(head("repos/main") == commit)
        // A sha256 repository's 64 digits.
        try write("repos/main/.git/HEAD", String(repeating: "ab", count: 32) + "\n")
        #expect(head("repos/main") == String(repeating: "ab", count: 32))

        // A branch: unborn (no ref anywhere) → no head, but the branch.
        try write("repos/main/.git/HEAD", "ref: refs/heads/main\n")
        #expect(head("repos/main") == nil && RecordSession.repository(containing: root + "/repos/main")?.branch == "main")
        // Packed only; header, peeled and other refs' lines don't match.
        try write("repos/main/.git/packed-refs", """
            # pack-refs with: peeled fully-peeled sorted\u{20}
            \(other) refs/heads/main-old
            \(commit) refs/heads/main
            ^\(other)
            \(other) refs/tags/v1

            """)
        #expect(head("repos/main") == commit)
        // A loose ref wins over its packed line.
        try write("repos/main/.git/refs/heads/main", other + "\n")
        #expect(head("repos/main") == other)

        // A worktree's branch lives in the common dir only.
        try write("repos/main/.git/worktrees/feature/HEAD", "ref: refs/heads/feature-x\n")
        #expect(head("wt/feature") == nil)
        try write("repos/main/.git/refs/heads/feature-x", commit + "\n")
        #expect(head("wt/feature") == commit)
        // A per-worktree ref in its own gitdir comes first.
        try write("repos/main/.git/worktrees/feature/HEAD", "ref: refs/bisect/bad\n")
        try write("repos/main/.git/worktrees/feature/refs/bisect/bad", other + "\n")
        try write("repos/main/.git/refs/bisect/bad", commit + "\n")
        #expect(head("wt/feature") == other)

        // Garbage: short, non-hex, non-ASCII digits, refs outside refs/, a broken loose ref.
        for text in ["0123456789abcdef", String(commit.dropLast()) + "g", String(repeating: "\u{FF10}", count: 40),
                     "ref: ../../../etc/passwd", "ref: refs/../../config", "ref:", "", "ref: refs/heads/broken"] {
            try write("repos/main/.git/HEAD", text + "\n")
            try write("repos/main/.git/refs/heads/broken", "not a sha\n")
            #expect(head("repos/main") == nil, "\(text)")
        }

        // Through the hook: the head lands in the spool line.
        try write("repos/main/.git/HEAD", commit + "\n")
        RecordSession.run(harness: "claude", stdin: Data(#"{"session_id":"h1","cwd":"\#(root)/repos/main"}"#.utf8),
                          env: env, now: Self.day(0))
        RecordSession.run(harness: "claude", stdin: Data(#"{"session_id":"h2","cwd":"/nowhere"}"#.utf8),
                          env: env, now: Self.day(0))
        let lines = try spoolLines(Self.day(0))
        #expect(lines.count == 2 && lines[0]["head"] as? String == commit && lines[1]["head"] == nil)
    }

    @Test func importedHeadIsTheFirstRecordedForTheSession() throws {
        let first = "0123456789abcdef0123456789abcdef01234567"
        let later = "89abcdef0123456789abcdef0123456789abcdef"
        func start(_ id: String, head: String?, at date: Date) {
            var line: [String: Any] = ["v": 1, "kind": "session_start", "harness": "claude", "session_id": id,
                                       "ts": Spool.milliseconds(date)]
            line["head"] = head
            Spool.append(line, home: home, now: date)
        }
        // No index yet: nil, and none is created.
        #expect(IndexQueries.sessionHead(harness: "claude", sessionID: "s1", env: env) == nil)
        #expect(!fm.fileExists(atPath: paths.database.path))

        start("s1", head: nil, at: Self.day(0, hours: 9))
        start("s1", head: first, at: Self.day(0, hours: 10))
        // Resumed later at a newer commit: the start's commit stays.
        start("s1", head: later, at: Self.day(0, hours: 12))
        start("s2", head: nil, at: Self.day(0, hours: 11))
        try runImport(now: Self.day(0, hours: 13))

        let db = try database()
        #expect(try count("SELECT COUNT(*) FROM hook_events WHERE head IS NOT NULL") == 2)
        #expect(try IndexQueries.head(db, harness: "claude", sessionID: "s1") == first)
        #expect(try IndexQueries.head(db, harness: "pi", sessionID: "s1") == nil)
        #expect(try IndexQueries.head(db, harness: "claude", sessionID: "s2") == nil)
        #expect(IndexQueries.sessionHead(harness: "claude", sessionID: "s1", env: env) == first)
        #expect(IndexQueries.sessionHead(harness: "claude", sessionID: "unknown", env: env) == nil)
    }

    @Test func overlongLineDropsTranscriptAndCwd() throws {
        let long = "/" + String(repeating: "a", count: 5_000)
        RecordSession.run(harness: "pi", stdin: Data(#"{"cwd":"\#(long)","transcript_path":"/s/2026-09-20T10-00-00-000Z_abc123.jsonl"}"#.utf8),
                          env: env, now: Self.day(0))
        let line = try #require(try spoolLines(Self.day(0)).first)
        #expect(line["session_id"] as? String == "abc123" && line["harness"] as? String == "pi")
        #expect(line["cwd"] == nil && line["transcript"] == nil)
    }

    /// 50 separate `akit record-session` processes (at most 16 at once) append ~3 KB lines to
    /// one day file with no lock; every line must come out whole.
    @Test func parallelAppendsDontInterleave() async throws {
        let padding = String(repeating: "x", count: 1_400)
        let home = self.home
        let results = await withTaskGroup(of: ProcessRunner.Result?.self) { group in
            var collected: [ProcessRunner.Result?] = []
            for index in 0..<50 {
                if index >= 16, let next = await group.next() { collected.append(next) }
                let input = #"{"session_id":"p\#(index)","cwd":"/nowhere/\#(padding)\#(index)","transcript_path":"/t/\#(padding)\#(index).jsonl"}"#
                group.addTask { try? await Self.recordSessionProcess(input, home: home) }
            }
            for await result in group { collected.append(result) }
            return collected
        }
        #expect(results.count == 50 && results.allSatisfy { $0?.succeeded == true && $0?.output.isEmpty == true })
        let files = try fm.contentsOfDirectory(atPath: paths.spool.path)
        // A run across UTC midnight may split the lines over two days.
        var ids: [String] = []
        for file in files {
            let text = try String(contentsOf: paths.spool.appending(path: file), encoding: .utf8)
            #expect(text.hasSuffix("\n"))
            for raw in text.split(separator: "\n", omittingEmptySubsequences: false).dropLast() {
                let line = try #require(JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any], "broken line")
                #expect(raw.utf8.count > 2_800 && raw.utf8.count < Spool.maxLine)
                ids.append(try #require(line["session_id"] as? String))
            }
        }
        #expect(ids.count == 50 && Set(ids) == Set((0..<50).map { "p\($0)" }))
    }

    // MARK: Spool import

    @Test func spoolOffsetSurvivesCrashBetweenReadAndCommit() throws {
        for index in 0..<3 { sessionStart("c\(index)", at: Self.day(0, hours: 10 + Double(index))) }
        let db = try database()
        // The importer reads every line, then dies when it stores the offset.
        try db.execute("CREATE TEMP TRIGGER crash BEFORE UPDATE OF offset ON sources BEGIN SELECT RAISE(ABORT, 'crash'); END")
        let crashed = try runImport(now: Self.day(0, hours: 20), database: db)
        #expect(crashed.skipped.count == 1)
        #expect(try db.value("SELECT COUNT(*) FROM hook_events")?.int == 0)
        #expect(try db.value("SELECT COUNT(*) FROM sources")?.int == 0)

        try db.execute("DROP TRIGGER crash")
        let report = try runImport(now: Self.day(0, hours: 20), database: db)
        #expect(report.spoolLines == 3 && report.skipped.isEmpty)
        sessionStart("c3", at: Self.day(0, hours: 21))
        try runImport(now: Self.day(0, hours: 22), database: db)
        try runImport(now: Self.day(0, hours: 23), database: db)
        #expect(try count("SELECT COUNT(*) FROM hook_events") == 4)
        #expect(try count("SELECT COUNT(DISTINCT session_id) FROM hook_events") == 4)
        let size = try #require(try fm.attributesOfItem(atPath: spoolFile(Self.day(0)).path)[.size] as? Int)
        #expect(try count("SELECT offset FROM sources WHERE kind = 'spool'") == size)
    }

    @Test func spoolFileDeletedOnlyWhenFullyReadAndTwoDaysOld() throws {
        sessionStart("d1", at: Self.day(0))
        let file = spoolFile(Self.day(0))
        try runImport(now: Self.day(1, hours: 23))
        #expect(fm.fileExists(atPath: file.path))

        // Two days on, but a line is still being written: kept.
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(#"{"v":1,"kind":"session_start","harness":"claude","session_id":"d2","ts":1789900000000"#.utf8))
        try runImport(now: Self.day(2, hours: 0.01))
        #expect(fm.fileExists(atPath: file.path))
        #expect(try count("SELECT COUNT(*) FROM hook_events") == 1)

        try handle.write(contentsOf: Data("}\n".utf8))
        try handle.close()
        try runImport(now: Self.day(2, hours: 0.01))
        #expect(!fm.fileExists(atPath: file.path))
        #expect(try count("SELECT COUNT(*) FROM hook_events") == 2)
        #expect(try count("SELECT COUNT(*) FROM sources WHERE kind = 'spool' AND state = 'done'") == 1)
    }

    @Test func deletedSpoolFileKeepsHookEvents() throws {
        sessionStart("k1", at: Self.day(0))
        sessionStart("k2", at: Self.day(0, hours: 11))
        try runImport(now: Self.day(3))
        #expect(!fm.fileExists(atPath: spoolFile(Self.day(0)).path))
        // Later runs (a new day file, a spool parser bump) never drop the facts of a deleted file.
        sessionStart("k3", at: Self.day(3))
        var newer = SessionImporter(env: env)
        newer.spoolParser = SpoolFacts.parserVersion + 1
        try runImport(newer, now: Self.day(3, hours: 12))
        #expect(try count("SELECT COUNT(*) FROM hook_events") == 3)
        #expect(try count("SELECT COUNT(*) FROM sources WHERE state = 'done'") == 1)
        #expect(try count("SELECT COUNT(*) FROM sources WHERE state = 'gone'") == 0)
    }

    @Test func unknownSpoolKindKeepsFile() throws {
        sessionStart("u1", at: Self.day(0))
        Spool.append(["v": 1, "kind": "apply", "project": "github.com/o/r", "layers": ["core"], "skills": ["tdd": "manual"],
                      "ts": Spool.milliseconds(Self.day(0, hours: 11))], home: home, now: Self.day(0, hours: 11))
        // An akit from the future wrote a line version nobody here reads yet.
        Spool.append(["v": 2, "kind": "session_start", "harness": "claude", "session_id": "u2", "ts": 1], home: home, now: Self.day(1))

        // An older akit that only knows session starts.
        var older = SessionImporter(env: env)
        older.spoolKinds = ["session_start"]
        try runImport(older, now: Self.day(5))
        #expect(fm.fileExists(atPath: spoolFile(Self.day(0)).path))
        #expect(try count("SELECT unknown_lines FROM sources WHERE path = ?", spoolFile(Self.day(0)).path) == 1)
        #expect(try count("SELECT COUNT(*) FROM applies") == 0)

        // This akit (a spool parser bump that knows applies) re-reads the file, then deletes it.
        var current = SessionImporter(env: env)
        current.spoolParser = SpoolFacts.parserVersion + 1
        try runImport(current, now: Self.day(5))
        #expect(try count("SELECT COUNT(*) FROM applies") == 1)
        #expect(try count("SELECT COUNT(*) FROM hook_events") == 1)
        #expect(!fm.fileExists(atPath: spoolFile(Self.day(0)).path))
        // The v2 line is still unknown: its file stays.
        #expect(fm.fileExists(atPath: spoolFile(Self.day(1)).path))
        #expect(try count("SELECT unknown_lines FROM sources WHERE path = ?", spoolFile(Self.day(1)).path) == 1)
    }

    // MARK: Apply events

    var brainRoot: URL { Brain.defaultRoot(home: home) }
    var project: URL { home.appending(path: "Projects/task") }

    func trash(_ url: URL) throws -> URL? {
        let target = home.appending(path: "Trash/\(UUID().uuidString)-\(url.lastPathComponent)")
        try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.moveItem(at: url, to: target)
        return target
    }

    /// A brain with a `task` layer (tdd manual) and a plan for Projects/task.
    func taskPlan() async throws -> (ProjectSetup.Plan, Brain) {
        try await BrainSetup.create(at: brainRoot, env: env)
        try write(".akit/registry/skills/tdd/SKILL.md", "---\nname: tdd\ndescription: Tests first\n---\n")
        try write(".akit/registry/layers/task/layer.yaml", "skills:\n  - name: tdd\n    mode: manual\n")
        try fm.createDirectory(at: project, withIntermediateDirectories: true)
        let brain = try #require(Brain.load(from: brainRoot))
        let answers = ProjectAnswers(layers: ["task"], values: [:], targets: ["claude"])
        return (ProjectSetup.plan(project: project, id: "local/task", answers: answers, brain: brain,
                                  store: .current(brain: brainRoot, home: home)), brain)
    }

    @Test func applyAppendsSpoolLineAndImportFillsApplies() async throws {
        let (plan, brain) = try await taskPlan()
        _ = try await ProjectSetup.apply(plan, brain: brain, home: home, env: env, trash: trash)
        let files = try fm.contentsOfDirectory(atPath: paths.spool.path)
        #expect(files.count == 1)
        let line = try #require(try String(contentsOf: paths.spool.appending(path: files[0]), encoding: .utf8)
            .split(separator: "\n").first.flatMap { try JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] })
        #expect(line["kind"] as? String == "apply" && line["project"] as? String == "local/task")
        #expect(line["layers"] as? [String] == ["task"] && line["skills"] as? [String: String] == ["tdd": "manual"])

        let report = try runImport(now: Date())
        #expect(report.spoolLines == 1)
        let row = try #require(try database().rows("SELECT project_id, layers, skills, ts FROM applies").first)
        #expect(row[0].text == "local/task" && row[1].text == #"["task"]"# && row[2].text == #"{"tdd":"manual"}"#)
        #expect(row[3].int == line["ts"] as? Int)
        // The spool is local: nothing of it reached the brain.
        #expect(!fm.fileExists(atPath: brainRoot.appending(path: "insights").path))
    }

    @Test func applySucceedsWhenSpoolUnwritable() async throws {
        let (plan, brain) = try await taskPlan()
        try write(".akit/index/spool", "a file where the spool folder should be")
        let outcome = try await ProjectSetup.apply(plan, brain: brain, home: home, env: env, trash: trash)
        #expect(outcome.written.contains(".agents/skills/tdd/SKILL.md"))
        #expect(ProjectRecords.savedAnswers(id: "local/task", in: plan.store)?.layers == ["task"])
    }

    @Test func sameSecondAppliesBothKept() async throws {
        let (plan, _) = try await taskPlan()
        for ms in [100.0, 900.0] {
            let at = Date(timeIntervalSince1970: 1_789_900_000 + ms / 1000)
            Spool.append(ProjectSetup.applyEvent(plan, now: at), home: home, now: at)
        }
        try runImport(now: Date(timeIntervalSince1970: 1_789_900_100))
        #expect(try database().rows("SELECT ts FROM applies ORDER BY ts").map { $0[0].int } == [1_789_900_000_100, 1_789_900_000_900])
    }

    // MARK: Installer

    /// Stands in for `claude` and `launchctl`: records every call and answers queries; nothing
    /// runs for real. `git` (only ever in the fake home's brain) runs for real.
    final class FakeRunner: @unchecked Sendable {
        private let lock = NSLock()
        private var calls: [[String]] = []
        let pluginList: String
        let marketplaces: String
        let gitEnvironment: [String: String]
        /// Whether `launchctl print` finds the agent.
        let loaded: Bool

        init(pluginList: String = "[]", marketplaces: String = "[]", loaded: Bool = false, gitEnvironment: [String: String]) {
            self.pluginList = pluginList
            self.marketplaces = marketplaces
            self.loaded = loaded
            self.gitEnvironment = gitEnvironment
        }

        var commands: [String] { lock.withLock { calls.map { $0.joined(separator: " ") } } }
        private func record(_ call: [String]) { lock.withLock { calls.append(call) } }

        var runner: CommandRunner {
            { executable, arguments, directory, timeout in
                if executable.lastPathComponent == "git" {
                    return await ProcessRunner.run(executable, arguments: arguments, directory: directory,
                                                   environment: self.gitEnvironment, timeout: timeout)
                }
                self.record([executable.lastPathComponent] + arguments)
                let output = switch arguments {
                case ["plugin", "--help"]: "Commands:\n  install|i <plugin>\n  list\n  marketplace\n  uninstall\n"
                case ["plugin", "list", "--json"]: self.pluginList
                case ["plugin", "marketplace", "list", "--json"]: self.marketplaces
                default: ""
                }
                let missing = arguments.first == "print" && !self.loaded
                return ProcessRunner.Result(exitedNormally: true, status: missing ? 113 : 0, timedOut: false, output: output)
            }
        }
    }

    /// Finds the fake `claude` (never run: the fake runner answers for it).
    var installerEnv: HarnessEnvironment {
        var environment = env
        environment.executableSearchPaths = [home.appending(path: "bin"), URL(filePath: "/usr/bin")]
        return environment
    }

    func fakeClaude() throws {
        try write("bin/claude", "#!/bin/sh\nexit 99\n")
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: home.appending(path: "bin/claude").path)
    }

    /// A brain made before brains had plugins/, and Pi's config folder.
    func oldBrain() async throws {
        try await BrainSetup.create(at: brainRoot, env: env)
        try fm.removeItem(at: brainRoot.appending(path: "plugins"))
        let fake = FakeRunner(gitEnvironment: env.variables)
        let git = URL(filePath: "/usr/bin/git")
        for arguments in [["add", "-A"], ["commit", "-qm", "Before plugins"]] {
            #expect(await fake.runner(git, arguments, brainRoot, 10)?.succeeded == true)
        }
        try fm.createDirectory(at: home.appending(path: ".pi/agent"), withIntermediateDirectories: true)
    }

    /// An installed akit (make install-cli) for the launchd agent; a stub unless `real`.
    func installedAkit(real: Bool = false) throws {
        let url = home.appending(path: ".local/bin/akit")
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if real {
            try fm.createSymbolicLink(at: url, withDestinationURL: try #require(Self.akitBinary))
        } else {
            try write(".local/bin/akit", "#!/bin/sh\nexit 0\n")
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
    }

    var plistFile: URL { home.appending(path: "Library/LaunchAgents/dev.ussov.akit.sessions-import.plist") }

    func cli(_ arguments: String..., runner: FakeRunner) async -> (code: Int32, out: String, err: String) {
        var out: [String] = [], err: [String] = []
        let code = await AKitCLI.run(arguments, env: installerEnv, cwd: home, out: { out.append($0) }, err: { err.append($0) },
                                     trash: trash, runner: runner.runner)
        return (code, out.joined(separator: "\n"), err.joined(separator: "\n"))
    }

    var extensionFile: URL { home.appending(path: ".pi/agent/extensions/akit-record.ts") }

    @Test func installerPlanListsEveryWriteAndCommand() async throws {
        try await oldBrain()
        try fakeClaude()
        try installedAkit()
        let fake = FakeRunner(gitEnvironment: env.variables)
        for arguments in [["insights", "install"], ["insights", "install", "--dry-run", "--yes"]] {
            var out: [String] = []
            let code = await AKitCLI.run(arguments, env: installerEnv, cwd: home, out: { out.append($0) }, err: { _ in },
                                         trash: trash, runner: fake.runner)
            let text = out.joined(separator: "\n")
            #expect(code == 0)
            for file in CaptureInstaller.pluginFiles {
                #expect(text.contains("NEW \(brainRoot.appending(path: file.path).path)"), "\(file.path)")
            }
            #expect(text.contains("COMMIT in the brain: Add the akit Claude plugin"))
            #expect(text.contains("RUN claude plugin marketplace add \(brainRoot.appending(path: "plugins").path)"))
            #expect(text.contains("RUN claude plugin install akit@akit-brain"))
            #expect(text.contains("NEW \(extensionFile.path)"))
            #expect(text.contains("FOLDER \(paths.folder.path)") && text.contains("NEW \(plistFile.path)"))
            #expect(text.contains("RUN launchctl bootstrap gui/\(getuid()) \(plistFile.path)"))
            #expect(text.contains("Run again with --yes"))
        }
        // Nothing written, only read-only queries run.
        #expect(!fm.fileExists(atPath: brainRoot.appending(path: "plugins").path))
        #expect(!fm.fileExists(atPath: extensionFile.path) && !fm.fileExists(atPath: plistFile.path))
        #expect(!fm.fileExists(atPath: paths.folder.path))
        #expect(fake.commands.allSatisfy { $0.hasSuffix("--help") || $0.hasSuffix("--json") || $0.hasPrefix("launchctl print") },
                "\(fake.commands)")
        // Without a brain only the Pi part can be installed.
        try fm.removeItem(at: brainRoot)
        #expect(await cli("insights", "install", runner: fake).code == 2)
        let pi = await cli("insights", "install", "--only", "pi", runner: fake)
        #expect(pi.code == 0 && pi.out.contains("NEW \(extensionFile.path)") && !pi.out.contains("claude plugin"))
        let launchd = await cli("insights", "install", "--only", "launchd", runner: fake)
        #expect(launchd.code == 0 && launchd.out.contains("NEW \(plistFile.path)") && !launchd.out.contains("claude plugin"))
        #expect(await cli("insights", "install", "--only", "codex", runner: fake).code == 2)
        #expect(await cli("insights", "status", "--dry-run", runner: fake).code == 2)
    }

    @Test func installerWritesValidPluginWithVersionAndPlist() async throws {
        try await oldBrain()
        try fakeClaude()
        try installedAkit(real: true)
        // Someone else's extension with AKit's file name: diffed, backed up, then replaced.
        try write(".pi/agent/extensions/akit-record.ts", "// mine\n")
        let fake = FakeRunner(gitEnvironment: env.variables)
        let result = await cli("insights", "install", "--yes", runner: fake)
        #expect(result.code == 0 && result.out.contains("Done."), "\(result)")
        #expect(result.out.contains("BACK UP \(extensionFile.path)") && result.out.contains("- // mine"))

        func json(_ path: String) throws -> [String: Any] {
            try #require(JSONSerialization.jsonObject(with: Data(contentsOf: brainRoot.appending(path: path))) as? [String: Any])
        }
        #expect(try json("plugins/akit/.claude-plugin/plugin.json")["version"] as? String == CaptureInstaller.pluginVersion)
        let marketplace = try json("plugins/.claude-plugin/marketplace.json")
        let entry = try #require((marketplace["plugins"] as? [[String: Any]])?.first)
        #expect(marketplace["name"] as? String == "akit-brain" && entry["name"] as? String == "akit" && entry["source"] as? String == "./akit")
        let hooks = try #require(try json("plugins/akit/hooks/hooks.json")["hooks"] as? [String: Any])
        let start = try #require((hooks["SessionStart"] as? [[String: Any]])?.first?["hooks"] as? [[String: Any]])
        #expect(start.first?["command"] as? String == #""${CLAUDE_PLUGIN_ROOT}/hooks/record-session.sh""#)
        let script = brainRoot.appending(path: "plugins/akit/hooks/record-session.sh")
        #expect(try fm.attributesOfItem(atPath: script.path)[.posixPermissions] as? Int == 0o755)

        let log = try #require(await fake.runner(URL(filePath: "/usr/bin/git"), ["log", "-1", "--format=%s", "--name-only"], brainRoot, 10))
        let logLines: [String] = log.output.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        let expected: [String] = ["Add the akit Claude plugin"] + CaptureInstaller.pluginFiles.map(\.path).sorted()
        #expect(logLines == expected)
        #expect(fake.commands.contains("claude plugin marketplace add \(brainRoot.appending(path: "plugins").path)"))
        #expect(fake.commands.contains("claude plugin install akit@akit-brain"))
        #expect(try String(contentsOf: extensionFile, encoding: .utf8) == CaptureInstaller.piExtensionText)
        let backups = try #require(fm.enumerator(atPath: home.appending(path: ".akit/backups").path)?.allObjects as? [String])
        #expect(backups.contains { $0.hasSuffix(".pi/agent/extensions/akit-record.ts") })

        // The launchd agent: hourly import with the installed akit, low priority, logging locally.
        let plist = try #require(PropertyListSerialization.propertyList(from: Data(contentsOf: plistFile), format: nil) as? [String: Any])
        #expect(plist["Label"] as? String == "dev.ussov.akit.sessions-import")
        #expect(plist["ProgramArguments"] as? [String] == [home.appending(path: ".local/bin/akit").path, "sessions", "import", "--quiet"])
        #expect(plist["StartInterval"] as? Int == 3600 && plist["RunAtLoad"] as? Bool == true)
        #expect(plist["LowPriorityIO"] as? Bool == true && plist["Nice"] as? Int == 10)
        #expect(plist["StandardOutPath"] as? String == paths.log.path && plist["StandardErrorPath"] as? String == paths.log.path)
        #expect(fake.commands.contains("launchctl bootstrap gui/\(getuid()) \(plistFile.path)"))
        #expect(fm.fileExists(atPath: paths.folder.path))

        // The hook script: silent and 0 without akit; with akit, one spool line.
        func hook(_ input: String, home: URL) async throws -> ProcessRunner.Result {
            try #require(await ProcessRunner.run(URL(filePath: "/bin/sh"), arguments: ["-c", #"printf '%s' "$IN" | "$HOOK""#],
                                                 environment: ["HOME": home.path, "PATH": "/usr/bin:/bin", "IN": input, "HOOK": script.path],
                                                 timeout: 20))
        }
        let bare = home.appending(path: "bare-home")
        try fm.createDirectory(at: bare, withIntermediateDirectories: true)
        let missing = try await hook(#"{"session_id":"h0"}"#, home: bare)
        let bareItems = try fm.contentsOfDirectory(atPath: bare.path)
        #expect(missing.succeeded && missing.output.isEmpty && bareItems.isEmpty)
        let recorded = try await hook(#"{"session_id":"h1","cwd":"/work"}"#, home: home)
        #expect(recorded.succeeded && recorded.output.isEmpty)
        #expect(try runImport(now: Date()).spoolLines == 1)
        #expect(try count("SELECT COUNT(*) FROM hook_events WHERE session_id = 'h1' AND harness = 'claude'") == 1)

        // Installed and current: nothing more to do.
        let installed = FakeRunner(pluginList: #"[{"id":"akit@akit-brain","version":"\#(CaptureInstaller.pluginVersion)","enabled":true}]"#,
                                   marketplaces: #"[{"name":"akit-brain"}]"#, loaded: true, gitEnvironment: env.variables)
        let again = await cli("insights", "install", runner: installed)
        #expect(again.code == 0 && again.out.contains("Nothing to do."), "\(again)")
    }

    @Test func hookScriptExitsZeroWhenAkitFails() async throws {
        let file = try #require(CaptureInstaller.pluginFiles.first { $0.path.hasSuffix("record-session.sh") })
        let script = home.appending(path: "hook/record-session.sh")
        try write("hook/record-session.sh", file.text)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        // An akit on PATH that reads the hook input, talks and fails.
        try write("failing/akit", "#!/bin/sh\ncat > \"$HOME/hook-input\"\necho out\necho err >&2\nexit 3\n")
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: home.appending(path: "failing/akit").path)
        let input = #"{"session_id":"h9","cwd":"/work"}"#
        let result = try #require(await ProcessRunner.run(URL(filePath: "/bin/sh"), arguments: ["-c", #"printf '%s' "$IN" | "$HOOK""#],
                                                          environment: ["HOME": home.path, "PATH": home.appending(path: "failing").path + ":/usr/bin:/bin",
                                                                        "IN": input, "HOOK": script.path], timeout: 20))
        #expect(result.succeeded && result.status == 0 && result.output.isEmpty, "\(result)")
        #expect(try String(contentsOf: home.appending(path: "hook-input"), encoding: .utf8) == input)
    }

    @Test func installerReportsAFailedBrainCommitAndStillLoadsTheAgent() async throws {
        try await oldBrain()
        try fakeClaude()
        try installedAkit()
        // Another git process holds the brain's index.
        try write(".akit/registry/.git/index.lock", "")
        let fake = FakeRunner(gitEnvironment: env.variables)
        let result = await cli("insights", "install", "--yes", runner: fake)
        #expect(result.code == 1 && result.out.contains("git add failed") && result.out.contains("not installed in Claude Code"), "\(result)")
        #expect(!fake.commands.contains { $0.hasPrefix("claude plugin marketplace add") || $0.hasPrefix("claude plugin install") },
                "\(fake.commands)")
        #expect(fake.commands.contains("launchctl bootstrap gui/\(getuid()) \(plistFile.path)"))
        #expect(fm.fileExists(atPath: plistFile.path) && fm.fileExists(atPath: extensionFile.path))
    }

    @Test func statusReportsNotInstalledAndVersionMismatch() async throws {
        let none = await cli("insights", "status", "--json", runner: FakeRunner(gitEnvironment: env.variables))
        let empty = try #require(JSONSerialization.jsonObject(with: Data(none.out.utf8)) as? [String: Any])
        let claude = try #require(empty["claude"] as? [String: Any])
        #expect(none.code == 0 && claude["claudeFound"] as? Bool == false && claude["installedVersion"] == nil)
        #expect(claude["brainVersion"] == nil && claude["versionMismatch"] as? Bool == false)
        #expect((empty["pi"] as? [String: Any])?["state"] as? String == "missing" && empty["lastImport"] == nil)
        #expect((empty["launchd"] as? [String: Any])?["present"] as? Bool == false)
        #expect(!fm.fileExists(atPath: paths.database.path))

        try await BrainSetup.create(at: brainRoot, env: env)
        try fakeClaude()
        try write(".pi/agent/extensions/akit-record.ts", "// \(CaptureInstaller.marker)\n// an older one\n")
        sessionStart("st", at: Self.day(0))
        let old = FakeRunner(pluginList: #"[{"id":"other@x","version":"9"},{"id":"akit@akit-brain","version":"0.9.0","enabled":true}]"#,
                             gitEnvironment: env.variables)
        let result = await cli("insights", "status", runner: old)
        #expect(result.out.contains("Claude plugin: brain \(CaptureInstaller.pluginVersion), installed 0.9.0"), "\(result)")
        #expect(result.out.contains("Versions differ") && result.out.contains("Pi extension: outdated"))
        #expect(result.out.contains("Last spool line: 2026-09-20T10:00:00Z"))
        // Unreadable `claude plugin list` output: not installed, no crash.
        let garbage = await cli("insights", "status", "--json", runner: FakeRunner(pluginList: "Error: nope", gitEnvironment: env.variables))
        #expect(garbage.code == 0 && garbage.out.contains(#""claudeFound" : true"#))
    }

    @Test func uninstallUsesTrash() async throws {
        try fakeClaude()
        try write(".pi/agent/extensions/akit-record.ts", CaptureInstaller.piExtensionText)
        try write("Library/LaunchAgents/dev.ussov.akit.sessions-import.plist", "<plist/>")
        let fake = FakeRunner(pluginList: #"[{"id":"akit@akit-brain","version":"1.0.0"}]"#, loaded: true, gitEnvironment: env.variables)
        let preview = await cli("insights", "uninstall", runner: fake)
        #expect(preview.out.contains("TRASH \(extensionFile.path)") && preview.out.contains("RUN claude plugin uninstall akit@akit-brain"))
        #expect(fm.fileExists(atPath: extensionFile.path) && !fake.commands.contains { $0.contains("uninstall") })

        let done = await cli("insights", "uninstall", "--yes", runner: fake)
        #expect(done.code == 0, "\(done)")
        #expect(!fm.fileExists(atPath: extensionFile.path))
        let trashed = try fm.contentsOfDirectory(atPath: home.appending(path: "Trash").path)
        #expect(trashed.contains { $0.hasSuffix("akit-record.ts") })
        #expect(fake.commands.contains("claude plugin uninstall akit@akit-brain"))
        #expect(fake.commands.contains("launchctl bootout gui/\(getuid())/dev.ussov.akit.sessions-import"))
        #expect(!fm.fileExists(atPath: plistFile.path) && trashed.contains { $0.hasSuffix("sessions-import.plist") })

        // Someone else's file is never trashed.
        try write(".pi/agent/extensions/akit-record.ts", "// mine\n")
        let foreign = await cli("insights", "uninstall", "--yes", runner: FakeRunner(gitEnvironment: env.variables))
        #expect(foreign.out.contains("was not written by AKit") && fm.fileExists(atPath: extensionFile.path))
    }

    @Test func launchdRefusesBuildFolderBinary() async throws {
        let fake = FakeRunner(gitEnvironment: env.variables)
        for path in ["/Users/me/akit/AKitCore/.build/release/akit", "/Users/me/Library/Developer/Xcode/DerivedData/AKit-x/Build/akit"] {
            let installer = CaptureInstaller(env: env, brainRoot: nil, run: fake.runner, akitExecutable: URL(filePath: path))
            let plan = await installer.installPlan(only: .launchd)
            #expect(plan.isEmpty && plan.refused.count == 1 && plan.refused[0].contains("make install-cli"), "\(plan.refused)")
        }
        #expect(!fm.fileExists(atPath: plistFile.path) && fake.commands.isEmpty)

        // Elsewhere the running binary is used, until make install-cli put one into ~/.local/bin.
        let elsewhere = CaptureInstaller(env: env, brainRoot: nil, run: fake.runner, akitExecutable: URL(filePath: "/opt/tools/akit"))
        #expect(try elsewhere.agentProgram().path == "/opt/tools/akit")
        try installedAkit()
        let installer = CaptureInstaller(env: env, brainRoot: nil, run: fake.runner,
                                         akitExecutable: URL(filePath: "/Users/me/akit/AKitCore/.build/debug/akit"))
        #expect(try installer.agentProgram() == home.appending(path: ".local/bin/akit"))
        let plan = await installer.installPlan(only: .launchd)
        #expect(plan.refused.isEmpty && plan.writes.map(\.url) == [plistFile])
        #expect(plan.writes.first?.text.contains("/.build/") == false)
    }
}
