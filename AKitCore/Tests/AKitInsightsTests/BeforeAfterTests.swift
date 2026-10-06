import Foundation
import Testing
import AKitFoundation
@testable import AKitCommandLine
@testable import AKitInsights

/// Before/after measurement of first-request context around applies and marks, and the k
/// calibration. Facts go straight into a temporary index in a temporary fake home.
struct BeforeAfterTests {
    let home: URL
    let fm = FileManager.default
    /// 2026-05-28 around 20:26 UTC: far from any real session.
    let anchor = Date(timeIntervalSince1970: 1_780_000_000)
    static let project = "github.com/acme/app"

    init() throws {
        home = fm.temporaryDirectory.appending(path: "akit-before-after-\(UUID().uuidString)")
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
    }

    var env: HarnessEnvironment {
        HarnessEnvironment(homeDirectory: home, variables: [
            "HOME": home.path, "GIT_CONFIG_NOSYSTEM": "1",
            "GIT_AUTHOR_NAME": "Test", "GIT_AUTHOR_EMAIL": "test@example.com",
            "GIT_COMMITTER_NAME": "Test", "GIT_COMMITTER_EMAIL": "test@example.com",
        ], executableSearchPaths: [URL(filePath: "/usr/bin")])
    }

    func database() throws -> IndexDatabase { try IndexSchema.open(InsightsPaths(home: home).database) }

    /// `count` main sessions an hour apart, after (`side` 1) or before (`side` -1) `at`, each
    /// listing the skills (description characters) and with a first request of `context` + 10 × i
    /// recorded tokens (input + cache read + cache write).
    func sessions(_ prefix: String, _ count: Int, side: Double, at date: Date? = nil, version: String = "2.0.1", model: String = "opus",
                  context: Int, skills: [String: Int] = [:], project: String? = nil, in db: IndexDatabase) throws {
        let base = (date ?? anchor).timeIntervalSince1970
        for index in 0..<count {
            let key = "claude:\(prefix)\(index)", started = base + side * Double(index + 1) * 3600
            try db.run("""
                INSERT INTO sessions(key, harness, native_id, harness_version, started, source_id, parser_version)
                VALUES(?, 'claude', ?, ?, ?, 0, 1)
                """, key, "\(prefix)\(index)", version, started)
            for (skill, chars) in skills {
                try db.run("""
                    INSERT INTO skill_listings(harness, listing_key, skill, session_key, ts, is_subagent, is_initial, desc_hash, desc_chars,
                      source_id, parser_version) VALUES('claude', ?, ?, ?, ?, 0, 1, 'h', ?, 0, 1)
                    """, UUID().uuidString, skill, key, started, chars)
            }
            let total = context + 10 * index
            try db.run("""
                INSERT INTO requests(harness, event_key, session_key, ts, model, input, cache_read, cache_write, is_subagent, source_id,
                  parser_version) VALUES('claude', ?, ?, ?, ?, ?, ?, 400, 0, 0, 1)
                """, UUID().uuidString, key, started + 10, model, total - 1000, 600)
            if let project {
                try db.run("""
                    INSERT INTO bindings(session_key, project_id, method, confidence, decided_at, resolver_version)
                    VALUES(?, ?, 'hook', 'exact', 0, 1)
                    """, key, project)
            }
        }
    }

    func applyRow(_ project: String, at date: Date, in db: IndexDatabase) throws {
        try db.run("INSERT INTO applies(project_id, ts, layers, skills, source_id, parser_version) VALUES(?, ?, '[\"core\"]', '{}', 0, 1)",
                   project, Spool.milliseconds(date))
    }

    func markRow(_ note: String, at date: Date, in db: IndexDatabase) throws {
        try db.run("INSERT INTO marks(ts, note, source_id, parser_version) VALUES(?, ?, 0, 1)", Spool.milliseconds(date), note)
    }

    func only(_ db: IndexDatabase, descriptions: [String: String] = [:]) throws -> ChangesReport.Change {
        let changes = try BeforeAfter.changes(db, descriptions: descriptions)
        #expect(changes.count == 1, "\(changes)")
        return try #require(changes.first)
    }

