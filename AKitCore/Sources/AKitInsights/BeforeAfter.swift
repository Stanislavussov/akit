import AKitFoundation
import Foundation

/// `akit stats changes`: what a change did to the first request's context. The JSON (`version` 1)
/// is the contract for `/akit`; the Insights screen shows the same report. Token counts are recorded; character
/// counts are the listed descriptions' lengths; k is characters per token.
public struct ChangesReport: Encodable, Equatable, Sendable {
    public struct Scope: Encodable, Equatable, Sendable {
        /// nil: every session on this Mac (a home apply or a mark).
        public let project: String?

        public func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(project, forKey: .project)
        }

        private enum CodingKeys: String, CodingKey { case project }
    }

    /// Sessions are compared only within one harness, harness version and model.
    public struct Group: Encodable, Equatable, Hashable, Sendable {
        public let harness: String
        public let harnessVersion: String?
        public let model: String?

        public func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(harness, forKey: .harness)
            try container.encode(harnessVersion, forKey: .harnessVersion)
            try container.encode(model, forKey: .model)
        }

        private enum CodingKeys: String, CodingKey { case harness, harnessVersion, model }
    }

    public struct Side: Encodable, Equatable, Sendable {
        public let sessions: Int
        /// Median first-request context (input + cache read + cache write), recorded tokens.
        public let median: Int
    }

    public struct Change: Encodable, Equatable, Sendable {
        /// ISO 8601.
        let at: String
        /// `apply` or `mark`.
        public let anchor: String
        /// The applied project (`home/…` for a home folder); nil for a mark.
        public let project: String?
        /// The mark's note; nil for an apply.
        public let note: String?
        public let scope: Scope
        /// `measured` or `notEnoughData`.
        let status: String
        public var group: Group?
        public var before: Side?
        public var after: Side?
        /// Median after − median before, recorded tokens.
        public var deltaTokens: Int?
        /// Description characters of the skills that joined the listing minus those that left it.
        public var deltaChars: Int?
        /// Skills listed in most sessions on one side and in none on the other.
        public var left: [String]?
        public var joined: [String]?
        /// deltaChars / deltaTokens; nil when either is 0 or their signs differ.
        public var k: Double?
        /// The script of the changed skills' descriptions (`latin` or `cyrillic`).
        public var script: String?
        /// Why nothing was measured.
        public var reason: String?
        /// Not encoded: the anchor's time.
        public var date = Date(timeIntervalSince1970: 0)

        public var isMeasured: Bool { status == "measured" }

        public func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(at, forKey: .at)
            try container.encode(anchor, forKey: .anchor)
            try container.encodeIfPresent(project, forKey: .project)
            try container.encodeIfPresent(note, forKey: .note)
            try container.encode(scope, forKey: .scope)
            try container.encode(status, forKey: .status)
            if isMeasured {
                try container.encode(group, forKey: .group)
                try container.encode(before, forKey: .before)
                try container.encode(after, forKey: .after)
                try container.encode(deltaTokens, forKey: .deltaTokens)
                try container.encode(deltaChars, forKey: .deltaChars)
                try container.encode(left ?? [], forKey: .left)
                try container.encode(joined ?? [], forKey: .joined)
                try container.encode(k, forKey: .k)
                try container.encode(script, forKey: .script)
            } else {
                try container.encode(reason, forKey: .reason)
            }
        }

        private enum CodingKeys: String, CodingKey {
            case at, anchor, project, note, scope, status, group, before, after, deltaTokens, deltaChars, left, joined, k, script, reason
        }
    }

    /// The k in use (see `ContextSize.calibration`) and the accepted pairs per script.
    public struct Calibration: Encodable, Equatable, Sendable {
        public let latin: Double
        public let cyrillic: Double
        /// Pairs behind the calibrated scripts; 0 while both use their defaults.
        let pairs: Int
        public let latinPairs: Int
        public let cyrillicPairs: Int
        /// `calibrated` (at least one script) or `defaults`.
        let source: String
    }

    let version: Int
    public let changes: [Change]
    public let calibration: Calibration
    /// Not encoded: import notes and whether the calibration was saved, for the text output (stderr with --json).
    public var notes: [String] = []

    public init(version: Int, changes: [Change], calibration: Calibration, notes: [String] = []) {
        self.version = version
        self.changes = changes
        self.calibration = calibration
        self.notes = notes
    }

    private enum CodingKeys: String, CodingKey { case version, changes, calibration }
}

/// Before/after measurement. Anchors are applies (spool `apply` lines) and marks (`akit stats mark`).
/// Per anchor, the first-request context of the sessions in its scope within 14 days on each side,
/// compared within one (harness, version, model) group with at least 5 sessions per side.
/// A home apply or a mark affects every project: its scope is every session on this Mac. A project
/// apply's scope is the sessions bound to that project in the binding set.
public enum BeforeAfter {
    public static let window: TimeInterval = 14 * 86_400
    static let minSessions = 5

