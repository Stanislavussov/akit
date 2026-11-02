import AKitFoundation
import Foundation

/// The user's corrections per session, counted by code from the signals scan and the ratings
/// (`docs/design/corrections.md`, part 1). A correction is a negative reaction: an interrupt, a
/// pushback, the user's own refusal of a tool call or a bad rating (not a permission rule's, a hook's
/// or the auto mode classifier's refusal). Plain follow-up turns don't count (C5). No
/// model is called and no session text is read here.
public struct CorrectedSession: Encodable, Equatable, Sendable, Identifiable {
    public var id: String { key }
    /// The index's key: `claude:<id>` or `pi:<id>`.
    public let key: String
    public let harness: String
    /// The session's log file, while the index knows it (local only).
    public let file: String?
    public let cwd: String?
    /// The project the session is bound to (at a confidence of the binding set), if any.
    public let project: String?
    public let started: Date?
    public let harnessVersion: String?
    /// The model that answered most main requests.
    public let model: String?
    public let interrupts: Int
    public let pushbacks: Int
    /// The user's own refusals of tool calls.
    public let refusals: Int
    public let badRatings: Int

    public var corrections: Int { interrupts + pushbacks + refusals + badRatings }

    public init(key: String, harness: String, file: String?, cwd: String?, project: String?, started: Date?, harnessVersion: String?,
                model: String?, interrupts: Int, pushbacks: Int, refusals: Int, badRatings: Int) {
        self.key = key
        self.harness = harness
        self.file = file
        self.cwd = cwd
        self.project = project
        self.started = started
        self.harnessVersion = harnessVersion
        self.model = model
        self.interrupts = interrupts
        self.pushbacks = pushbacks
        self.refusals = refusals
        self.badRatings = badRatings
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(key, forKey: .key)
        try container.encode(harness, forKey: .harness)
        try container.encodeIfPresent(file, forKey: .file)
        try container.encodeIfPresent(cwd, forKey: .cwd)
        try container.encode(project, forKey: .project)
        try container.encode(started.map { ISO8601DateFormatter().string(from: $0) }, forKey: .started)
        try container.encode(model, forKey: .model)
        try container.encode(interrupts, forKey: .interrupts)
        try container.encode(pushbacks, forKey: .pushbacks)
        try container.encode(refusals, forKey: .refusals)
        try container.encode(badRatings, forKey: .badRatings)
        try container.encode(corrections, forKey: .corrections)
    }

    private enum CodingKeys: String, CodingKey {
        case key, harness, file, cwd, project, started, model, interrupts, pushbacks, refusals, badRatings, corrections
    }
}

public enum CorrectionStats {
    /// Every scanned session started in `from...to` with its corrections, oldest first. `project`:
    /// only sessions bound to it. `excluding`: index keys left out (Lab's own runs, D19).
    public static func sessions(_ database: IndexDatabase, from: Date, to: Date, project: String? = nil,
                                bindings: BindingSet = .default, excluding: Set<String> = []) throws -> [CorrectedSession] {
        let scope = InsightsStats.Scope(project: project, bindings: bindings, from: from, to: to)
        let (scoped, values) = scope.cte
        let bad = try badRatings(database)
        return try database.rows("""
            WITH \(scoped) SELECT x.key, x.harness, src.path, x.cwd,
              (SELECT b.project_id FROM bindings b WHERE b.session_key = x.key AND b.confidence IN \(bindings.sqlList)),
              x.started, x.harness_version,
              (SELECT r.model FROM requests r WHERE r.session_key = x.key AND r.is_subagent = 0 AND r.model IS NOT NULL
                 GROUP BY r.model ORDER BY COUNT(*) DESC LIMIT 1),
              g.interrupts, g.pushbacks, g.user_refusals
            FROM signals g JOIN scoped s ON s.key = g.session_key JOIN sessions x ON x.key = g.session_key
            LEFT JOIN sources src ON src.id = x.source_id
            ORDER BY x.started, x.key
            """, values).compactMap { row in
            guard let key = row[0].text, !excluding.contains(key) else { return nil }
            return CorrectedSession(key: key, harness: row[1].text ?? "", file: row[2].text, cwd: row[3].text, project: row[4].text,
                                    started: row[5].double.map(Date.init(timeIntervalSince1970:)), harnessVersion: row[6].text,
                                    model: row[7].text, interrupts: row[8].int ?? 0, pushbacks: row[9].int ?? 0,
                                    refusals: row[10].int ?? 0, badRatings: bad[key] ?? 0)
        }
    }

    /// Bad ratings per session key, each run's current rating only (a rating taken back or
    /// changed to good doesn't count).
    static func badRatings(_ database: IndexDatabase) throws -> [String: Int] {
        guard try database.userVersion >= 7 else { return [:] }
        var counts: [String: Int] = [:]
        for rating in Ratings.current(try Ratings.all(database)) where rating.rating == "bad" {
            counts["\(rating.harness):\(rating.sessionID)", default: 0] += 1
        }
        return counts
    }
}

