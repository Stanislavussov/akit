import Foundation
import Testing
@testable import AKitCore

/// `akit recommend`: the auto → manual rule, its actions by owner, `apply` and `dismiss`. Facts are
/// written straight into a temporary index in a temporary fake home; the brain is a temporary git
/// repository with its own test identity; the hardware hash is injected.
struct RecommenderTests {
    let home: URL
    let fm = FileManager.default
    let calendar = Calendar.current
    let now: Date
    let today: Date
    static let email = "me@example.com"
    static let project = "github.com/acme/app"

    init() throws {
        home = fm.temporaryDirectory.appending(path: "akit-recommend-\(UUID().uuidString)")
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
        now = Date()
        today = calendar.startOfDay(for: now)
    }

    var env: HarnessEnvironment {
        HarnessEnvironment(homeDirectory: home, variables: [
            "HOME": home.path, "GIT_CONFIG_NOSYSTEM": "1",
            "GIT_AUTHOR_NAME": "Test", "GIT_AUTHOR_EMAIL": "test@example.com",
            "GIT_COMMITTER_NAME": "Test", "GIT_COMMITTER_EMAIL": "test@example.com",
        ], executableSearchPaths: [URL(filePath: "/usr/bin")])
    }

    var brainRoot: URL { Brain.defaultRoot(home: home) }

    // MARK: Facts

    func database() throws -> IndexDatabase { try IndexSchema.open(InsightsPaths(home: home).database) }

    /// `hour` o'clock (local) `daysAgo` days before today.
    func at(_ daysAgo: Int, _ hour: Double = 12) -> Double {
        (calendar.date(byAdding: .day, value: -daysAgo, to: today) ?? today).timeIntervalSince1970 + hour * 3600
    }

    func day(_ daysAgo: Int) -> String { UsageSummary.day(Date(timeIntervalSince1970: at(daysAgo)), calendar: calendar) }

    func session(_ id: String, started: Double, harness: String = "claude", in db: IndexDatabase) throws {
        try db.run("INSERT INTO sessions(key, harness, native_id, started, source_id, parser_version) VALUES(?, ?, ?, ?, 0, 1)",
                   "\(harness):\(id)", harness, id, started)
    }

    func listing(_ id: String, _ skill: String, at ts: Double, hash: String? = "h1", chars: Int = 40, in db: IndexDatabase) throws {
        try db.run("""
            INSERT INTO skill_listings(harness, listing_key, skill, session_key, ts, is_subagent, is_initial, desc_hash, desc_chars,
              source_id, parser_version) VALUES('claude', ?, ?, ?, ?, 0, 1, ?, ?, 0, 1)
            """, UUID().uuidString, skill, "claude:\(id)", ts, hash, chars)
    }

    /// The keys of a JSON object.
    func keys(_ value: Any?) -> Set<String> { Set((value as? [String: Any]).map { Array($0.keys) } ?? []) }

    func request(_ id: String, at ts: Double, in db: IndexDatabase) throws {
        try db.run("""
            INSERT INTO requests(harness, event_key, session_key, ts, input, cache_read, cache_write, is_subagent, source_id, parser_version)
            VALUES('claude', ?, ?, ?, 100, 0, 0, 0, 0, 1)
            """, UUID().uuidString, "claude:\(id)", ts)
    }

    func call(_ id: String, _ skill: String, at ts: Double, by: String = "model", subagent: Bool = false, harness: String = "claude",
              in db: IndexDatabase) throws {
        try db.run("""
            INSERT INTO skill_calls(harness, event_key, session_key, ts, skill, by, is_subagent, source_id, parser_version)
            VALUES(?, ?, ?, ?, ?, ?, ?, 0, 1)
            """, harness, UUID().uuidString, "\(harness):\(id)", ts, skill, by, subagent)
    }

    func bind(_ id: String, to project: String, in db: IndexDatabase) throws {
        try db.run("""
            INSERT INTO bindings(session_key, project_id, method, confidence, decided_at, resolver_version) VALUES(?, ?, 'hook', 'exact', 0, 1)
            """, "claude:\(id)", project)
    }

    func apply(_ project: String, layers: [String], at ts: Double, in db: IndexDatabase) throws {
        try db.run("INSERT INTO applies(project_id, ts, layers, skills, source_id, parser_version) VALUES(?, ?, ?, '{}', 0, 1)",
                   project, Int64(ts * 1000), String(decoding: try JSONEncoder().encode(layers), as: UTF8.self))
    }

    /// `count` main sessions over `days` distinct days (from `firstDay` days ago back), each listing
    /// the skills once and making one request after that.
    func listedSessions(_ skills: [String], count: Int = 20, days: Int = 14, firstDay: Int = 1, id: String = "s",
                        hash: String? = "h1", project: String? = nil, in db: IndexDatabase) throws {
        for index in 0..<count {
            let key = "\(id)\(index)", ts = at(firstDay + index % days, 9 + Double(index / days))
            try session(key, started: ts, in: db)
            for skill in skills { try listing(key, skill, at: ts, hash: hash, in: db) }
            try request(key, at: ts + 60, in: db)
            if let project { try bind(key, to: project, in: db) }
        }
    }

    /// Another Mac's summary with one day of counts per skill (`[listed, model, user]`).
    func otherMac(_ key: String = "abcdef0123456789", name: String? = "mbp", updatedDaysAgo: Int = 0,
                  days: [String: [String: [Int]]], hashes: [String: [[String]]]? = nil) -> UsageSummary.File {
        let updated = Date(timeIntervalSince1970: at(updatedDaysAgo, 8)).formatted(.iso8601)
        return UsageSummary.File(version: 1, machine: key, name: name, updated: updated,
                                 days: days.mapValues { .init(sessions: 1, firstContextSum: 0, firstContextN: 0, skills: $0) },
                                 descHashes: hashes)
    }

    // MARK: Brain