    /// A measured change as the calibration sees it.
    func pair(k: Double, chars: Int = 4000, script: ContextSize.Script = .latin) -> ChangesReport.Change {
        .init(at: "", anchor: "mark", project: nil, note: "x", scope: .init(project: nil), status: "measured",
              deltaTokens: -Int((Double(chars) / k).rounded()), deltaChars: -chars, k: k, script: script.rawValue)
    }

    func akit(_ arguments: String...) async -> (code: Int32, out: String, err: String) {
        var out: [String] = [], err: [String] = []
        let code = await AKitCLI.run(arguments, env: env, cwd: home, projectsRoot: home.appending(path: "Projects"), hostName: "TestMac.local",
                                     installedTargets: ["claude"], out: { out.append($0) }, err: { err.append($0) },
                                     trash: { _ in nil }, hardwareHash: { "test-hardware" })
        return (code, out.joined(separator: "\n"), err.joined(separator: "\n"))
    }
}

// MARK: - Pairs

extension BeforeAfterTests {
    @Test func pairsRequireSameVersionAndModel() throws {
        let db = try database()
        try applyRow("home/testmac", at: anchor, in: db)
        try sessions("b", 5, side: -1, context: 20_000, in: db)
        try sessions("v", 5, side: 1, version: "2.0.2", context: 18_000, in: db)
        try sessions("m", 6, side: 1, model: "sonnet", context: 18_000, in: db)
        let apart = try only(db)
        #expect(!apart.isMeasured && apart.reason?.contains("same harness version and model") == true, "\(apart)")
        #expect(apart.scope.project == nil && apart.project == "home/testmac", "a home apply counts every session")

        try sessions("a", 5, side: 1, context: 19_000, in: db)
        let change = try only(db)
        #expect(change.isMeasured && change.group == .init(harness: "claude", harnessVersion: "2.0.1", model: "opus"), "\(change)")
        #expect(change.before == .init(sessions: 5, median: 20_020) && change.after == .init(sessions: 5, median: 19_020))
        #expect(change.deltaTokens == -1000)
    }

    @Test func notEnoughDataBelowFiveSessions() throws {
        let db = try database()
        try applyRow(Self.project, at: anchor, in: db)
        try sessions("b", 4, side: -1, context: 20_000, project: Self.project, in: db)
        try sessions("a", 6, side: 1, context: 19_000, project: Self.project, in: db)
        // Older than 14 days, or not bound to the project: not counted.
        try sessions("old", 3, side: -1, at: anchor.addingTimeInterval(-15 * 86_400), context: 20_000, project: Self.project, in: db)
        try sessions("other", 3, side: -1, context: 20_000, in: db)
        let change = try only(db)
        #expect(!change.isMeasured && change.scope.project == Self.project)
        #expect(change.reason?.hasPrefix("4 before and 6 after in the best group (claude 2.0.1, opus)") == true, "\(change.reason ?? "")")
        let object = try #require(try JSONSerialization.jsonObject(with: Data(AKitCLI.encode(change).utf8)) as? [String: Any])
        #expect(Set(object.keys) == ["at", "anchor", "project", "scope", "status", "reason"] && object["status"] as? String == "notEnoughData")

        // Nothing at all around a mark.
        try markRow("Disabled marketing", at: anchor.addingTimeInterval(60 * 86_400), in: db)
        let empty = try #require(try BeforeAfter.changes(db, descriptions: [:]).last)
        #expect(empty.anchor == "mark" && empty.note == "Disabled marketing" && empty.reason?.hasPrefix("no sessions") == true)
    }

