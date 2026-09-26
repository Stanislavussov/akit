import Foundation

/// What one import run did. JSON for `akit sessions import --json`.
struct ImportReport: Encodable, Equatable {
    struct Skipped: Encodable, Equatable {
        let path: String
        let reason: String
    }

    /// Files that had new (or re-read) lines.
    var sources = 0
    var newBytes: UInt64 = 0
    /// Rows added to the index.
    var sessions = 0
    var requests = 0
    var toolCalls = 0
    var skillCalls = 0
    var spoolLines = 0
    var skipped: [Skipped] = []
    /// Files left for the next run because the time budget ran out.
    var pending = 0
    var ms = 0
}

/// Reads new lines of Claude Code and Pi session logs into the index, oldest file first.
/// Per file (one transaction each):
/// - appended bytes (same inode, not shorter, the line before the stored offset unchanged):
///   read from the offset;
/// - parser bump on an intact file: delete that source's facts, read from 0;
/// - replaced, shrunk or rewritten: the old generation stays as a tombstone with its facts,
///   a new generation reads from 0 and natural keys drop lines seen before;
/// - vanished: `gone`, facts kept forever.
/// Facts are upserted: a row's identity never changes, it moves only to a newer generation of
/// the same file, and its values change only for a newer parser (or its own file re-reading them).
struct SessionImporter {
    let env: HarnessEnvironment
    var claudeParser = ClaudeFacts.parserVersion
    var piParser = PiFacts.parserVersion

    /// A log file found on disk.
    struct LogFile {
        let url: URL
        let harness: String
        let kind: String
        let inode: Int64
        let size: UInt64
        let modified: Date
    }

    static func `import`(env: HarnessEnvironment, database: IndexDatabase, now: Date = Date(),
                         budget: TimeInterval? = nil) throws -> ImportReport {
        try SessionImporter(env: env).run(database: database, now: now, budget: budget)
    }

    func run(database: IndexDatabase, now: Date = Date(), budget: TimeInterval? = nil) throws -> ImportReport {
        let clock = Date()
        try Self.checkKeyVersion(database)
        let before = try Self.counts(database)
        var report = ImportReport()
        let keepExamples = Self.keepsManualCallExamples(home: env.homeDirectory)
        let files = discover().sorted { $0.modified < $1.modified }
        for (index, file) in files.enumerated() {
            if let budget, Date().timeIntervalSince(clock) > budget {
                report.pending = files.count - index
                break
            }
            do {
                // Decoded JSON objects are autoreleased; drain them per file, or a long run holds them all.
                if let bytes = try autoreleasepool(invoking: {
                    try importFile(file, database: database, now: now, keepExamples: keepExamples)
                }) {
                    report.sources += 1
                    report.newBytes += bytes
                }
            } catch {
                report.skipped.append(.init(path: file.url.path, reason: error.localizedDescription))
            }
        }
        try markGone(database, found: Set(files.map(\.url.path)))
        let after = try Self.counts(database)
        report.sessions = after[0] - before[0]
        report.requests = after[1] - before[1]
        report.toolCalls = after[2] - before[2]
        report.skillCalls = after[3] - before[3]
        report.ms = Int(Date().timeIntervalSince(clock) * 1000)
        return report
    }

    /// The index must derive keys the way this akit does; mixed keys would double-count.
    static func checkKeyVersion(_ database: IndexDatabase) throws {
        let stored = try database.value("SELECT value FROM meta WHERE key = 'keyVersion'")?.text
        guard stored == "\(IndexSchema.keyVersion)" else {
            throw IndexDatabase.Failure(message: """
                The index at \(database.url.path) uses key version \(stored ?? "none"); this akit uses \
                \(IndexSchema.keyVersion). Nothing was imported. Update akit.
                """)
        }
    }