/// `akit corrections`: the sessions of a window where the user corrected the agent, with the
/// count per project and harness and the share of all scanned sessions. The JSON (`version` 1) is
/// the contract for `/akit` and the Insights screen's Corrections card.
public struct CorrectionsReport: Encodable, Equatable, Sendable {
    public struct Count: Encodable, Equatable, Sendable, Identifiable {
        public var id: String { name ?? "" }
        /// A project id or a harness; nil: sessions bound to no project.
        public let name: String?
        public let sessions: Int
        public let corrected: Int
    }

    public let version: Int
    public let days: Int
    public let project: String?
    /// Sessions in scope whose signals were scanned.
    public let sessionsScanned: Int
    /// Of those, sessions with at least one correction.
    public let sessionsCorrected: Int
    /// Corrected sessions, most corrections first.
    public let sessions: [CorrectedSession]
    public let byProject: [Count]
    public let byHarness: [Count]

    public var share: Double { sessionsScanned == 0 ? 0 : Double(sessionsCorrected) / Double(sessionsScanned) }

    public static func empty(days: Int, project: String?) -> CorrectionsReport {
        CorrectionsReport(version: 1, days: days, project: project, sessionsScanned: 0, sessionsCorrected: 0, sessions: [],
                          byProject: [], byHarness: [])
    }

    public init(version: Int = 1, days: Int, project: String?, sessionsScanned: Int, sessionsCorrected: Int, sessions: [CorrectedSession],
                byProject: [Count], byHarness: [Count]) {
        self.version = version
        self.days = days
        self.project = project
        self.sessionsScanned = sessionsScanned
        self.sessionsCorrected = sessionsCorrected
        self.sessions = sessions
        self.byProject = byProject
        self.byHarness = byHarness
    }

    public init(days: Int, project: String?, scanned: [CorrectedSession]) {
        let corrected = scanned.filter { $0.corrections > 0 }
            .sorted { ($0.corrections, $0.started ?? .distantPast) > ($1.corrections, $1.started ?? .distantPast) }
        func counts(_ name: (CorrectedSession) -> String?) -> [Count] {
            Dictionary(grouping: scanned, by: { name($0) ?? "" }).map { key, members in
                Count(name: key.isEmpty ? nil : key, sessions: members.count, corrected: members.filter { $0.corrections > 0 }.count)
            }
            .filter { $0.corrected > 0 }
            .sorted { ($0.corrected, $1.name ?? "") > ($1.corrected, $0.name ?? "") }
        }
        self.init(days: days, project: project, sessionsScanned: scanned.count, sessionsCorrected: corrected.count, sessions: corrected,
                  byProject: counts(\.project), byHarness: counts(\.harness))
    }

    public static func report(_ database: IndexDatabase, days: Int = InsightsStats.defaultDays, project: String? = nil,
                              bindings: BindingSet = .default, excluding: Set<String> = [], now: Date = Date()) throws -> CorrectionsReport {
        let scanned = try CorrectionStats.sessions(database, from: now.addingTimeInterval(-Double(days) * 86_400), to: now, project: project,
                                                   bindings: bindings, excluding: excluding)
        return CorrectionsReport(days: days, project: project, scanned: scanned)
    }

    /// Lines for the terminal.
    public var text: String {
        var lines = ["Corrections, last \(days) days\(project.map { " in \($0)" } ?? ""): \(sessionsCorrected) of \(sessionsScanned) "
                     + "scanned sessions (\(Int((share * 100).rounded()))%) had an interrupt, a pushback, your refusal of a tool call or a bad rating."]
        guard !sessions.isEmpty else { return lines.joined(separator: "\n") }
        if project == nil, !byProject.isEmpty {
            lines.append("")
            lines.append("By project:")
            for count in byProject { lines.append("  \(count.name ?? "(no project)"): \(count.corrected) of \(count.sessions)") }
        }
        lines.append("")
        lines.append("By harness:")
        for count in byHarness { lines.append("  \(count.name ?? "?"): \(count.corrected) of \(count.sessions)") }
        lines.append("")
        for session in sessions {
            let parts = [(session.interrupts, "interrupt"), (session.pushbacks, "pushback"), (session.refusals, "refused call"),
                         (session.badRatings, "bad rating")].filter { $0.0 > 0 }.map { "\($0.0) \($0.1)\($0.0 == 1 ? "" : "s")" }
            let day = session.started.map { String(ISO8601DateFormatter().string(from: $0).prefix(10)) } ?? "?"
            lines.append("\(day)  \(session.key)  \(parts.joined(separator: ", "))"
                         + (session.project.map { "  \($0)" } ?? session.cwd.map { "  \(($0 as NSString).lastPathComponent)" } ?? ""))
        }
        lines.append("")
        lines.append("Find Pattern (one model call, at most about 15k tokens of excerpts): akit corrections find")
        return lines.joined(separator: "\n")
    }
}