    func write(_ path: String, _ text: String = "") throws {
        let url = home.appending(path: path)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    func read(_ path: String) throws -> String { try String(contentsOf: home.appending(path: path), encoding: .utf8) }

    @discardableResult
    func git(_ arguments: String..., extra: [String: String] = [:], in folder: URL? = nil) async throws -> String {
        let result = try #require(await ProcessRunner.run(URL(filePath: "/usr/bin/git"), arguments: arguments, directory: folder ?? brainRoot,
                                                          environment: env.variables.merging(extra) { $1 }, timeout: 30))
        #expect(result.succeeded, "git \(arguments): \(result.output)")
        return result.output
    }

    static let coreLayer = """
        description: Home folder
        skills:
          - name: tdd
            mode: auto
          - name: review   # code review
            mode: auto
        """

    /// A brain repo with the skills and the core layer, committed 60 days ago, with its own git email.
    @discardableResult
    func writeBrain(_ layer: String = RecommenderTests.coreLayer, skills: [String] = ["tdd", "review"]) async throws -> Brain {
        for name in skills { try write(".akit/registry/skills/\(name)/SKILL.md", "---\nname: \(name)\ndescription: \(name) skill\n---\n") }
        try write(".akit/registry/layers/core/layer.yaml", layer + "\n")
        try await git("init", "-q", "-b", "main")
        try await git("config", "--local", "user.email", Self.email)
        try await git("config", "--local", "user.name", "Me")
        try await git("add", "--all")
        let old = Date(timeIntervalSince1970: at(60)).formatted(.iso8601)
        try await git("commit", "-qm", "Brain", extra: ["GIT_AUTHOR_DATE": old, "GIT_COMMITTER_DATE": old])
        return try #require(Brain.load(from: brainRoot))
    }

    func layerInputs(_ brain: Brain?, owners: [String: SkillOwner] = ["tdd": .layer(["core"]), "review": .layer(["core"])]) -> Recommender.Inputs {
        var inputs = Recommender.Inputs()
        inputs.brain = brain
        inputs.stats.owners = owners
        inputs.stats.hasBrain = brain != nil
        return inputs
    }

    func recommend(_ db: IndexDatabase, _ options: Recommender.Options = .init(top: nil),
                   _ inputs: Recommender.Inputs = .init()) throws -> RecommendReport {
        try Recommender.recommend(db, options: options, inputs: inputs, now: now, calendar: calendar)
    }

    func skills(_ report: RecommendReport) -> [String] { report.recommendations.map(\.skill) }

    // MARK: CLI

    /// This Mac's home as `akit apply --home` leaves it: tdd and review rendered from the core layer
    /// into ~/.agents/skills (~/.claude/skills links there), recorded in the home lock. Without a
    /// brain only the installed skills.
    func setUpHome(brain withBrain: Bool = true, work: Bool = false) async throws {
        var rendered: [String: String] = [:]
        for name in ["tdd", "review"] {
            let text = "---\nname: \(name)\ndescription: \(name) skill\n---\n"
            try write(".agents/skills/\(name)/SKILL.md", text)
            rendered[".agents/skills/\(name)/SKILL.md"] = ProjectSetup.sha256(Data(text.utf8))
        }
        try fm.createDirectory(at: home.appending(path: ".claude"), withIntermediateDirectories: true)
        try fm.createSymbolicLink(atPath: home.appending(path: ".claude/skills").path, withDestinationPath: "../.agents/skills")
        guard withBrain else { return }
        if work {
            var profile = MachineProfile(kind: .work, name: "work")
            profile.id = "0123456789abcdef"
            profile.pseudonym = "work-abc123"
            profile.hardwareHash = "test-hardware"
            profile.kindSince = Date(timeIntervalSince1970: at(90))
            try profile.save(home: home)
        }
        try await writeBrain()
        let folder = work ? ".akit/local/projects/home/work" : ".akit/registry/projects/home/testmac"
        try write("\(folder)/answers.json", #"{"layers": ["core"], "values": {}, "targets": ["claude"]}"#)
        let files = rendered.map { #""\#($0.key)": {"layers": ["core"], "sha256": "\#($0.value)"}"# }.sorted().joined(separator: ", ")
        try write("\(folder)/lock.json", #"{"brainDirty": false, "files": {\#(files)}}"#)
        if !work {
            try await git("add", "--all")
            try await git("commit", "-qm", "Render the core layer into home/testmac")
        }
    }

    /// Runs `akit` in-process from the home folder; returns (exit code, stdout, stderr).
    func akit(_ arguments: String...) async -> (code: Int32, out: String, err: String) {
        var out: [String] = [], err: [String] = []
        let code = await AKitCLI.run(arguments, env: env, cwd: home, projectsRoot: home.appending(path: "Projects"), hostName: "TestMac.local",
                                     installedTargets: ["claude"], out: { out.append($0) }, err: { err.append($0) },
                                     trash: { _ in nil }, hardwareHash: { "test-hardware" })
        return (code, out.joined(separator: "\n"), err.joined(separator: "\n"))
    }

    func json(_ result: (code: Int32, out: String, err: String)) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: Data(result.out.utf8)) as? [String: Any], "\(result)")
    }

    func recommendations(_ result: (code: Int32, out: String, err: String)) throws -> [[String: Any]] {
        try json(result)["recommendations"] as? [[String: Any]] ?? []
    }
}

// MARK: - The rule