    /// Manual-call examples are the one kind of message text in the index: kept only when
    /// `~/.akit/insights.json` says `"keepManualCallExamples": true`, and never on a work Mac
    /// (or one whose machine.json can't be read).
    static func keepsManualCallExamples(home: URL) -> Bool {
        let machine = MachineProfile.load(home: home)
        guard !machine.isWork, machine.problem == nil,
              let data = try? Data(contentsOf: InsightsPaths(home: home).settings),
              let settings = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        return settings["keepManualCallExamples"] as? Bool == true
    }

    private static func counts(_ database: IndexDatabase) throws -> [Int] {
        try ["sessions", "requests", "tool_calls", "skill_calls"].map {
            try database.value("SELECT COUNT(*) FROM \($0)")?.int ?? 0
        }
    }

    // MARK: - Files

    /// Claude `projects/*/*.jsonl` and `projects/*/<session>/subagents/*.jsonl`; Pi `<sessions>/*/*.jsonl`.
    func discover() -> [LogFile] {
        var found: [LogFile] = []
        let projects = ClaudeCodeAdapter().configRoot(in: env).appending(path: "projects")
        for folder in SkillScanner.children(of: projects) where SkillScanner.isDirectory(folder) {
            for item in SkillScanner.children(of: folder) {
                if item.pathExtension == "jsonl" {
                    found += Self.logFile(item, harness: "claude", kind: "session").map { [$0] } ?? []
                } else if SkillScanner.isDirectory(item) {
                    for agent in SkillScanner.children(of: item.appending(path: "subagents")) where agent.pathExtension == "jsonl" {
                        found += Self.logFile(agent, harness: "claude", kind: "subagent").map { [$0] } ?? []
                    }
                }
            }
        }
        let pi = PiSessions.folder(configRoot: PiAdapter().configRoot(in: env), in: env)
        for folder in SkillScanner.children(of: pi) where SkillScanner.isDirectory(folder) {
            for item in SkillScanner.children(of: folder) where item.pathExtension == "jsonl" {
                found += Self.logFile(item, harness: "pi", kind: "session").map { [$0] } ?? []
            }
        }
        return found
    }