    struct Anchor: Equatable {
        let date: Date
        /// `apply` or `mark`.
        let kind: String
        let project: String?
        let note: String?

        /// The project whose sessions count; nil: every session.
        var scopeProject: String? {
            guard kind == "apply", let project, !project.hasPrefix("home/") else { return nil }
            return project
        }
    }

    /// One session's first main request.
    struct Session {
        let key: String
        let group: ChangesReport.Group
        let context: Int
    }

    /// Applies and marks, oldest first.
    static func anchors(_ database: IndexDatabase) throws -> [Anchor] {
        var anchors: [Anchor] = []
        for row in try database.rows("SELECT project_id, ts FROM applies") {
            guard let project = row[0].text, let ts = row[1].double else { continue }
            anchors.append(.init(date: Date(timeIntervalSince1970: ts / 1000), kind: "apply", project: project, note: nil))
        }
        for row in try database.rows("SELECT note, ts FROM marks") {
            guard let note = row[0].text, let ts = row[1].double else { continue }
            anchors.append(.init(date: Date(timeIntervalSince1970: ts / 1000), kind: "mark", project: nil, note: note))
        }
        return anchors.sorted { ($0.date, $0.kind, $0.project ?? $0.note ?? "") < ($1.date, $1.kind, $1.project ?? $1.note ?? "") }
    }

    /// Every anchor measured. `descriptions`: skill descriptions (installed and brain), for the
    /// script of the skills that changed; unknown ones count as Latin.
    public static func changes(_ database: IndexDatabase, descriptions: [String: String], bindings: BindingSet = .default) throws
        -> [ChangesReport.Change] {
        try anchors(database).map { try measure($0, database: database, descriptions: descriptions, bindings: bindings) }
    }

    static func measure(_ anchor: Anchor, database: IndexDatabase, descriptions: [String: String],
                        bindings: BindingSet = .default) throws -> ChangesReport.Change {
        let before = try sessions(database, project: anchor.scopeProject, bindings: bindings,
                                  from: anchor.date.addingTimeInterval(-window), to: anchor.date.addingTimeInterval(-0.001))
        let after = try sessions(database, project: anchor.scopeProject, bindings: bindings, from: anchor.date,
                                 to: anchor.date.addingTimeInterval(window))
        let beforeGroups = Dictionary(grouping: before, by: \.group), afterGroups = Dictionary(grouping: after, by: \.group)
        func label(_ group: ChangesReport.Group) -> String {
            "\(group.harness) \(group.harnessVersion ?? "?"), \(group.model ?? "unknown model")"
        }
        // The group with the most sessions on its thinner side.
        let best = Set(beforeGroups.keys).union(afterGroups.keys).max { a, b in
            let (ba, aa) = (beforeGroups[a]?.count ?? 0, afterGroups[a]?.count ?? 0)
            let (bb, ab) = (beforeGroups[b]?.count ?? 0, afterGroups[b]?.count ?? 0)
            return (min(ba, aa), ba + aa, label(b)) < (min(bb, ab), bb + ab, label(a))
        }
        var change = ChangesReport.Change(
            at: anchor.date.formatted(.iso8601), anchor: anchor.kind, project: anchor.project, note: anchor.note,
            scope: .init(project: anchor.scopeProject), status: "notEnoughData", date: anchor.date)
        let need = "a pair needs \(minSessions) sessions on each side within 14 days, with the same harness version and model"
        guard let best else {
            change.reason = "no sessions with a recorded first request within 14 days before or after; \(need)"
            return change
        }
        let old = beforeGroups[best] ?? [], new = afterGroups[best] ?? []
        guard old.count >= minSessions, new.count >= minSessions else {
            change.reason = "\(old.count) before and \(new.count) after in the best group (\(label(best))); \(need)"
            return change
        }
        let oldMedian = median(old.map(\.context)), newMedian = median(new.map(\.context))
        let deltaTokens = newMedian - oldMedian
        let (left, joined, deltaChars, script) = try listingChange(database, before: old.map(\.key), after: new.map(\.key),
                                                                   descriptions: descriptions)
        change = ChangesReport.Change(
            at: change.at, anchor: anchor.kind, project: anchor.project, note: anchor.note, scope: change.scope, status: "measured",
            group: best, before: .init(sessions: old.count, median: oldMedian), after: .init(sessions: new.count, median: newMedian),
            deltaTokens: deltaTokens, deltaChars: deltaChars, left: left, joined: joined,
            k: deltaChars != 0 && deltaTokens != 0 && (deltaChars > 0) == (deltaTokens > 0)
                ? (Double(deltaChars) / Double(deltaTokens) * 100).rounded() / 100 : nil,
            script: script.rawValue, date: anchor.date)
        return change
    }