    @Test func deltaUsesRecordedTokensOnly() throws {
        let db = try database()
        try markRow("Disabled marketing", at: anchor, in: db)
        try sessions("b", 5, side: -1, context: 20_000, skills: ["marketing:seo": 4000, "tdd": 400], in: db)
        // tdd's description grew, but it is listed on both sides: only skills that left or joined count.
        try sessions("a", 5, side: 1, context: 19_000, skills: ["tdd": 900], in: db)
        // Recorded only: a session without requests, and subagent requests, count nothing.
        try db.run("INSERT INTO sessions(key, harness, native_id, harness_version, started, source_id, parser_version) VALUES('claude:x', 'claude', 'x', '2.0.1', ?, 0, 1)",
                   anchor.timeIntervalSince1970 + 7200)
        for index in 0..<5 {
            try db.run("""
                INSERT INTO requests(harness, event_key, session_key, ts, model, input, cache_read, cache_write, is_subagent, source_id,
                  parser_version) VALUES('claude', ?, ?, ?, 'opus', 900000, 0, 0, 1, 0, 1)
                """, UUID().uuidString, "claude:a\(index)", anchor.timeIntervalSince1970 + Double(index + 1) * 3600 + 1)
        }
        let change = try only(db)
        #expect(change.isMeasured && change.after?.sessions == 5 && change.deltaTokens == -1000, "\(change)")
        #expect(change.left == ["marketing:seo"] && change.joined == [] && change.deltaChars == -4000)
        #expect(change.k == 4.0 && change.script == "latin")
        let text = AKitCLI.changesText(ChangesReport(version: 1, changes: [change], calibration: ContextCalibration.summary(ContextSize.defaults)),
                                       project: nil)
        #expect(text.contains("change −1.0k tokens") && text.contains("1 skill left, −4.0k description characters"), "\(text)")
        for money in ["$", "usd", "cost", "price", "dollar", "€"] { #expect(!text.lowercased().contains(money), "\(money)") }
    }
}

// MARK: - Calibration

extension BeforeAfterTests {
    @Test func calibrationNeedsTwoPairs() throws {
        let db = try database()
        // Too few characters, an implausible k, or nothing measured: not accepted.
        var unmeasured = pair(k: 4)
        unmeasured = .init(at: "", anchor: "mark", project: nil, note: "x", scope: .init(project: nil), status: "notEnoughData",
                           k: unmeasured.k, script: "latin")
        #expect(ContextCalibration.accepted([pair(k: 4, chars: 300), pair(k: 0.3), unmeasured]).isEmpty)

        let one = ContextCalibration.calibration(from: [pair(k: 3.0)])
        #expect(!one.isCalibrated && one.latin == ContextSize.defaults.latin && one.latinPairs == 1)
        try ContextCalibration.save(one, database: db)
        #expect(try ContextSize.calibration(db) == ContextSize.defaults)
        #expect(try db.value("SELECT COUNT(*) FROM meta WHERE key LIKE 'k.%'")?.int == 0)

        let two = ContextCalibration.calibration(from: [pair(k: 3.0), pair(k: 3.6)])
        #expect(two.isCalibrated && two.latin == 3.3 && two.cyrillic == ContextSize.defaults.cyrillic && two.pairs == 2)
        try ContextCalibration.save(two, database: db)
        let stored = try ContextSize.calibration(db)
        #expect(stored.latin == 3.3 && stored.pairs == 2 && stored.latinPairs == 2 && stored.cyrillicPairs == 0)
        #expect(stored.describe == "k 3.3 Latin (calibrated from 2 before/after pairs), 2.5 Cyrillic (default)", "\(stored.describe)")
        #expect(ContextSize.approxTokens(chars: 33, script: .latin, calibration: stored).tokens == 10)
        // Back to one pair: the defaults again.
        try ContextCalibration.save(one, database: db)
        #expect(try ContextSize.calibration(db) == ContextSize.defaults)
    }

