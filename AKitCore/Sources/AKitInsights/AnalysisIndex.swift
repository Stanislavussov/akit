import AKitFoundation
import Foundation

/// One session of the index, as error analysis samples it.
public struct IndexedSession: Sendable, Hashable {
    /// The index's key: `claude:<id>` or `pi:<id>`.
    public let key: String
    /// `claude` or `pi`, as in the index.
    public let harness: String
    public let nativeID: String
    /// The session's log file, while the index knows it.
    public let file: String?
    public let cwd: String?
    public let started: Date?
    public let lastActivity: Date?
    /// API requests of the main conversation (subagents left out): the session's length.
    public let requests: Int
    /// The model that answered most requests.
    public let model: String?
    /// The project the session is bound to, when one is.
    public let projectID: String?
    /// The harness version that wrote the session (its system prompt changes with it).
    public var harnessVersion: String?

    public init(key: String, harness: String, nativeID: String, file: String?, cwd: String?, started: Date?, lastActivity: Date?,
                requests: Int, model: String?, projectID: String?) {
        self.key = key
        self.harness = harness
        self.nativeID = nativeID
        self.file = file
        self.cwd = cwd
        self.started = started
        self.lastActivity = lastActivity
        self.requests = requests
        self.model = model
        self.projectID = projectID
    }
}

/// Signals computed by code from a session's transcript, with no model call: what the batch
/// sample is stratified by (`docs/design/error-analysis.md`, "Sampling").
/// `interrupts`, `rejected`, `toolErrors` and `repeatedCalls` are `FailureSignals`, the rules
/// Lab uses too (`docs/design/definitions.md`, "Failure signals").
public struct SessionSignals: Codable, Sendable, Hashable {
    /// User messages that start with `[Request interrupted by user`.
    public var interrupts: Int
    /// User turns that push back: "no", "not that", "I asked for", a revert.
    public var pushbacks: Int
    /// Tool calls that the user, a permission rule, a hook, the auto mode classifier or a Pi extension refused.
    public var rejected: Int
    /// Failed tool calls, without rejected and interrupted ones.
    public var toolErrors: Int
    /// Runs of 3 or more calls of the same tool with the same input in a row, each run once.
    public var repeatedCalls: Int
    /// "Done" with no test run or check after the last edit.
    public var unverifiedDone: Bool
    public var userTurns: Int
    /// Transcript items: the session's length in steps.
    public var steps: Int

    public init(interrupts: Int = 0, pushbacks: Int = 0, rejected: Int = 0, toolErrors: Int = 0, repeatedCalls: Int = 0,
                unverifiedDone: Bool = false, userTurns: Int = 0, steps: Int = 0) {
        self.interrupts = interrupts
        self.pushbacks = pushbacks
        self.rejected = rejected
        self.toolErrors = toolErrors
        self.repeatedCalls = repeatedCalls
        self.unverifiedDone = unverifiedDone
        self.userTurns = userTurns
        self.steps = steps
    }

    /// Whether any signal says something went wrong.
    public var raised: Bool { interrupts > 0 || pushbacks > 0 || rejected > 0 || toolErrors > 0 || repeatedCalls > 0 || unverifiedDone }
}

/// The signals of one session and the file state they were computed from.
public struct StoredSignals: Sendable, Hashable {
    public let signals: SessionSignals
    public let fileSize: Int
    public let fileModified: Double
    /// The code version that computed them: a newer one recomputes.
    public let version: Int

    public init(signals: SessionSignals, fileSize: Int, fileModified: Double, version: Int) {
        self.signals = signals
        self.fileSize = fileSize
        self.fileModified = fileModified
        self.version = version
    }
}