    static func logFile(_ url: URL, harness: String, kind: String) -> LogFile? {
        var info = stat()
        guard stat(url.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { return nil }
        let modified = Date(timeIntervalSince1970: Double(info.st_mtimespec.tv_sec) + Double(info.st_mtimespec.tv_nsec) / 1e9)
        return LogFile(url: url, harness: harness, kind: kind, inode: Int64(bitPattern: UInt64(info.st_ino)),
                       size: UInt64(info.st_size), modified: modified)
    }

    /// Active sources whose file is gone keep their facts; the row says so.
    private func markGone(_ database: IndexDatabase, found: Set<String>) throws {
        for row in try database.rows("SELECT id, path FROM sources WHERE state = 'active' AND kind != 'spool'") {
            guard let path = row[1].text, !found.contains(path), !FileManager.default.fileExists(atPath: path) else { continue }
            try database.run("UPDATE sources SET state = 'gone' WHERE id = ?", row[0])
        }
    }

    private func parserVersion(_ harness: String) -> Int { harness == "pi" ? piParser : claudeParser }

    /// Reads what's new in one file. Returns the bytes read, nil when nothing changed.
    private func importFile(_ file: LogFile, database: IndexDatabase, now: Date, keepExamples: Bool) throws -> UInt64? {
        let parser = parserVersion(file.harness)
        let latest = try database.rows("""
            SELECT id, generation, inode, offset, tail_hash, parser_version, state, imported_at, session_key
            FROM sources WHERE path = ? ORDER BY generation DESC LIMIT 1
            """, file.url.path).first
        var start: UInt64 = 0
        var reparse = false
        var newGeneration = true
        if let row = latest, row[6].text == "active" {
            let offset = UInt64(row[3].int ?? 0), storedParser = row[5].int ?? 0
            let sameInode = row[2] == .int(file.inode)
            // Fast path: nothing written since the last import.
            if sameInode, file.size == offset, storedParser >= parser, let at = row[7].double,
               file.modified.timeIntervalSince1970 < at {
                return nil
            }
            let intact = sameInode && file.size >= offset
                && (offset == 0 || JSONLines.tailHash(of: file.url, endingAt: offset) == row[4].text)
            if intact {
                newGeneration = false
                if storedParser < parser {
                    reparse = true
                } else if file.size == offset {
                    try database.run("UPDATE sources SET imported_at = ? WHERE id = ?", now.timeIntervalSince1970, row[0])
                    return nil
                } else {
                    start = offset
                }
            }
        }

        return try database.transaction {
            let sourceID: Int64
            let sessionKey = latest?[8].text
            if newGeneration {
                if let row = latest, row[6].text == "active" {
                    try database.run("UPDATE sources SET state = 'replaced' WHERE id = ?", row[0])
                }
                try database.run("""
                    INSERT INTO sources(path, generation, harness, kind, session_key, inode, size, offset, parser_version, state)
                    VALUES(?, ?, ?, ?, ?, ?, ?, 0, ?, 'active')
                    """, file.url.path, (latest?[1].int ?? 0) + 1, file.harness, file.kind, sessionKey, file.inode,
                    file.size, parser)
                sourceID = database.lastInsertedRow
            } else {
                sourceID = Int64(latest?[0].int ?? 0)
                if reparse {
                    for table in IndexSchema.factTables {
                        try database.run("DELETE FROM \(table) WHERE source_id = ?", sourceID)
                    }
                }
            }

            // A read from an offset has no header: the session and its cwd come from the earlier run.
            let cwd = start > 0 ? try sessionKey.flatMap { try database.value("SELECT cwd FROM sessions WHERE key = ?", $0)?.text } : nil
            var reader = FactReader(file: file.url, harness: file.harness, sessionKey: sessionKey, cwd: cwd, env: env)
            var writer = FactWriter(database: database, context: FactContext(
                harness: file.harness, sessionKey: reader.sessionKey, sourceID: sourceID,
                isSubagent: file.kind == "subagent", parserVersion: parser))
            writer.keepManualCallExamples = keepExamples
            let read = try JSONLines.lines(of: file.url, from: start) { line, offset in
                guard let entry = JSONLines.decode(line) else { return }
                let facts = reader.facts(from: entry, offset: offset)
                writer.context.sessionKey = reader.sessionKey
                for fact in facts { try writer.write(fact) }
            }
            if let session = reader.sessionFact { try writer.write(session) }
            try database.run("""
                UPDATE sources SET inode = ?, size = ?, offset = ?, tail_hash = COALESCE(?, tail_hash), parser_version = ?,
                  state = 'active', imported_at = ?, session_key = ? WHERE id = ?
                """, file.inode, file.size, read.offset, read.tailHash, parser, now.timeIntervalSince1970,
                reader.sessionKey, sourceID)
            return read.offset - start
        }
    }
}

/// The parser for one file's harness.
struct FactReader {
    private enum Parser {
        case claude(ClaudeFacts)
        case pi(PiFacts)
    }

    private var parser: Parser

    init(file: URL, harness: String, sessionKey: String?, cwd: String?, env: HarnessEnvironment) {
        parser = harness == "pi" ? .pi(PiFacts(file: file, sessionKey: sessionKey, cwd: cwd, env: env)) : .claude(ClaudeFacts(file: file))
    }

    var sessionKey: String {
        switch parser {
        case .claude(let claude): claude.sessionKey
        case .pi(let pi): pi.sessionKey
        }
    }

    var sessionFact: Fact? {
        switch parser {
        case .claude(let claude): claude.sessionFact
        case .pi(let pi): pi.sessionFact
        }
    }