    /// Main sessions in scope started in [from, to] with a recorded first main request.
    static func sessions(_ database: IndexDatabase, project: String?, bindings: BindingSet, from: Date, to: Date) throws -> [Session] {
        let (scoped, values) = InsightsStats.Scope(project: project, bindings: bindings, from: from, to: to).cte
        let first = "FROM requests r WHERE r.session_key = s.key AND r.is_subagent = 0 ORDER BY r.ts IS NULL, r.ts LIMIT 1"
        return try database.rows("""
            WITH \(scoped) SELECT s.key, s.harness, s.harness_version, (SELECT r.model \(first)),
              (SELECT COALESCE(r.input, 0) + COALESCE(r.cache_read, 0) + COALESCE(r.cache_write, 0) \(first))
            FROM sessions s JOIN scoped x ON x.key = s.key
            """, values).compactMap { row in
            guard let key = row[0].text, let harness = row[1].text, let context = row[4].int else { return nil }
            return Session(key: key, group: .init(harness: harness, harnessVersion: row[2].text, model: row[3].text), context: context)
        }
    }

    /// Skills listed in more than half of the sessions on one side and in none on the other, and
    /// the character delta of their descriptions (the median of each skill's per-session size).
    static func listingChange(_ database: IndexDatabase, before: [String], after: [String], descriptions: [String: String]) throws
        -> (left: [String], joined: [String], deltaChars: Int, script: ContextSize.Script) {
        func listed(_ keys: [String]) throws -> [String: [Int]] {
            let json = String(decoding: try JSONEncoder().encode(keys), as: UTF8.self)
            var sizes: [String: [Int]] = [:]
            for row in try database.rows("""
                SELECT skill, MAX(desc_chars) FROM skill_listings WHERE is_subagent = 0 AND session_key IN (SELECT value FROM json_each(?))
                GROUP BY skill, session_key
                """, json) {
                if let skill = row[0].text { sizes[skill, default: []].append(row[1].int ?? 0) }
            }
            return sizes
        }
        let old = try listed(before), new = try listed(after)
        let left = old.filter { $0.value.count * 2 > before.count && new[$0.key] == nil }.keys.sorted()
        let joined = new.filter { $0.value.count * 2 > after.count && old[$0.key] == nil }.keys.sorted()
        var delta = 0, cyrillic = 0, total = 0
        for (skill, chars) in left.map({ ($0, median(old[$0] ?? [])) }) + joined.map({ ($0, median(new[$0] ?? [])) }) {
            delta += joined.contains(skill) ? chars : -chars
            total += chars
            if descriptions[skill].map(ContextSize.script) == .cyrillic { cyrillic += chars }
        }
        return (left, joined, delta, total > 0 && cyrillic * 2 >= total ? .cyrillic : .latin)
    }

    /// The median; the mean of the two middle values (rounded) for an even count; 0 when empty.
    static func median(_ values: [Int]) -> Int {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return 0 }
        let middle = sorted.count / 2
        return sorted.count % 2 == 1 ? sorted[middle] : Int((Double(sorted[middle - 1] + sorted[middle]) / 2).rounded())
    }

    /// `--at`: `2026-09-26` (local midnight), `2026-09-26T14:30`, `2026-09-26 14:30` (local time),
    /// or ISO 8601 with a zone.
    public static func date(from text: String, timeZone: TimeZone = .current) -> Date? {
        if let date = ISO8601DateFormatter().date(from: text) { return date }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.isLenient = false
        for format in ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd HH:mm", "yyyy-MM-dd"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: text) { return date }
        }
        return nil
    }
}

extension BeforeAfter {
    /// `akit stats changes` and the Insights screen's Changes: every anchor measured, and the k
    /// they give saved when it changed (only under the import lock), then the anchors of
    /// `project` (its applies, and the marks, which are Mac-wide) or all of them.
    public static func report(_ database: IndexDatabase, env: HarnessEnvironment, descriptions: [String: String], project: String?,
                              notes: [String] = []) throws -> ChangesReport {
        let changes = try changes(database, descriptions: descriptions)
        // Every anchor calibrates, whatever the report shows.
        let calibration = ContextCalibration.calibration(from: changes)
        var notes = notes
        let stored = try ContextSize.calibration(database)
        // Neither calibrated: the defaults apply and nothing is stored either way.
        let unchanged = stored.isCalibrated || calibration.isCalibrated ? stored == calibration : true
        if unchanged {
            // Nothing to write, so no lock taken: an import starting now isn't kept waiting.
        } else if let lock = try ImportLock.acquire(InsightsPaths(env: env).lock) {
            try withExtendedLifetime(lock) { try ContextCalibration.save(calibration, database: database) }
        } else {
            notes.append("calibration not saved: an import is running; run akit stats changes again later")
        }
        return ChangesReport(version: 1, changes: project.map { id in changes.filter { $0.project == id || $0.anchor == "mark" } } ?? changes,
                             calibration: ContextCalibration.summary(calibration), notes: notes)
    }
}