extension RecommenderTests {
    @Test func recommendsWhenListedEnoughAndNeverModelCalled() async throws {
        let brain = try await writeBrain()
        let db = try database()
        try listedSessions(["tdd"], in: db)
        let report = try recommend(db, .init(top: nil), layerInputs(brain))
        #expect(report.rule == .init(name: "auto-to-manual", minSessions: 20, minDistinctDays: 14, staleAfterDays: 14,
                                     bindings: ["exact", "high", "medium"]))
        let item = try #require(report.recommendations.first, "\(report)")
        #expect(report.recommendations.count == 1 && item.skill == "tdd" && item.type == "patch" && !item.stale)
        #expect(item.owner == .init(kind: "layer", name: "core") && item.scope == .init(project: nil))
        #expect(item.action.kind == "layerPatch" && item.action.layer == "core")
        #expect(item.action.diff?.contains("-     mode: auto") == true && item.action.diff?.contains("+     mode: manual") == true,
                "\(item.action.diff ?? "")")
        let evidence = item.evidence
        #expect(evidence.sessions == 20 && evidence.distinctDays == 14 && evidence.from == day(14) && evidence.to == day(1))
        #expect(evidence.modelCalls == 0 && evidence.userCalls == 0 && evidence.callRate == 0 && evidence.callRateUpperBound95 == 0.15)
        #expect(evidence.approxContextSpace == 200, "20 sessions × 1 request × ≈ 10 tokens")
        #expect(evidence.binding == nil && evidence.machines.map(\.name) == ["this Mac"])
        // review is listed nowhere; the core layer still holds it as auto.
        #expect(!skills(report).contains("review"))
    }

    @Test func userOnlyCallsStillRecommend() async throws {
        let brain = try await writeBrain()
        let db = try database()
        try listedSessions(["tdd"], in: db)
        for index in 0..<3 { try call("s\(index)", "tdd", at: at(1 + index, 10), by: "user", in: db) }
        let item = try #require(try recommend(db, .init(top: nil), layerInputs(brain)).recommendations.first)
        #expect(item.skill == "tdd" && item.evidence.userCalls == 3 && item.evidence.modelCalls == 0)
    }

    @Test func anyModelCallAnywhereBlocks() async throws {
        let db = try database()
        let names = ["other-mac", "subagent", "pi", "quiet"]
        try listedSessions(names, in: db)
        // A subagent of a listed session, a Pi session and another Mac call three of them.
        try call("s3", "subagent", at: at(4, 11), subagent: true, in: db)
        try session("p1", started: at(2), harness: "pi", in: db)
        try call("p1", "pi", at: at(2, 13), harness: "pi", in: db)
        var inputs = layerInputs(nil, owners: Dictionary(uniqueKeysWithValues: names.map { ($0, SkillOwner.handInstalled("~/.claude/skills/\($0)/SKILL.md")) }))
        inputs.others.machines["abcdef0123456789"] = otherMac(days: [day(3): ["other-mac": [1, 1, 0]]])
        #expect(skills(try recommend(db, .init(top: nil), inputs)) == ["quiet"])

        // In a project, a call in another project blocks too: the fix (a layer, an import) is shared.
        let brain = try await writeBrain()
        try listedSessions(["tdd"], id: "b", project: Self.project, in: db)
        try session("elsewhere", started: at(2), in: db)
        try call("elsewhere", "tdd", at: at(2, 13), in: db)
        #expect(!skills(try recommend(db, .init(project: Self.project, top: nil), layerInputs(brain))).contains("tdd"))
    }

    @Test func belowThresholdNoRecommendation() throws {
        let db = try database()
        try listedSessions(["few"], count: 19, id: "a", in: db)
        try listedSessions(["short"], count: 20, days: 13, id: "b", in: db)
        let inputs = layerInputs(nil, owners: ["few": .handInstalled("~/few"), "short": .handInstalled("~/short")])
        #expect(try recommend(db, .init(top: nil), inputs).recommendations.isEmpty)
        #expect(skills(try recommend(db, .init(minSessions: 19, top: nil), inputs)) == ["few"])
        #expect(skills(try recommend(db, .init(minDays: 13, top: nil), inputs)) == ["short"])
    }

    @Test func distinctDaysNotSpan() throws {
        let db = try database()
        // 20 sessions spanning 14 days, but on only two of them.
        for index in 0..<20 {
            let ts = at(index < 10 ? 1 : 14, 9 + Double(index % 10))
            try session("s\(index)", started: ts, in: db)
            try listing("s\(index)", "tdd", at: ts, in: db)
        }
        let inputs = layerInputs(nil, owners: ["tdd": .handInstalled("~/tdd")])
        #expect(try recommend(db, .init(top: nil), inputs).recommendations.isEmpty)
        // Other Macs' days join this Mac's: 12 more distinct days make 14.
        var others = inputs
        others.others.machines["abcdef0123456789"] = otherMac(days: Dictionary(uniqueKeysWithValues: (2...13).map { (day($0), ["tdd": [1, 0, 0]]) }))
        let item = try #require(try recommend(db, .init(top: nil), others).recommendations.first)
        #expect(item.evidence.distinctDays == 14 && item.evidence.sessions == 32 && item.evidence.machines.map(\.name) == ["this Mac", "mbp"])
    }

    @Test func descriptionChangeRestartsWindow() throws {
        let db = try database()
        try listedSessions(["tdd"], count: 20, days: 14, firstDay: 3, hash: "A", in: db)
        let inputs = layerInputs(nil, owners: ["tdd": .handInstalled("~/tdd")])
        #expect(skills(try recommend(db, .init(top: nil), inputs)) == ["tdd"])
        // A new text two days ago: only the sessions since then count.
        try listedSessions(["tdd"], count: 4, days: 2, firstDay: 1, id: "new", hash: "B", in: db)
        #expect(try recommend(db, .init(top: nil), inputs).recommendations.isEmpty)
        // Back to the old text: A is no news, the window stays at B.
        try listedSessions(["tdd"], count: 2, days: 1, firstDay: 1, id: "back", hash: "A", in: db)
        #expect(try recommend(db, .init(top: nil), inputs).recommendations.isEmpty)
        #expect(skills(try recommend(db, .init(minSessions: 6, minDays: 2, top: nil), inputs)) == ["tdd"])
    }

    @Test func otherMacDescHashesFeedWindow() throws {
        let db = try database()
        try listedSessions(["tdd"], count: 20, days: 14, firstDay: 1, hash: "A", in: db)
        var inputs = layerInputs(nil, owners: ["tdd": .handInstalled("~/tdd")])
        // Another Mac saw A long ago: no news.
        inputs.stats.otherMacHashes = ["tdd": [.init(fromDay: day(40), hash: "A")]]
        #expect(skills(try recommend(db, .init(top: nil), inputs)) == ["tdd"])
        // It saw a text this Mac never listed, five days ago: the window starts at that day.
        inputs.stats.otherMacHashes = ["tdd": [.init(fromDay: day(5), hash: "C")]]
        #expect(try recommend(db, .init(top: nil), inputs).recommendations.isEmpty)
        let item = try #require(try recommend(db, .init(minSessions: 5, minDays: 5, top: nil), inputs).recommendations.first)
        #expect(item.evidence.from == day(5) && item.evidence.distinctDays == 5)
    }
}

// MARK: - Layers