    mutating func facts(from entry: JSONLines.Object, offset: UInt64) -> [Fact] {
        switch parser {
        case .claude(var claude):
            defer { parser = .claude(claude) }
            return claude.facts(from: entry)
        case .pi(var pi):
            defer { parser = .pi(pi) }
            return pi.facts(from: entry, offset: offset)
        }
    }
}

/// Writes facts with the upsert rule (see SessionImporter).
struct FactWriter {
    let database: IndexDatabase
    var context: FactContext
    /// Off unless the user opted in; then examples are stored masked.
    var keepManualCallExamples = false
    /// Event keys of the calls read in this run, by the harness's call id.
    private var callKeys: [String: String] = [:]

    init(database: IndexDatabase, context: FactContext) {
        self.database = database
        self.context = context
    }

    mutating func write(_ fact: Fact) throws {
        let c = context
        switch fact {
        case .session(let session):
            try database.run(Self.sessionSQL, c.sessionKey, c.harness, session.nativeID, session.cwd, session.gitBranch,
                             session.harnessVersion, session.started?.timeIntervalSince1970,
                             session.lastActivity?.timeIntervalSince1970, c.sourceID, c.parserVersion)
        case .request(let request):
            let t = request.tokens
            try database.run(Self.requestSQL, c.harness, request.key, c.sessionKey, request.ts?.timeIntervalSince1970,
                             request.isSubagent, request.model, t.input, t.output, t.cacheRead, t.cacheWrite, t.reasoning,
                             request.cost, String?.none, c.sourceID, c.parserVersion)
        case .toolCall(let call):
            var extra: [String: String] = [:]
            if let hash = call.pathHash { extra["path_hash"] = hash }
            if call.callID != call.key {
                extra["call_id"] = call.callID
                callKeys[call.callID] = call.key
            }
            try database.run(Self.toolCallSQL, c.harness, call.key, c.sessionKey, call.ts?.timeIntervalSince1970,
                             call.isSubagent, call.name, call.inputBytes, Self.json(extra), c.sourceID, c.parserVersion)
        case .toolResult(let callID, let bytes, let isError):
            // Claude keys a call by its own id. Pi keys it by entry: a call read in an earlier run is looked up.
            var key = callKeys[callID]
            if key == nil, c.harness != "claude" {
                key = try database.value("""
                    SELECT event_key FROM tool_calls WHERE source_id = ? AND json_extract(extra, '$.call_id') = ?
                    """, c.sourceID, callID)?.text
            }
            // The call's own file may re-read it; a copy elsewhere only fills a missing size.
            try database.run("""
                UPDATE tool_calls SET output_bytes = ?, is_error = ?
                WHERE harness = ? AND event_key = ? AND (output_bytes IS NULL OR source_id = ?)
                """, bytes, isError, c.harness, key ?? callID, c.sourceID)
        case .skillListing(let listing):
            for skill in listing.skills {
                try database.run(Self.listingSQL, c.harness, listing.key, skill.name, c.sessionKey,
                                 listing.ts?.timeIntervalSince1970, listing.isSubagent, listing.isInitial, skill.descHash,
                                 skill.descChars, c.sourceID, c.parserVersion)
            }
        case .skillCall(let call), .command(let call):
            try database.run(Self.skillCallSQL, c.harness, call.key, c.sessionKey, call.ts?.timeIntervalSince1970,
                             call.isSubagent, call.skill, call.by.rawValue, call.hasArgs, String?.none, c.sourceID,
                             c.parserVersion)
        case .manualCallExample(let example):
            guard keepManualCallExamples else { return }
            let args = SecretFilter.masked(example.args)
            try database.run(Self.exampleSQL, c.harness, example.key, example.skill, example.ts?.timeIntervalSince1970,
                             args.isEmpty ? nil : args, example.request.map(SecretFilter.masked), c.sourceID)
        }
    }

