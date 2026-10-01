import AKitFoundation
import AKitInsights
import AKitLab
import Foundation

/// A fix for a failure or efficiency mode (`docs/design/error-analysis.md`, "Fixes"): written
/// down before any run, together with what should change and the rule for "helped". The
/// user applies it; AKit never changes the context of real sessions.
public struct FixDraft: Codable, Hashable, Sendable {
    public enum Layer: String, Codable, Sendable, CaseIterable {
        case claudeMD = "claude-md"
        case agentsMD = "agents-md"
        case skill, hook
        case toolDescription = "tool-description"
        case environment

        public var title: String {
            switch self {
            case .claudeMD: "CLAUDE.md rule"
            case .agentsMD: "AGENTS.md rule"
            case .skill: "Skill"
            case .hook: "Hook"
            case .toolDescription: "Tool description"
            case .environment: "Environment"
            }
        }

        /// The file a control run's variant appends the text to, when the layer is a file in
        /// the repository; hooks and the environment can't be tried that way.
        public func patchFile(skillName: String?) -> String? {
            switch self {
            case .claudeMD: "CLAUDE.md"
            case .agentsMD: "AGENTS.md"
            case .skill: skillName.map { ".claude/skills/\($0)/SKILL.md" }
            case .hook, .toolDescription, .environment: nil
            }
        }
    }

    public var modeID: String
    public var layer: Layer
    /// For a skill: its folder name.
    public var skillName: String?
    public var text: String
    /// Notes that show the problem (`session#note`).
    public var exemplars: [NoteRef]
    /// What should change in transcripts once the fix works.
    public var expectedChange: String
    /// The "helped" criterion in the user's words, fixed before any run.
    public var helpedCriterion: String
    public var createdAt: Date

    public init(modeID: String, layer: Layer, skillName: String? = nil, text: String, exemplars: [NoteRef] = [], expectedChange: String,
                helpedCriterion: String, createdAt: Date = .now) {
        self.modeID = modeID
        self.layer = layer
        self.skillName = skillName
        self.text = text
        self.exemplars = exemplars
        self.expectedChange = expectedChange
        self.helpedCriterion = helpedCriterion
        self.createdAt = createdAt
    }

    /// The draft as a control run's one difference, when its layer allows one.
    public var patch: ControlPatch? { layer.patchFile(skillName: skillName).map { ControlPatch(file: $0, text: text) } }
}

public struct FixStore: Sendable {
    let paths: AnalysisPaths

    public init(env: HarnessEnvironment) { paths = AnalysisPaths(env: env) }

    func file(_ modeID: String) -> URL { paths.fixes.appending(path: AnalysisPaths.fileName(modeID) + ".json") }

    public func load(_ modeID: String) -> FixDraft? {
        (try? Data(contentsOf: file(modeID))).flatMap { try? AnalysisJSON.decoder.decode(FixDraft.self, from: $0) }
    }

    public func save(_ draft: FixDraft) throws {
        try JSONFile.write(draft, to: file(draft.modeID))
    }

    public func all() -> [FixDraft] {
        FileWalk.children(of: paths.fixes).filter { $0.pathExtension == "json" }
            .compactMap { (try? Data(contentsOf: $0)).flatMap { try? AnalysisJSON.decoder.decode(FixDraft.self, from: $0) } }
    }
}

/// The production signal of a fix: the mode's check over indexed sessions before and after T.
public struct FixEvaluation: Codable, Hashable, Sendable {
    public struct Side: Codable, Hashable, Sendable {
        public var sessions: Int
        public var failures: Int
        public var interval: Stats.Interval
        /// The model most sessions of the period used.
        public var model: String?
        /// The harness version most sessions of the period ran on (its prompt changes with it).
        public var harnessVersion: String?
    }

    public enum Verdict: String, Codable, Sendable {
        /// P(after < before) ≥ 0.95 and not worse.
        case helped
        /// The rule isn't met.
        case notShown = "not-shown"
        /// Fewer than 15 sessions on a side.
        case noConclusion = "no-conclusion"
    }

    public var modeID: String
    public var appliedAt: Date
    public var before: Side
    public var after: Side
    /// P(failure rate after < before) under Beta(1,1) posteriors.
    public var probabilityLower: Double
    /// P(failure rate after > before): the "not worse" guard (≤ 50%).
    public var probabilityHigher: Double
    public var fisherP: Double
    public var verdict: Verdict
    /// The smallest failure rate after T this many sessions per side could tell from the
    /// rate before (80% power, 5% two-sided).
    public var minimumDetectable: Double?
    /// The check isn't exact or validated: the numbers are a heuristic's.
    public var checkTrust: CheckTrust.Level
    /// Things that changed between the periods besides the fix.
    public var flags: [String]
}

public enum Fixes {
    public static let minimumPerSide = 15
    public static let helpedProbability = 0.95

