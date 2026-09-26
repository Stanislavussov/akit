import Foundation
import Testing
@testable import AKitCore

/// The session index: schema, import rules, facts. Temporary fake home and index; never
/// reads the real ~/.claude or ~/.pi.
struct InsightsImportTests {
    let home: URL
    let fm = FileManager.default

    init() throws {
        home = fm.temporaryDirectory.appending(path: "akit-insights-\(UUID().uuidString)")
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
    }

    var env: HarnessEnvironment { HarnessEnvironment(homeDirectory: home) }
    var paths: InsightsPaths { InsightsPaths(home: home) }

    // MARK: Helpers

    static let sentinel = "SENTINEL-7f3a"

    func line(_ object: [String: Any]) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: object, options: .sortedKeys), as: UTF8.self)
    }

    func write(_ path: String, lines: [[String: Any]], atomically: Bool = true) throws {
        let url = home.appending(path: path)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = Data((try lines.map(line).joined(separator: "\n") + "\n").utf8)
        if atomically {
            try data.write(to: url, options: .atomic)
        } else {
            // Same inode: truncate and write in place.
            let handle = try FileHandle(forWritingTo: url)
            try handle.truncate(atOffset: 0)
            try handle.write(contentsOf: data)
            try handle.close()
        }
    }

    func append(_ path: String, text: String) throws {
        let handle = try FileHandle(forWritingTo: home.appending(path: path))
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
        try handle.close()
    }

    func append(_ path: String, lines: [[String: Any]]) throws {
        try append(path, text: try lines.map(line).joined(separator: "\n") + "\n")
    }

    func setModified(_ path: String, _ date: Date) throws {
        try fm.setAttributes([.modificationDate: date], ofItemAtPath: home.appending(path: path).path)
    }

    func database() throws -> IndexDatabase { try IndexSchema.open(paths.database) }

    @discardableResult
    func runImport(_ importer: SessionImporter? = nil) throws -> ImportReport {
        try (importer ?? SessionImporter(env: env)).run(database: try database())
    }

    func count(_ sql: String, _ values: any SQLBindable...) throws -> Int {
        let db = try database()
        return try db.rows(sql, values).first?.first?.int ?? 0
    }

    func text(_ sql: String, _ values: any SQLBindable...) throws -> String? {
        let db = try database()
        return try db.rows(sql, values).first?.first?.text
    }

    // MARK: Claude fixtures

    let claudeFile = ".claude/projects/-work-app/s1.jsonl"
    let subagentFile = ".claude/projects/-work-app/s1/subagents/agent-a1.jsonl"

    static func usage(_ input: Int, _ output: Int, read: Int = 100, write: Int = 20, thinking: Int = 0) -> [String: Any] {
        ["input_tokens": input, "output_tokens": output, "cache_read_input_tokens": read, "cache_creation_input_tokens": write,
         "output_tokens_details": ["thinking_tokens": thinking]]
    }

    static func assistant(_ id: String, _ time: String, content: [[String: Any]], usage: [String: Any]? = nil,
                          model: String = "claude-opus-5-5", sidechain: Bool = false) -> [String: Any] {
        var message: [String: Any] = ["id": id, "role": "assistant", "model": model, "content": content]
        message["usage"] = usage ?? Self.usage(10, 5, thinking: 2)
        return ["type": "assistant", "uuid": "u-\(id)-\(content.count)", "sessionId": "s1", "isSidechain": sidechain,
                "timestamp": "2026-09-20T10:00:\(time).000Z", "message": message]
    }

    static func user(_ uuid: String, _ time: String, _ content: Any, sidechain: Bool = false) -> [String: Any] {
        ["type": "user", "uuid": uuid, "sessionId": "s1", "isSidechain": sidechain, "cwd": "/work/app",
         "timestamp": "2026-09-20T10:00:\(time).000Z", "message": ["role": "user", "content": content]]
    }

    static func listing(_ uuid: String, _ time: String, names: [String], content: String, initial: Bool = true,
                        sidechain: Bool = false) -> [String: Any] {
        ["type": "attachment", "uuid": uuid, "sessionId": "s1", "isSidechain": sidechain, "cwd": "/work/app",
         "timestamp": "2026-09-20T10:00:\(time).000Z",
         "attachment": ["type": "skill_listing", "isInitial": initial, "names": names, "content": content, "skillCount": names.count]]
    }

    func claudeSession() -> [[String: Any]] {
        let s = Self.sentinel
        return [
            ["type": "permission-mode", "permissionMode": "default", "sessionId": "s1"],
            Self.listing("L1", "00", names: ["tdd", "marketing:draft-content", "marketing"],
                         content: "- tdd: Tests first \(s)\n- marketing:draft-content: Draft posts \(s)\n- marketing"),
            ["type": "attachment", "uuid": "D1", "sessionId": "s1", "cwd": "/work/app", "version": "2.1.283", "gitBranch": "main",
             "timestamp": "2026-09-20T10:00:00.500Z", "attachment": ["type": "date", "date": "2026-09-20"]],
            Self.user("U1", "01", "<command-name>/model</command-name>\n<command-args>opus \(s)</command-args>"),
            Self.user("U2", "02", "Fix the login bug \(s)"),
            // One response written as two lines with the same id and usage.
            Self.assistant("m1", "03", content: [["type": "thinking", "thinking": "Look \(s)", "signature": "x"]]),
            Self.assistant("m1", "03", content: [
                ["type": "text", "text": "Reading \(s)"],
                ["type": "tool_use", "id": "t1", "name": "Read", "input": ["file_path": "/work/app/login.swift"]],
                ["type": "tool_use", "id": "t2", "name": "Skill", "input": ["skill": "tdd", "args": ""]],
            ]),
            Self.user("U3", "04", [
                ["type": "tool_result", "tool_use_id": "t1", "content": [["type": "text", "text": "func login() \(s)"]]],
                ["type": "tool_result", "tool_use_id": "t2", "content": "Launching skill: tdd", "is_error": false],
            ]),
            Self.user("U4", "05", [["type": "text", "text": "<command-message>tdd</command-message>\n<command-name>/tdd</command-name>\n<command-args>write tests \(s)</command-args>"]]),
            Self.assistant("m2", "06", content: [["type": "text", "text": "Done \(s)"]], usage: Self.usage(30, 7)),
            // Synthetic entries are not requests.
            Self.assistant("m3", "07", content: [["type": "text", "text": "No response requested."]], usage: Self.usage(0, 0),
                           model: "<synthetic>"),
            // An old-version side chain inside the main file.
            Self.assistant("m4", "08", content: [["type": "tool_use", "id": "t3", "name": "Skill", "input": ["skill": "lint"]]],
                           usage: Self.usage(3, 1), sidechain: true),
        ]
    }

    func subagentRun() -> [[String: Any]] {
        [
            Self.listing("SL1", "10", names: ["tdd", "lint"], content: "- tdd: Tests first\n- lint: Lint code", sidechain: true),
            Self.user("SU1", "11", "Check the code", sidechain: true),
            Self.assistant("sm1", "12", content: [["type": "tool_use", "id": "st1", "name": "Skill", "input": ["skill": "lint"]]],
                           usage: Self.usage(50, 9), sidechain: true),
        ]
    }

    // MARK: Claude import

    @Test func importsClaudeFixtureFacts() throws {
        try write(claudeFile, lines: claudeSession())
        try write(subagentFile, lines: subagentRun())
        let report = try runImport()
        #expect(report.sources == 2 && report.skipped.isEmpty)
        #expect(report.sessions == 1)
        #expect(report.requests == 4) // m1 once, m2, side chain m4, subagent sm1; not the synthetic m3

        let db = try database()
        let session = try #require(try db.rows("SELECT key, native_id, cwd, git_branch, harness_version, started, last_activity FROM sessions").first)
        #expect(session[0].text == "claude:s1" && session[1].text == "s1")
        #expect(session[2].text == "/work/app" && session[3].text == "main" && session[4].text == "2.1.283")
        #expect(session[5].double == JSONLines.date("2026-09-20T10:00:00.000Z")?.timeIntervalSince1970)
        #expect(session[6].double == JSONLines.date("2026-09-20T10:00:08.000Z")?.timeIntervalSince1970)

        let m1 = try #require(try db.rows("SELECT input, output, cache_read, cache_write, reasoning, is_subagent, model FROM requests WHERE event_key = 'm1'").first)
        #expect(m1.map(\.int) == [10, 5, 100, 20, 2, 0, nil] && m1[6].text == "claude-opus-5-5")
        #expect(try count("SELECT COUNT(*) FROM requests WHERE is_subagent = 1") == 2)

        let read = try #require(try db.rows("SELECT name, input_bytes, output_bytes, is_error, json_extract(extra, '$.path_hash') FROM tool_calls WHERE event_key = 't1'").first)
        #expect(read[0].text == "Read")
        #expect(read[1].int == Fact.jsonBytes(["file_path": "/work/app/login.swift"]))
        #expect(read[2].int == "func login() \(Self.sentinel)".utf8.count && read[3].int == 0)
        #expect(read[4].text == Fact.sha256("/work/app/login.swift"))

        let calls = try db.rows("SELECT skill, by, is_subagent, has_args FROM skill_calls ORDER BY ts, skill")
            .map { "\($0[0].text ?? "")/\($0[1].text ?? "")/\($0[2].int ?? -1)/\($0[3].int ?? -1)" }
        #expect(calls == ["model/user/0/1", "tdd/model/0/0", "tdd/user/0/1", "lint/model/1/0", "lint/model/1/0"])
        // `/model` is a command the user typed, not a listed skill.
        #expect(try count("SELECT COUNT(*) FROM skill_listings WHERE skill = 'model'") == 0)
        #expect(try count("SELECT COUNT(*) FROM skill_listings WHERE listing_key = 'L1'") == 3)
    }

    @Test func listingDeltasAndRepeatedInitialsAggregateOnce() throws {
        try write(claudeFile, lines: [
            Self.listing("L1", "00", names: ["a", "b"], content: "- a: A\n- b: B"),
            Self.listing("L2", "05", names: ["c"], content: "- c: C", initial: false),
            // After a compaction the whole list comes again.
            Self.listing("L3", "09", names: ["a", "b", "c"], content: "- a: A\n- b: B\n- c: C"),
        ])
        try runImport()
        #expect(try count("SELECT COUNT(*) FROM skill_listings") == 6)
        let exposure = try IndexQueries.exposure(try database(), session: "claude:s1")
        #expect(exposure == [
            "a": try #require(JSONLines.date("2026-09-20T10:00:00.000Z")),
            "b": try #require(JSONLines.date("2026-09-20T10:00:00.000Z")),
            "c": try #require(JSONLines.date("2026-09-20T10:00:05.000Z")),
        ])
        #expect(try count("SELECT COUNT(*) FROM skill_listings WHERE is_initial = 0") == 1)
    }

    @Test func pluginNamesWithColonsParse() throws {
        let skills = ClaudeFacts.listedSkills([
            "names": ["marketing", "marketing:draft-content", "a:b:c"],
            "content": "- marketing:draft-content: Draft posts\n- a:b:c: Colons: inside too\n- marketing: The plugin",
        ])
        #expect(skills.map(\.name) == ["marketing", "marketing:draft-content", "a:b:c"])
        #expect(skills.map(\.descChars) == ["The plugin".count, "Draft posts".count, "Colons: inside too".count])
        #expect(skills[0].descHash == Fact.sha256("The plugin"))
        #expect(skills[2].descHash == Fact.sha256("Colons: inside too"))
    }

    @Test func nameOnlyListingLineHasNoHash() throws {
        try write(claudeFile, lines: [Self.listing("L1", "00", names: ["tdd", "zoom"], content: "- tdd\n- zoom: Zoom out")])
        try runImport()
        let rows = try database().rows("SELECT skill, desc_hash, desc_chars FROM skill_listings ORDER BY skill")
        #expect(rows[0] == [.text("tdd"), .null, .int(0)])
        #expect(rows[1] == [.text("zoom"), .text(Fact.sha256("Zoom out")), .int(8)])
    }

    @Test func subagentListingIsExposureButNotASession() throws {
        try write(claudeFile, lines: claudeSession())
        try write(subagentFile, lines: subagentRun())
        try runImport()
        #expect(try count("SELECT COUNT(*) FROM sessions") == 1)
        #expect(try count("SELECT COUNT(*) FROM skill_listings WHERE skill = 'lint' AND is_subagent = 1 AND session_key = 'claude:s1'") == 1)
        let db = try database()
        #expect(try IndexQueries.exposure(db, session: "claude:s1")["lint"] == nil)
        #expect(try IndexQueries.exposure(db, session: "claude:s1", includeSubagents: true)["lint"] != nil)
        #expect(try count("SELECT COUNT(*) FROM sources WHERE kind = 'subagent' AND session_key = 'claude:s1'") == 1)
    }

    @Test func importIsIncremental() throws {
        try write(claudeFile, lines: Array(claudeSession().prefix(6)))
        let first = try runImport()
        #expect(first.requests == 1)
        let size = try #require(try fm.attributesOfItem(atPath: home.appending(path: claudeFile).path)[.size] as? Int)
        #expect(try count("SELECT offset FROM sources") == size)

        let more = Array(claudeSession().dropFirst(6))
        let appended = try more.map(line).joined(separator: "\n") + "\n"
        try append(claudeFile, text: appended)
        let second = try runImport()
        #expect(second.sources == 1 && second.newBytes == UInt64(appended.utf8.count))
        #expect(second.requests == 2 && second.sessions == 0)

        let third = try runImport()
        #expect(third.sources == 0 && third.newBytes == 0 && third.requests == 0)
        #expect(try count("SELECT COUNT(*) FROM sources") == 1)
    }

    @Test func partialLastLineWaits() throws {
        try write(claudeFile, lines: [Self.assistant("m1", "01", content: [])])
        let next = try line(Self.assistant("m2", "02", content: []))
        let cut = next.index(next.startIndex, offsetBy: 20)
        try append(claudeFile, text: String(next[..<cut]))
        try runImport()
        #expect(try count("SELECT COUNT(*) FROM requests") == 1)

        try append(claudeFile, text: String(next[cut...]) + "\n")
        let report = try runImport()
        #expect(report.requests == 1 && report.skipped.isEmpty)
        #expect(try count("SELECT COUNT(*) FROM sources") == 1) // appended, not replaced
    }

    @Test func resumedSessionCopiesAreNotDoubleCounted() throws {
        try write(claudeFile, lines: claudeSession())
        try setModified(claudeFile, Date(timeIntervalSinceNow: -3600))
        // A resumed session copies the earlier lines into its own file, then goes on.
        try write(".claude/projects/-work-app/s2.jsonl",
                  lines: claudeSession() + [Self.assistant("m9", "30", content: [], usage: Self.usage(1, 1))])
        try runImport()
        #expect(try count("SELECT COUNT(*) FROM requests") == 4)
        #expect(try count("SELECT COUNT(*) FROM requests WHERE session_key = 'claude:s1'") == 3)
        #expect(try text("SELECT session_key FROM requests WHERE event_key = 'm9'") == "claude:s2")
        #expect(try count("SELECT COUNT(*) FROM skill_calls") == 4)
    }

    @Test func reparseDoesNotDoubleCountListings() throws {
        try write(claudeFile, lines: claudeSession())
        try runImport()
        let listings = try count("SELECT COUNT(*) FROM skill_listings")
        var bumped = SessionImporter(env: env)
        bumped.claudeParser = ClaudeFacts.parserVersion + 1
        let report = try runImport(bumped)
        #expect(report.sources == 1)
        #expect(try count("SELECT COUNT(*) FROM skill_listings") == listings)
        #expect(try count("SELECT COUNT(*) FROM skill_listings WHERE parser_version = ?", bumped.claudeParser) == listings)
        #expect(try count("SELECT COUNT(*) FROM requests") == 3)
        #expect(try count("SELECT COUNT(*) FROM sources") == 1)
        #expect(try count("SELECT parser_version FROM sources") == bumped.claudeParser)
    }

    @Test func replacedLogKeepsOldFacts() throws {
        try write(claudeFile, lines: claudeSession())
        try runImport()
        // Rewritten as a new file: m2 is gone from it, m5 is new.
        var lines = claudeSession().filter { (($0["message"] as? [String: Any])?["id"] as? String) != "m2" }
        lines.append(Self.assistant("m5", "20", content: [], usage: Self.usage(4, 4)))
        try write(claudeFile, lines: lines)
        let report = try runImport()
        #expect(report.sources == 1)

        let generations = try database().rows("SELECT generation, state FROM sources ORDER BY generation")
        #expect(generations == [[.int(1), .text("replaced")], [.int(2), .text("active")]])
        #expect(try count("SELECT COUNT(*) FROM requests") == 4) // m1, m2 (kept), m4, m5
        #expect(try count("SELECT s.generation FROM requests r JOIN sources s ON s.id = r.source_id WHERE event_key = 'm2'") == 1)
        #expect(try count("SELECT s.generation FROM requests r JOIN sources s ON s.id = r.source_id WHERE event_key = 'm1'") == 2)
        #expect(try count("SELECT COUNT(*) FROM skill_listings") == 3)
        #expect(try count("SELECT COUNT(*) FROM sessions") == 1)
    }

    @Test func vanishedFileMarkedGoneFactsKept() throws {
        try write(claudeFile, lines: claudeSession())
        try runImport()
        try fm.removeItem(at: home.appending(path: claudeFile))
        try runImport()
        #expect(try text("SELECT state FROM sources") == "gone")
        #expect(try count("SELECT COUNT(*) FROM requests") == 3)
        #expect(try count("SELECT COUNT(*) FROM sessions") == 1)
    }

    @Test func midFileRewriteDetectedByTailHash() throws {
        let original = claudeSession()
        try write(claudeFile, lines: original)
        try runImport()
        // Same inode, longer, but the line before the old offset is different now.
        var rewritten = original
        rewritten[1] = Self.listing("L1", "00", names: ["tdd"], content: "- tdd: A much longer description than before, \(Self.sentinel)")
        rewritten.removeLast()
        rewritten.append(Self.assistant("m6", "09", content: [], usage: Self.usage(1, 1)))
        rewritten.append(Self.assistant("m7", "10", content: [], usage: Self.usage(1, 1)))
        try write(claudeFile, lines: rewritten, atomically: false)
        let size = try #require(try fm.attributesOfItem(atPath: home.appending(path: claudeFile).path)[.size] as? Int)
        #expect(size >= (try count("SELECT offset FROM sources")))
        let before = try count("SELECT inode FROM sources")
        try runImport()
        #expect(try count("SELECT MAX(inode) FROM sources") == before)
        #expect(try database().rows("SELECT state FROM sources ORDER BY generation") == [[.text("replaced")], [.text("active")]])
        #expect(try count("SELECT COUNT(*) FROM requests WHERE event_key IN ('m6', 'm7')") == 2)
        #expect(try count("SELECT COUNT(*) FROM requests WHERE event_key = 'm4'") == 1) // kept from the old generation
    }

    @Test func olderParserNeverDowngradesRow() throws {
        try write(claudeFile, lines: [Self.assistant("m1", "01", content: [], usage: Self.usage(10, 5), model: "model-a")])
        try setModified(claudeFile, Date(timeIntervalSinceNow: -3600))
        var newer = SessionImporter(env: env)
        newer.claudeParser = 2
        try runImport(newer)

        // Another file with the same response id, read by an older akit: changes nothing.
        let copy = ".claude/projects/-work-app/s2.jsonl"
        try write(copy, lines: [Self.assistant("m1", "01", content: [], usage: Self.usage(99, 99), model: "model-b")])
        var older = SessionImporter(env: env)
        older.claudeParser = 1
        try runImport(older)
        let kept = try database().rows("SELECT model, input, parser_version, session_key FROM requests")
        #expect(kept == [[.text("model-a"), .int(10), .int(2), .text("claude:s1")]])

        // A newer parser upgrades the values, never the identity or the owner.
        var newest = SessionImporter(env: env)
        newest.claudeParser = 3
        try runImport(newest)
        let upgraded = try database().rows("SELECT model, input, parser_version, session_key, source_id FROM requests")
        #expect(upgraded.first?[2] == .int(3) && upgraded.first?[3] == .text("claude:s1"))
        #expect(upgraded.first?[4] == .int(1))
    }

    @Test func keyVersionMismatchRefusesImport() throws {
        try write(claudeFile, lines: claudeSession())
        try database().run("UPDATE meta SET value = '0' WHERE key = 'keyVersion'")
        #expect(throws: IndexDatabase.Failure.self) { try runImport() }
        #expect(try count("SELECT COUNT(*) FROM sources") == 0)
        #expect(try count("SELECT COUNT(*) FROM requests") == 0)
    }

    @Test func parityWithSessionUsageClaude() throws {
        try write(claudeFile, lines: claudeSession())
        try write(subagentFile, lines: subagentRun())
        try runImport()
        let usage = try ClaudeSessions.transcript(of: home.appending(path: claudeFile)).usage
        func tokens(subagent: Int) throws -> TokenCounts {
            let row = try #require(try database().rows("""
                SELECT SUM(input), SUM(output), SUM(cache_read), SUM(cache_write), SUM(reasoning), COUNT(*)
                FROM requests WHERE is_subagent = ?
                """, subagent).first)
            return TokenCounts(input: row[0].int ?? 0, output: row[1].int ?? 0, cacheRead: row[2].int ?? 0,
                               cacheWrite: row[3].int ?? 0, reasoning: row[4].int ?? 0)
        }
        #expect(try tokens(subagent: 0) == usage.tokens)
        #expect(try tokens(subagent: 1) == usage.subagentTokens)
        #expect(try count("SELECT COUNT(*) FROM requests WHERE is_subagent = 0") == usage.requests)
    }

    @Test func noMessageTextStored() throws {
        try write(claudeFile, lines: claudeSession())
        try write(subagentFile, lines: subagentRun())
        try runImport()
        let db = try database()
        let tables = try db.rows("SELECT name FROM sqlite_master WHERE type = 'table'").compactMap { $0[0].text }
        #expect(tables.count == IndexSchema.factTables.count + 2)
        var checked = 0
        for table in tables {
            for row in try db.rows("SELECT * FROM \(table)") {
                for value in row {
                    guard let text = value.text else { continue }
                    checked += 1
                    #expect(!text.contains(Self.sentinel), "\(table): \(text)")
                }
            }
        }
        #expect(checked > 20)
    }

    @Test func concurrentImportSkips() throws {
        var held = try ImportLock.acquire(paths.lock)
        #expect(held != nil)
        #expect(try ImportLock.acquire(paths.lock) == nil)
        held = nil
        #expect(try ImportLock.acquire(paths.lock) != nil)
    }

    // MARK: Schema

    @Test func migrationsAreOrderedAndIdempotent() throws {
        let database = try IndexSchema.open(paths.database)
        #expect(try database.userVersion == IndexSchema.migrations.count)
        #expect(try database.value("SELECT value FROM meta WHERE key = 'keyVersion'")?.text == "\(IndexSchema.keyVersion)")

        // Opening again runs nothing twice (a second run of v1 would fail on CREATE TABLE).
        try database.run("INSERT INTO sources(path, generation, harness, kind, parser_version, state) VALUES('x', 1, 'claude', 'session', 1, 'active')")
        let again = try IndexSchema.open(paths.database)
        #expect(try again.userVersion == IndexSchema.migrations.count)
        #expect(try again.value("SELECT COUNT(*) FROM sources")?.int == 1)
        #expect(try again.value("SELECT COUNT(*) FROM meta")?.int == 1)

        // No fact table can cascade from sources, and each has its source index.
        for table in IndexSchema.factTables {
            #expect(try again.rows("SELECT * FROM pragma_foreign_key_list('\(table)')").isEmpty, "\(table)")
            #expect(try again.value("SELECT name FROM sqlite_master WHERE type = 'index' AND name = ?", "\(table)_source")?.text
                    == "\(table)_source")
        }

        // An index from a newer akit is refused, not downgraded.
        try again.execute("PRAGMA user_version = \(IndexSchema.migrations.count + 1)")
        #expect(throws: IndexDatabase.Failure.self) { _ = try IndexSchema.open(paths.database) }
    }
}
