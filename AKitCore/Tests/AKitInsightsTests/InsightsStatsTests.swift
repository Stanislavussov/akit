import Foundation
import Testing
import AKitBrain
import AKitFoundation
import AKitHarnesses
import AKitSkills
@testable import AKitCommandLine
@testable import AKitInsights

/// `akit stats`: owners, description windows, ≈ context space and calls. Facts are written straight
/// into a temporary index in a temporary fake home; the brain is a temporary git repository.
struct InsightsStatsTests {
    let home: URL
    let fm = FileManager.default
    let calendar = Calendar.current
    /// Local midnight of a fixed day, and "now" in its evening.
    let today: Date
    let now: Date

    init() throws {
        home = fm.temporaryDirectory.appending(path: "akit-stats-\(UUID().uuidString)")
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

    // MARK: Helpers

    func database() throws -> IndexDatabase { try IndexSchema.open(InsightsPaths(home: home).database) }

    /// `hour` o'clock (local) `daysAgo` days before today.
    func at(_ daysAgo: Int, _ hour: Double = 12) -> Double {
        (calendar.date(byAdding: .day, value: -daysAgo, to: today) ?? today).timeIntervalSince1970 + hour * 3600
    }

    func write(_ path: String, _ text: String = "") throws {
        let url = home.appending(path: path)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    func session(_ id: String, started: Double, harness: String = "claude", in db: IndexDatabase) throws {
        try db.run("INSERT INTO sessions(key, harness, native_id, started, source_id, parser_version) VALUES(?, ?, ?, ?, 0, 1)",
                   "\(harness):\(id)", harness, id, started)
    }

    /// One listing line of `skill`; `hash` nil for a name-only line.
    func listing(_ id: String, _ skill: String, at ts: Double, hash: String?, chars: Int = 40, subagent: Bool = false,
                 in db: IndexDatabase) throws {
        try db.run("""
            INSERT INTO skill_listings(harness, listing_key, skill, session_key, ts, is_subagent, is_initial, desc_hash, desc_chars,
              source_id, parser_version) VALUES('claude', ?, ?, ?, ?, ?, 1, ?, ?, 0, 1)
            """, UUID().uuidString, skill, "claude:\(id)", ts, subagent, hash, hash == nil ? 0 : chars)
    }

    func request(_ id: String, at ts: Double, context: Int = 100, subagent: Bool = false, harness: String = "claude",
                 in db: IndexDatabase) throws {
        try db.run("""
            INSERT INTO requests(harness, event_key, session_key, ts, input, cache_read, cache_write, is_subagent, source_id, parser_version)
            VALUES(?, ?, ?, ?, ?, 0, 0, ?, 0, 1)
            """, harness, UUID().uuidString, "\(harness):\(id)", ts, context, subagent)
    }

    func call(_ id: String, _ skill: String, at ts: Double, by: String = "model", subagent: Bool = false, harness: String = "claude",
              kind: String? = nil, in db: IndexDatabase) throws {
        try db.run("""
            INSERT INTO skill_calls(harness, event_key, session_key, ts, skill, by, is_subagent, source_id, parser_version, extra)
            VALUES(?, ?, ?, ?, ?, ?, ?, 0, 1, ?)
            """, harness, UUID().uuidString, "\(harness):\(id)", ts, skill, by, subagent, kind.map { #"{"kind":"\#($0)"}"# })
    }

    func bind(_ id: String, to project: String, _ confidence: Confidence, in db: IndexDatabase) throws {
        try db.run("""
            INSERT INTO bindings(session_key, project_id, method, confidence, decided_at, resolver_version) VALUES(?, ?, ?, ?, 0, 1)
            """, "claude:\(id)", project, confidence == .low ? "sibling" : "live", confidence.rawValue)
    }

    func report(_ db: IndexDatabase, _ options: InsightsStats.Options = .init(top: nil),
                inputs: InsightsStats.Inputs = .init()) throws -> StatsReport {
        try InsightsStats.report(db, options: options, inputs: inputs, now: now)
    }

    func skill(_ name: String, in report: StatsReport) throws -> StatsReport.SkillStats {
        try #require(report.skills.first { $0.name == name }, "\(name) in \(report.skills.map(\.name))")
    }

    func iso(_ ts: Double) -> String { Date(timeIntervalSince1970: ts).formatted(.iso8601) }

    @discardableResult
    func git(_ arguments: String..., in folder: URL) async throws -> String {
        let git = try #require(env.findExecutable("git"))
        let result = try #require(await ProcessRunner.run(git, arguments: arguments, directory: folder,
                                                          environment: env.variables.merging(["PATH": env.pathForChildProcesses]) { $1 },
                                                          timeout: 30))
        #expect(result.succeeded, "git \(arguments): \(result.output)")
        return result.output
    }
}

// MARK: - Owners and windows

extension InsightsStatsTests {
    @Test func ownersClassifiedFromScannerAndBrainLinks() throws {
        let app = home.appending(path: "Projects/app")
        for name in ["kept", "twin"] { try write(".akit/registry/skills/\(name)/SKILL.md", "---\nname: \(name)\ndescription: Brain\n---\n") }
        try write(".akit/registry/layers/web/layer.yaml", "skills: [kept]\n")
        // Rendered as AKit does: into .agents/skills, which .claude/skills links to.
        try write("Projects/app/.agents/skills/kept/SKILL.md", "---\nname: kept\ndescription: Rendered\n---\n")
        try write("Projects/app/.agents/skills/twin/SKILL.md", "---\nname: twin\ndescription: Not from AKit\n---\n")
        try fm.createDirectory(at: app.appending(path: ".claude"), withIntermediateDirectories: true)
        try fm.createSymbolicLink(atPath: app.appending(path: ".claude/skills").path, withDestinationPath: "../.agents/skills")
        try write(".claude/skills/mine/SKILL.md", "---\nname: mine\ndescription: Own\n---\n")
        let sha = Checksum.sha256(Data("---\nname: kept\ndescription: Rendered\n---\n".utf8))
        try write(".akit/registry/projects/github.com/me/app/answers.json", #"{"layers": ["web"], "values": {}, "targets": []}"#)
        try write(".akit/registry/projects/github.com/me/app/lock.json", """
            {"brainDirty": false, "files": {".agents/skills/kept/SKILL.md": {"layers": ["web"], "sha256": "\(sha)"},
              ".claude/skills": {"layers": [], "link": "../.agents/skills"}}}
            """)
        let brain = try #require(Brain.load(from: Brain.defaultRoot(home: home)))
        let installed = SkillScanner.scan(installations: HarnessCatalog.detectAll(in: env), extraProjects: [app], in: env)
        #expect(Set(installed.map(\.name)).isSuperset(of: ["kept", "twin", "mine"]), "\(installed.map(\.name))")
        let links = BrainLinks.links(for: installed, brain: brain, folders: ["github.com/me/app": app])
        let names = ["kept", "twin", "mine", "marketing:seo-audit", "init"]

        let owners = SkillOwners.classify(names, installed: installed, links: links, home: home)
        #expect(owners["kept"] == .layer(["web"]))
        #expect(owners["twin"] == .unknown, "the brain has a twin, but AKit didn't render this copy")
        #expect(owners["mine"] == .handInstalled("~/.claude/skills/mine/SKILL.md"))
        #expect(owners["marketing:seo-audit"] == .plugin("marketing"))
        #expect(owners["init"] == .builtIn)

        // Without a brain no own skill can be told apart from a layer skill.
        let blind = SkillOwners.classify(names, installed: installed, links: nil, home: home)
        #expect(blind["kept"] == .unknown && blind["mine"] == .unknown && blind["twin"] == .unknown)
        #expect(blind["marketing:seo-audit"] == .plugin("marketing") && blind["init"] == .builtIn)
    }

    @Test func descriptionChangeRestartsWindow() throws {
        let db = try database()
        for (id, day, hash) in [("s1", 10, "A"), ("s2", 5, "B"), ("s3", 2, "B")] {
            try session(id, started: at(day), in: db)
            try listing(id, "tdd", at: at(day), hash: hash, in: db)
            try request(id, at: at(day, 12.1), in: db)
            try call(id, "tdd", at: at(day, 12.2), in: db)
        }
        #expect(try DescriptionWindow.hashStarts(db)["tdd"] == .init(date: Date(timeIntervalSince1970: at(5)), versions: 2))
        let tdd = try skill("tdd", in: try report(db))
        #expect(tdd.windowStart == iso(at(5)))
        #expect(tdd.listedSessions == 2 && tdd.listedDays == 2 && tdd.modelCalls == 2, "s1 saw the old text: \(tdd)")
    }

    @Test func nameOnlyListingDoesNotRestartWindow() throws {
        let db = try database()
        for (id, day, hash) in [("s1", 10, "A"), ("s2", 5, nil), ("s3", 2, "A")] as [(String, Int, String?)] {
            try session(id, started: at(day), in: db)
            try listing(id, "tdd", at: at(day), hash: hash, in: db)
        }
        #expect(try DescriptionWindow.hashStarts(db)["tdd"] == .init(date: Date(timeIntervalSince1970: at(10)), versions: 1))
        // Only names ever: the window starts at the first listing.
        try session("s4", started: at(8), in: db)
        try listing("s4", "bare", at: at(8), hash: nil, in: db)
        try listing("s1", "bare", at: at(10, 13), hash: nil, in: db)
        #expect(try DescriptionWindow.hashStarts(db)["bare"] == .init(date: Date(timeIntervalSince1970: at(10, 13)), versions: 0))
        #expect(try skill("tdd", in: try report(db)).listedSessions == 2, "s2 listed it by name only")
    }

    @Test func nameOnlyExposuresDoNotCountAsListed() throws {
        let db = try database()
        // s1 lists tdd with its description; s2 and s3 by name only (over budget), s3 then with it.
        try session("s1", started: at(3), in: db)
        try listing("s1", "tdd", at: at(3), hash: "A", chars: 80, in: db)
        try request("s1", at: at(3, 12.5), in: db)
        try session("s2", started: at(2), in: db)
        try listing("s2", "tdd", at: at(2), hash: nil, in: db)
        try request("s2", at: at(2, 12.5), in: db)
        try call("s2", "tdd", at: at(2, 13), in: db)
        try session("s3", started: at(1), in: db)
        try listing("s3", "tdd", at: at(1), hash: nil, in: db)
        try request("s3", at: at(1, 12.2), in: db)
        try listing("s3", "tdd", at: at(1, 12.4), hash: "A", chars: 80, in: db)
        try request("s3", at: at(1, 12.5), in: db)
        // Only ever by name: listed, but in no session with its description.
        try listing("s2", "bare", at: at(2), hash: nil, in: db)

        let result = try report(db)
        let tdd = try skill("tdd", in: result)
        #expect(tdd.listedSessions == 2 && tdd.listedDays == 2, "s1 and s3, not s2: \(tdd)")
        #expect(tdd.approxContextSpace == 40, "80 chars / 4 × the one request after each described listing")
        #expect(tdd.modelCalls == 1 && tdd.callRate == 0, "a call in a name-only session still counts as a call: \(tdd)")
        let bare = try skill("bare", in: result)
        #expect(bare.listedSessions == 0 && bare.listedDays == 0 && bare.approxContextSpace == 0)
    }

    @Test func droppedDescriptionsFinding() throws {
        let db = try database()
        // Four Claude sessions with a listing: two of them lost descriptions, one lost two skills.
        for (id, day) in [("s1", 4), ("s2", 3), ("s3", 2), ("s4", 1)] {
            try session(id, started: at(day), in: db)
            try listing(id, "kept", at: at(day), hash: "K", in: db)
        }
        try listing("s2", "rare", at: at(3), hash: nil, in: db)
        try listing("s2", "odd", at: at(3), hash: nil, in: db)
        try listing("s3", "rare", at: at(2), hash: nil, in: db)
        try listing("s3", "rare", at: at(2, 13), hash: nil, in: db)  // the same session twice counts once
        // Not counted: a subagent's name-only listing, a session without any listing, a session out of the window.
        try listing("s4", "sub", at: at(1, 13), hash: nil, subagent: true, in: db)
        try session("empty", started: at(1), in: db)
        try session("old", started: at(40), in: db)
        try listing("old", "rare", at: at(40), hash: nil, in: db)

        let dropped = try report(db).droppedDescriptions
        #expect(dropped == .init(sessions: 4, withNameOnly: 2, share: 0.5,
                                 skills: [.init(name: "rare", sessions: 2), .init(name: "odd", sessions: 1)]), "\(dropped)")
        #expect(dropped.text == "Descriptions dropped by the harness: 2 of 4 Claude sessions (50%) listed some skills by name only; "
                + "most often rare (2), odd (1). Such sessions don't count as listed for those skills.")
        #expect(AKitCLI.statsText(try report(db), details: false).contains("\n\nDescriptions dropped by the harness: 2 of 4"))
        // A project: only its sessions.
        try bind("s2", to: "github.com/o/r", .exact, in: db)
        try bind("s1", to: "github.com/o/r", .exact, in: db)
        let project = try report(db, .init(project: "github.com/o/r", top: nil)).droppedDescriptions
        #expect(project.sessions == 2 && project.withNameOnly == 1 && project.share == 0.5 && project.skills.map(\.name) == ["odd", "rare"])
        // No Claude listing at all: no finding line.
        let none = try report(db, .init(days: 0, top: nil))
        #expect(none.droppedDescriptions.sessions == 0 && none.droppedDescriptions.text == nil)
        #expect(!AKitCLI.statsText(none, details: false).contains("Descriptions dropped"))
    }

