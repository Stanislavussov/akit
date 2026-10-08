import Foundation
import Testing
import AKitBrain
import AKitFoundation
@testable import AKitCommandLine
@testable import AKitInsights

/// Machine identity and the usage summaries published to the brain. Facts are written straight into
/// a temporary index in a temporary fake home; the brain is a temporary git repository; the
/// hardware hash is always injected.
struct UsageSummaryTests {
    let home: URL
    let fm = FileManager.default
    let calendar = Calendar.current
    /// Local midnight of a fixed day, and "now" in its evening.
    let today: Date
    let now: Date
    static let project = "github.com/acme/secret-app"
    static let email = "me@example.com"

    init() throws {
        home = fm.temporaryDirectory.appending(path: "akit-summary-\(UUID().uuidString)")
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
        today = calendar.startOfDay(for: Date(timeIntervalSince1970: 1_790_000_000))
        now = today.addingTimeInterval(20 * 3600)
    }

    var env: HarnessEnvironment {
        HarnessEnvironment(homeDirectory: home, variables: [
            "HOME": home.path, "GIT_CONFIG_NOSYSTEM": "1",
            "GIT_AUTHOR_NAME": "Test", "GIT_AUTHOR_EMAIL": "test@example.com",
            "GIT_COMMITTER_NAME": "Test", "GIT_COMMITTER_EMAIL": "test@example.com",
        ], executableSearchPaths: [URL(filePath: "/usr/bin")])
    }

    var brainRoot: URL { Brain.defaultRoot(home: home) }

    // MARK: Helpers

    /// A brain with the skills `tdd` and `review`, committed, with its own git email and name unless nil.
    @discardableResult
    func setUpBrain(email: String? = UsageSummaryTests.email) async throws -> Brain {
        try await BrainSetup.create(at: brainRoot, env: env)
        for name in ["tdd", "review"] {
            try write(".akit/registry/skills/\(name)/SKILL.md", "---\nname: \(name)\ndescription: \(name) skill\n---\n")
        }
        try await git("add", "--all")
        try await git("commit", "-qm", "Skills")
        if let email {
            try await git("config", "--local", "user.email", email)
            try await git("config", "--local", "user.name", "Me")
        }
        return try #require(Brain.load(from: brainRoot))
    }

    func write(_ path: String, _ text: String = "") throws {
        let url = home.appending(path: path)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    @discardableResult
    func git(_ arguments: String..., in folder: URL? = nil) async throws -> String {
        let result = try #require(await ProcessRunner.run(URL(filePath: "/usr/bin/git"), arguments: arguments,
                                                          directory: folder ?? brainRoot, environment: env.variables, timeout: 30))
        #expect(result.succeeded, "git \(arguments): \(result.output)")
        return result.output
    }

    /// git output that may fail (e.g. a missing path).
    func tryGit(_ arguments: String...) async -> (ok: Bool, output: String) {
        let result = await ProcessRunner.run(URL(filePath: "/usr/bin/git"), arguments: arguments, directory: brainRoot,
                                             environment: env.variables, timeout: 30)
        return (result?.succeeded ?? false, result?.output ?? "")
    }

    func commitCount() async throws -> Int {
        Int(try await git("rev-list", "--count", "HEAD").trimmingCharacters(in: .whitespacesAndNewlines)) ?? -1
    }

    func database() throws -> IndexDatabase { try IndexSchema.open(InsightsPaths(home: home).database) }

    /// `hour` o'clock (local) `daysAgo` days before today.
    func at(_ daysAgo: Int, _ hour: Double = 12) -> Double {
        (calendar.date(byAdding: .day, value: -daysAgo, to: today) ?? today).timeIntervalSince1970 + hour * 3600
    }

    func day(_ daysAgo: Int) -> String { UsageSummary.day(Date(timeIntervalSince1970: at(daysAgo)), calendar: calendar) }

    func session(_ id: String, started: Double, cwd: String? = nil, branch: String? = nil, in db: IndexDatabase) throws {
        try db.run("""
            INSERT INTO sessions(key, harness, native_id, cwd, git_branch, started, source_id, parser_version)
            VALUES(?, 'claude', ?, ?, ?, ?, 0, 1)
            """, "claude:\(id)", id, cwd, branch, started)
    }

    func listing(_ id: String, _ skill: String, at ts: Double, hash: String?, subagent: Bool = false, in db: IndexDatabase) throws {
        try db.run("""
            INSERT INTO skill_listings(harness, listing_key, skill, session_key, ts, is_subagent, is_initial, desc_hash, desc_chars,
              source_id, parser_version) VALUES('claude', ?, ?, ?, ?, ?, 1, ?, 40, 0, 1)
            """, UUID().uuidString, skill, "claude:\(id)", ts, subagent, hash)
    }

    func request(_ id: String, at ts: Double, context: Int, in db: IndexDatabase) throws {
        try db.run("""
            INSERT INTO requests(harness, event_key, session_key, ts, input, cache_read, cache_write, is_subagent, source_id, parser_version)
            VALUES('claude', ?, ?, ?, ?, 0, 0, 0, 0, 1)
            """, UUID().uuidString, "claude:\(id)", ts, context)
    }

    func call(_ id: String, _ skill: String, at ts: Double, by: String = "model", in db: IndexDatabase) throws {
        try db.run("""
            INSERT INTO skill_calls(harness, event_key, session_key, ts, skill, by, is_subagent, source_id, parser_version)
            VALUES('claude', ?, ?, ?, ?, ?, 0, 0, 1)
            """, UUID().uuidString, "claude:\(id)", ts, skill, by)
    }

    func bind(_ id: String, to project: String, _ confidence: Confidence, repo: String? = nil, in db: IndexDatabase) throws {
        try db.run("""
            INSERT INTO bindings(session_key, project_id, method, confidence, repo_path, decided_at, resolver_version)
            VALUES(?, ?, 'live', ?, ?, 0, 1)
            """, "claude:\(id)", project, confidence.rawValue, repo)
    }

    /// Yesterday: sessions a (bound exactly to the project) and b (unbound); today: c (bound low).
    /// Brain skills tdd and review, a plugin skill and a hand skill.
    func writeFacts(_ db: IndexDatabase) throws {
        try session("a", started: at(1, 10), cwd: "/Users/someone/work/secret-app", branch: "feature/secret-branch", in: db)
        try listing("a", "tdd", at: at(1, 10), hash: "h-tdd-1", in: db)
        try listing("a", "marketing:seo-audit", at: at(1, 10), hash: "h-plugin", in: db)
        try listing("a", "handmade", at: at(1, 10), hash: "h-hand", in: db)
        try request("a", at: at(1, 10.1), context: 1000, in: db)
        try call("a", "tdd", at: at(1, 10.2), in: db)
        try bind("a", to: Self.project, .exact, repo: "/Users/someone/work/secret-app/.git", in: db)

        try session("b", started: at(1, 15), in: db)
        try listing("b", "tdd", at: at(1, 15), hash: "h-tdd-1", in: db)
        try request("b", at: at(1, 15.1), context: 3000, in: db)
        try call("b", "tdd", at: at(1, 15.2), by: "user", in: db)

        try session("c", started: at(0, 9), in: db)
        try listing("c", "tdd", at: at(0, 9), hash: "h-tdd-2", in: db)
        try listing("c", "review", at: at(0, 9), hash: "h-review", in: db)
        try request("c", at: at(0, 9.1), context: 500, in: db)
        try call("c", "review", at: at(0, 9.2), in: db)
        try bind("c", to: Self.project, .low, in: db)
    }

    func publish(_ db: IndexDatabase, hardware: String? = "hw-1", dryRun: Bool = false, at time: Date? = nil,
                 hostName: String = "TestMac.local") async throws -> SummaryPublisher.Outcome {
        let brain = try #require(Brain.load(from: brainRoot))
        return try await SummaryPublisher.publish(env: env, brain: brain, database: db, hostName: hostName, hardware: hardware,
                                                  dryRun: dryRun, now: time ?? now, calendar: calendar)
    }

    func summary(_ path: String) throws -> UsageSummary.File {
        try #require(UsageSummary.read(brainRoot.appending(path: path)), "no summary at \(path)")
    }

    func bytes(_ path: String) throws -> String {
        try String(contentsOf: brainRoot.appending(path: path), encoding: .utf8)
    }

    /// A work Mac whose kind changed long before the facts.
    func saveWorkProfile(pseudonym: String = "work-abc123", id: String = "0123456789abcdef") throws {
        var profile = MachineProfile(kind: .work, name: "work")
        profile.id = id
        profile.pseudonym = pseudonym
        profile.hardwareHash = "hw-1"
        profile.kindSince = Date(timeIntervalSince1970: at(30))
        try profile.save(home: home)
    }

    func machine(_ arguments: String..., hardware: String = "hw-1") async -> (code: Int32, out: String, err: String) {
        var out: [String] = [], err: [String] = []
        let code = await AKitCLI.run(["machine"] + arguments, env: env, cwd: home, hostName: "TestMac.local",
                                     out: { out.append($0) }, err: { err.append($0) }, hardwareHash: { hardware })
        return (code, out.joined(separator: "\n"), err.joined(separator: "\n"))
    }
}

