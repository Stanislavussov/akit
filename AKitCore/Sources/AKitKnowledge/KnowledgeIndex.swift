import AKitFoundation
import Foundation

/// The search index of a base (K20, 3.2a): one SQLite file `<base>/.akit-index.sqlite`, git-ignored,
/// that can always be dropped and rebuilt from the files (K2). It holds `areas/` only: a proposal
/// in `inbox/` is never indexed, so `search` never returns it.
///
/// - `files(path, size, mtime, hash)`: what was read, to find changes;
/// - `notes`, `nodes` (notes and maps), `edges` (the arrows of every map, from `MapGraph`);
/// - `chunks` + `chunks_fts` (FTS5, BM25): one chunk per `##` section of a note, and one for the
///   text before the first `##` (the title chunk);
/// - `meta`: `schema` (the version that wrote it) and `compatible` (the oldest version that reads it).
///
/// Every read refreshes it first (mtime + size, then hash) under `.akit-index.lock`, never waiting:
/// when another process holds the lock, the read uses the current snapshot and says `stale`.
public struct KnowledgeIndex {
    public struct Failure: Error, LocalizedError, Equatable {
        public let message: String
        public var errorDescription: String? { message }
        public init(message: String) { self.message = message }
    }

    /// The version of the tables this akit writes. An older index is rebuilt; a newer one is never
    /// written (no ping-pong between an older CLI and a newer app), only read when its
    /// `compatible` is at most this.
    public static let schema = 1
    public static let fileName = ".akit-index.sqlite"
    public static let lockName = ".akit-index.lock"
    /// Searches that found nothing good: time, result count, top score, query. Local and
    /// git-ignored; the query text is kept only here.
    public static let missesName = ".akit-misses.log"
    /// A search whose best BM25 score is at or above this (or with no result) is a miss (7.0).
    public static let missScore = -1.0

    public let base: KnowledgeBase

    public init(base: KnowledgeBase) { self.base = base }

    public var file: URL { base.root.appending(path: Self.fileName) }
    var lockFile: URL { base.root.appending(path: Self.lockName) }
    var missesFile: URL { base.root.appending(path: Self.missesName) }

    // MARK: - Answers (the JSON of `akit kb search / show / index`)

    public struct Status: Encodable, Equatable, Sendable {
        public let notes: Int
        public let maps: Int
        public let chunks: Int
        /// Built from nothing: a first build, an older schema, or `--rebuild`.
        public let rebuilt: Bool
        /// Another process holds the index lock, or the index is newer than this akit: not refreshed.
        public let stale: Bool
        public var tokens = 0
    }

    public struct Hit: Encodable, Equatable, Sendable {
        /// The note id (`payments/orders-api`).
        public let note: String
        /// The section's heading; nil for the text before the first `##`.
        public let heading: String?
        /// BM25: lower is better, below `missScore` is a good match.
        public let score: Double
        public let snippet: String
        /// The notes one arrow away on any map.
        public let neighbors: [String]

        private enum CodingKeys: String, CodingKey { case note, heading, score, snippet, neighbors }