    @Test func oscillatingDescriptionsDoNotRestartWindow() throws {
        let db = try database()
        for (index, hash) in ["A", "B", "A", "B"].enumerated() {
            let id = "s\(index)", day = 10 - 2 * index
            try session(id, started: at(day), in: db)
            try listing(id, "dataviz", at: at(day), hash: hash, in: db)
        }
        let starts = try DescriptionWindow.hashStarts(db)
        #expect(starts["dataviz"] == .init(date: Date(timeIntervalSince1970: at(8)), versions: 2), "one restart, at the first B")
        #expect(try skill("dataviz", in: try report(db)).listedSessions == 3)

        // Other Macs' hashes: a text seen there first is no news; a new one restarts at its day.
        func dayText(_ ts: Double) -> String {
            let parts = calendar.dateComponents([.year, .month, .day], from: Date(timeIntervalSince1970: ts))
            return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
        }
        let known = DescriptionWindow.OtherMacHash(fromDay: dayText(at(20)), hash: "B")
        #expect(try DescriptionWindow.hashStarts(db, otherMacs: ["dataviz": [known]])["dataviz"]?.date == Date(timeIntervalSince1970: at(10)))
        let new = DescriptionWindow.OtherMacHash(fromDay: dayText(at(3)), hash: "C")
        #expect(try DescriptionWindow.hashStarts(db, otherMacs: ["dataviz": [new]])["dataviz"]
                == .init(date: Date(timeIntervalSince1970: at(3, 0)), versions: 3))
    }

    @Test func brainSkillWindowUsesAuthorDateOfDescriptionChange() async throws {
        let brain = home.appending(path: ".akit/registry")
        try fm.createDirectory(at: brain, withIntermediateDirectories: true)
        try await git("init", "-q", "-b", "main", in: brain)
        for (description, body, date) in [("One", "", "2026-01-01T10:00:00+00:00"), ("Two", "", "2026-02-01T10:00:00+02:00"),
                                          ("Two", "More body.", "2026-03-01T10:00:00+00:00")] {
            try write(".akit/registry/skills/tdd/SKILL.md", "---\nname: tdd\ndescription: \(description)\n---\n\(body)\n")
            try write(".akit/registry/skills/lint/SKILL.md", "---\nname: lint\ndescription: Lint\n---\n\(body)\n")
            try await git("add", "-A", in: brain)
            try await git("commit", "-q", "-m", "Edit", "--date", date, in: brain)
        }
        let db = try database()
        let expected = try #require(ISO8601DateFormatter().date(from: "2026-02-01T08:00:00Z"))
        let first = try #require(ISO8601DateFormatter().date(from: "2026-01-01T10:00:00Z"))
        // A generous budget: on a busy Mac the real git calls can take longer than the default 10 s.
        let starts = await DescriptionWindow.brainStarts(brainRoot: brain, skills: ["tdd", "lint", "ghost"], database: db, env: env,
                                                         budget: 120)
        #expect(starts == ["tdd": expected, "lint": first], "author dates, not commit dates; the body edit doesn't count")

        // Cached per brain HEAD: the next run asks git only for HEAD.
        final class Calls: @unchecked Sendable {
            let lock = NSLock()
            var arguments: [[String]] = []
        }
        let calls = Calls(), live = CaptureInstaller.liveRunner(env)
        let counting: CommandRunner = { executable, arguments, directory, timeout in
            calls.lock.withLock { calls.arguments.append(arguments) }
            return await live(executable, arguments, directory, timeout)
        }
        let again = await DescriptionWindow.brainStarts(brainRoot: brain, skills: ["tdd", "lint"], database: db, env: env, run: counting,
                                                     budget: 120)
        #expect(again == ["tdd": expected, "lint": first] && calls.arguments == [["rev-parse", "HEAD"]], "\(calls.arguments)")
    }
}