// MARK: - Summaries

extension UsageSummaryTests {
    @Test func personalMachineAndProjectSummariesPerDay() async throws {
        try await setUpBrain()
        let db = try database()
        try writeFacts(db)
        let outcome = try await publish(db)
        let id = try #require(MachineProfile.load(home: home).id)
        #expect(id.count == 16 && id.allSatisfy(\.isHexDigit))
        #expect(outcome.key == id && !outcome.isWork)
        let machinePath = "insights/machines/\(id).json", projectPath = "projects/\(Self.project)/usage/\(id).json"
        #expect(outcome.committed == [machinePath, projectPath])
        #expect(try await git("log", "-1", "--format=%s") == "Update usage summaries (TestMac)\n")

        let machine = try summary(machinePath)
        #expect(machine.version == 1 && machine.machine == id && machine.name == "TestMac")
        #expect(machine.days == [
            day(1): .init(sessions: 2, firstContextSum: 4000, firstContextN: 2,
                          skills: ["tdd": [2, 1, 1], "marketing:seo-audit": [1, 0, 0], "handmade": [1, 0, 0]],
                          described: ["tdd": 2, "marketing:seo-audit": 1, "handmade": 1]),
            day(0): .init(sessions: 1, firstContextSum: 500, firstContextN: 1, skills: ["tdd": [1, 0, 0], "review": [1, 1, 0]],
                          described: ["tdd": 1, "review": 1]),
        ])
        #expect(machine.descHashes?["tdd"] == [[day(1), "h-tdd-1"], [day(0), "h-tdd-2"]])

        // The project file: only the exactly bound session (low bindings are left out by default).
        let project = try summary(projectPath)
        #expect(project.machine == id && project.name == nil && project.descHashes == nil)
        #expect(project.days == [day(1): .init(sessions: 1, firstContextSum: 1000, firstContextN: 1,
                                                skills: ["tdd": [1, 1, 0], "marketing:seo-audit": [1, 0, 0], "handmade": [1, 0, 0]],
                                                described: ["tdd": 1, "marketing:seo-audit": 1, "handmade": 1])])
        // Sorted keys, one day per line.
        let text = try bytes(machinePath)
        #expect(text.hasPrefix("{\n\"days\": {\n  \"\(day(1))\": {\"described\":{\"handmade\":1,\"marketing:seo-audit\":1,\"tdd\":2},\"firstContextN\":2,\"firstContextSum\":4000,\"sessions\":2,\"skills\":{"))
        #expect(text.hasSuffix("\"version\": 1\n}\n"))
    }

    @Test func workSummaryContainsOnlyBrainSkillsAndNoProjectData() async throws {
        try await setUpBrain()
        try saveWorkProfile()
        let db = try database()
        try writeFacts(db)
        let outcome = try await publish(db)
        #expect(outcome.isWork && outcome.key == "work-abc123")
        let path = "insights/machines/work-abc123.json"
        #expect(try summary(path).days == [
            day(1): .init(skills: ["tdd": [2, 1, 1]], described: ["tdd": 2]),
            day(0): .init(skills: ["tdd": [1, 0, 0], "review": [1, 1, 0]], described: ["tdd": 1, "review": 1]),
        ])
        let text = try bytes(path)
        for leak in ["marketing", "seo-audit", "handmade", "acme", "secret", "TestMac", "testmac", "/Users", "feature",
                     "h-tdd", "0123456789abcdef", "sessions", "firstContext", "descHashes", "name"] {
            #expect(!text.contains(leak), "\(leak) in \(text)")
        }
        let object = try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        #expect(Set(object.keys) == ["version", "machine", "updated", "days"])
    }

    @Test func workCommitLeaksNothing() async throws {
        try await setUpBrain()
        try saveWorkProfile()
        let db = try database()
        try writeFacts(db)
        // A global signing setting with a work key: the brain's commits are never signed with it.
        try write(".gitconfig", "[user]\n\tname = Work Name\n\tsigningkey = WORKKEY\n[commit]\n\tgpgsign = true\n")
        let before = try await commitCount()
        _ = try await publish(db)
        #expect(try await commitCount() == before + 1)
        #expect(try await git("log", "-1", "--format=%an|%cn") == "Me|Me\n")
        #expect(!(try await git("cat-file", "-p", "HEAD").contains("gpgsig")))
        #expect(try await git("log", "-1", "--format=%B", "--name-only")
                == "Update usage summaries (work-abc123)\n\n\ninsights/machines/work-abc123.json\n")
        // The brain's own identity, not the environment's (which may be the work one).
        #expect(try await git("log", "-1", "--format=%ae %ce") == "\(Self.email) \(Self.email)\n")
        #expect(try await git("status", "--porcelain").isEmpty)

        // The filter itself: another path, another message, another field or a skill not in the brain are refused.
        let brain = try #require(Brain.load(from: brainRoot))
        let kind = WorkFilter.Kind.summary(pseudonym: "work-abc123", brainSkills: Set(brain.skills.map(\.name)))
        let profile = MachineProfile.load(home: home)
        let good = Data(#"{"days":{"2026-09-20":{"skills":{"tdd":[1,0,0]}}},"machine":"work-abc123","updated":"2026-09-20T10:00:00Z","version":1}"#.utf8)
        let attempts: [([String: Data], String)] = [
            (["insights/machines/work-abc123.json": good, "projects/x/usage/y.json": good], kind.message),
            (["insights/machines/work-abc123.json": good], "Update usage summaries (acme laptop)"),
            (["insights/machines/work-abc123.json": Data(#"{"days":{},"machine":"work-abc123","name":"TestMac","updated":"2026-09-20T10:00:00Z","version":1}"#.utf8)], kind.message),
            (["insights/machines/work-abc123.json": Data(#"{"days":{"2026-09-20":{"skills":{"marketing:seo-audit":[1,0,0]}}},"machine":"work-abc123","updated":"2026-09-20T10:00:00Z","version":1}"#.utf8)], kind.message),
            (["insights/machines/work-abc123.json": Data(#"{"days":{"2026-09-20":{"sessions":3,"skills":{}}},"machine":"work-abc123","updated":"2026-09-20T10:00:00Z","version":1}"#.utf8)], kind.message),
        ]
        let committed = try await git("rev-parse", "HEAD")
        let file = try bytes("insights/machines/work-abc123.json")
        for (files, message) in attempts {
            await #expect(throws: WorkFilter.Failure.self) {
                try await WorkFilter.commit(kind, files: files, message: message, brain: brainRoot, machine: profile, env: env)
            }
            #expect(try await git("rev-parse", "HEAD") == committed)
            #expect(try await git("diff", "--cached", "--name-only").isEmpty)
            #expect(try bytes("insights/machines/work-abc123.json") == file)
            #expect(!fm.fileExists(atPath: brainRoot.appending(path: "projects/x").path))
        }
    }

    @Test func workProjectSummariesStayInLocalStore() async throws {
        try await setUpBrain()
        try saveWorkProfile()
        let db = try database()
        try writeFacts(db)
        let outcome = try await publish(db)
        let local = ProjectStore.local(home: home)
        let url = UsageSummary.projectURL(Self.project, key: "0123456789abcdef", in: local)
        #expect(outcome.local == [url.path])
        #expect(UsageSummary.read(url)?.days[day(1)]?.skills["tdd"] == [1, 1, 0])
        #expect(!fm.fileExists(atPath: brainRoot.appending(path: "projects/github.com").path))
        #expect(!(try await git("ls-files", "projects")).contains("usage"))
    }

    @Test func workPublishRefusesWithoutBrainIdentityOrBrokenProfile() async throws {
        try await setUpBrain(email: nil)
        try saveWorkProfile()
        let db = try database()
        try writeFacts(db)
        let head = try await git("rev-parse", "HEAD")
        func refused(_ why: String) async throws {
            await #expect(throws: SummaryPublisher.Failure.self, "\(why)") { _ = try await publish(db) }
            #expect(!fm.fileExists(atPath: brainRoot.appending(path: "insights/machines/work-abc123.json").path), "\(why)")
            #expect(!fm.fileExists(atPath: home.appending(path: ".akit/local/projects/github.com").path), "\(why)")
        }
        try await refused("no email of its own (the environment's doesn't count)")
        try await git("config", "--local", "user.email", "")
        try await refused("empty email")

        try await git("config", "--local", "user.email", Self.email)
        try await refused("an email but no name of its own (the global one may be the work name)")
        try await git("config", "--local", "user.name", "Me")

        // An unreadable config: hasOwnGitIdentity would say yes, the filter says no.
        let config = brainRoot.appending(path: ".git/config")
        try fm.setAttributes([.posixPermissions: 0], ofItemAtPath: config.path)
        #expect(MachineProfile.hasOwnGitIdentity(brainRoot))
        try await refused("unreadable config")
        try fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: config.path)

        // .git as a file pointing nowhere.
        try fm.moveItem(at: brainRoot.appending(path: ".git"), to: home.appending(path: "saved.git"))
        try write(".akit/registry/.git", "gitdir: /nonexistent/akit\n")
        try await refused(".git is a file")
        try fm.removeItem(at: brainRoot.appending(path: ".git"))
        try fm.moveItem(at: home.appending(path: "saved.git"), to: brainRoot.appending(path: ".git"))

        // A broken machine.json counts as work and is never rewritten.
        try write(".akit/machine.json", "{")
        try await refused("broken machine.json")
        #expect(try String(contentsOf: MachineProfile.file(home: home), encoding: .utf8) == "{")
        #expect(try await git("rev-parse", "HEAD") == head)
    }

    @Test func publishCommitsOnlyOnChange() async throws {
        try await setUpBrain()
        let db = try database()
        try writeFacts(db)
        let before = try await commitCount()
        #expect(try await !publish(db).committed.isEmpty)
        #expect(try await commitCount() == before + 1)
        // Later the same evening: only `updated` would differ.
        #expect(try await publish(db, at: now.addingTimeInterval(1800)).committed.isEmpty)
        #expect(try await publish(db, dryRun: true).changed.isEmpty)
        #expect(try await commitCount() == before + 1)

        try call("c", "tdd", at: at(0, 11), in: db)
        let dry = try await publish(db, dryRun: true)
        let id = try #require(MachineProfile.load(home: home).id)
        #expect(dry.changed == ["insights/machines/\(id).json"] && dry.committed.isEmpty)
        #expect(try await commitCount() == before + 1)
        #expect(try await publish(db).committed == ["insights/machines/\(id).json"])
        #expect(try await commitCount() == before + 2)
    }

    @Test func dryRunOnANewMacShowsNoMadeUpID() async throws {
        try await setUpBrain()
        let db = try database()
        try writeFacts(db)
        // No id yet: a dry run can't know the random one the real publish makes.
        let dry = try await publish(db, dryRun: true)
        #expect(dry.key == SummaryPublisher.newID, "\(dry)")
        #expect(dry.changed == ["insights/machines/<new id>.json", "projects/\(Self.project)/usage/<new id>.json"], "\(dry.changed)")
        #expect(MachineProfile.load(home: home).id == nil)
        #expect(AKitCLI.publishText(dry).contains("insights/machines/<new id>.json"))
        let real = try await publish(db)
        let id = try #require(MachineProfile.load(home: home).id)
        #expect(real.key == id && real.committed == ["insights/machines/\(id).json", "projects/\(Self.project)/usage/\(id).json"])
        // Once it exists, a dry run shows it.
        try call("c", "tdd", at: at(0, 11), in: db)
        #expect(try await publish(db, dryRun: true).changed == ["insights/machines/\(id).json"])

        // A work Mac without a pseudonym yet, and a lost machine.json that gets its id back from the index.
        var work = MachineProfile(kind: .work, name: "work")
        work.id = id
        work.hardwareHash = "hw-1"
        try work.save(home: home)
        let workDry = try await publish(db, dryRun: true)
        #expect(workDry.key == SummaryPublisher.newPseudonym && workDry.message == "Update usage summaries (<new pseudonym>)", "\(workDry)")
        try fm.removeItem(at: MachineProfile.file(home: home))
        #expect(try await publish(db, dryRun: true).key == id)
    }

    @Test func retentionDropsOldDays() async throws {
        try await setUpBrain()
        let db = try database()
        for daysAgo in [0, 119, 120, 130] {
            try session("s\(daysAgo)", started: at(daysAgo), in: db)
            try listing("s\(daysAgo)", "tdd", at: at(daysAgo), hash: "h", in: db)
        }
        _ = try await publish(db)
        let id = try #require(MachineProfile.load(home: home).id)
        #expect(Set(try summary("insights/machines/\(id).json").days.keys) == [day(0), day(119)])
        // Ten days later the oldest kept day is gone too.
        _ = try await publish(db, at: now.addingTimeInterval(10 * 86_400))
        #expect(Set(try summary("insights/machines/\(id).json").days.keys) == [day(0)])
    }

    @Test func summariesHaveNoPathsOrBranches() async throws {
        try await setUpBrain()
        let db = try database()
        try writeFacts(db)
        try db.run("""
            INSERT INTO hook_events(harness, session_id, ts, cwd, gitdir, branch, transcript, source_id, parser_version)
            VALUES('claude', 'a', 1, '/Users/someone/work/secret-app', '/Users/someone/work/secret-app/.git', 'feature/secret-branch',
                   '/Users/someone/.claude/projects/x/a.jsonl', 0, 1)
            """)
        _ = try await publish(db)
        let id = try #require(MachineProfile.load(home: home).id)
        for path in ["insights/machines/\(id).json", "projects/\(Self.project)/usage/\(id).json"] {
            let text = try bytes(path)
            for leak in ["/Users", "someone", "secret-app", "acme", "feature", "secret-branch", ".jsonl", "claude:a", "\"a\""] {
                #expect(!text.contains(leak), "\(leak) in \(path)")
            }
        }
    }

    @Test func zeroSkillEntriesOmittedAndDescHashesListedOnce() async throws {
        try await setUpBrain()
        let db = try database()
        // Seen first by a subagent two days ago, then in three main sessions over two days.
        try session("x", started: at(2), in: db)
        try listing("x", "tdd", at: at(2), hash: "h1", subagent: true, in: db)
        try listing("x", "quiet", at: at(2), hash: "hq", subagent: true, in: db)
        for (id, daysAgo) in [("p", 1), ("q", 1), ("r", 0)] {
            try session(id, started: at(daysAgo), in: db)
            try listing(id, "tdd", at: at(daysAgo), hash: "h1", in: db)
        }
        try call("r", "tdd", at: at(0, 13), by: "user", in: db)
        try db.run("""
            INSERT INTO skill_calls(harness, event_key, session_key, ts, skill, by, is_subagent, source_id, parser_version, extra)
            VALUES('claude', 'cmd', 'claude:r', ?, 'model-switch', 'user', 0, 0, 1, '{"kind":"command"}')
            """, at(0, 14))
        _ = try await publish(db)
        let id = try #require(MachineProfile.load(home: home).id)
        let file = try summary("insights/machines/\(id).json")
        #expect(file.days[day(2)] == .init(sessions: 1, firstContextSum: 0, firstContextN: 0, skills: [:]))
        #expect(file.days[day(1)]?.skills == ["tdd": [2, 0, 0]])
        #expect(file.days[day(0)]?.skills == ["tdd": [1, 0, 1]])
        #expect(file.descHashes == ["tdd": [[day(2), "h1"]], "quiet": [[day(2), "hq"]]])
        #expect(UsageSummary.withoutZeroSkills(.init(skills: ["a": [0, 0, 0], "b": [0, 1, 0]])).skills == ["b": [0, 1, 0]])
    }

    @Test func describedDayFieldWrittenAndRead() async throws {
        try await setUpBrain()
        let db = try database()
        // Yesterday: tdd with its description in a, by name only in b; today only by name in c.
        try session("a", started: at(1, 10), in: db)
        try listing("a", "tdd", at: at(1, 10), hash: "h1", in: db)
        try session("b", started: at(1, 12), in: db)
        try listing("b", "tdd", at: at(1, 12), hash: nil, in: db)
        try session("c", started: at(0, 9), in: db)
        try listing("c", "tdd", at: at(0, 9), hash: nil, in: db)
        try call("c", "tdd", at: at(0, 9.5), in: db)
        try session("d", started: at(0, 10), in: db)  // no listing at all
        _ = try await publish(db)
        let id = try #require(MachineProfile.load(home: home).id)
        let path = "insights/machines/\(id).json"
        let file = try summary(path)
        // `skills` keeps its meaning for older readers: every listing; `described` only the described ones.
        #expect(file.days[day(1)]?.skills == ["tdd": [2, 0, 0]] && file.days[day(1)]?.described == ["tdd": 1])
        #expect(file.days[day(0)]?.skills == ["tdd": [1, 1, 0]] && file.days[day(0)]?.described == [:], "listed, none described")
        let today = try #require(file.days[day(0)])
        #expect(UsageSummary.described(today, skill: "tdd") == 0)
        #expect(try bytes(path).contains("\"described\":{},"))
        // A day with no listing has no `described`.
        #expect(UsageSummary.withoutZeroSkills(.init(sessions: 1, skills: [:], described: [:])).described == nil)

        // An older akit's file decodes with no `described`; an older akit's decoder ignores the new key.
        let old = Data(#"{"days":{"2026-09-20":{"skills":{"tdd":[3,0,0]}}},"machine":"fedcba9876543210","version":1}"#.utf8)
        let decoded = try JSONDecoder().decode(UsageSummary.File.self, from: old)
        let oldDay = try #require(decoded.days["2026-09-20"])
        #expect(oldDay.described == nil && UsageSummary.described(oldDay, skill: "tdd") == 0)
        struct OldDay: Decodable { let skills: [String: [Int]] }
        struct OldFile: Decodable { let version: Int; let days: [String: OldDay] }
        let readByOld = try JSONDecoder().decode(OldFile.self, from: Data(try bytes(path).utf8))
        #expect(readByOld.version == 1 && readByOld.days[day(1)]?.skills == ["tdd": [2, 0, 0]])
    }

    @Test func workFilterAcceptsDescribedAndNothingElse() async throws {
        try await setUpBrain()
        try saveWorkProfile()
        let db = try database()
        try writeFacts(db)
        try listing("b", "review", at: at(1, 15), hash: nil, in: db)  // by name only: in skills, not in described
        _ = try await publish(db)
        let path = "insights/machines/work-abc123.json"
        #expect(try summary(path).days[day(1)] == .init(skills: ["tdd": [2, 1, 1], "review": [1, 0, 0]], described: ["tdd": 2]))
        #expect(try await git("log", "-1", "--format=%s") == "Update usage summaries (work-abc123)\n")

        func check(_ json: String) throws {
            try WorkFilter.checkSummary(Data(json.utf8), pseudonym: "work-abc123", brainSkills: ["tdd", "review"], path: path)
        }
        func withDay(_ fields: String) -> String {
            #"{"days":{"2026-09-20":"# + fields + #"},"machine":"work-abc123","updated":"2026-09-20T10:00:00Z","version":1}"#
        }
        try check(withDay(#"{"skills":{"tdd":[1,0,0]},"described":{"tdd":1}}"#))
        try check(withDay(#"{"skills":{"tdd":[1,0,0]},"described":{}}"#))
        try check(withDay(#"{"skills":{"tdd":[1,0,0]}}"#))
        for refused in [#"{"skills":{"tdd":[1,0,0]},"described":{"marketing:seo-audit":1}}"#,
                        #"{"skills":{"tdd":[1,0,0]},"described":{"tdd":-1}}"#,
                        #"{"skills":{"tdd":[1,0,0]},"described":{"tdd":1.5}}"#,
                        #"{"skills":{"tdd":[1,0,0]},"described":{"tdd":"one"}}"#,
                        #"{"skills":{"tdd":[1,0,0]},"described":["tdd"]}"#,
                        #"{"described":{"tdd":1}}"#,
                        #"{"skills":{"tdd":[1,0,0]},"described":{"tdd":1},"sessions":3}"#] {
            #expect(throws: WorkFilter.Failure.self, "\(refused)") { try check(withDay(refused)) }
        }
    }
}

// MARK: - Identity

extension UsageSummaryTests {
    @Test func idAndPseudonymStableAcrossMachineChange() async throws {
        try await setUpBrain()
        let db = try database()
        try writeFacts(db)
        _ = try await publish(db)
        let id = try #require(MachineProfile.load(home: home).id)

        let work = await machine("work")
        #expect(work.code == 0, "\(work)")
        let profile = MachineProfile.load(home: home)
        let pseudonym = try #require(profile.pseudonym)
        #expect(profile.id == id && profile.isWork && profile.kindSince != nil && profile.hardwareHash == "hw-1")
        #expect(pseudonym.count == 11 && pseudonym.hasPrefix("work-") && pseudonym.dropFirst(5).allSatisfy(\.isHexDigit))
        // The warning names the project summaries this Mac published while personal.
        #expect(work.out.contains("projects/\(Self.project)/usage/\(id).json"), "\(work.out)")
        #expect(await machine().out.contains("as \(pseudonym)"))

        #expect(await machine("personal").code == 0)
        #expect(MachineProfile.load(home: home).id == id && MachineProfile.load(home: home).pseudonym == pseudonym)
        #expect(!(await machine().out.contains(pseudonym)))
        #expect(await machine("work", "--name", "office").code == 0)
        let again = MachineProfile.load(home: home)
        #expect(again.id == id && again.pseudonym == pseudonym && again.name == "office")
    }

    @Test func pseudonymNotHostDerived() async throws {
        var seen: Set<String> = []
        for index in 0..<2 {
            let other = home.appending(path: "mac\(index)")
            _ = try MachineProfile.change(to: MachineProfile(kind: .work), brain: other.appending(path: "brain"), home: other,
                                          hostName: "acme-corp-laptop.local", hardware: "hw-same", ownKeys: .init())
            let profile = MachineProfile.load(home: other)
            let pseudonym = try #require(profile.pseudonym)
            #expect(!pseudonym.contains("acme") && !pseudonym.contains("corp") && !pseudonym.contains("laptop"))
            #expect(!pseudonym.dropFirst(5).contains(String((profile.id ?? "").prefix(6))))
            seen.insert(pseudonym)
        }
        #expect(seen.count == 2)  // random, not derived from the same host or hardware
    }

    @Test func lostMachineFileReusesOwnId() async throws {
        try await setUpBrain()
        let db = try database()
        try writeFacts(db)
        _ = try await publish(db)
        let id = try #require(MachineProfile.load(home: home).id)
        try fm.removeItem(at: MachineProfile.file(home: home))

        let again = try await publish(db)
        #expect(again.key == id && again.committed.isEmpty)
        #expect(MachineProfile.load(home: home).id == id)
        #expect(UsageSummary.ownKeys(db).ids == [id])
        // Switching to work after that reuses nothing it never had: a new pseudonym, kept from then on.
        _ = try MachineProfile.change(to: MachineProfile(kind: .work), brain: brainRoot, home: home, hardware: "hw-1")
        #expect(MachineProfile.load(home: home).id == id)
    }

    @Test func brokenProfileNeverSavesId() async throws {
        try await setUpBrain()
        let db = try database()
        try writeFacts(db)
        try write(".akit/machine.json", "{\"kind\": ")
        await #expect(throws: SummaryPublisher.Failure.self) { _ = try await publish(db) }
        #expect(try String(contentsOf: MachineProfile.file(home: home), encoding: .utf8) == "{\"kind\": ")
        #expect(UsageSummary.ownKeys(db) == .init())
        #expect(MachineProfile.load(home: home).problem != nil && MachineProfile.load(home: home).id == nil)
        #expect(try await git("status", "--porcelain").isEmpty)
    }

    @Test func clonedMacGetsNewIdAndPseudonym() async throws {
        try await setUpBrain()
        try saveWorkProfile()
        let db = try database()
        try writeFacts(db)
        #expect(try await publish(db).key == "work-abc123")
        // The same machine.json on other hardware (Migration Assistant, Time Machine).
        let clone = try await publish(db, hardware: "hw-2")
        let profile = MachineProfile.load(home: home)
        #expect(profile.hardwareHash == "hw-2" && profile.id != "0123456789abcdef" && profile.pseudonym != "work-abc123")
        // The copied days are the original's: nothing to publish until the clone has a day of its own.
        #expect(clone.key == profile.pseudonym && clone.committed.isEmpty && profile.idSince == now)
        #expect(fm.fileExists(atPath: brainRoot.appending(path: "insights/machines/work-abc123.json").path))
        try session("clone-1", started: at(-1, 10), in: db)
        try listing("clone-1", "tdd", at: at(-1, 10), hash: "h-tdd-1", in: db)
        let later = Date(timeIntervalSince1970: at(-1, 20))
        #expect(try await publish(db, hardware: "hw-2", at: later).committed == ["insights/machines/\(clone.key).json"])
        #expect(Array(try summary("insights/machines/\(clone.key).json").days.keys) == [day(-1)])
        // No hardware hash at all (IOKit said nothing): the keys stay.
        #expect(try await publish(db, hardware: nil, at: later).key == clone.key)
    }

    @Test func newIdRemovesOwnStaleKeyFilesInSameCommit() async throws {
        try await setUpBrain()
        let db = try database()
        try writeFacts(db)
        _ = try await publish(db)
        let old = try #require(MachineProfile.load(home: home).id)
        let commits = try await commitCount()

        // Same Mac, another id (machine.json restored from an older backup): the old id's files are its own.
        var profile = MachineProfile.load(home: home)
        profile.id = "feedfacefeedface"
        try profile.save(home: home)
        let outcome = try await publish(db)
        let new = try #require(MachineProfile.load(home: home).id)
        #expect(new != old && outcome.key == new)
        #expect(try await commitCount() == commits + 1)
        let changes = try await git("show", "--name-status", "--no-renames", "--format=", "HEAD")
        #expect(Set(changes.split(separator: "\n").map(String.init)) == [
            "A\tinsights/machines/\(new).json", "A\tprojects/\(Self.project)/usage/\(new).json",
            "D\tinsights/machines/\(old).json", "D\tprojects/\(Self.project)/usage/\(old).json",
        ])
        #expect(UsageSummary.ownKeys(db).ids == [old, new])
    }

    @Test func cloneNeverRemovesOriginalMacFilesOrRepublishesItsDays() async throws {
        try await setUpBrain()
        let db = try database()
        try writeFacts(db)
        _ = try await publish(db)
        let original = try #require(MachineProfile.load(home: home).id)
        // Keys as an akit before hardware records wrote them: the index alone can't say whose they are.
        try db.run("UPDATE meta SET value = ? WHERE key = ?", #"{"ids":["\#(original)"],"pseudonyms":[]}"#, UsageSummary.ownKeysMeta)
        let originalFiles = ["insights/machines/\(original).json", "projects/\(Self.project)/usage/\(original).json"]
        let originalBytes = try originalFiles.map(bytes)

        // The clone: other hardware, the same machine.json and index. It removes nothing of the original
        // and publishes none of the days its copied index holds.
        let first = try await publish(db, hardware: "hw-2")
        let profile = MachineProfile.load(home: home)
        let clone = try #require(profile.id)
        #expect(clone != original && first.key == clone && profile.idSince == now)
        #expect(!first.changed.contains { $0.contains(original) }, "\(first.changed)")
        #expect(try originalFiles.map(bytes) == originalBytes)
        #expect(try summary("insights/machines/\(clone).json").days.isEmpty)

        // Its own session tomorrow is its first day; publishing again still leaves the original alone.
        try session("clone-1", started: at(-1, 10), in: db)
        try listing("clone-1", "tdd", at: at(-1, 10), hash: "h-tdd-1", in: db)
        try bind("clone-1", to: Self.project, .exact, in: db)
        let later = Date(timeIntervalSince1970: at(-1, 20))
        let second = try await publish(db, hardware: "hw-2", at: later)
        #expect(Set(second.committed) == ["insights/machines/\(clone).json", "projects/\(Self.project)/usage/\(clone).json"])
        #expect(Array(try summary("insights/machines/\(clone).json").days.keys) == [day(-1)])
        #expect(Array(try summary("projects/\(Self.project)/usage/\(clone).json").days.keys) == [day(-1)])
        #expect(try originalFiles.map(bytes) == originalBytes)
        #expect(UsageSummary.ownKeys(db).hardware == [clone: "hw-2"])

        // A lost machine.json on the clone: its own id and clone day come back from the index.
        try fm.removeItem(at: MachineProfile.file(home: home))
        let third = try await publish(db, hardware: "hw-2", at: later)
        #expect(third.key == clone && third.committed.isEmpty && MachineProfile.load(home: home).idSince == now)
        #expect(try await git("status", "--porcelain").isEmpty)

        // The clone reads the original as another Mac, only its days after the clone day.
        var file = try summary(originalFiles[0])
        file.days[day(-1)] = .init(sessions: 1, firstContextSum: 0, firstContextN: 0, skills: ["review": [1, 0, 0]])
        try write(".akit/registry/\(originalFiles[0])", String(decoding: UsageSummary.encode(file), as: UTF8.self))
        let ownership = UsageSummary.ownership(db, machine: MachineProfile.load(home: home), hardware: "hw-2", calendar: calendar)
        #expect(ownership == .init(own: [clone], copied: [original: day(0)]))
        let others = UsageSummary.load(brain: brainRoot, store: .brain(brainRoot), ownership: ownership, now: later, calendar: calendar)
        #expect(Array(others.machines.keys) == [original] && others.machines[original].map { Array($0.days.keys) } == [day(-1)])
        #expect(others.projects[Self.project]?[original]?.days.isEmpty == true)
    }

    @Test func cloneTellsTheOriginalApartBeforeItsFirstPublish() async throws {
        let brain = try await setUpBrain()
        let db = try database()
        try writeFacts(db)
        _ = try await publish(db)
        let original = try #require(MachineProfile.load(home: home).id)
        let profileBytes = try Data(contentsOf: MachineProfile.file(home: home))
        // The original Mac publishes a day after the clone was made (after the real clock, so it is never too old to read).
        let later = UsageSummary.day(Date().addingTimeInterval(2 * 86_400), calendar: calendar)
        var file = try summary("insights/machines/\(original).json")
        file.days[later] = .init(sessions: 1, firstContextSum: 0, firstContextN: 0, skills: ["review": [1, 0, 0]])
        try write(".akit/registry/insights/machines/\(original).json", String(decoding: UsageSummary.encode(file), as: UTF8.self))
        func others(hardware: String?) async throws -> UsageSummary.Others {
            try await Recommender.inputs(env: env, database: db, brain: brain, project: nil, projectsRoot: home.appending(path: "Projects"),
                                         hostName: "TestMac.local", hardware: hardware).others
        }

        // The Mac itself reads nothing of its own; a clone (other hardware, the same machine.json and
        // index) that hasn't published yet reads the original's later days.
        #expect(try await others(hardware: "hw-1").machines.isEmpty)
        #expect(try await others(hardware: "hw-2").machines[original].map { Array($0.days.keys) } == [later])
        let ownership = UsageSummary.ownership(db, machine: MachineProfile.load(home: home), hardware: "hw-2", now: now, calendar: calendar)
        #expect(ownership.copied == [original: day(0)] && ownership.own.count == 1 && !ownership.own.contains(original))
        // Identified in memory only.
        #expect(try Data(contentsOf: MachineProfile.file(home: home)) == profileBytes)

        // A broken machine.json identifies nothing: the index's keys stay left out.
        try write(".akit/machine.json", "{")
        let broken = UsageSummary.ownership(db, machine: MachineProfile.load(home: home), hardware: "hw-2", now: now, calendar: calendar)
        #expect(broken == .init(own: [original]))
    }

    @Test func otherMacsOldDaysAreNotRead() async throws {
        try await setUpBrain()
        let other = UsageSummary.File(version: 1, machine: "fedcba9876543210", name: "old", updated: "2026-01-01T10:00:00Z",
                                      days: [day(130): .init(sessions: 1, firstContextSum: 0, firstContextN: 0, skills: ["tdd": [1, 0, 0]]),
                                             day(3): .init(sessions: 1, firstContextSum: 0, firstContextN: 0, skills: ["tdd": [1, 0, 0]])])
        try write(".akit/registry/insights/machines/fedcba9876543210.json", String(decoding: UsageSummary.encode(other), as: UTF8.self))
        let others = UsageSummary.load(brain: brainRoot, store: nil, ownership: .init(), now: now, calendar: calendar)
        #expect(others.machines["fedcba9876543210"].map { Array($0.days.keys) } == [day(3)])
    }

    @Test func publishWhileAnImportRunsLeavesKeysForNextTime() async throws {
        try await setUpBrain()
        let db = try database()
        try writeFacts(db)
        var lock = try ImportLock.acquire(InsightsPaths(home: home).lock)
        #expect(lock != nil)
        let outcome = try await publish(db)
        withExtendedLifetime(lock) {}
        #expect(!outcome.committed.isEmpty && outcome.notes.count == 1, "\(outcome)")
        #expect(UsageSummary.ownKeys(db) == .init())
        lock = nil
        #expect(try await publish(db).notes.isEmpty)
        #expect(UsageSummary.ownKeys(db).ids == [try #require(MachineProfile.load(home: home).id)])
    }

    @Test func switchedMacCountsEachDayOnce() async throws {
        try await setUpBrain()
        let db = try database()
        func sessionOn(_ id: String, _ daysAgo: Int, _ hour: Double) throws {
            try session(id, started: at(daysAgo, hour), in: db)
            try listing(id, "tdd", at: at(daysAgo, hour), hash: "h", in: db)
        }
        try sessionOn("d3", 3, 12)
        try sessionOn("d2-before", 2, 10)
        // Personal until day 2, 15:00; published at 14:00.
        _ = try await publish(db, at: Date(timeIntervalSince1970: at(2, 14)))
        let id = try #require(MachineProfile.load(home: home).id)
        _ = try MachineProfile.change(to: MachineProfile(kind: .work), brain: brainRoot, home: home, hardware: "hw-1",
                                      now: Date(timeIntervalSince1970: at(2, 15)))
        try sessionOn("d2-after", 2, 18)
        try sessionOn("d1", 1, 12)
        let work = try await publish(db, at: Date(timeIntervalSince1970: at(1, 20)))
        // Back to personal on day 1, 22:00: that day stays under the work key.
        _ = try MachineProfile.change(to: MachineProfile(kind: .personal), brain: brainRoot, home: home, hardware: "hw-1",
                                      now: Date(timeIntervalSince1970: at(1, 22)))
        try sessionOn("d0", 0, 12)
        _ = try await publish(db)

        let personal = try summary("insights/machines/\(id).json").days
        let workDays = try summary("insights/machines/\(work.key).json").days
        #expect(Set(personal.keys) == [day(3), day(2), day(0)])
        #expect(personal[day(2)]?.skills["tdd"] == [1, 0, 0])  // the switch day stays under the old key, as published
        #expect(Set(workDays.keys) == [day(1)])
        #expect(Set(personal.keys).isDisjoint(with: workDays.keys))
    }

    @Test func ownMachineExcludedByIdNotName() async throws {
        let brain = try await setUpBrain()
        let db = try database()
        try writeFacts(db)
        _ = try await publish(db)
        let id = try #require(MachineProfile.load(home: home).id)
        // Another Mac with the same name.
        let other = UsageSummary.File(version: 1, machine: "fedcba9876543210", name: "TestMac", updated: "2026-09-01T10:00:00Z",
                                      days: [day(3): .init(sessions: 1, firstContextSum: 10, firstContextN: 1, skills: ["tdd": [1, 0, 0]])],
                                      descHashes: ["tdd": [[day(40), "h-other"]]])
        try write(".akit/registry/insights/machines/fedcba9876543210.json", String(decoding: UsageSummary.encode(other), as: UTF8.self))
        try write(".akit/registry/projects/\(Self.project)/usage/fedcba9876543210.json",
                  String(decoding: UsageSummary.encode(UsageSummary.File(version: 1, machine: "fedcba9876543210", days: other.days)), as: UTF8.self))

        let others = UsageSummary.load(brain: brainRoot, store: .brain(brainRoot), ownership: .init(own: [id]), now: now, calendar: calendar)
        #expect(Array(others.machines.keys) == ["fedcba9876543210"])
        #expect(others.machines["fedcba9876543210"]?.updated == "2026-09-01T10:00:00Z")
        #expect(others.projects == [Self.project: ["fedcba9876543210": UsageSummary.File(version: 1, machine: "fedcba9876543210", days: other.days)]])

        // Their description hashes feed the description window; this Mac's own file doesn't.
        let inputs = try await InsightsStats.inputs(env: env, database: db, brain: brain, projectsRoot: home.appending(path: "Projects"),
                                                    hostName: "TestMac.local", hardware: "hw-1")
        #expect(inputs.otherMacHashes["tdd"] == [.init(fromDay: day(40), hash: "h-other")])
    }

    @Test func syncImportsThenPublishesAndStillPullsWhenWorkFilterRefuses() async throws {
        try await setUpBrain()
        try write(".akit/registry/skills/mine/SKILL.md", "---\nname: mine\ndescription: Own skill\n---\n")
        try await git("add", "--all")
        try await git("commit", "-qm", "Mine")
        let remote = home.appending(path: "remote.git"), otherMac = home.appending(path: "other/registry")
        try await git("init", "--quiet", "--bare", "--initial-branch=main", remote.path, in: home)
        try await git("remote", "add", "origin", remote.path)
        try await git("push", "--quiet", "-u", "origin", "HEAD:main")
        try await git("branch", "--quiet", "--set-upstream-to=origin/main")
        try fm.createDirectory(at: otherMac.deletingLastPathComponent(), withIntermediateDirectories: true)
        try await git("clone", "--quiet", remote.path, otherMac.path, in: home)

        // A recent Claude session listing and calling the brain skill.
        let time = Date().addingTimeInterval(-3600)
        func line(_ type: String, _ uuid: String, _ seconds: Double, _ fields: [String: Any]) throws -> String {
            let object = fields.merging(["type": type, "uuid": uuid, "sessionId": "l1", "version": "2.1.283", "cwd": "/work/app",
                                         "timestamp": time.addingTimeInterval(seconds).formatted(.iso8601)]) { $1 }
            return String(decoding: try JSONSerialization.data(withJSONObject: object, options: .sortedKeys), as: UTF8.self)
        }
        try write(".claude/projects/-work-app/l1.jsonl", [
            try line("attachment", "L1", 0, ["attachment": ["type": "skill_listing", "isInitial": true, "names": ["mine"],
                                                            "content": "- mine: Own skill"]]),
            try line("assistant", "A1", 1, ["message": ["id": "m1", "model": "claude-opus-5-5",
                                                        "usage": ["input_tokens": 3, "output_tokens": 1],
                                                        "content": [["type": "tool_use", "id": "t1", "name": "Skill", "input": ["skill": "mine"]]]]]),
        ].joined(separator: "\n") + "\n")

        func sync() async -> (code: Int32, out: String, err: String) {
            var out: [String] = [], err: [String] = []
            let code = await AKitCLI.run(["sync"], env: env, cwd: home, projectsRoot: home.appending(path: "Projects"),
                                         hostName: "TestMac.local", out: { out.append($0) }, err: { err.append($0) },
                                         hardwareHash: { "hw-1" })
            return (code, out.joined(separator: "\n"), err.joined(separator: "\n"))
        }
        // Personal: the session is imported, then published, then pushed.
        let first = await sync()
        #expect(first.code == 0 && first.err.isEmpty, "\(first)")
        let id = try #require(MachineProfile.load(home: home).id)
        #expect(first.out.contains("Update usage summaries (TestMac)") && first.out.contains("Pushed 1 commit."), "\(first.out)")
        let pushed = try await git("--git-dir", remote.path, "show", "main:insights/machines/\(id).json", in: home)
        #expect(pushed.contains("\"mine\":[1,1,0]"), "\(pushed)")

        // Work, and the brain has no email of its own: the publish is refused, the pull still happens.
        let work = await machine("work")
        #expect(work.code == 0)
        try await git("config", "--local", "--unset", "user.email")
        try await git("pull", "--quiet", in: otherMac)
        try write("other/registry/layers/core/notes.md", "from the other Mac\n")
        try await git("add", "--all", in: otherMac)
        try await git("commit", "-qm", "Other Mac", in: otherMac)
        try await git("push", "--quiet", in: otherMac)
        let pseudonym = try #require(MachineProfile.load(home: home).pseudonym)

        let second = await sync()
        #expect(second.code == 0, "\(second)")
        #expect(second.err.contains("usage summaries not published") && second.err.contains("git email"), "\(second.err)")
        #expect(second.out.contains("Pulled 1 commit."), "\(second.out)")
        #expect(fm.fileExists(atPath: brainRoot.appending(path: "layers/core/notes.md").path))
        #expect(!fm.fileExists(atPath: brainRoot.appending(path: "insights/machines/\(pseudonym).json").path))

        // The app's Sync runs the same sequence; its result lines say what was published or why not.
        let brain = try #require(Brain.load(from: brainRoot))
        func appSync() async throws -> InsightsSync.Outcome {
            try await InsightsSync.run(env: env, brain: brain, projectsRoot: home.appending(path: "Projects"),
                                       hostName: "TestMac.local", hardware: "hw-1")
        }
        try write("other/registry/layers/core/notes.md", "from the other Mac, again\n")
        try await git("commit", "-qam", "Other Mac again", in: otherMac)
        try await git("push", "--quiet", in: otherMac)
        let refused = try await appSync()
        #expect(refused.published.outcome == nil && refused.sync.pulled == 1, "\(refused)")
        #expect(refused.published.lines.count == 1 && refused.published.lines[0].hasPrefix("Usage summaries not published:"),
                "\(refused.published.lines)")

        // With the identity back the publish runs; the session is from before the switch to work, so there is nothing to commit.
        try await git("config", "--local", "user.email", Self.email)
        let quiet = try await appSync()
        #expect(quiet.published.outcome?.isWork == true && quiet.published.lines.isEmpty && quiet.sync.pushed == 0, "\(quiet)")
    }

    @Test func appSyncLinesSayWhatWasPublished() {
        var outcome = SummaryPublisher.Outcome(key: "0123456789abcdef", isWork: false, message: "Update usage summaries (TestMac)")
        #expect(InsightsSync.Published(outcome: outcome).lines.isEmpty)
        outcome.committed = ["insights/machines/0123456789abcdef.json", "projects/x/usage/0123456789abcdef.json"]
        #expect(InsightsSync.Published(outcome: outcome).lines == ["Published this Mac's usage summaries (2 files)."])
        let work = SummaryPublisher.Outcome(key: "work-abc123", isWork: true, message: "", committed: ["insights/machines/work-abc123.json"],
                                            notes: ["A step is left for the next publish."])
        #expect(InsightsSync.Published(outcome: work).lines == [
            "Published this work Mac's usage summary (1 file): only brain-skill counts, under its pseudonym work-abc123.",
            "A step is left for the next publish.",
        ])
        #expect(InsightsSync.Published(problem: "No email.").lines == ["Usage summaries not published: No email."])
    }
}