extension RecommenderTests {
    @Test func layerAddedLaterStartsProjectWindowAtApply() async throws {
        let brain = try await writeBrain()
        let db = try database()
        try listedSessions(["tdd"], count: 30, days: 30, project: Self.project, in: db)
        // tdd was listed there all along (e.g. from the home folder); the core layer came ten days ago.
        try apply(Self.project, layers: ["core"], at: at(10, 8), in: db)
        var inputs = layerInputs(brain)
        inputs.layerStarts = try await LayerHistory.starts(project: Self.project, database: db, store: .local(home: home), brain: brain, env: env)
        #expect(inputs.layerStarts == ["core": Date(timeIntervalSince1970: at(10, 8))])
        #expect(try recommend(db, .init(project: Self.project, top: nil), inputs).recommendations.isEmpty)
        let item = try #require(try recommend(db, .init(project: Self.project, minSessions: 10, minDays: 10, top: nil), inputs)
            .recommendations.first)
        #expect(item.evidence.sessions == 10 && item.evidence.from == day(10) && item.scope == .init(project: Self.project))
        #expect(item.evidence.binding == .init(methods: ["hook"], confidence: "exact"))
        // Globally the layer date doesn't apply.
        #expect(try recommend(db, .init(top: nil), inputs).recommendations.first?.evidence.sessions == 30)
    }

    @Test func localApplyWinsOverGitBackfill() async throws {
        try await writeBrain()
        try write(".akit/registry/layers/web/layer.yaml", "requires: [core]\n")
        try write(".akit/registry/layers/extra/layer.yaml", "description: Extra\n")
        let answers = "projects/\(Self.project)/answers.json"
        for (layers, daysAgo) in [(#"["web"]"#, 40), (#"["web", "extra"]"#, 20)] {
            try write(".akit/registry/\(answers)", #"{"layers": \#(layers), "values": {}, "targets": ["claude"]}"#)
            try await git("add", "--all")
            let date = Date(timeIntervalSince1970: at(daysAgo)).formatted(.iso8601)
            try await git("commit", "-qm", "Render app", extra: ["GIT_AUTHOR_DATE": date, "GIT_COMMITTER_DATE": date])
        }
        let brain = try #require(Brain.load(from: brainRoot))
        let db = try database()
        func starts(_ store: ProjectStore) async throws -> [String: Date] {
            try await LayerHistory.starts(project: Self.project, database: db, store: store, brain: brain, env: env)
        }
        // No local apply yet: the brain's history, requires included.
        #expect(try await starts(.brain(brainRoot)) == ["web": Date(timeIntervalSince1970: at(40)), "core": Date(timeIntervalSince1970: at(40)),
                                                         "extra": Date(timeIntervalSince1970: at(20))])
        // A local apply wins for its layers; a work Mac's local store has no history to fill in from.
        try apply(Self.project, layers: ["web", "core"], at: at(5), in: db)
        #expect(try await starts(.brain(brainRoot)) == ["web": Date(timeIntervalSince1970: at(5)), "core": Date(timeIntervalSince1970: at(5)),
                                                         "extra": Date(timeIntervalSince1970: at(20))])
        #expect(try await starts(.local(home: home, readingBrain: brainRoot)) == ["web": Date(timeIntervalSince1970: at(5)),
                                                                                  "core": Date(timeIntervalSince1970: at(5))])
    }

    @Test func keepAutoPins() async throws {
        let layer = RecommenderTests.coreLayer.replacingOccurrences(of: "  - name: tdd\n    mode: auto", with: "  - name: tdd\n    mode: auto\n    keep_auto: true")
        let brain = try await writeBrain(layer)
        let parsed = try #require(brain.layers.first { $0.name == "core" })
        #expect(parsed.skills.map(\.keepAuto) == [true, false] && brain.problems.isEmpty, "\(brain.problems)")
        let db = try database()
        try listedSessions(["tdd", "review"], in: db)
        #expect(skills(try recommend(db, .init(top: nil), layerInputs(brain))) == ["review"])
        // akit layers shows it.
        let layers = await akit("layers", "--json")
        let core = try #require((try JSONSerialization.jsonObject(with: Data(layers.out.utf8)) as? [[String: Any]])?.first)
        #expect((core["skills"] as? [[String: Any]])?.map { $0["keepAuto"] as? Bool } == [true, false], "\(layers)")
        #expect(await akit("layers").out.contains("skill tdd auto (keep auto)"))
    }

    @Test func layerPatchReadsBackAndOnlyChangesMode() throws {
        func edit(_ text: String, _ skill: String = "tdd", change: LayerPatch.Change = .manual) throws -> String {
            try LayerPatch.edit(text, skill: skill, layer: "core", change: change)
        }
        // A map entry: only its mode line changes, a comment stays.
        #expect(try edit("skills:\n  - name: lint\n    mode: auto\n  - name: tdd\n    mode: auto   # tests first\n    when: stack\nfields:\n  - id: stack\n")
                == "skills:\n  - name: lint\n    mode: auto\n  - name: tdd\n    mode: manual   # tests first\n    when: stack\nfields:\n  - id: stack\n")
        // A bare name becomes a map; mode first, name below; no mode line yet; CRLF kept.
        #expect(try edit("skills:\n  - lint\n  - tdd  # mine\n") == "skills:\n  - lint\n  - name: tdd  # mine\n    mode: manual\n")
        #expect(try edit("skills:\n- mode: auto\n  name: tdd\n") == "skills:\n- mode: manual\n  name: tdd\n")
        #expect(try edit("skills:\r\n  - name: tdd\r\n    when: stack\r\n\r\nfiles: []\r\n")
                == "skills:\r\n  - name: tdd\r\n    when: stack\r\n    mode: manual\r\n\r\nfiles: []\r\n")
        #expect(try edit("skills:\n  - name: tdd\n    mode: auto\n", change: .keepAuto) == "skills:\n  - name: tdd\n    mode: auto\n    keep_auto: true\n")
        #expect(try edit("skills:\n  - name: tdd\n    keep_auto: false\n", change: .keepAuto) == "skills:\n  - name: tdd\n    keep_auto: true\n")
        // Refused: a one-line list, a skill that isn't there or isn't auto.
        for text in ["skills: [tdd]\n", "skills:\n  - name: lint\n", "skills:\n  - name: tdd\n    mode: manual\n"] {
            #expect(throws: LayerPatch.Failure.self, "\(text)") { _ = try edit(text) }
        }
        // The read-back check sees anything else riding along.
        let before = "skills:\n  - name: tdd\n    mode: auto\n  - name: lint\n    mode: auto\n"
        #expect(LayerPatch.problem(before: before, after: try edit(before), skill: "tdd", layer: "core", change: .manual) == nil)
        for after in ["skills:\n  - name: tdd\n    mode: manual\n  - name: lint\n    mode: manual\n",
                      "skills:\n  - name: tdd\n    mode: manual  # github.com/acme/app\n  - name: lint\n    mode: auto\n",
                      "# acme\nskills:\n  - name: tdd\n    mode: manual\n  - name: lint\n    mode: auto\n",
                      "description: acme\nskills:\n  - name: tdd\n    mode: manual\n  - name: lint\n    mode: auto\n"] {
            #expect(LayerPatch.problem(before: before, after: after, skill: "tdd", layer: "core", change: .manual) != nil, "\(after)")
        }
    }

    @Test func unrenderedManualLayerSkillGetsApplyAdvice() async throws {
        // The core layer lists ast as manual, but ~/.agents/skills/ast was not written by AKit
        // (akit apply --home skips files it didn't write), so Claude still lists it as auto.
        let layer = RecommenderTests.coreLayer + "\n  - name: ast\n    mode: manual"
        let brain = try await writeBrain(layer, skills: ["tdd", "review", "ast"])
        try write(".agents/skills/ast/SKILL.md", "---\nname: ast\ndescription: Old copy\n---\n")
        try fm.createDirectory(at: home.appending(path: ".claude"), withIntermediateDirectories: true)
        try fm.createSymbolicLink(atPath: home.appending(path: ".claude/skills").path, withDestinationPath: "../.agents/skills")
        let installed = SkillScanner.scan(installations: HarnessCatalog.detectAll(in: env), extraProjects: [], in: env)
        let links = BrainLinks.links(for: installed, brain: brain, folders: ["home/testmac": home])
        let owners = SkillOwners.classify(["ast"], installed: installed, links: links, layers: brain.layers, home: home)
        let owner = try #require(owners["ast"])
        guard case .unrendered(let layers, let file) = owner else { Issue.record("\(owner)"); return }
        #expect(layers == ["core"] && file.hasPrefix("~/.") && file.hasSuffix("/ast/SKILL.md"), "\(file)")
        // The stats keep their owner kinds.
        #expect(StatsReport.Owner(owner).kind == "unknown" && StatsReport.Owner(owner).name == nil)

        let db = try database()
        try listedSessions(["ast"], in: db)
        let item = try #require(try recommend(db, .init(top: nil), layerInputs(brain, owners: owners)).recommendations.first)
        #expect(item.type == "advice" && item.owner == .init(kind: "unknown", name: nil) && item.action.kind == "applyUnmanaged")
        #expect(item.action.text?.contains("akit apply --home --include-unmanaged") == true
                && item.action.text?.contains("--include .agents/skills/ast/SKILL.md") == true
                && item.action.text?.contains("manual mode") == true, "\(item.action)")

        // Were it auto in the layer, the patch comes first, with the same note.
        try write(".akit/registry/layers/core/layer.yaml", RecommenderTests.coreLayer + "\n  - name: ast\n    mode: auto\n")
        let auto = try #require(Brain.load(from: brainRoot))
        let patch = try #require(try recommend(db, .init(top: nil), layerInputs(auto, owners: owners)).recommendations.first)
        #expect(patch.type == "patch" && patch.owner == .init(kind: "layer", name: "core") && patch.action.text?.contains("--include-unmanaged") == true)
    }
}