// MARK: - Counting

extension InsightsStatsTests {
    @Test func callsOnlyCountAfterFirstListing() throws {
        let db = try database()
        try session("s1", started: at(3), in: db)
        try call("s1", "tdd", at: at(3, 11), in: db)  // before the skill was listed
        try request("s1", at: at(3, 11), in: db)
        try listing("s1", "tdd", at: at(3, 12), hash: "A", chars: 80, in: db)
        try request("s1", at: at(3, 12), in: db)
        try request("s1", at: at(3, 13), in: db)
        try call("s1", "tdd", at: at(3, 13), in: db)
        try call("s1", "tdd", at: at(3, 14), by: "user", kind: "skill", in: db)
        try call("s1", "tdd", at: at(3, 15), by: "user", kind: "command", in: db)
        try call("s1", "tdd", at: at(3, 16), by: "user", in: db)  // an older row without a kind is a skill call
        // A Pi session: no listing, its calls count from the window start.
        try session("p1", started: at(2), harness: "pi", in: db)
        try call("p1", "tdd", at: at(2), harness: "pi", in: db)
        try call("p1", "tdd", at: at(2, 13), by: "user", harness: "pi", kind: "skill", in: db)

        let tdd = try skill("tdd", in: try report(db))
        #expect(tdd.modelCalls == 1 && tdd.userCalls == 3 && tdd.piModelCalls == 1, "\(tdd)")
        #expect(tdd.listedSessions == 1 && tdd.callRate == 1)
        #expect(tdd.approxTokens == 20 && tdd.approxContextSpace == 40, "80 chars / 4 × the 2 requests from the listing on")
    }

