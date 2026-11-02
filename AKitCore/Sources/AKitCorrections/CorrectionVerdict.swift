import AKitErrorAnalysis
import AKitFoundation
import AKitInsights
import Foundation

/// Whether a rule worked (`docs/design/corrections.md`, part 4), by code only: the share of
/// sessions with a correction in the rule's scope, before its mark and after it, compared within
/// one harness and model (C7: not the harness version, which changes every few days).
public struct CorrectionVerdict: Encodable, Equatable, Sendable, Identifiable {
    public enum Status: String, Encodable, Sendable {
        /// Fewer than `minAfter` sessions after the rule, or too few before it on the same model.
        case waiting
        case fewer
        case noChange
        case more
        /// Remove Rule… took it out.
        case removed
    }

    public struct Side: Encodable, Equatable, Sendable {
        public let sessions: Int
        public let corrected: Int
        public var share: Double { sessions == 0 ? 0 : Double(corrected) / Double(sessions) }
    }

    public var id: String { rule.id }
    public let rule: CorrectionRule
    public let status: Status
    /// `claude · claude-opus-5-5`: the group compared; nil when none had sessions on both sides.
    public let group: String?
    public let before: Side?
    public let after: Side?
    /// Why there is no verdict yet, or the line that a few sessions are noise.
    public let note: String

    /// Step 0 (2026-11-02): about 15–25 sessions a week on this Mac, so 10 after a global rule is
    /// a week or less; a project's rule may wait longer.
    public static let minAfter = 10
    static let minBefore = 5
    /// A change in the share smaller than this is "no change".
    static let margin = 0.10

    /// The verdict of each rule, applied ones first, newest first.
    public static func all(_ rules: [CorrectionRule], database: IndexDatabase?, excluding: Set<String>, bindings: BindingSet = .default,
                           now: Date = Date()) throws -> [CorrectionVerdict] {
        try rules.sorted { ($0.removed == nil ? 1 : 0, $0.applied) > ($1.removed == nil ? 1 : 0, $1.applied) }.map { rule in
            guard let database else { return judge(rule, before: [], after: [], now: now) }
            let before = try CorrectionStats.sessions(database, from: rule.applied.addingTimeInterval(-BeforeAfter.window), to: rule.applied,
                                                      project: rule.scope, bindings: bindings, excluding: excluding)
                .filter { ($0.started ?? .distantPast) < rule.applied }
            let after = try CorrectionStats.sessions(database, from: rule.applied, to: rule.removed ?? now, project: rule.scope,
                                                     bindings: bindings, excluding: excluding)
            return judge(rule, before: before, after: after, now: now)
        }
    }

    static func judge(_ rule: CorrectionRule, before: [CorrectedSession], after: [CorrectedSession], now: Date) -> CorrectionVerdict {
        if rule.removed != nil {
            return CorrectionVerdict(rule: rule, status: .removed, group: nil, before: nil, after: nil, note: "Taken out by Remove Rule….")
        }
        func group(_ session: CorrectedSession) -> String { "\(session.harness) · \(session.model ?? "model not recorded")" }
        let beforeGroups = Dictionary(grouping: before, by: group), afterGroups = Dictionary(grouping: after, by: group)
        let candidates = afterGroups.filter { (beforeGroups[$0.key]?.count ?? 0) >= minBefore }
        guard let (name, members) = candidates.max(by: { ($0.value.count, $1.key) < ($1.value.count, $0.key) }) else {
            let total = after.count
            return CorrectionVerdict(rule: rule, status: .waiting, group: nil, before: nil, after: nil,
                                     note: total == 0 ? "No session in the rule's scope since it was applied."
                                         : "\(total) session\(total == 1 ? "" : "s") since the rule, but no harness and model with "
                                           + "\(minBefore) or more sessions before it to compare with.")
        }
        let old = beforeGroups[name] ?? []
        let beforeSide = Side(sessions: old.count, corrected: old.filter { $0.corrections > 0 }.count)
        let afterSide = Side(sessions: members.count, corrected: members.filter { $0.corrections > 0 }.count)
        guard afterSide.sessions >= minAfter else {
            let left = minAfter - afterSide.sessions
            return CorrectionVerdict(rule: rule, status: .waiting, group: name, before: beforeSide, after: afterSide,
                                     note: "\(left) more session\(left == 1 ? "" : "s") on \(name) before a verdict.")
        }
        let delta = afterSide.share - beforeSide.share
        let status: Status = delta <= -margin ? .fewer : delta >= margin ? .more : .noChange
        return CorrectionVerdict(rule: rule, status: status, group: name, before: beforeSide, after: afterSide,
                                 note: "A few sessions are noise: one more corrected session moves the share by "
                                     + "\(Int((100 / Double(afterSide.sessions)).rounded())) points.")
    }

    public var statusTitle: String {
        switch status {
        case .waiting: "waiting"
        case .fewer: "fewer"
        case .noChange: "no change"
        case .more: "more"
        case .removed: "removed"
        }
    }

    /// Remove Rule… is offered when the rule didn't make corrections fewer.
    public var offersRemove: Bool { status == .noChange || status == .more }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(rule.id, forKey: .id)
        try container.encode(rule.title, forKey: .title)
        try container.encode(rule.rule, forKey: .rule)
        try container.encode(rule.scope, forKey: .scope)
        try container.encode(rule.target, forKey: .target)
        try container.encode(ISO8601DateFormatter().string(from: rule.applied), forKey: .applied)
        try container.encode(status, forKey: .status)
        try container.encode(group, forKey: .group)
        try container.encode(before, forKey: .before)
        try container.encode(after, forKey: .after)
        try container.encode(note, forKey: .note)
    }

    private enum CodingKeys: String, CodingKey { case id, title, rule, scope, target, applied, status, group, before, after, note }

    /// One line and its details for the terminal.
    public var text: String {
        var lines = ["\(rule.id)  \(statusTitle)  \(rule.title)",
                     "  \(rule.isGlobal ? "Global Instructions" : rule.target) · applied \(String(ISO8601DateFormatter().string(from: rule.applied).prefix(10)))"
                     + (rule.scope.map { " · scope \($0)" } ?? " · scope every session")]
        if let before, let after, let group {
            lines.append("  \(group): before \(before.corrected) of \(before.sessions) corrected, after \(after.corrected) of \(after.sessions)")
        }
        lines.append("  \(note)")
        return lines.joined(separator: "\n")
    }
}

extension Corrections {
    /// `akit corrections rules` and the card's rule list: every recorded rule with its verdict.
    public static func verdicts(env: HarnessEnvironment, bindings: BindingSet = .default, now: Date = Date()) throws -> [CorrectionVerdict] {
        let state: CorrectionsState
        do { state = try CorrectionsState.load(env: env) } catch { throw Failure(message: error.message) }
        guard !state.rules.isEmpty else { return [] }
        if let lock = try ImportLock.acquire(InsightsPaths(env: env).lock) {
            defer { withExtendedLifetime(lock) {} }
            try SignalScanner.refresh(env: env)
        }
        return try CorrectionVerdict.all(state.rules, database: try AnalysisIndex.open(env: env),
                                         excluding: IndexedSessions.labKeys(env: env), bindings: bindings, now: now)
    }
}