// MARK: - Owners, ids, dismissals, staleness

extension RecommenderTests {
    @Test func dismissedReturnsOnlyAtDoubleEvidence() async throws {
        try await writeBrain()
        let db = try database()
        try listedSessions(["hand"], in: db)
        var inputs = layerInputs(nil, owners: ["hand": .handInstalled("~/.claude/skills/hand/SKILL.md")])
        let item = try #require(try recommend(db, .init(top: nil), inputs).recommendations.first)
        #expect(item.type == "advice" && item.action.kind == "importManual" && item.evidence.approxContextSpace == 200)

        // Dismissed on a personal Mac: kept in the brain, one commit.
        let url = try await Dismissals.dismiss(.init(id: item.id, at: now.formatted(.iso8601), approxContextSpace: 200), project: nil,
                                               brain: brainRoot, home: home, machine: MachineProfile(), env: env)
        #expect(url.path == brainRoot.appending(path: "insights/dismissed.json").path)
        #expect(try await git("log", "-1", "--format=%s", "--name-only") == "Dismiss recommendation \(item.id)\n\ninsights/dismissed.json\n")
        inputs.dismissed = Dismissals.load(project: nil, brain: brainRoot, home: home, store: .brain(brainRoot))
        var report = try recommend(db, .init(top: nil), inputs)
        #expect(report.recommendations.isEmpty && report.hiddenByDismissal == 1)

        // One more request in 19 sessions: 390, still under twice 200.
        for index in 0..<19 { try request("s\(index)", at: at(1 + index % 14, 9 + Double(index / 14)) + 120, in: db) }
        report = try recommend(db, .init(top: nil), inputs)
        #expect(report.recommendations.isEmpty && report.hiddenByDismissal == 1)
        try request("s19", at: at(1 + 19 % 14, 10) + 120, in: db)
        report = try recommend(db, .init(top: nil), inputs)
        #expect(report.recommendations.first?.id == item.id && report.recommendations.first?.evidence.approxContextSpace == 400
                && report.hiddenByDismissal == 0)
    }

    @Test func dismissedAtZeroContextSpaceReturnsOnceThereIsSome() {
        let entry = Dismissals.Entry(id: "r-0123456789", at: "2026-09-01T00:00:00Z", approxContextSpace: 0)
        #expect(Dismissals.hides(entry, approxContextSpace: 0) && Dismissals.hides(entry, approxContextSpace: 1))
        #expect(!Dismissals.hides(entry, approxContextSpace: 2))
        #expect(Dismissals.showsAgainAt(0) == 2 && Dismissals.showsAgainAt(1) == 2 && Dismissals.showsAgainAt(200) == 400)
    }

    @Test func handInstalledIdKeepsWhenTheFileMoves() throws {
        let db = try database()
        try listedSessions(["hand"], in: db)
        func item(_ path: String) throws -> RecommendReport.Recommendation {
            try #require(try recommend(db, .init(top: nil), layerInputs(nil, owners: ["hand": .handInstalled(path)])).recommendations.first)
        }
        let first = try item("~/.claude/skills/hand/SKILL.md"), moved = try item("~/.agents/skills/hand/SKILL.md")
        #expect(first.id == moved.id && first.owner.name == "~/.claude/skills/hand/SKILL.md")
        #expect(first.id == "r-" + ProjectSetup.sha256(Data("auto-to-manual|handInstalled|hand|hand|global".utf8)).prefix(10))
    }

    @Test func idStableAcrossRuns() async throws {
        let brain = try await writeBrain()
        let db = try database()
        try listedSessions(["tdd"], project: Self.project, in: db)
        let first = try #require(try recommend(db, .init(top: nil), layerInputs(brain)).recommendations.first)
        #expect(first.id == "r-" + ProjectSetup.sha256(Data("auto-to-manual|layer|core|tdd|global".utf8)).prefix(10))
        #expect(first.id.count == 12 && first.id.dropFirst(2).allSatisfy(\.isHexDigit))
        try listedSessions(["tdd"], count: 3, id: "more", in: db)
        #expect(try recommend(db, .init(top: nil), layerInputs(brain)).recommendations.first?.id == first.id)
        // Another scope, another id.
        let project = try #require(try recommend(db, .init(project: Self.project, top: nil), layerInputs(brain)).recommendations.first)
        #expect(project.id != first.id && project.id == Recommender.id(owner: .init(kind: "layer", name: "core"), skill: "tdd",
                                                                          project: Self.project))
    }

    @Test func pluginAdviceProjectVsGlobal() throws {
        let db = try database()
        try listedSessions(["marketing:seo-audit"], project: Self.project, in: db)
        let inputs = layerInputs(nil, owners: ["marketing:seo-audit": .plugin("marketing")])
        func action(_ project: String?) throws -> String? {
            try recommend(db, .init(project: project, top: nil), inputs).recommendations.first?.action.kind
        }
        #expect(try action(Self.project) == "disablePluginGlobally" && action(nil) == "disablePluginGlobally")
        // Another project calls one of the plugin's skills: disable it only here.
        try session("other", started: at(2), in: db)
        try call("other", "marketing:brand-review", at: at(2, 13), by: "user", in: db)
        #expect(try action(Self.project) == "disablePluginInProject" && action(nil) == "disablePluginGlobally")
        let item = try #require(try recommend(db, .init(project: Self.project, top: nil), inputs).recommendations.first)
        #expect(item.owner == .init(kind: "plugin", name: "marketing") && item.action.text?.contains(" in \(Self.project), ") == true,
                "\(item.action.text ?? "")")
        // The model calls this very skill elsewhere: still advice for the project, nothing globally.
        try call("other", "marketing:seo-audit", at: at(2, 14), in: db)
        #expect(try action(Self.project) == "disablePluginInProject" && action(nil) == nil)
        // Once the model calls it in the project (here a subagent), nothing there either.
        try call("s0", "marketing:seo-audit", at: at(1, 15), subagent: true, in: db)
        #expect(try action(Self.project) == nil)
    }

    @Test func pluginWithAUsedSkillGetsOneNoteNotDisable() throws {
        let db = try database()
        let names = ["omc:ralph", "omc:plan", "omc:wiki", "omc:hud"]
        try listedSessions(names, in: db)
        try call("s2", "omc:ralph", at: at(3, 10), in: db)
        let inputs = layerInputs(nil, owners: Dictionary(uniqueKeysWithValues: names.map { ($0, SkillOwner.plugin("omc")) }))
        let report = try recommend(db, .init(top: nil), inputs)
        #expect(report.recommendations.count == 1, "\(report.recommendations)")
        let item = try #require(report.recommendations.first)
        #expect(item.skill == "*" && item.owner == .init(kind: "plugin", name: "omc") && item.type == "advice")
        #expect(item.action.kind == "unusedPluginSkills" && item.action.text?.hasPrefix("3 of 4 listed skills of omc") == true,
                "\(item.action.text ?? "")")
        #expect(item.evidence.skills == ["omc:hud", "omc:plan", "omc:wiki"] && item.evidence.approxContextSpace == 600)
        #expect(item.evidence.sessions == 20 && item.evidence.distinctDays == 14 && item.evidence.modelCalls == 0)
        #expect(item.id == "r-" + ProjectSetup.sha256(Data("auto-to-manual|plugin|omc|*unused|global".utf8)).prefix(10))
        // Below the threshold on its own, an unused skill is left out; with none left, no note at all.
        try call("s4", "omc:plan", at: at(5, 10), in: db)
        try call("s5", "omc:wiki", at: at(6, 10), in: db)
        try call("s6", "omc:hud", at: at(7, 10), in: db)
        #expect(try recommend(db, .init(top: nil), inputs).recommendations.isEmpty)
        // Dismissed like any advice.
        var dismissed = inputs
        dismissed.dismissed[item.id] = .init(id: item.id, at: "2026-09-01T00:00:00Z", approxContextSpace: 600)
        try listedSessions(["omc:extra"], id: "x", in: db)
        dismissed.stats.owners["omc:extra"] = .plugin("omc")
        #expect(try recommend(db, .init(top: nil), dismissed).hiddenByDismissal == 1)
    }

    @Test func fullyUnusedPluginIsOneDisableAdviceWithSummedEvidence() throws {
        let db = try database()
        // Neither skill alone reaches 20 sessions on 14 days; the plugin as a whole does.
        try listedSessions(["mkt:seo"], count: 10, days: 7, firstDay: 1, id: "a", in: db)
        try listedSessions(["mkt:brand"], count: 10, days: 7, firstDay: 8, id: "b", in: db)
        try listedSessions(["mkt:email"], count: 2, days: 2, firstDay: 1, id: "c", in: db)
        let inputs = layerInputs(nil, owners: ["mkt:seo": .plugin("mkt"), "mkt:brand": .plugin("mkt"), "mkt:email": .plugin("mkt")])
        let report = try recommend(db, .init(top: nil), inputs)
        #expect(report.recommendations.count == 1, "\(report.recommendations)")
        let item = try #require(report.recommendations.first)
        #expect(item.skill == "*" && item.action.kind == "disablePluginGlobally" && item.owner == .init(kind: "plugin", name: "mkt"))
        #expect(item.evidence.skills == ["mkt:brand", "mkt:email", "mkt:seo"])
        #expect(item.evidence.sessions == 22 && item.evidence.distinctDays == 14 && item.evidence.from == day(14) && item.evidence.to == day(1))
        #expect(item.evidence.approxContextSpace == 220, "22 sessions × 1 request × ≈ 10 tokens")
        #expect(item.id == "r-" + ProjectSetup.sha256(Data("auto-to-manual|plugin|mkt|*|global".utf8)).prefix(10))
        // Other Macs: a day counts the most sessions one of its skills was listed in, not their sum.
        var others = inputs
        others.others.machines["abcdef0123456789"] = otherMac(days: [day(3): ["mkt:seo": [3, 0, 0], "mkt:brand": [2, 0, 0]]])
        let summed = try #require(try recommend(db, .init(top: nil), others).recommendations.first)
        #expect(summed.evidence.sessions == 25 && summed.evidence.distinctDays == 14, "\(summed.evidence)")
        // The text output names the plugin and its skills.
        let text = AKitCLI.recommendText(report, details: false)
        #expect(text.contains("\(item.id)  plugin mkt: advice") && text.contains("skills: mkt:brand, mkt:email, mkt:seo"), "\(text)")
    }

    @Test func pluginDisableProjectVsGlobalByModelCalls() throws {
        let db = try database()
        try listedSessions(["omc:ralph", "omc:hud"], project: Self.project, in: db)
        let inputs = layerInputs(nil, owners: ["omc:ralph": .plugin("omc"), "omc:hud": .plugin("omc")])
        func kinds(_ project: String?) throws -> [String] {
            try recommend(db, .init(project: project, top: nil), inputs).recommendations.map(\.action.kind)
        }
        #expect(try kinds(Self.project) == ["disablePluginGlobally"] && kinds(nil) == ["disablePluginGlobally"])
        // Another project's session: the model calls one of its skills there.
        try session("other", started: at(2), in: db)
        try call("other", "omc:ralph", at: at(2, 13), in: db)
        #expect(try kinds(Self.project) == ["disablePluginInProject"])
        // Globally one skill is used: only the note on the other one.
        let global = try recommend(db, .init(top: nil), inputs).recommendations
        #expect(global.map(\.action.kind) == ["unusedPluginSkills"] && global.first?.evidence.skills == ["omc:hud"])
    }

    @Test func staleOtherMacFlagsRecommendation() async throws {
        let db = try database()
        try listedSessions(["old", "fresh"], in: db)
        // More context space for `old` (a longer description), which a stale Mac also lists.
        for index in 0..<20 { try listing("s\(index)", "old", at: at(1 + index % 14, 9 + Double(index / 14)), chars: 400, in: db) }
        var inputs = layerInputs(nil, owners: ["old": .handInstalled("~/old"), "fresh": .handInstalled("~/fresh")])
        // Its last day lies in the window (a Mac whose days all end before it flags nothing).
        inputs.others.machines["abcdef0123456789"] = otherMac(updatedDaysAgo: 20, days: [day(10): ["old": [1, 0, 0]]])
        inputs.others.machines["fedcba9876543210"] = otherMac("fedcba9876543210", name: "studio", days: [day(3): ["fresh": [1, 0, 0]]])
        let report = try recommend(db, .init(top: nil), inputs)
        #expect(report.recommendations.map(\.skill) == ["fresh", "old"], "stale ones after fresh ones, whatever their size")
        let old = try #require(report.recommendations.last)
        #expect(old.stale && old.staleMachines == ["mbp"] && old.evidence.machines.contains { $0.name == "mbp" && $0.stale })
        #expect(!report.recommendations[0].stale && report.recommendations[0].evidence.machines.map(\.name) == ["this Mac", "studio"])
        #expect(try recommend(db, .init(staleAfterDays: 30, top: nil), inputs).recommendations.allSatisfy { !$0.stale })

        // akit recommend apply says to sync first.
        try await setUpHome()
        try write(".akit/registry/insights/machines/abcdef0123456789.json",
                  String(decoding: UsageSummary.encode(otherMac(updatedDaysAgo: 20, days: [day(10): ["tdd": [1, 0, 0]]])), as: UTF8.self))
        try await git("add", "--all")
        try await git("commit", "-qm", "Update usage summaries (mbp)")
        try listedSessions(["tdd"], id: "t", in: db)
        let listed = try recommendations(await akit("recommend", "--json"))
        let tdd = try #require(listed.first { $0["skill"] as? String == "tdd" }, "\(listed)")
        #expect(tdd["stale"] as? Bool == true)
        let applied = await akit("recommend", "apply", tdd["id"] as? String ?? "")
        #expect(applied.code == 0 && applied.out.contains("run akit sync first"), "\(applied)")
    }

    @Test func macRetiredBeforeTheWindowFlagsNothing() throws {
        let db = try database()
        try listedSessions(["tdd"], count: 20, days: 14, firstDay: 1, hash: "A", in: db)
        var inputs = layerInputs(nil, owners: ["tdd": .handInstalled("~/tdd")])
        // Another Mac saw a new text five days ago: the window starts there.
        inputs.stats.otherMacHashes = ["tdd": [.init(fromDay: day(5), hash: "C")]]
        // A Mac that listed tdd, last heard of long before the window.
        inputs.others.machines["abcdef0123456789"] = otherMac(updatedDaysAgo: 30, days: [day(30): ["tdd": [1, 0, 0]]])
        let options = Recommender.Options(minSessions: 5, minDays: 5, top: nil)
        let item = try #require(try recommend(db, options, inputs).recommendations.first)
        #expect(!item.stale && item.staleMachines.isEmpty && item.evidence.machines.map(\.name) == ["this Mac"])
        // A day of it inside the window: its old counts may be behind, so it is stale again.
        inputs.others.machines["abcdef0123456789"] = otherMac(updatedDaysAgo: 30, days: [day(30): ["tdd": [1, 0, 0]], day(4): ["review": [1, 0, 0]]])
        #expect(try recommend(db, options, inputs).recommendations.first { $0.skill == "tdd" }?.staleMachines == ["mbp"])
    }

    @Test func jsonShapeIsTheContract() async throws {
        let brain = try await writeBrain()
        let db = try database()
        try listedSessions(["tdd", "marketing:seo-audit"], in: db)
        for index in 0..<20 { try listing("s\(index)", "tdd", at: at(1 + index % 14, 9 + Double(index / 14)), chars: 400, in: db) }
        try session("p", started: at(2), harness: "pi", in: db)
        try call("p", "pi-helper", at: at(2, 13), harness: "pi", in: db)
        var inputs = layerInputs(brain, owners: ["tdd": .layer(["core"]), "marketing:seo-audit": .plugin("marketing")])
        inputs.stats.piOnly = ["pi-notes"]
        let report = try recommend(db, .init(top: 1), inputs)
        let text = AKitCLI.encode(report)
        let object = try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        #expect(Set(object.keys) == ["version", "rule", "summary", "recommendations", "noData", "hiddenByDismissal", "omitted"])
        #expect(object["version"] as? Int == 1 && object["omitted"] as? Int == 1 && object["hiddenByDismissal"] as? Int == 0)
        #expect(keys(object["rule"]) == ["name", "minSessions", "minDistinctDays", "staleAfterDays", "bindings"])
        let byOwner = (object["summary"] as? [String: Any])?["approxContextPerRequestByOwner"] as? [[String: Any]]
        #expect(byOwner?.map { $0["owner"] as? String } == ["layer", "plugin", "handInstalled", "builtIn", "unknown"])
        let item = try #require((object["recommendations"] as? [[String: Any]])?.first)
        #expect(Set(item.keys) == ["id", "type", "stale", "owner", "skill", "scope", "action", "evidence"])
        #expect((item["scope"] as? [String: Any])?["project"] is NSNull && keys(item["owner"]) == ["kind", "name"])
        #expect(keys(item["action"]) == ["kind", "layer", "diff"] && item["skill"] as? String == "tdd")
        let evidence = try #require(item["evidence"] as? [String: Any])
        #expect(Set(evidence.keys) == ["sessions", "distinctDays", "from", "to", "machines", "binding", "approxContextSpace", "modelCalls",
                                       "userCalls", "callRate", "callRateUpperBound95"])
        #expect(evidence["binding"] is NSNull && keys((evidence["machines"] as? [[String: Any]])?.first) == ["name", "updated", "stale"])
        #expect((object["noData"] as? [[String: Any]])?.map { $0["skill"] as? String } == ["pi-helper", "pi-notes"])
        let shown = AKitCLI.recommendText(try recommend(db, .init(top: nil), inputs), details: true)
        #expect(shown.contains("≈ tokens = description characters / k (k 4.0 Latin, 2.5 Cyrillic, defaults until"), "\(shown)")
        let words = (text + shown).lowercased()
        for money in ["$", "usd", "cost", "price", "dollar", "€"] { #expect(!words.contains(money), "\(money)") }
    }
}