    @Test func subagentCallsCountSubagentSessionsDont() throws {
        let db = try database()
        try session("s1", started: at(3), in: db)
        try listing("s1", "tdd", at: at(3), hash: "A", in: db)
        try listing("s1", "tdd", at: at(3, 13), hash: "A", subagent: true, in: db)
        try request("s1", at: at(3, 12.5), in: db)
        for hour in [13.1, 13.2, 13.3] { try request("s1", at: at(3, hour), subagent: true, in: db) }
        try call("s1", "tdd", at: at(3, 13.2), subagent: true, in: db)
        // Listed only in a subagent run: not a listed session, but its call counts.
        try session("s2", started: at(2), in: db)
        try listing("s2", "tdd", at: at(2, 13), hash: "A", subagent: true, in: db)
        try request("s2", at: at(2, 13.1), subagent: true, in: db)
        try call("s2", "tdd", at: at(2, 13.2), subagent: true, in: db)

        let result = try report(db)
        let tdd = try skill("tdd", in: result)
        #expect(tdd.listedSessions == 1 && tdd.listedDays == 1 && tdd.modelCalls == 2 && tdd.callRate == 1, "\(tdd)")
        #expect(tdd.approxContextSpace == 10, "40 chars / 4 × the one main request")
        #expect(result.summary.sessions == 2 && result.summary.requests == 1)
    }

