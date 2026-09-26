import Foundation

/// Tables of the session index. One script per version, each run in one transaction that
/// also sets `PRAGMA user_version`. A shipped script is never edited: changes are new scripts.
enum IndexSchema {
    /// How `event_key` / `listing_key` are derived. Changing the derivation needs a migration
    /// that rewrites the keys of every row (including rows of files that are gone) and bumps
    /// `meta.keyVersion`; the importer refuses to run when the two differ.
    static let keyVersion = 1

    /// Fact tables: every row carries `source_id` (a `sources` row, which is never deleted).
    static let factTables = ["sessions", "requests", "tool_calls", "skill_listings", "skill_calls", "manual_call_examples"]

    static let migrations: [String] = [
        // v1: facts of Claude Code and Pi sessions. No FOREIGN KEY from facts to sources, so
        // nothing can cascade-delete facts that outlive their log files.
        """
        CREATE TABLE meta(key TEXT PRIMARY KEY, value TEXT NOT NULL);
        INSERT INTO meta(key, value) VALUES('keyVersion', '1');
        CREATE TABLE sources(id INTEGER PRIMARY KEY, path TEXT NOT NULL, generation INTEGER NOT NULL,
          harness TEXT NOT NULL, kind TEXT NOT NULL,
          session_key TEXT, inode INTEGER, size INTEGER, offset INTEGER NOT NULL DEFAULT 0,
          tail_hash TEXT, parser_version INTEGER NOT NULL,
          unknown_lines INTEGER NOT NULL DEFAULT 0,
          state TEXT NOT NULL,
          imported_at REAL, UNIQUE(path, generation));
        CREATE TABLE sessions(key TEXT PRIMARY KEY,
          harness TEXT NOT NULL, native_id TEXT NOT NULL, cwd TEXT, git_branch TEXT, harness_version TEXT,
          started REAL, last_activity REAL, source_id INTEGER NOT NULL, parser_version INTEGER NOT NULL, extra TEXT);
        CREATE TABLE requests(harness TEXT, event_key TEXT, session_key TEXT NOT NULL, ts REAL, model TEXT,
          input INTEGER, output INTEGER, cache_read INTEGER, cache_write INTEGER, reasoning INTEGER, cost REAL,
          is_subagent INTEGER NOT NULL, source_id INTEGER NOT NULL, parser_version INTEGER NOT NULL, extra TEXT,
          PRIMARY KEY(harness, event_key));
        CREATE TABLE tool_calls(harness TEXT, event_key TEXT, session_key TEXT NOT NULL, ts REAL, name TEXT,
          input_bytes INTEGER, output_bytes INTEGER, is_error INTEGER, is_subagent INTEGER NOT NULL,
          source_id INTEGER NOT NULL, parser_version INTEGER NOT NULL, extra TEXT, PRIMARY KEY(harness, event_key));
        CREATE TABLE skill_listings(harness TEXT, listing_key TEXT, skill TEXT, session_key TEXT NOT NULL,
          ts REAL, is_subagent INTEGER NOT NULL, is_initial INTEGER NOT NULL, desc_hash TEXT, desc_chars INTEGER,
          source_id INTEGER NOT NULL, parser_version INTEGER NOT NULL,
          PRIMARY KEY(harness, listing_key, skill));
        CREATE TABLE skill_calls(harness TEXT, event_key TEXT, session_key TEXT NOT NULL, ts REAL, skill TEXT,
          by TEXT NOT NULL CHECK(by IN ('model','user')), is_subagent INTEGER NOT NULL, has_args INTEGER,
          source_id INTEGER NOT NULL, parser_version INTEGER NOT NULL, extra TEXT, PRIMARY KEY(harness, event_key));
        CREATE TABLE manual_call_examples(harness TEXT, event_key TEXT, skill TEXT, ts REAL,
          args_masked TEXT, request_masked TEXT, source_id INTEGER NOT NULL, PRIMARY KEY(harness, event_key));
        CREATE INDEX requests_session ON requests(session_key, ts);
        CREATE INDEX calls_skill ON skill_calls(skill, by, ts);
        CREATE INDEX listings_skill ON skill_listings(skill, ts);
        CREATE INDEX listings_session ON skill_listings(session_key, skill);
        CREATE INDEX sessions_started ON sessions(started);
        CREATE INDEX sessions_source ON sessions(source_id);
        CREATE INDEX requests_source ON requests(source_id);
        CREATE INDEX tool_calls_source ON tool_calls(source_id);
        CREATE INDEX skill_listings_source ON skill_listings(source_id);
        CREATE INDEX skill_calls_source ON skill_calls(source_id);
        CREATE INDEX manual_call_examples_source ON manual_call_examples(source_id);
        """,
    ]

    /// Brings the database to the latest version. Refuses an index written by a newer akit.
    static func migrate(_ database: IndexDatabase) throws {
        let current = try database.userVersion
        if current > migrations.count {
            throw IndexDatabase.Failure(message: "The index at \(database.url.path) has schema v\(current); this akit knows v\(migrations.count). Update akit.")
        }
        for (index, script) in migrations.enumerated() where index + 1 > current {
            let version = index + 1
            try database.transaction {
                // Another importer may have migrated since the check above.
                guard try database.userVersion < version else { return }
                try database.execute(script)
                try database.execute("PRAGMA user_version = \(version)")
            }
        }
    }

    /// Opens the index and migrates it.
    static func open(_ url: URL) throws -> IndexDatabase {
        let database = try IndexDatabase(url: url)
        try migrate(database)
        return database
    }
}