// MARK: - apply and dismiss

extension RecommenderTests {
    @Test func applyWritesAndCommitsOnlyWithYes() async throws {
        try await setUpHome()
        let db = try database()
        try listedSessions(["tdd"], in: db)
        let listed = try recommendations(await akit("recommend", "--json"))
        let item = try #require(listed.first, "\(listed)")
        let id = try #require(item["id"] as? String)
        #expect(item["type"] as? String == "patch" && item["skill"] as? String == "tdd", "\(item)")
        #expect((item["owner"] as? [String: Any])?["kind"] as? String == "layer")
        let text = await akit("recommend")
        #expect(text.code == 0 && text.out.contains("\(id)  tdd (layer core): patch") && text.out.contains("akit recommend apply \(id)"), "\(text)")

        let layerFile = ".akit/registry/layers/core/layer.yaml"
        let before = try read(layerFile)
        let head = try await git("rev-parse", "HEAD")
        let preview = await akit("recommend", "apply", id)
        #expect(preview.code == 0 && preview.out.contains("+     mode: manual") && preview.out.contains("Run again with --yes"), "\(preview)")
        let unchanged = try await git("rev-parse", "HEAD")
        #expect(try read(layerFile) == before && unchanged == head)

        let done = await akit("recommend", "apply", id, "--yes")
        #expect(done.code == 0 && done.out.contains("Committed “Set tdd to manual in layer core”")
                && done.out.contains("Run akit plan/apply in: home/testmac (akit apply --home)."), "\(done)")
        #expect(try await git("log", "-1", "--format=%B", "--name-only") == "Set tdd to manual in layer core\n\n\nlayers/core/layer.yaml\n")
        #expect(try read(layerFile) == before.replacingOccurrences(of: "  - name: tdd\n    mode: auto", with: "  - name: tdd\n    mode: manual"))
        #expect(try await git("status", "--porcelain").isEmpty)
        // The next render makes the copy manual.
        let plan = await akit("plan", "--home")
        #expect(plan.out.contains("+ disable-model-invocation: true"), "\(plan)")
        // Until then it is still listed: the advice is to re-apply.
        let again = try recommendations(await akit("recommend", "--json"))
        #expect((again.first?["action"] as? [String: Any])?["kind"] as? String == "reapply", "\(again)")
        #expect(await akit("recommend", "apply", "r-0000000000").code == 2)
    }

    @Test func noBrainMeansAdviceOnly() async throws {
        try await setUpHome(brain: false)
        let db = try database()
        try listedSessions(["tdd", "marketing:seo-audit"], in: db)
        let listed = try recommendations(await akit("recommend", "--json"))
        #expect(Set(listed.compactMap { $0["type"] as? String }) == ["advice"], "\(listed)")
        let tdd = try #require(listed.first { $0["skill"] as? String == "tdd" })
        #expect((tdd["owner"] as? [String: Any])?["kind"] as? String == "unknown")
        #expect((tdd["action"] as? [String: Any])?["kind"] as? String == "editByHand")
        let plugin = listed.first { $0["skill"] as? String == "*" }
        #expect((plugin?["action"] as? [String: Any])?["kind"] as? String == "disablePluginGlobally")
        #expect((plugin?["evidence"] as? [String: Any])?["skills"] as? [String] == ["marketing:seo-audit"])
        let id = try #require(tdd["id"] as? String)
        let refused = await akit("recommend", "apply", id, "--yes")
        #expect(refused.code == 2 && refused.err.contains("is advice"), "\(refused)")

        // Dismissed without a brain: kept on this Mac.
        #expect(await akit("recommend", "dismiss", id, "--yes").code == 0)
        #expect(Dismissals.read(Dismissals.localURL(home: home)).dismissed.map(\.id) == [id])
        let after = try json(await akit("recommend", "--json"))
        #expect(after["hiddenByDismissal"] as? Int == 1)
        #expect(!fm.fileExists(atPath: brainRoot.path))
    }

    @Test func workMachineDismissalStaysLocal() async throws {
        try await writeBrain()
        var work = MachineProfile(kind: .work, name: "work")
        work.pseudonym = "work-abc123"
        try work.save(home: home)
        let head = try await git("rev-parse", "HEAD")
        let entry = Dismissals.Entry(id: "r-0123456789", at: now.formatted(.iso8601), approxContextSpace: 200)
        let global = try await Dismissals.dismiss(entry, project: nil, brain: brainRoot, home: home, machine: work, env: env)
        #expect(global.path == Dismissals.localURL(home: home).path)
        let project = try await Dismissals.dismiss(entry, project: Self.project, brain: brainRoot, home: home, machine: work, env: env)
        #expect(project.path == home.appending(path: ".akit/local/projects/\(Self.project)/dismissed.json").path)
        #expect(try await git("rev-parse", "HEAD") == head)
        #expect(try await git("status", "--porcelain", "--untracked-files=all").isEmpty)
        #expect(!fm.fileExists(atPath: brainRoot.appending(path: "insights").path))
        // Read back for both scopes.
        let store = ProjectStore.current(brain: brainRoot, home: home, machine: work)
        #expect(Dismissals.load(project: nil, brain: brainRoot, home: home, store: store)[entry.id] == entry)
        #expect(Dismissals.load(project: Self.project, brain: brainRoot, home: home, store: store)[entry.id] == entry)
        #expect(Dismissals.load(project: "github.com/acme/other", brain: brainRoot, home: home, store: store).isEmpty)
    }

    @Test func workRecommendApplyCommitLeaksNothing() async throws {
        try await setUpHome(work: true)
        let db = try database()
        try listedSessions(["tdd", "review"], in: db)
        let listed = try recommendations(await akit("recommend", "--json"))
        func id(_ skill: String) throws -> String {
            try #require(listed.first { $0["skill"] as? String == skill }?["id"] as? String, "\(listed)")
        }
        let applied = await akit("recommend", "apply", try id("tdd"), "--yes")
        #expect(applied.code == 0 && applied.out.contains("home/work (akit apply --home)"), "\(applied)")
        #expect(try await git("log", "-1", "--format=%B", "--name-only") == "Set tdd to manual in layer core\n\n\nlayers/core/layer.yaml\n")
        // The brain's own identity, not the environment's (which may be the work one).
        #expect(try await git("log", "-1", "--format=%ae %ce") == "\(Self.email) \(Self.email)\n")
        let dismissed = await akit("recommend", "dismiss", try id("review"), "--yes")
        #expect(dismissed.code == 0, "\(dismissed)")
        #expect(try await git("log", "-1", "--format=%B", "--name-only") == "Keep review auto in layer core\n\n\nlayers/core/layer.yaml\n")
        #expect(try read(".akit/registry/layers/core/layer.yaml").contains("  - name: review   # code review\n    mode: auto\n    keep_auto: true\n"))
        #expect(try await git("status", "--porcelain", "--untracked-files=all").isEmpty)
        #expect(!(try await git("log", "--format=%B", "--name-only")).contains("projects/"))

        // The filter itself: more than the one line, another message, another path: nothing committed.
        let head = try await git("rev-parse", "HEAD")
        let path = "layers/core/layer.yaml"
        let current = try read(".akit/registry/\(path)")
        let kind = WorkFilter.Kind.layer(layer: "core", skill: "tdd", change: .keepAuto)
        let good = current.replacingOccurrences(of: "    mode: manual\n", with: "    mode: manual\n    keep_auto: true\n")
        let attempts: [([String: Data], String)] = [
            ([path: Data((good + "# github.com/acme/app\n").utf8)], kind.message),
            ([path: Data(good.replacingOccurrences(of: "keep_auto: true", with: "keep_auto: true  # acme").utf8)], kind.message),
            ([path: Data(good.replacingOccurrences(of: "description: Home folder", with: "description: acme").utf8)], kind.message),
            ([path: Data(good.utf8)], "Keep tdd auto in layer core for github.com/acme/app"),
            ([path: Data(good.utf8), "projects/x/answers.json": Data("{}".utf8)], kind.message),
        ]
        for (files, message) in attempts {
            await #expect(throws: WorkFilter.Failure.self) {
                try await WorkFilter.commit(kind, files: files, message: message, brain: brainRoot, machine: MachineProfile.load(home: home), env: env)
            }
            #expect(try await git("rev-parse", "HEAD") == head)
            #expect(try read(".akit/registry/\(path)") == current)
            #expect(try await git("status", "--porcelain", "--untracked-files=all").isEmpty)
        }
        #expect(try await WorkFilter.commit(kind, files: [path: Data(good.utf8)], message: kind.message, brain: brainRoot,
                                            machine: MachineProfile.load(home: home), env: env))
    }

    @Test func recommendFlagsAndSubcommandWords() async throws {
        try await setUpHome(brain: false)
        let scoped = try json(await akit("recommend", "--project", "apply", "--json"))
        #expect(scoped["recommendations"] as? [Any] != nil)
        for arguments in [["recommend", "bogus"], ["recommend", "apply"], ["recommend", "--home"], ["recommend", "--yes"],
                          ["recommend", "--project", "x", "--all"], ["recommend", "--min-days", "0"], ["recommend", "--bindings", "maybe"],
                          ["recommend", "apply", "r-1", "--json"], ["recommend", "--top", "3"]] {
            var out: [String] = [], err: [String] = []
            let code = await AKitCLI.run(arguments, env: env, cwd: home, projectsRoot: home.appending(path: "Projects"), hostName: "TestMac.local",
                                         out: { out.append($0) }, err: { err.append($0) }, hardwareHash: { "test-hardware" })
            #expect(code == 2, "\(arguments): \(out) \(err)")
        }
        #expect(await akit("recommend", "--min-sessions", "5", "--min-days", "3", "--all").code == 0)
        #expect(await akit("--help").out.contains("akit recommend apply ID [--yes]"))
    }
}