    @Test func lowBindingsExcludedByDefault() throws {
        let db = try database()
        for (id, confidence) in [("s1", Confidence.exact), ("s2", .medium), ("s3", .low), ("s4", nil)] as [(String, Confidence?)] {
            try session(id, started: at(2), in: db)
            try listing(id, "tdd", at: at(2), hash: "A", in: db)
            try request(id, at: at(2, 12.5), in: db)
            if let confidence { try bind(id, to: "github.com/o/r", confidence, in: db) }
        }
        let project = try report(db, .init(project: "github.com/o/r", top: nil))
        #expect(project.summary.sessions == 2 && project.scope == .init(project: "github.com/o/r", bindings: ["exact", "high", "medium"]))
        #expect(try skill("tdd", in: project).listedSessions == 2)
        let withLow = try report(db, .init(project: "github.com/o/r", bindings: try BindingSet.parse("exact,high,medium,low"), top: nil))
        #expect(withLow.summary.sessions == 3 && withLow.scope.bindings == ["exact", "high", "medium", "low"])
        let all = try report(db)
        #expect(all.summary.sessions == 4 && all.scope.project == nil)
        // The window: a session older than --days is out.
        try session("old", started: at(40), in: db)
        #expect(try report(db).summary.sessions == 4 && report(db, .init(days: 60, top: nil)).summary.sessions == 5)
    }
}

