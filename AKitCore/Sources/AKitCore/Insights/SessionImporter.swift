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
    /// Files left for the next run because the time budget ran out (one of them maybe half read).
    var pending = 0
    /// Session bindings added or changed, and sessions left for the next run (see ProjectBinder).
    var bindings = 0
    var bindingsPending = 0
    var ms = 0
}

/// Reads new lines of Claude Code and Pi session logs into the index, oldest file first: by
/// the start in a Pi file's name, else the file's birth time (a parent is born before its
/// fork or resumed copy, while it may be written to after them), then modification time.
/// Per file (one transaction each):
/// - appended bytes (same inode, not shorter, the line before the stored offset unchanged):
///   read from the offset;
/// - parser bump on an intact file: delete that source's facts, read from 0;
/// - replaced, shrunk or rewritten: the old generation stays as a tombstone with its facts,
///   a new generation reads from 0 and natural keys drop lines seen before;
/// - vanished: `gone`, facts kept forever.
/// Spool day files are read the same way; lines of a kind this akit doesn't know are counted
/// in `sources.unknown_lines`, and a file is deleted (its row kept as `done`) only when fully
/// read, two days old and without such lines.
/// Facts are upserted: a row's identity never changes, it moves only to a newer generation of
/// the same file, and its values change only for a newer parser (or its own file, or a newer
/// generation of it, re-reading them).
struct SessionImporter {
    let env: HarnessEnvironment
    var claudeParser = ClaudeFacts.parserVersion
    var piParser = PiFacts.parserVersion
    var spoolParser = SpoolFacts.parserVersion
    /// Spool line kinds this importer understands.
    var spoolKinds = Spool.kinds

    /// A log file found on disk.
    struct LogFile {
        let url: URL
        let harness: String
        let kind: String
        let inode: Int64
        let size: UInt64
        let modified: Date
        /// When the file was started: the time in a Pi file's name, else its birth time.
        let created: Date
    }

    static func `import`(env: HarnessEnvironment, database: IndexDatabase, now: Date = Date(),
                         budget: TimeInterval? = nil) throws -> ImportReport {
        try SessionImporter(env: env).run(database: database, now: now, budget: budget)
    }

    /// An import, then project bindings for the sessions in the index (see ProjectBinder).
    /// `budget` covers both: binding gets what the import left (and at most its own git budget).
    static func importAndBind(env: HarnessEnvironment, projectsRoot: URL, database: IndexDatabase, now: Date = Date(),
                              budget: TimeInterval? = nil, runner: CommandRunner? = nil) async throws -> ImportReport {
        let clock = Date()
        var report = try SessionImporter(env: env).run(database: database, now: now, budget: budget)
        let binding = try await ProjectBinder(env: env, projectsRoot: projectsRoot, run: runner)
            .bind(database: database, now: now, deadline: budget.map { clock.addingTimeInterval($0) })
        report.bindings = binding.changed
        report.bindingsPending = binding.pending
        report.ms = Int(Date().timeIntervalSince(clock) * 1000)
        return report
    }