    @Test func cyrillicAndLatinCalibratedSeparately() throws {
        let db = try database()
        let descriptions = ["en": "Checks the code before a commit", "ru": "Проверяет код перед коммитом"]
        // Four marks 40 days apart; at each, one skill leaves the listing.
        let cases: [(skill: String, chars: Int, delta: Int)] = [("en", 4000, 1000), ("en", 4000, 800), ("ru", 2000, 1000), ("ru", 2200, 1000)]
        for (index, item) in cases.enumerated() {
            let date = anchor.addingTimeInterval(Double(index) * 40 * 86_400)
            try markRow("change \(index)", at: date, in: db)
            try sessions("b\(index)-", 5, side: -1, at: date, context: 20_000, skills: [item.skill: item.chars, "tdd": 400], in: db)
            try sessions("a\(index)-", 5, side: 1, at: date, context: 20_000 - item.delta, skills: ["tdd": 400], in: db)
        }
        let changes = try BeforeAfter.changes(db, descriptions: descriptions)
        #expect(changes.map(\.k) == [4.0, 5.0, 2.0, 2.2] && changes.map(\.script) == ["latin", "latin", "cyrillic", "cyrillic"], "\(changes)")
        let calibration = ContextCalibration.calibration(from: changes)
        #expect(calibration.latin == 4.5 && calibration.cyrillic == 2.1 && calibration.pairs == 4)
        try ContextCalibration.save(calibration, database: db)
        let stored = try ContextSize.calibration(db)
        #expect(stored.latin == 4.5 && stored.cyrillic == 2.1 && stored.latinPairs == 2 && stored.cyrillicPairs == 2)
        #expect(ContextSize.approxTokens(chars: 21, script: .cyrillic, calibration: stored).tokens == 10)
        #expect(ContextCalibration.summary(stored) == .init(latin: 4.5, cyrillic: 2.1, pairs: 4, latinPairs: 2, cyrillicPairs: 2,
                                                           source: "calibrated"))
        // Only the Latin pairs: Cyrillic keeps its default.
        let latinOnly = ContextCalibration.calibration(from: Array(changes.prefix(3)))
        #expect(latinOnly.latin == 4.5 && latinOnly.cyrillic == ContextSize.defaults.cyrillic && latinOnly.pairs == 2
                && latinOnly.cyrillicPairs == 1)
    }
}

// MARK: - Marks and the CLI