    private static func json(_ fields: [String: String]) -> String? {
        guard !fields.isEmpty, let data = try? JSONSerialization.data(withJSONObject: fields, options: .sortedKeys) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: - SQL

    /// `INSERT … ON CONFLICT DO UPDATE` with the upsert rule. Columns in the order
    /// `key + identity + values + source_id, parser_version`.
    static func upsert(_ table: String, key: [String], identity: [String], values: [String]) -> String {
        let columns = key + identity + values + ["source_id", "parser_version"]
        let newer = """
            (excluded.parser_version > \(table).parser_version OR (excluded.parser_version = \(table).parser_version \
            AND excluded.source_id = \(table).source_id))
            """
        let moves = """
            EXISTS(SELECT 1 FROM sources old, sources new WHERE old.id = \(table).source_id AND new.id = excluded.source_id \
            AND new.path = old.path AND new.generation > old.generation)
            """
        let sets = values.map { "\($0) = CASE WHEN \(newer) THEN excluded.\($0) ELSE \(table).\($0) END" }
            + ["source_id = CASE WHEN \(moves) THEN excluded.source_id ELSE \(table).source_id END",
               "parser_version = MAX(\(table).parser_version, excluded.parser_version)"]
        return """
            INSERT INTO \(table)(\(columns.joined(separator: ", "))) VALUES(\(columns.map { _ in "?" }.joined(separator: ", ")))
            ON CONFLICT(\(key.joined(separator: ", "))) DO UPDATE SET \(sets.joined(separator: ", "))
            """
    }

    static let requestSQL = upsert("requests", key: ["harness", "event_key"], identity: ["session_key", "ts", "is_subagent"],
                                   values: ["model", "input", "output", "cache_read", "cache_write", "reasoning", "cost", "extra"])
    /// Output size and error come from the result line, not from the call.
    static let toolCallSQL = upsert("tool_calls", key: ["harness", "event_key"], identity: ["session_key", "ts", "is_subagent"],
                                    values: ["name", "input_bytes", "extra"])
    static let listingSQL = upsert("skill_listings", key: ["harness", "listing_key", "skill"],
                                   identity: ["session_key", "ts", "is_subagent"], values: ["is_initial", "desc_hash", "desc_chars"])
    static let skillCallSQL = upsert("skill_calls", key: ["harness", "event_key"], identity: ["session_key", "ts", "is_subagent"],
                                     values: ["skill", "by", "has_args", "extra"])

    /// An example is written once; copies of its line (resumed sessions, forks) keep the first.
    static let exampleSQL = """
        INSERT INTO manual_call_examples(harness, event_key, skill, ts, args_masked, request_masked, source_id)
        VALUES(?, ?, ?, ?, ?, ?, ?) ON CONFLICT(harness, event_key) DO NOTHING
        """

    /// A session row grows with its file: `started`/`last_activity` only widen and empty
    /// fields fill in; a newer parser replaces the fields it has.
    static let sessionSQL: String = {
        let newer = "excluded.parser_version > sessions.parser_version"
        let moves = """
            EXISTS(SELECT 1 FROM sources old, sources new WHERE old.id = sessions.source_id AND new.id = excluded.source_id \
            AND new.path = old.path AND new.generation > old.generation)
            """
        let fields = ["cwd", "git_branch", "harness_version"].map {
            "\($0) = CASE WHEN \(newer) THEN COALESCE(excluded.\($0), sessions.\($0)) ELSE COALESCE(sessions.\($0), excluded.\($0)) END"
        }
        return """
            INSERT INTO sessions(key, harness, native_id, cwd, git_branch, harness_version, started, last_activity, source_id, parser_version)
            VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(key) DO UPDATE SET \(fields.joined(separator: ", ")),
              started = MIN(COALESCE(sessions.started, excluded.started), COALESCE(excluded.started, sessions.started)),
              last_activity = MAX(COALESCE(sessions.last_activity, excluded.last_activity), COALESCE(excluded.last_activity, sessions.last_activity)),
              source_id = CASE WHEN \(moves) THEN excluded.source_id ELSE sessions.source_id END,
              parser_version = MAX(sessions.parser_version, excluded.parser_version)
            """
    }()
}