        public func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(note, forKey: .note)
            try container.encode(heading, forKey: .heading) // null for the title chunk
            try container.encode(score, forKey: .score)
            try container.encode(snippet, forKey: .snippet)
            try container.encode(neighbors, forKey: .neighbors)
        }
    }

    public struct SearchAnswer: Encodable, Equatable, Sendable {
        public var results: [Hit]
        public let stale: Bool
        public var tokens = 0
    }

    public struct Section: Encodable, Equatable, Sendable {
        /// nil for the text before the first `##`.
        public let heading: String?
        public var text: String

        private enum CodingKeys: String, CodingKey { case heading, text }

        public func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(heading, forKey: .heading)
            try container.encode(text, forKey: .text)
        }
    }

    public struct Frontmatter: Encodable, Equatable, Sendable {
        public let kind: String?
        public let repo: String?
        public let files: [String]

        private enum CodingKeys: String, CodingKey { case kind, repo, files }

        public func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(kind, forKey: .kind)
            try container.encode(repo, forKey: .repo)
            try container.encode(files, forKey: .files)
        }
    }

    public struct ShowAnswer: Encodable, Equatable, Sendable {
        public let note: String
        public let title: String
        public let frontmatter: Frontmatter
        public var sections: [Section]
        /// Sections were cut or left out to stay under `--max-tokens`.
        public var truncated: Bool
        /// Always false: `show` reads the note's file itself.
        public let stale: Bool
        public var tokens = 0
    }

    // MARK: - Reads

    /// Refreshes the index (or, with `rebuild`, builds it again from nothing) and counts it.
    public func refresh(rebuild: Bool = false) throws(Failure) -> Status {
        let opened = try prepare(rebuild: rebuild)
        var status = Status(notes: 0, maps: 0, chunks: 0, rebuilt: opened.rebuilt, stale: opened.stale)
        if let database = opened.database {
            do {
                status = Status(notes: try database.value("SELECT count(*) FROM notes")?.int ?? 0,
                                maps: try database.value("SELECT count(*) FROM nodes WHERE type = 'map'")?.int ?? 0,
                                chunks: try database.value("SELECT count(*) FROM chunks")?.int ?? 0,
                                rebuilt: opened.rebuilt, stale: opened.stale)
            } catch {
                throw failure(error)
            }
        }
        _ = Budget.measure(&status, field: \.tokens)
        return status
    }

    /// The best chunks for `query` (every word must be there, BM25 order), at most `limit`, then
    /// cut from the end to stay under `maxTokens`. A miss (no result, or a best score at or above
    /// `missScore`) adds a line to `.akit-misses.log`.
    public func search(_ query: String, area: String? = nil, limit: Int = 10,
                       maxTokens: Int = Budget.defaultTokens) throws(Failure) -> SearchAnswer {
        let area = area.map(KnowledgeBase.nfc)
        if let area, !base.areas().contains(where: { $0.name == area }) {
            throw Failure(message: "No area “\(area)” in \(base.root.path). Areas: \(base.areas().map(\.name).joined(separator: ", ")).")
        }
        let match = Self.ftsQuery(query)
        let opened = try prepare(rebuild: false)
        var hits: [Hit] = []
        if let database = opened.database, !match.isEmpty, limit > 0 {
            do {
                let rows = try database.rows("""
                    SELECT c.note, c.heading, bm25(chunks_fts), snippet(chunks_fts, -1, '', '', '…', 16)
                    FROM chunks_fts JOIN chunks c ON c.id = chunks_fts.rowid
                    WHERE chunks_fts MATCH ? AND (? IS NULL OR c.area = ?)
                    ORDER BY bm25(chunks_fts), c.note, c.ord LIMIT ?
                    """, match, area, area, limit)
                for row in rows {
                    let note = row[0].text ?? ""
                    let neighbors = try database.rows("""
                        SELECT to_note FROM edges WHERE from_note = ?1 AND to_note != ?1
                        UNION SELECT from_note FROM edges WHERE to_note = ?1 AND from_note != ?1 ORDER BY 1
                        """, note).compactMap { $0[0].text }
                    let score = ((row[2].double ?? 0) * 10_000).rounded() / 10_000
                    hits.append(Hit(note: note, heading: row[1].text, score: score,
                                    snippet: (row[3].text ?? "").split(whereSeparator: \.isNewline).joined(separator: " "),
                                    neighbors: neighbors))
                }
            } catch {
                throw failure(error)
            }
        }
        if !match.isEmpty, hits.first.map({ $0.score >= Self.missScore }) ?? true { logMiss(query, hits: hits) }
        var answer = SearchAnswer(results: hits, stale: opened.stale)
        while Budget.measure(&answer, field: \.tokens) > maxTokens, !answer.results.isEmpty { answer.results.removeLast() }
        return answer
    }

    /// A note's title, `kind` / `repo` / `files` and sections (one with `section`), read from its
    /// file. Sections are cut from the end to stay under `maxTokens`, then marked `truncated`.
    public func show(_ name: String, section: String? = nil, maxTokens: Int = Budget.defaultTokens) throws(Failure) -> ShowAnswer {
        let id: String
        do { id = try base.noteID(name) } catch { throw Failure(message: error.message) }
        guard let note = KnowledgeNote.load(base.noteFile(id)) else {
            throw Failure(message: "The note \(id) can't be read as UTF-8 text.")
        }
        var sections = Self.chunks(of: note).map { Section(heading: $0.heading, text: $0.text) }
            .filter { $0.heading != nil || !$0.text.isEmpty }
        if let section {
            let wanted = KnowledgeBase.nfc(section.trimmingCharacters(in: .whitespaces))
            sections = sections.filter { $0.heading.map(KnowledgeBase.nfc) == wanted }
            guard !sections.isEmpty else {
                let headings = note.sections.map(\.heading)
                throw Failure(message: "The note \(id) has no section “## \(section)”."
                    + (headings.isEmpty ? "" : " Sections: \(headings.joined(separator: ", "))."))
            }
        }
        var answer = ShowAnswer(note: id, title: note.title ?? id.split(separator: "/").last.map(String.init) ?? id,
                                frontmatter: Frontmatter(kind: note.kind, repo: note.repo, files: note.files),
                                sections: sections, truncated: false, stale: false)
        while true {
            let over = Budget.measure(&answer, field: \.tokens) - maxTokens
            guard over > 0, let last = answer.sections.last else { break }
            answer.truncated = true
            // Cut the last section's text by what is over (and a little, for the "…"), else drop it.
            let keep = last.text.utf8.count - over * 4 - 16
            if keep > 64 {
                var text = String(decoding: last.text.utf8.prefix(keep), as: UTF8.self)
                while text.last == "\u{FFFD}" { text.removeLast() }
                answer.sections[answer.sections.count - 1].text = text + "…"
            } else {
                answer.sections.removeLast()
            }
        }
        return answer
    }

    /// The FTS5 query of a search: each word quoted (an inner `"` doubled), so `-`, `:` or `*`
    /// are text, never syntax; words with no letter or digit are left out. Empty → "" (no result).
    public static func ftsQuery(_ text: String) -> String {
        KnowledgeBase.nfc(text).split(whereSeparator: \.isWhitespace)
            .filter { $0.unicodeScalars.contains(where: CharacterSet.alphanumerics.contains) }
            .map { "\"" + $0.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
            .joined(separator: " ")
    }

    /// A note's chunks: the text before the first `##` (its `# title` line left out; heading nil),
    /// then each `##` section, trimmed.
    static func chunks(of note: KnowledgeNote) -> [(heading: String?, text: String)] {
        let sections = note.sections
        let introEnd = sections.first?.headingRange.lowerBound ?? note.text.endIndex
        var intro = note.text[note.body.startIndex..<introEnd].components(separatedBy: "\n")
        if let title = intro.firstIndex(where: { $0.hasPrefix("# ") }) { intro.remove(at: title) }
        return [(nil, intro.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines))]
            + sections.map { ($0.heading, String(note.text[$0.bodyRange]).trimmingCharacters(in: .whitespacesAndNewlines)) }
    }

    // MARK: - Open, version, refresh

    private enum Version { case current, older, newer(compatible: Bool, schema: Int) }

    /// The version of the index file; `older` when it can't be read as one.
    private func version() -> Version {
        guard let database = try? SQLiteDatabase(url: file, readOnly: true),
              let schema = (try? database.meta("schema")).flatMap({ $0.flatMap(Int.init) }) else { return .older }
        if schema == Self.schema { return .current }
        if schema < Self.schema { return .older }
        let compatible = (try? database.meta("compatible")).flatMap { $0.flatMap(Int.init) } ?? schema
        return .newer(compatible: compatible <= Self.schema, schema: schema)
    }

    private func updateAkit(_ schema: Int) -> Failure {
        Failure(message: "The knowledge index \(file.path) was written by a newer akit (schema v\(schema)); this akit reads up to v\(Self.schema). Update akit.")
    }

    /// A connection to read from, whether it is stale, and whether it was built from nothing. Takes
    /// the index lock without waiting; busy → the current snapshot (nil when there is none), stale.
    private func prepare(rebuild: Bool) throws(Failure) -> (database: SQLiteDatabase?, stale: Bool, rebuilt: Bool) {
        let fm = FileManager.default
        // A base folder AKit can't write to is read as it is, like a busy lock.
        guard let lock = try? FileLock.acquire(lockFile) else { return (try snapshot(), true, false) }
        defer { lock.release() }
        var rebuilt = rebuild || !fm.fileExists(atPath: file.path)
        if fm.fileExists(atPath: file.path) {
            switch version() {
            case .current: break
            case .older: rebuilt = true
            case .newer(let compatible, let schema):
                // A newer index is never written, not even by --rebuild.
                guard compatible, !rebuild else { throw updateAkit(schema) }
                return (try? SQLiteDatabase(url: file, readOnly: true), true, false)
            }
        }
        do {
            return (try build(fresh: rebuilt), false, rebuilt)
        } catch where !rebuilt {
            // A broken file: build it again once.
            do { return (try build(fresh: true), false, true) } catch { throw failure(error) }
        } catch {
            throw failure(error)
        }
    }

    /// The index as it is now, for a read while another process refreshes it.
    private func snapshot() throws(Failure) -> SQLiteDatabase? {
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        switch version() {
        case .current: return try? SQLiteDatabase(url: file, readOnly: true)
        case .newer(true, _): return try? SQLiteDatabase(url: file, readOnly: true)
        case .newer(false, let schema): throw updateAkit(schema)
        case .older: return nil
        }
    }

    private func build(fresh: Bool) throws -> SQLiteDatabase {
        if fresh {
            for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: file.path + suffix) }
        }
        let database = try SQLiteDatabase(url: file, privateFolder: false)
        if fresh {
            try database.transaction {
                try database.execute(Self.tables)
                try database.setMeta("schema", String(Self.schema))
                try database.setMeta("compatible", String(Self.schema))
            }
        }
        try update(database)
        return database
    }

    static let tables = """
        CREATE TABLE meta(key TEXT PRIMARY KEY, value TEXT NOT NULL);
        CREATE TABLE files(path TEXT PRIMARY KEY, size INTEGER NOT NULL, mtime REAL NOT NULL, hash TEXT NOT NULL);
        CREATE TABLE notes(id TEXT PRIMARY KEY, path TEXT NOT NULL, area TEXT NOT NULL, title TEXT NOT NULL,
          kind TEXT, repo TEXT, files TEXT NOT NULL);
        CREATE TABLE chunks(id INTEGER PRIMARY KEY, note TEXT NOT NULL, area TEXT NOT NULL, ord INTEGER NOT NULL,
          heading TEXT, body TEXT NOT NULL);
        CREATE INDEX chunks_note ON chunks(note);
        CREATE VIRTUAL TABLE chunks_fts USING fts5(title, heading, body, tokenize='unicode61 remove_diacritics 2');
        CREATE TABLE nodes(type TEXT NOT NULL, id TEXT NOT NULL, area TEXT NOT NULL, title TEXT NOT NULL, PRIMARY KEY(type, id));
        CREATE TABLE edges(map TEXT NOT NULL, arrow TEXT NOT NULL, from_note TEXT NOT NULL, to_note TEXT NOT NULL,
          kind TEXT, flow TEXT, PRIMARY KEY(map, arrow));
        CREATE INDEX edges_from ON edges(from_note);
        CREATE INDEX edges_to ON edges(to_note);
        """

    /// Brings the rows up to the files: unchanged size and mtime → skipped; same hash → only the
    /// mtime; else the file's rows again. When a note or map appears or goes (an add, a delete, a
    /// rename), every link is resolved again and `edges` is rebuilt (M5); otherwise only the
    /// changed maps' edges change.
    private func update(_ database: SQLiteDatabase) throws {
        struct OnDisk { let url: URL; let id: String; let isMap: Bool; let size: Int; let mtime: Double }
        let areas = base.areasFolder
        var disk: [String: OnDisk] = [:]
        for url in KnowledgeBase.files(in: areas) {
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            let id = KnowledgeBase.id(of: url, areas: areas)
            let isMap = url.pathExtension == "excalidraw"
            disk["areas/" + id + (isMap ? ".excalidraw" : ".md")] = OnDisk(
                url: url, id: id, isMap: isMap, size: values?.fileSize ?? 0,
                mtime: values?.contentModificationDate?.timeIntervalSince1970 ?? 0)
        }
        var known: [String: (size: Int, mtime: Double, hash: String)] = [:]
        for row in try database.rows("SELECT path, size, mtime, hash FROM files") {
            known[row[0].text ?? ""] = (row[1].int ?? 0, row[2].double ?? 0, row[3].text ?? "")
        }
        var touched: [(path: String, file: OnDisk)] = []
        var changed: [(path: String, file: OnDisk, data: Data, hash: String)] = []
        for (path, file) in disk.sorted(by: { $0.key < $1.key }) {
            let old = known[path]
            if let old, old.size == file.size, old.mtime == file.mtime { continue }
            let data = (try? Data(contentsOf: file.url)) ?? Data()
            let hash = Checksum.sha256(data)
            if let old, old.hash == hash { touched.append((path, file)) } else { changed.append((path, file, data, hash)) }
        }
        let removed = known.keys.filter { disk[$0] == nil }.sorted()
        let pathsChanged = !removed.isEmpty || changed.contains { known[$0.path] == nil }
        guard !touched.isEmpty || !changed.isEmpty || !removed.isEmpty else { return }

        let targets = KnowledgeLinks(notes: disk.values.filter { !$0.isMap }.map(\.id), maps: disk.values.filter(\.isMap).map(\.id))
        try database.transaction {
            for (path, file) in touched {
                try database.run("UPDATE files SET size = ?, mtime = ? WHERE path = ?", file.size, file.mtime, path)
            }
            for path in removed {
                try database.run("DELETE FROM files WHERE path = ?", path)
                let isMap = path.hasSuffix(".excalidraw")
                let id = String(path.dropFirst("areas/".count).dropLast(isMap ? ".excalidraw".count : ".md".count))
                if isMap { try removeMap(id, database) } else { try removeNote(id, database) }
            }
            for (path, file, data, hash) in changed {
                try database.run("INSERT INTO files(path, size, mtime, hash) VALUES(?, ?, ?, ?) ON CONFLICT(path) DO UPDATE SET size = excluded.size, mtime = excluded.mtime, hash = excluded.hash",
                                 path, file.size, file.mtime, hash)
                if file.isMap {
                    try removeMap(file.id, database)
                    try database.run("INSERT INTO nodes(type, id, area, title) VALUES('map', ?, ?, ?)",
                                     file.id, Self.area(of: file.id), file.url.deletingPathExtension().lastPathComponent)
                    if !pathsChanged { try insertEdges(of: file.id, data: data, targets: targets, database) }
                } else {
                    try removeNote(file.id, database)
                    try insertNote(file.id, path: path, text: String(decoding: data, as: UTF8.self), database)
                }
            }
            if pathsChanged {
                try database.run("DELETE FROM edges")
                for file in disk.values.filter(\.isMap).sorted(by: { $0.id < $1.id }) {
                    try insertEdges(of: file.id, data: (try? Data(contentsOf: file.url)) ?? Data(), targets: targets, database)
                }
            }
        }
    }

    private func insertNote(_ id: String, path: String, text: String, _ database: SQLiteDatabase) throws {
        let note = KnowledgeNote(text: text)
        let title = note.title ?? id.split(separator: "/").last.map(String.init) ?? id
        let area = Self.area(of: id)
        let files = String(decoding: (try? JSONEncoder().encode(note.files)) ?? Data("[]".utf8), as: UTF8.self)
        try database.run("INSERT INTO notes(id, path, area, title, kind, repo, files) VALUES(?, ?, ?, ?, ?, ?, ?)",
                         id, path, area, title, note.kind, note.repo, files)
        try database.run("INSERT INTO nodes(type, id, area, title) VALUES('note', ?, ?, ?)", id, area, title)
        for (order, chunk) in Self.chunks(of: note).enumerated() {
            try database.run("INSERT INTO chunks(note, area, ord, heading, body) VALUES(?, ?, ?, ?, ?)", id, area, order, chunk.heading, chunk.text)
            try database.run("INSERT INTO chunks_fts(rowid, title, heading, body) VALUES(?, ?, ?, ?)",
                             database.lastInsertedRow, title, chunk.heading ?? "", chunk.text)
        }
    }

    private func removeNote(_ id: String, _ database: SQLiteDatabase) throws {
        try database.run("DELETE FROM chunks_fts WHERE rowid IN (SELECT id FROM chunks WHERE note = ?)", id)
        try database.run("DELETE FROM chunks WHERE note = ?", id)
        try database.run("DELETE FROM notes WHERE id = ?", id)
        try database.run("DELETE FROM nodes WHERE type = 'note' AND id = ?", id)
    }

    private func removeMap(_ id: String, _ database: SQLiteDatabase) throws {
        try database.run("DELETE FROM nodes WHERE type = 'map' AND id = ?", id)
        try database.run("DELETE FROM edges WHERE map = ?", id)
    }

    private func insertEdges(of map: String, data: Data, targets: KnowledgeLinks, _ database: SQLiteDatabase) throws {
        let graph = MapGraph.map(id: map, file: ExcalidrawFile.parse(data), targets: targets)
        for edge in graph.edges {
            try database.run("INSERT OR REPLACE INTO edges(map, arrow, from_note, to_note, kind, flow) VALUES(?, ?, ?, ?, ?, ?)",
                             edge.map, edge.arrow, edge.from, edge.to, edge.kind, edge.flow)
        }
    }

    static func area(of id: String) -> String { id.split(separator: "/").first.map(String.init) ?? "" }

    /// One line per miss: ISO time, result count, top score (`-` without one), the query.
    private func logMiss(_ query: String, hits: [Hit]) {
        let line = [Date.now.formatted(.iso8601), String(hits.count), hits.first.map { String($0.score) } ?? "-",
                    query.split(whereSeparator: { $0.isNewline || $0 == "\t" }).joined(separator: " ")].joined(separator: "\t") + "\n"
        let fd = open(missesFile.path, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return }
        defer { close(fd) }
        _ = line.utf8CString.withUnsafeBufferPointer { write(fd, $0.baseAddress, $0.count - 1) }
    }

    private func failure(_ error: any Error) -> Failure {
        Failure(message: "The knowledge index \(file.path) failed: \(error.localizedDescription)")
    }

    /// The rows a refresh writes, in a stable order (chunk ids left out): an incremental refresh
    /// and a full rebuild give the same list.
    func dump() throws -> [String] {
        guard let database = try? SQLiteDatabase(url: file, readOnly: true) else { return [] }
        func text(_ row: [SQLValue]) -> String {
            row.map { value in value.text ?? value.int.map(String.init) ?? "null" }.joined(separator: "|")
        }
        return try database.rows("SELECT id, path, area, title, kind, repo, files FROM notes ORDER BY id").map { "note " + text($0) }
            + database.rows("SELECT type, id, area, title FROM nodes ORDER BY type, id").map { "node " + text($0) }
            + database.rows("SELECT map, arrow, from_note, to_note, kind, flow FROM edges ORDER BY map, arrow").map { "edge " + text($0) }
            + database.rows("SELECT note, area, ord, heading, body FROM chunks ORDER BY note, ord").map { "chunk " + text($0) }
            + database.rows("SELECT c.note, c.ord, f.title, f.heading, f.body FROM chunks_fts f JOIN chunks c ON c.id = f.rowid ORDER BY c.note, c.ord")
            .map { "fts " + text($0) }
    }
}