/// The index's questions and writes for error analysis. Local paths stay on this Mac.
public enum AnalysisIndex {
    /// Main sessions with their log files, request counts, main model and project.
    public static func sessions(_ database: IndexDatabase) throws -> [IndexedSession] {
        let rows = try database.rows("""
            SELECT s.key, s.harness, s.native_id, src.path, s.cwd, s.started, s.last_activity,
              (SELECT COUNT(*) FROM requests r WHERE r.session_key = s.key AND r.is_subagent = 0),
              (SELECT r.model FROM requests r WHERE r.session_key = s.key AND r.is_subagent = 0 AND r.model IS NOT NULL
                 GROUP BY r.model ORDER BY COUNT(*) DESC LIMIT 1),
              b.project_id, s.harness_version
            FROM sessions s LEFT JOIN sources src ON src.id = s.source_id LEFT JOIN bindings b ON b.session_key = s.key
            ORDER BY s.started
            """)
        return rows.compactMap { row in
            guard let key = row[0].text, let harness = row[1].text, let native = row[2].text else { return nil }
            var session = IndexedSession(key: key, harness: harness, nativeID: native, file: row[3].text, cwd: row[4].text,
                                         started: row[5].double.map(Date.init(timeIntervalSince1970:)),
                                         lastActivity: row[6].double.map(Date.init(timeIntervalSince1970:)),
                                         requests: row[7].int ?? 0, model: row[8].text, projectID: row[9].text)
            session.harnessVersion = row[10].text
            return session
        }
    }

    public static func signals(_ database: IndexDatabase) throws -> [String: StoredSignals] {
        var result: [String: StoredSignals] = [:]
        for row in try database.rows("""
            SELECT session_key, file_size, file_mtime, version, interrupts, pushbacks, tool_errors, repeated_calls,
              unverified_done, user_turns, steps, rejected FROM signals
            """) {
            guard let key = row[0].text else { continue }
            let signals = SessionSignals(interrupts: row[4].int ?? 0, pushbacks: row[5].int ?? 0, rejected: row[11].int ?? 0,
                                         toolErrors: row[6].int ?? 0,
                                         repeatedCalls: row[7].int ?? 0, unverifiedDone: (row[8].int ?? 0) != 0,
                                         userTurns: row[9].int ?? 0, steps: row[10].int ?? 0)
            result[key] = StoredSignals(signals: signals, fileSize: row[1].int ?? 0, fileModified: row[2].double ?? 0,
                                        version: row[3].int ?? 0)
        }
        return result
    }

    public static func store(_ signals: [String: StoredSignals], in database: IndexDatabase) throws {
        try database.transaction {
            for (key, stored) in signals {
                let s = stored.signals
                try database.run("""
                    INSERT INTO signals(session_key, file_size, file_mtime, version, interrupts, pushbacks, tool_errors,
                      repeated_calls, unverified_done, user_turns, steps, rejected) VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(session_key) DO UPDATE SET file_size = excluded.file_size, file_mtime = excluded.file_mtime,
                      version = excluded.version, interrupts = excluded.interrupts, pushbacks = excluded.pushbacks,
                      tool_errors = excluded.tool_errors, repeated_calls = excluded.repeated_calls,
                      unverified_done = excluded.unverified_done, user_turns = excluded.user_turns, steps = excluded.steps,
                      rejected = excluded.rejected
                    """, key, stored.fileSize, stored.fileModified, stored.version, s.interrupts, s.pushbacks, s.toolErrors,
                                 s.repeatedCalls, s.unverifiedDone, s.userTurns, s.steps, s.rejected)
            }
        }
    }

    /// Forgets the signals of these sessions.
    public static func deleteSignals(_ keys: Set<String>, in database: IndexDatabase) throws {
        try database.transaction {
            for key in keys { _ = try database.run("DELETE FROM signals WHERE session_key = ?", key) }
        }
    }

    /// The index at its standard path; nil when there is none yet (none is created).
    public static func open(env: HarnessEnvironment) throws -> IndexDatabase? {
        let url = InsightsPaths(env: env).database
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try IndexSchema.open(url)
    }
}