    /// `budget`: stop at a line boundary once it is spent (the offset read so far is kept, the
    /// next run goes on from there). It is checked only once this run has read something, so
    /// every run reads at least one line when there is one. nil reads everything.
    func run(database: IndexDatabase, now: Date = Date(), budget: TimeInterval? = nil) throws -> ImportReport {
        let clock = Date()
        let deadline = budget.map { clock.addingTimeInterval($0) }
        try Self.checkKeyVersion(database)
        let before = try Self.counts(database)
        var report = ImportReport()
        let keepExamples = Self.keepsManualCallExamples(home: env.homeDirectory)
        // Turning the setting off (or a Mac becoming a work Mac) drops what was kept.
        if !keepExamples { try database.run("DELETE FROM manual_call_examples") }
        let files = discover().sorted { ($0.created, $0.modified, $0.url.path) < ($1.created, $1.modified, $1.url.path) }
        for (index, file) in files.enumerated() {
            if let deadline, report.newBytes > 0, Date() >= deadline {
                report.pending = files.count - index
                break
            }
            var stopped = false
            do {
                // Decoded JSON objects are autoreleased; drain them per file, or a long run holds them all.
                if let read = try autoreleasepool(invoking: {
                    try importFile(file, database: database, now: now, keepExamples: keepExamples, until: deadline)
                }) {
                    // A line still being written reads nothing: not a file read.
                    if read.bytes > 0 { report.sources += 1 }
                    report.newBytes += read.bytes
                    report.spoolLines += read.spoolLines
                    stopped = read.stopped
                }
                if !stopped, file.kind == "spool" { try retireSpool(file, database: database, now: now) }
            } catch {
                report.skipped.append(.init(path: file.url.path, reason: error.localizedDescription))
            }
            if stopped {
                report.pending = files.count - index
                break
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
        let stored = try database.meta("keyVersion")
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
        guard !machine.isWork, machine.problem == nil else { return false }
        return InsightsPaths(home: home).readSettings()["keepManualCallExamples"] as? Bool == true
    }

    private static func counts(_ database: IndexDatabase) throws -> [Int] {
        try ["sessions", "requests", "tool_calls", "skill_calls"].map {
            try database.value("SELECT COUNT(*) FROM \($0)")?.int ?? 0
        }
    }

    // MARK: - Files

    /// Claude `projects/*/*.jsonl` and `projects/*/<session>/subagents/*.jsonl`; Pi `<sessions>/*/*.jsonl`;
    /// spool day files.
    func discover() -> [LogFile] {
        var found: [LogFile] = []
        let projects = HarnessCatalog.configRoot(of: .claudeCode, in: env)!.appending(path: "projects")
        for folder in FileWalk.children(of: projects) where FileWalk.isDirectory(folder) {
            for item in FileWalk.children(of: folder) {
                if item.pathExtension == "jsonl" {
                    found += Self.logFile(item, harness: "claude", kind: "session").map { [$0] } ?? []
                } else if FileWalk.isDirectory(item) {
                    for agent in FileWalk.children(of: item.appending(path: "subagents")) where agent.pathExtension == "jsonl" {
                        found += Self.logFile(agent, harness: "claude", kind: "subagent").map { [$0] } ?? []
                    }
                }
            }
        }
        let pi = PiLogFormat.folder(configRoot: HarnessCatalog.configRoot(of: .pi, in: env)!, in: env)
        for folder in FileWalk.children(of: pi) where FileWalk.isDirectory(folder) {
            for item in FileWalk.children(of: folder) where item.pathExtension == "jsonl" {
                found += Self.logFile(item, harness: "pi", kind: "session").map { [$0] } ?? []
            }
        }
        for item in FileWalk.children(of: InsightsPaths(env: env).spool) where item.pathExtension == "jsonl" {
            found += Self.logFile(item, harness: "akit", kind: "spool").map { [$0] } ?? []
        }
        return found
    }

    static func logFile(_ url: URL, harness: String, kind: String) -> LogFile? {
        var info = stat()
        guard stat(url.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { return nil }
        func date(_ time: timespec) -> Date { Date(timeIntervalSince1970: Double(time.tv_sec) + Double(time.tv_nsec) / 1e9) }
        let born = date(info.st_birthtimespec)
        return LogFile(url: url, harness: harness, kind: kind, inode: Int64(bitPattern: UInt64(info.st_ino)),
                       size: UInt64(info.st_size), modified: date(info.st_mtimespec),
                       created: harness == "pi" ? piStart(ofFile: url.lastPathComponent) ?? born : born)
    }

    /// Pi names a session file after its start: `2026-09-20T10-00-00-000Z_<id>.jsonl`. Unlike the
    /// birth time it survives copies (a restored backup, a new Mac).
    static func piStart(ofFile name: String) -> Date? {
        guard let stamp = name.split(separator: "_").first, stamp.count == 24 else { return nil }
        var iso = Array(stamp)
        iso[13] = ":"
        iso[16] = ":"
        iso[19] = "."
        return JSONLines.date(String(iso))
    }

    /// The bounded tail hash of the line before `offset` when it is still `stored`, nil when the
    /// file was rewritten. Hashes stored before the bound covered the whole line; for a line
    /// longer than the bound that hash is accepted too (once: the bounded one is stored next).
    static func tailHash(of url: URL, endingAt offset: UInt64, matching stored: String?) -> String? {
        guard let stored, let tail = JSONLines.tailHash(of: url, endingAt: offset) else { return nil }
        if tail.hash == stored { return tail.hash }
        return !tail.whole && JSONLines.wholeLineHash(of: url, endingAt: offset) == stored ? tail.hash : nil
    }

    /// Active sources whose file is gone keep their facts; the row says so.
    private func markGone(_ database: IndexDatabase, found: Set<String>) throws {
        for row in try database.rows("SELECT id, path FROM sources WHERE state = 'active'") {
            guard let path = row[1].text, !found.contains(path), !FileManager.default.fileExists(atPath: path) else { continue }
            try database.run("UPDATE sources SET state = 'gone' WHERE id = ?", row[0])
        }
    }

    private func parserVersion(_ file: LogFile) -> Int {
        file.kind == "spool" ? spoolParser : file.harness == "pi" ? piParser : claudeParser
    }

    /// Reads what's new in one file. Returns the bytes (and spool lines) read and whether the
    /// deadline stopped the read; nil when nothing changed.
    private func importFile(_ file: LogFile, database: IndexDatabase, now: Date, keepExamples: Bool,
                            until deadline: Date?) throws -> (bytes: UInt64, spoolLines: Int, stopped: Bool)? {
        let parser = parserVersion(file)
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
            let tail = sameInode && file.size >= offset && offset > 0
                ? Self.tailHash(of: file.url, endingAt: offset, matching: row[4].text) : nil
            if sameInode, file.size >= offset, offset == 0 || tail != nil {
                newGeneration = false
                if storedParser < parser {
                    reparse = true
                } else if file.size == offset {
                    try database.run("UPDATE sources SET imported_at = ?, tail_hash = COALESCE(?, tail_hash) WHERE id = ?",
                                     now.timeIntervalSince1970, tail, row[0])
                    return nil
                } else {
                    start = offset
                }
            }
        }

        // A parser bump deleted the file's facts first: its re-read is never cut short, so the
        // facts are whole again in the same transaction.
        let deadline = reparse ? nil : deadline
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

            if file.kind == "spool" {
                return try importSpool(file, from: start, sourceID: sourceID, parser: parser, database: database, now: now,
                                       until: deadline)
            }
            // A read from an offset has no header: the session and its cwd come from the earlier run.
            let cwd = start > 0 ? try sessionKey.flatMap { try database.value("SELECT cwd FROM sessions WHERE key = ?", $0)?.text } : nil
            var reader = FactReader(file: file.url, harness: file.harness, sessionKey: sessionKey, cwd: cwd, env: env)
            var writer = FactWriter(database: database, context: FactContext(
                harness: file.harness, sessionKey: reader.sessionKey, sourceID: sourceID,
                isSubagent: file.kind == "subagent", parserVersion: parser))
            writer.keepManualCallExamples = keepExamples
            let read = try JSONLines.lines(of: file.url, from: start, until: deadline) { line, offset in
                guard let entry = JSONLines.decode(line) else { return }
                let facts = reader.facts(from: entry, offset: offset)
                writer.context.sessionKey = reader.sessionKey
                for fact in facts { try writer.write(fact) }
            }
            if let session = reader.sessionFact { try writer.write(session) }
            try database.run("""
                UPDATE sources SET inode = ?, size = ?, offset = ?, tail_hash = COALESCE(?, tail_hash), parser_version = ?,
                  state = 'active', imported_at = ?, session_key = ? WHERE id = ?
                """, file.inode, max(file.size, read.offset), read.offset, read.tailHash, parser, now.timeIntervalSince1970,
                reader.sessionKey, sourceID)
            return (read.offset - start, 0, read.stopped)
        }
    }

    /// Spool lines from `start` into `hook_events` / `applies`, inside the caller's transaction.
    private func importSpool(_ file: LogFile, from start: UInt64, sourceID: Int64, parser: Int, database: IndexDatabase,
                             now: Date, until deadline: Date?) throws -> (bytes: UInt64, spoolLines: Int, stopped: Bool) {
        var lines = 0, unknown = 0
        let read = try JSONLines.lines(of: file.url, from: start, until: deadline) { line, _ in
            lines += 1
            guard let entry = JSONLines.decode(line) else { return }
            let outcome = try SpoolFacts.write(entry, kinds: spoolKinds, database: database, sourceID: sourceID, parserVersion: parser)
            if case .unknown = outcome { unknown += 1 }
        }
        // A read from 0 (new generation, parser bump) counts afresh.
        try database.run("""
            UPDATE sources SET inode = ?, size = ?, offset = ?, tail_hash = COALESCE(?, tail_hash), parser_version = ?,
              unknown_lines = CASE WHEN ? = 0 THEN ? ELSE unknown_lines + ? END, state = 'active', imported_at = ? WHERE id = ?
            """, file.inode, max(file.size, read.offset), read.offset, read.tailHash, parser, start, unknown, unknown,
            now.timeIntervalSince1970, sourceID)
        return (read.offset - start, lines, read.stopped)
    }

    /// Deletes a spool day file no hook can still write to (its UTC day is at least two days
    /// back) once every line of it is in the index and understood. The row stays as `done`.
    private func retireSpool(_ file: LogFile, database: IndexDatabase, now: Date) throws {
        guard let day = Spool.dayStart(ofFile: file.url.lastPathComponent),
              let today = Spool.dayStart(ofFile: Spool.fileName(for: now)),
              day <= today.addingTimeInterval(-2 * 86_400),
              let current = Self.logFile(file.url, harness: file.harness, kind: file.kind) else { return }
        guard let row = try database.rows("""
            SELECT id, inode, offset, unknown_lines, parser_version, state FROM sources WHERE path = ?
            ORDER BY generation DESC LIMIT 1
            """, file.url.path).first,
              row[5].text == "active", row[3].int == 0, (row[4].int ?? 0) >= spoolParser,
              row[1] == .int(current.inode), row[2].int.map(UInt64.init) == current.size else { return }
        try database.transaction {
            try database.run("UPDATE sources SET state = 'done' WHERE id = ?", row[0])
            guard unlink(file.url.path) == 0 || errno == ENOENT else {
                throw IndexDatabase.Failure(message: "Can't delete \(file.url.path): \(String(cString: strerror(errno)))")
            }
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
            // A user call says whether it was a skill or a built-in command like `/model`.
            var kind: String?
            if case .command = fact { kind = "command" } else if call.by == .user { kind = "skill" }
            try database.run(Self.skillCallSQL, c.harness, call.key, c.sessionKey, call.ts?.timeIntervalSince1970,
                             call.isSubagent, call.skill, call.by.rawValue, call.hasArgs, Self.json(kind.map { ["kind": $0] } ?? [:]),
                             c.sourceID, c.parserVersion)
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
    /// `key + identity + values + source_id, parser_version`. SET expressions all see the old
    /// row, so a row moving to a newer generation takes that line's values in the same statement.
    static func upsert(_ table: String, key: [String], identity: [String], values: [String]) -> String {
        let columns = key + identity + values + ["source_id", "parser_version"]
        let moves = """
            EXISTS(SELECT 1 FROM sources old, sources new WHERE old.id = \(table).source_id AND new.id = excluded.source_id \
            AND new.path = old.path AND new.generation > old.generation)
            """
        let newer = """
            (excluded.parser_version > \(table).parser_version OR (excluded.parser_version = \(table).parser_version \
            AND excluded.source_id = \(table).source_id) OR (excluded.parser_version >= \(table).parser_version AND \(moves)))
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