    /// Applies the rule to failure counts on both sides.
    public static func evaluate(modeID: String, appliedAt: Date, before: (failures: Int, sessions: Int, model: String?),
                                after: (failures: Int, sessions: Int, model: String?), trust: CheckTrust.Level,
                                versions: (before: String?, after: String?) = (nil, nil)) -> FixEvaluation {
        let lower = Stats.probabilityLower(after: after.failures, of: after.sessions, before: before.failures, of: before.sessions)
        let higher = Stats.probabilityLower(after: before.failures, of: before.sessions, before: after.failures, of: after.sessions)
        let verdict: FixEvaluation.Verdict
        if before.sessions < minimumPerSide || after.sessions < minimumPerSide {
            verdict = .noConclusion
        } else if lower >= helpedProbability, higher <= 0.5 {
            verdict = .helped
        } else {
            verdict = .notShown
        }
        var flags: [String] = []
        if let a = before.model, let b = after.model, a != b { flags.append("The sessions' model changed: \(a) before, \(b) after.") }
        if let a = versions.before, let b = versions.after, a != b {
            flags.append("The harness version (and its system prompt) changed: \(a) before, \(b) after.")
        }
        if trust != .exact && trust != .validated { flags.append("The mode's check isn't validated: these are a heuristic's numbers.") }
        let rate = before.sessions > 0 ? Double(before.failures) / Double(before.sessions) : nil
        return FixEvaluation(modeID: modeID, appliedAt: appliedAt,
                             before: .init(sessions: before.sessions, failures: before.failures, interval: Stats.wilson(before.failures, before.sessions),
                                           model: before.model, harnessVersion: versions.before),
                             after: .init(sessions: after.sessions, failures: after.failures, interval: Stats.wilson(after.failures, after.sessions),
                                          model: after.model, harnessVersion: versions.after),
                             probabilityLower: lower, probabilityHigher: higher,
                             fisherP: Stats.fisherExact(before.failures, before.sessions, after.failures, after.sessions), verdict: verdict,
                             minimumDetectable: rate.flatMap { minimumDetectable(from: $0, perSide: min(before.sessions, after.sessions)) },
                             checkTrust: trust, flags: flags)
    }

    /// The smallest lower rate distinguishable from `rate` with `n` sessions per side, by the
    /// arcsine approximation (z 1.96 + 0.84 for 80% power). nil when none is.
    public static func minimumDetectable(from rate: Double, perSide n: Int) -> Double? {
        guard n > 0, rate > 0 else { return nil }
        let h = (1.959964 + 0.841621) * (2.0 / Double(n)).squareRoot()
        let target = asin(rate.squareRoot()) - h / 2
        guard target > 0 else { return nil }
        return pow(sin(target), 2)
    }

    /// The fix of a mode, judged on its check over the indexed sessions started before and
    /// after T (Lab's own sessions left out); the "before" window is as long as the "after" one.
    public static func evaluate(_ mode: Mode, env: HarnessEnvironment, now: Date = .now) throws -> FixEvaluation? {
        guard let applied = mode.fixAppliedAt, let results = Validation.verdicts(modeID: mode.id, env: env),
              let database = try AnalysisIndex.open(env: env) else { return nil }
        let lab = IndexedSessions.labKeys(env: env)
        let sessions = try AnalysisIndex.sessions(database).filter { !lab.contains($0.key) && results.verdicts[$0.key] != nil }
        let span = max(now.timeIntervalSince(applied), 86_400)
        func members(_ range: Range<Date>) -> [IndexedSession] {
            sessions.filter { session in (session.started ?? session.lastActivity).map(range.contains) ?? false }
        }
        func most(_ values: [String]) -> String? { Dictionary(grouping: values, by: { $0 }).max { $0.value.count < $1.value.count }?.key }
        func side(_ members: [IndexedSession]) -> (failures: Int, sessions: Int, model: String?) {
            (members.filter { results.verdicts[$0.key]?.positive == true }.count, members.count, most(members.compactMap(\.model)))
        }
        let before = members(applied.addingTimeInterval(-span)..<applied), after = members(applied..<now.addingTimeInterval(1))
        let trust = Validation.trustMap(modes: [mode], env: env)[mode.id]?.level ?? .none
        return evaluate(modeID: mode.id, appliedAt: applied, before: side(before), after: side(after), trust: trust,
                        versions: (most(before.compactMap(\.harnessVersion)), most(after.compactMap(\.harnessVersion))))
    }

    /// Modes whose check shows a higher failure rate after the fix's T: regressions offline
    /// tasks miss.
    public static func regressions(modes: [Mode], since applied: Date, env: HarnessEnvironment, now: Date = .now) throws -> [String] {
        var rose: [String] = []
        for mode in modes where mode.isCurrent && mode.status == .active && mode.kind.takesFixes {
            var probe = mode
            probe.fixAppliedAt = applied
            if let evaluation = try evaluate(probe, env: env, now: now), evaluation.before.sessions >= minimumPerSide,
               evaluation.after.sessions >= minimumPerSide, evaluation.probabilityHigher >= helpedProbability {
                rose.append(mode.id)
            }
        }
        return rose
    }

    /// The transition matrix of reviewed sessions before T against after T, as a difference.
    public static func matrixDifference(appliedAt: Date, pool: [SessionNotes], env: HarnessEnvironment) throws -> [String: TransitionMatrix.Difference] {
        guard let database = try AnalysisIndex.open(env: env) else { return [:] }
        let started = Dictionary(try AnalysisIndex.sessions(database).map { ($0.key, $0.started ?? $0.lastActivity) }, uniquingKeysWith: { a, _ in a })
        var phases: [String: [Int: Phase]] = [:]
        for notes in pool {
            if let items = try? Bootstrap.items(transcript: notes.transcript, sessionKey: notes.sessionKey, env: env) {
                phases[notes.sessionKey] = PhaseClassifier.phases(of: items)
            }
        }
        let before = pool.filter { (started[$0.sessionKey] ?? nil).map { $0 < appliedAt } ?? false }
        let after = pool.filter { (started[$0.sessionKey] ?? nil).map { $0 >= appliedAt } ?? false }
        return TransitionMatrix.difference(before: TransitionMatrix.build(before, phases: phases), after: TransitionMatrix.build(after, phases: phases))
    }
}