// MARK: - Output

extension InsightsStatsTests {
    /// Three skills of different sizes in one session with two requests, owned by a layer, a plugin and nobody known.
    func threeSkills(_ db: IndexDatabase) throws -> InsightsStats.Inputs {
        try session("s1", started: at(1), in: db)
        for (name, chars) in [("small", 40), ("mkt:big", 400), ("medium", 120)] {
            try listing("s1", name, at: at(1), hash: name, chars: chars, in: db)
        }
        try request("s1", at: at(1, 12.1), context: 5000, in: db)
        try request("s1", at: at(1, 12.2), in: db)
        return .init(owners: ["small": .layer(["core"]), "mkt:big": .plugin("mkt"), "medium": .handInstalled("~/.claude/skills/medium/SKILL.md")])
    }

    @Test func compactOutputRespectsTop() throws {
        let db = try database()
        let inputs = try threeSkills(db)
        let compact = try report(db, .init(top: 2), inputs: inputs)
        #expect(compact.skills.map(\.name) == ["mkt:big", "medium"] && compact.omitted.skills == 1)
        #expect(compact.summary.byOwner.map(\.owner) == ["layer", "plugin", "handInstalled", "builtIn", "unknown"])
        #expect(compact.summary.byOwner.map(\.skills) == [1, 1, 1, 0, 0], "the summary covers every skill, not only the top")
        #expect(compact.summary.approxListingTokensPerRequest == 140, "(10 + 100 + 30) tokens in each of the 2 requests")
        let text = AKitCLI.statsText(compact, details: false)
        #expect(text.contains("Top 2 by ≈ context space") && text.contains("mkt:big (plugin mkt): ≈ 200 context space, ≈ 100 tokens per request; listed with its description in 1 session on 1 day; model calls 0 (0% of sessions), user calls 0"), "\(text)")
        #expect(!text.contains("small (") && text.contains("1 more skill: --top N, or --details for all."))
        #expect(text.contains("  plugin: 1 skill, ≈ 100") && !text.contains("built-in:"), "\(text)")
        #expect(!text.contains("counted since"))

        let details = AKitCLI.statsText(try report(db, .init(top: nil), inputs: inputs), details: true)
        #expect(details.contains("Skills by ≈ context space") && details.contains("small (layer core)") && !details.contains("more skill"))
        #expect(details.contains("counted since its description window start \(iso(at(1)))"), "\(details)")
    }