extension BeforeAfterTests {
    @Test func markAnchorsFromSpoolWithAtDate() async throws {
        let marked = await akit("stats", "mark", "Disabled the marketing plugin", "--at", "2026-09-20T14:30")
        #expect(marked.code == 0 && marked.out.hasPrefix("Marked "), "\(marked)")
        let file = InsightsPaths(home: home).spool.appending(path: Spool.fileName(for: Date()))
        let line = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let at = try #require(calendar.date(from: DateComponents(year: 2026, month: 9, day: 20, hour: 14, minute: 30)))
        #expect(line["kind"] as? String == "mark" && line["note"] as? String == "Disabled the marketing plugin" && line["v"] as? Int == 1)
        #expect((line["ts"] as? NSNumber)?.int64Value == Spool.milliseconds(at))
        #expect(await akit("stats", "mark", "Settings", "--at", "2026-09-21").code == 0)

        // An older akit, which knows no marks, counts the lines as unknown and keeps the file.
        let db = try database()
        var older = SessionImporter(env: env)
        older.spoolKinds = ["session_start", "apply"]
        older.spoolParser = 1
        _ = try older.run(database: db, now: Date())
        #expect(try db.value("SELECT unknown_lines FROM sources WHERE path = ?", file.path)?.int == 2)
        #expect(try db.value("SELECT COUNT(*) FROM marks")?.int == 0)
        // This akit's spool parser reads the file again.
        _ = try SessionImporter(env: env).run(database: db, now: Date())
        #expect(try db.value("SELECT unknown_lines FROM sources WHERE path = ?", file.path)?.int == 0)
        let midnight = try #require(calendar.date(from: DateComponents(year: 2026, month: 9, day: 21)))
        #expect(try BeforeAfter.anchors(db) == [.init(date: at, kind: "mark", project: nil, note: "Disabled the marketing plugin"),
                                                .init(date: midnight, kind: "mark", project: nil, note: "Settings")])
    }

    /// The Insights screen's Add Mark… writes the same line as akit stats mark, and refuses the same notes.
    @Test func spoolMarkChecksTheNoteAndTime() throws {
        let now = Date()
        func refused(_ note: String, at date: Date) -> String? {
            do {
                try Spool.mark(note, at: date, home: home, now: now)
                return nil
            } catch {
                return error.message
            }
        }
        #expect(refused("  ", at: now) == "The note is empty.")
        #expect(refused(String(repeating: "x", count: 501), at: now) == "The note is longer than 500 characters.")
        #expect(refused("Later", at: now.addingTimeInterval(60)) == "The time is in the future.")
        #expect(!FileManager.default.fileExists(atPath: InsightsPaths(home: home).spool.path), "nothing was marked")
        #expect(try Spool.mark("  Turned off a plugin \n", at: now.addingTimeInterval(-3600), home: home, now: now) == "Turned off a plugin")
        let file = InsightsPaths(home: home).spool.appending(path: Spool.fileName(for: now))
        let line = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        #expect(line["kind"] as? String == "mark" && line["note"] as? String == "Turned off a plugin")
        #expect((line["ts"] as? NSNumber)?.int64Value == Spool.milliseconds(now.addingTimeInterval(-3600)))
    }

    @Test func statsMarkAndChangesParse() async throws {
        let noNote = await akit("stats", "mark")
        #expect(noNote.code == 2 && noNote.err.contains("akit stats mark \"<note>\""), "\(noNote)")
        #expect(await akit("stats", "mark", "x", "--json").err.contains("--json doesn't go with akit stats mark"))
        #expect(await akit("stats", "mark", "x", "--project", "p").code == 2)
        #expect(await akit("stats", "mark", "x", "--at", "yesterday").err.contains("--at needs a date"))
        #expect(await akit("stats", "mark", "x", "--at", "2999-01-01").err.contains("future"))
        #expect(await akit("stats", "--at", "2026-09-20").err.contains("--at goes with akit stats mark"))
        #expect(await akit("stats", "changes", "--days", "3").err.contains("--days doesn't go with akit stats changes"))
        #expect(await akit("stats", "changes", "extra").code == 2)
        #expect(!FileManager.default.fileExists(atPath: InsightsPaths(home: home).spool.path), "nothing was marked")
        // The spool can't be written (a file where its folder belongs): the mark fails and says so.
        let spool = InsightsPaths(home: home).spool
        try FileManager.default.createDirectory(at: spool.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: spool)
        let failed = await akit("stats", "mark", "Lost")
        #expect(failed.code != 0 && failed.err.contains("Couldn't write the mark") && !failed.out.contains("Marked"), "\(failed)")
        try FileManager.default.removeItem(at: spool)

        #expect(await akit("stats", "mark", "Disabled marketing").code == 0)
        let result = await akit("stats", "--all", "changes", "--json")
        #expect(result.code == 0, "\(result)")
        let object = try #require(try JSONSerialization.jsonObject(with: Data(result.out.utf8)) as? [String: Any], "\(result)")
        #expect(Set(object.keys) == ["version", "changes", "calibration"] && object["version"] as? Int == 1)
        let calibration = try #require(object["calibration"] as? [String: Any])
        #expect(Set(calibration.keys) == ["latin", "cyrillic", "pairs", "latinPairs", "cyrillicPairs", "source"])
        #expect(calibration["source"] as? String == "defaults" && calibration["latin"] as? Double == 4)
        let change = try #require((object["changes"] as? [[String: Any]])?.first)
        #expect(change["anchor"] as? String == "mark" && change["status"] as? String == "notEnoughData" && change["reason"] is String)
        // A project shows its own applies and the marks, which are Mac-wide.
        let project = try #require(try JSONSerialization.jsonObject(with: Data(await akit("stats", "changes", "--project", Self.project, "--json").out.utf8))
                                   as? [String: Any])
        #expect((project["changes"] as? [[String: Any]])?.map { $0["anchor"] as? String } == ["mark"], "\(project)")
        let text = await akit("stats", "changes")
        #expect(text.code == 0 && text.out.contains("mark “Disabled marketing” (all sessions on this Mac)")
                && text.out.contains("not enough data: no sessions") && text.out.contains("≈ sizes use k 4.0 Latin (default"), "\(text)")
    }
}