    @Test func jsonShapeIsStable() throws {
        let db = try database()
        let now = Date(timeIntervalSince1970: 1_790_000_000), ts = now.timeIntervalSince1970
        try session("s1", started: ts - 600, in: db)
        try listing("s1", "alpha", at: ts - 600, hash: "h1", chars: 40, in: db)
        try listing("s1", "mkt:seo", at: ts - 600, hash: "h2", chars: 80, in: db)
        try request("s1", at: ts - 590, context: 1000, in: db)
        try request("s1", at: ts - 580, in: db)
        try call("s1", "alpha", at: ts - 585, in: db)
        try session("p1", started: ts - 500, harness: "pi", in: db)
        try request("p1", at: ts - 490, context: 2000, harness: "pi", in: db)
        try call("p1", "alpha", at: ts - 480, harness: "pi", in: db)
        let report = try InsightsStats.report(db, inputs: .init(owners: ["alpha": .layer(["core"]), "mkt:seo": .plugin("mkt")]), now: now)
        #expect(AKitCLI.encode(report) == #"""
            {
              "droppedDescriptions" : {
                "sessions" : 1,
                "share" : 0,
                "skills" : [

                ],
                "withNameOnly" : 0
              },
              "generated" : "2026-09-21T14:13:20Z",
              "import" : {
                "last" : null,
                "running" : false
              },
              "notes" : [
                "≈ tokens = description characters / k (k 4.0 Latin, 2.5 Cyrillic, defaults until before/after measurements calibrate them)",
                "Pi records no skill list; Pi calls only protect skills"
              ],
              "omitted" : {
                "skills" : 0
              },
              "scope" : {
                "bindings" : [
                  "exact",
                  "high",
                  "medium"
                ],
                "project" : null
              },
              "skills" : [
                {
                  "approxContextSpace" : 40,
                  "approxTokens" : 20,
                  "callRate" : 0,
                  "listedDays" : 1,
                  "listedSessions" : 1,
                  "modelCalls" : 0,
                  "name" : "mkt:seo",
                  "owner" : {
                    "kind" : "plugin",
                    "name" : "mkt"
                  },
                  "piModelCalls" : 0,
                  "userCalls" : 0,
                  "windowStart" : "2026-09-21T14:03:20Z"
                },
                {
                  "approxContextSpace" : 20,
                  "approxTokens" : 10,
                  "callRate" : 1,
                  "listedDays" : 1,
                  "listedSessions" : 1,
                  "modelCalls" : 1,
                  "name" : "alpha",
                  "owner" : {
                    "kind" : "layer",
                    "name" : "core"
                  },
                  "piModelCalls" : 1,
                  "userCalls" : 0,
                  "windowStart" : "2026-09-21T14:03:20Z"
                }
              ],
              "summary" : {
                "approxListingTokensPerRequest" : 30,
                "byOwner" : [
                  {
                    "approxTokens" : 10,
                    "owner" : "layer",
                    "skills" : 1
                  },
                  {
                    "approxTokens" : 20,
                    "owner" : "plugin",
                    "skills" : 1
                  },
                  {
                    "approxTokens" : 0,
                    "owner" : "handInstalled",
                    "skills" : 0
                  },
                  {
                    "approxTokens" : 0,
                    "owner" : "builtIn",
                    "skills" : 0
                  },
                  {
                    "approxTokens" : 0,
                    "owner" : "unknown",
                    "skills" : 0
                  }
                ],
                "firstRequestContext" : {
                  "median" : 1000,
                  "p90" : 2000
                },
                "requests" : 3,
                "sessions" : 2
              },
              "version" : 1,
              "window" : {
                "days" : 30,
                "from" : "2026-08-22T14:13:20Z",
                "to" : "2026-09-21T14:13:20Z"
              }
            }
            """#)
    }

    @Test func noMoneyWordsInOutput() throws {
        let db = try database()
        let inputs = try threeSkills(db)
        try call("s1", "small", at: at(1, 12.3), in: db)
        try db.run("INSERT INTO meta(key, value) VALUES('k.latin', '3.5'), ('k.cyrillic', '2.0'), ('k.pairs', '2')")
        let result = try report(db, .init(project: nil, top: 1), inputs: inputs)
        #expect(result.notes.contains { $0.contains("calibrated from 2 before/after pairs") }, "\(result.notes)")
        for text in [AKitCLI.statsText(result, details: false), AKitCLI.statsText(try report(db, inputs: inputs), details: true),
                     AKitCLI.encode(result)] {
            let lower = text.lowercased()
            for word in ["$", "cost", "price", "usd", "money", "dollar"] { #expect(!lower.contains(word), "“\(word)” in \(text)") }
            #expect(text.contains("≈"))
        }
    }

    @Test func contextSizeByScriptAndCalibration() throws {
        #expect(ContextSize.script(of: "Tests first, then code") == .latin)
        #expect(ContextSize.script(of: "Сначала тесты, then code") == .cyrillic)
        #expect(ContextSize.approxTokens(chars: 100, script: .latin) == .init(tokens: 25))
        #expect(ContextSize.approxTokens(chars: 100, script: .cyrillic).tokens == 40 && ContextSize.approxTokens(chars: 1, script: .latin).isApprox)
        let db = try database()
        try db.run("INSERT INTO meta(key, value) VALUES('k.latin', '3.0'), ('k.cyrillic', '2.0'), ('k.pairs', '1')")
        #expect(try ContextSize.calibration(db) == ContextSize.defaults, "one pair is not enough")
        try db.run("UPDATE meta SET value = '2' WHERE key = 'k.pairs'")
        #expect(try ContextSize.calibration(db) == .init(latin: 3, cyrillic: 2, pairs: 2))
        // A session's own description size counts, with the skill's script.
        try session("s1", started: at(1), in: db)
        try listing("s1", "ru", at: at(1), hash: "r", chars: 90, in: db)
        try request("s1", at: at(1, 13), in: db)
        let ru = try skill("ru", in: try report(db, inputs: .init(descriptions: ["ru": "Проверяет код"])))
        #expect(ru.approxTokens == 45 && ru.approxContextSpace == 45)
    }
}
