import AKitFoundation
import AKitLab
import AKitModel
import AKitSessions
import Foundation

/// How far a mode's check can be trusted (`docs/design/error-analysis.md`, "Validation").
public struct CheckTrust: Codable, Hashable, Sendable {
    public enum Level: String, Codable, Sendable {
        /// The check is the definition (a mechanical code check): exact, no correction.
        case exact
        /// Validated: the Wilson lower bounds of TPR and TNR on the test labels are ≥ 80%, with
        /// 30+ test labels per class.
        case validated
        /// 20+ test labels per class: its rate is shown beside "seen in k notes", never as a
        /// frequency.
        case provisional
        /// Not validated yet.
        case none
    }

    public var level: Level
    /// The test labels behind TPR and TNR, for the correction and its interval.
    public var labels: Stats.CheckLabels?

    public init(level: Level, labels: Stats.CheckLabels? = nil) {
        self.level = level
        self.labels = labels
    }

    public static let exact = CheckTrust(level: .exact)
    public static let none = CheckTrust(level: .none)
}

/// One mode in a batch report.
public struct ModeFrequency: Codable, Hashable, Sendable {
    public var modeID: String
    public var name: String
    public var trust: CheckTrust.Level
    /// Accepted notes routed to the mode in this batch.
    public var seenInNotes: Int
    /// Done sessions of the batch the mode counts over (its project's only, for a
    /// project-scoped mode): the N of "checked of N".
    public var sessions: Int
    /// Sessions of the batch the check ran on, and its positives.
    public var checked: Int
    public var positive: Int
    /// Horvitz–Thompson weighted share, and the plain share next to it.
    public var weighted: Double?
    public var unweighted: Double?
    /// Rogan–Gladen corrected share (validated checks only).
    public var corrected: Double?
    /// 95% bootstrap interval of the reported share.
    public var interval: Stats.Interval?
    public var belowDetectionThreshold: Bool
    /// The weighted share among sessions that reached their goal, and among those that didn't.
    public var achieved: Double?
    public var notAchieved: Double?

    /// Whether the report may show a frequency for it; otherwise "seen in k notes".
    public var hasFrequency: Bool { trust == .exact || trust == .validated }
    /// As frequent in successful sessions as in failed ones: maybe not worth fixing.
    public var notWorthFixing: Bool {
        guard let achieved, let notAchieved, hasFrequency else { return false }
        return abs(achieved - notAchieved) < 0.05 && achieved > 0
    }
}

/// The transition matrix (after Bryan Bischof): the row is the phase of the step just before
/// the decisive step's action (before its call, for a tool result), the column the phase of
/// the decisive step; one more column counts sessions with no failure.
public struct TransitionMatrix: Codable, Hashable, Sendable {
    public static let noFailures = "no-failures"

    /// `row|column` → session keys.
    public var cells: [String: [String]]
    public var sessions: Int
    /// Sessions with accepted notes but no decisive step: failures the matrix can't place.
    public var unlocated: [String] = []

    public func count(_ row: Phase, _ column: String) -> Int { cells["\(row.rawValue)|\(column)"]?.count ?? 0 }
    public func sessions(_ row: Phase, _ column: String) -> [String] { cells["\(row.rawValue)|\(column)"] ?? [] }

    /// Deviations per phase (the decisive step's), for small N.
    public var funnel: [String: Int] {
        var result: [String: Int] = [:]
        for (key, keys) in cells {
            let column = String(key.split(separator: "|").last ?? "")
            result[column, default: 0] += keys.count
        }
        return result
    }

    public static func build(_ pool: [SessionNotes], phases: [String: SessionPhases]) -> TransitionMatrix {
        var cells: [String: [String]] = [:]
        var unlocated: [String] = []
        for notes in pool {
            let sessionPhases = phases[notes.sessionKey]
            if notes.noFailures {
                cells["\(Phase.report.rawValue)|\(noFailures)", default: []].append(notes.sessionKey)
                continue
            }
            guard let step = notes.deviation.decisiveStep else {
                unlocated.append(notes.sessionKey)
                continue
            }
            // The model may label only understand and plan; code labels the rest.
            let labeled = notes.notes.first { $0.step == step && ($0.phase == .understand || $0.phase == .plan) }?.phase
            let column = labeled ?? sessionPhases?.steps[step] ?? .understand
            let previous = sessionPhases?.before[step] ?? .understand
            cells["\(previous.rawValue)|\(column.rawValue)", default: []].append(notes.sessionKey)
        }
        return TransitionMatrix(cells: cells, sessions: pool.count, unlocated: unlocated)
    }

    /// One cell of a comparison of two runs: the change of its share, whether it is within
    /// noise (Fisher's exact p ≥ 0.05), and whether either side is too small to read.
    public struct Difference: Codable, Hashable, Sendable {
        public var before: Int
        public var after: Int
        public var change: Double
        public var withinNoise: Bool
        public var dimmed: Bool
    }

    public static let minimumCell = 3

    public static func difference(before: TransitionMatrix, after: TransitionMatrix) -> [String: Difference] {
        var result: [String: Difference] = [:]
        for key in Set(before.cells.keys).union(after.cells.keys) {
            let a = before.cells[key]?.count ?? 0, b = after.cells[key]?.count ?? 0
            let shareA = before.sessions > 0 ? Double(a) / Double(before.sessions) : 0
            let shareB = after.sessions > 0 ? Double(b) / Double(after.sessions) : 0
            let p = Stats.fisherExact(a, max(before.sessions, a), b, max(after.sessions, b))
            result[key] = Difference(before: a, after: b, change: shareB - shareA, withinNoise: p >= 0.05,
                                     dimmed: a < minimumCell && b < minimumCell)
        }
        return result
    }
}

/// What a batch report shows (`docs/design/error-analysis.md`, "Batch report").
public struct BatchReport: Codable, Hashable, Sendable {
    public var batchID: String
    public var coverage: [Int]
    public var notesVersion: String?
    /// The bootstrap recall of the notes model and prompt version the batch used, and its
    /// [found, the user's notes] (nil without bootstrap metrics for that version).
    public var notesRecall: Double?
    public var notesRecallCounts: [Int]?
    /// Share of the model's notes the verifier rejected, and [rejected, model notes].
    public var verifierRejection: Double?
    public var verifierRejectionCounts: [Int]
    /// The notes' precision from the user's spot checks of this batch's notes, and [agreed,
    /// checked].
    public var spotCheckPrecision: Double?
    public var spotCheckCounts: [Int]
    /// Routes the user accepted, of those reviewed.
    public var routeAcceptance: [Int]
    public var modes: [ModeFrequency]
    /// Share of accepted notes that matched no mode, and modes confirmed since the batch began.
    public var unmatchedShare: Double?
    public var newModes: [String]
    /// The same per project.
    public var projects: [String: Saturation]
    /// Suggest clustering all notes again from scratch.
    public var rebuild: String?
    public var matrix: TransitionMatrix
    /// Why the matrix and funnel are hidden, when they are.
    public var matrixHidden: String?
    /// Fewer than 50 sessions of the project in batches: a funnel instead of the matrix.
    public var showFunnel: Bool

    public struct Saturation: Codable, Hashable, Sendable {
        public var sessions: Int
        public var unmatchedShare: Double?
        public var newModes: Int
    }
}

public enum Reports {
    /// The phase agreement the matrix needs from the bootstrap.
    public static let phaseGate = 0.7
    public static let funnelBelow = 50
    public static let rebuildEvery = 5
    public static let rebuildUnmatched = 0.15

    /// The report of a batch, with everything `build` needs read from disk.
    public static func build(_ batch: Batch, env: HarnessEnvironment) async throws -> BatchReport {
        let modes = try await ModeStore(env: env).list()
        let pool = NotesStore(env: env).all()
        let labels = Bootstrap.LabelStore(env: env).all()
        let metrics = Bootstrap.metrics(labels: labels, notes: pool, pairings: Bootstrap.PairingStore(env: env).all(),
                                        phases: Bootstrap.phases(of: labels))
        return build(batch, modes: modes, pool: pool, checks: modes.compactMap { Validation.verdicts(modeID: $0.id, env: env) },
                     trust: Validation.trustMap(modes: modes, env: env), bootstrap: metrics, acceptance: Matching.acceptance(pool),
                     allBatches: BatchStore(env: env).all(), phases: phases(of: batch), spotChecks: LabelBookStore(env: env).load().spotChecks)
    }

    /// Builds the report of a batch. `trust` says how far each mode's check can be trusted;
    /// `checks` are the verdicts of code checks and judges; `spotChecks` the user's precision
    /// spot checks (`<session>#<note>` → agrees). A project-scoped mode counts over the
    /// batch's sessions of its project only, and is left out when the batch has none.
    public static func build(_ batch: Batch, modes: [Mode], pool: [SessionNotes], checks: [CheckResults], trust: [String: CheckTrust],
                             bootstrap: [Bootstrap.Metrics], acceptance: (accepted: Int, reviewed: Int), allBatches: [Batch],
                             phases: [String: SessionPhases], spotChecks: [String: Bool] = [:], seed: UInt64 = 1) -> BatchReport {
        let done = batch.sessions.filter { $0.status == .done }
        let keys = Set(done.map(\.pick.sessionKey))
        let notes = pool.filter { keys.contains($0.sessionKey) }
        let byKey = Dictionary(notes.map { ($0.sessionKey, $0) }, uniquingKeysWith: { first, _ in first })
        let picks = Dictionary(done.map { ($0.pick.sessionKey, $0.pick) }, uniquingKeysWith: { first, _ in first })
        let version = notes.first.map { Bootstrap.notesVersion($0.notesConfig) }
        let seen = Matching.seen(notes, modes: modes)

        var frequencies: [ModeFrequency] = []
        for mode in modes where mode.isCurrent && mode.status == .active {
            var scoped = keys
            if case .project(let project) = mode.scope {
                scoped = Set(done.filter { $0.pick.projectID == project }.map(\.pick.sessionKey))
                if scoped.isEmpty { continue }
            }
            let results = checks.first { $0.modeID == mode.id }
            let level = trust[mode.id]?.level ?? (CodeChecks.check(for: mode.id)?.kind == .mechanical ? .exact : CheckTrust.Level.none)
            var observations: [Stats.Observation] = []
            var byOutcome: [Bool: [Stats.Observation]] = [:]
            for key in scoped {
                guard let verdict = results?.verdicts[key], let pick = picks[key] else { continue }
                let observation = Stats.Observation(positive: verdict.positive, inclusion: pick.inclusion, group: pick.sampling)
                observations.append(observation)
                if let outcome = byKey[key]?.outcome, outcome != .unclear {
                    byOutcome[outcome == .achieved, default: []].append(observation)
                }
            }
            let weighted = Stats.weightedShare(observations)
            let labels = trust[mode.id]?.labels
            var corrected: Double?
            var below = false
            if level == .validated, let weighted, let tpr = labels?.tpr, let tnr = labels?.tnr {
                below = Stats.belowDetectionThreshold(observed: weighted, tnr: tnr)
                corrected = below ? nil : Stats.roganGladen(observed: weighted, tpr: tpr, tnr: tnr)
            }
            let interval = (level == .exact || level == .validated) && !below
                ? Stats.bootstrapInterval(observations, labels: level == .validated ? labels : nil, iterations: 1000, seed: seed) : nil
            let seenInNotes = seen.byMode[mode.id]?.filter { scoped.contains($0.sessionKey) }.count ?? 0
            frequencies.append(ModeFrequency(modeID: mode.id, name: mode.name, trust: level, seenInNotes: seenInNotes,
                                             sessions: scoped.count, checked: observations.count, positive: observations.filter(\.positive).count,
                                             weighted: weighted, unweighted: Stats.unweightedShare(observations), corrected: corrected,
                                             interval: interval, belowDetectionThreshold: below,
                                             achieved: byOutcome[true].flatMap(Stats.weightedShare),
                                             notAchieved: byOutcome[false].flatMap(Stats.weightedShare)))
        }
        frequencies.sort { ($0.hasFrequency ? 1 : 0, $0.weighted ?? 0, $0.seenInNotes) > ($1.hasFrequency ? 1 : 0, $1.weighted ?? 0, $1.seenInNotes) }

        let modelNotes = notes.flatMap { $0.notes.filter { $0.source == .model } }
        let rejected = modelNotes.filter { !$0.isAccepted }.count
        let refs = Set(notes.flatMap { review in review.notes.filter { $0.source == .model }.map { "\(review.sessionKey)#\($0.id)" } })
        let spotChecked = spotChecks.filter { refs.contains($0.key) }.values
        let spotAgreed = spotChecked.filter { $0 }.count
        let routed = notes.flatMap { Matching.currentRoutes($0).values }
        func unmatchedShare(_ subset: [SessionNotes]) -> Double? {
            let routes = subset.flatMap { Matching.currentRoutes($0).values }
            return routes.isEmpty ? nil : Double(routes.filter { $0.modeID == nil }.count) / Double(routes.count)
        }
        let newModes = modes.filter { mode in
            !mode.origin.isSeed && mode.status == .active && (mode.confirmedAt.map { $0 >= batch.createdAt } ?? false)
        }.map(\.id)
        var projects: [String: BatchReport.Saturation] = [:]
        for (project, members) in Dictionary(grouping: done, by: { $0.pick.projectID ?? "unbound" }) {
            let subset = members.compactMap { byKey[$0.pick.sessionKey] }
            let created = Set(batch.candidates)
            let newHere = subset.flatMap { Matching.currentRoutes($0).values.compactMap(\.modeID) }.filter(created.contains)
            projects[project] = BatchReport.Saturation(sessions: members.count, unmatchedShare: unmatchedShare(subset),
                                                       newModes: Set(newHere).count)
        }
        let unmatched = routed.isEmpty ? nil : Double(routed.filter { $0.modeID == nil }.count) / Double(routed.count)
        var rebuild: String?
        if let unmatched, unmatched > rebuildUnmatched {
            rebuild = String(format: "%.0f%% of the notes matched no mode (more than 15%%): cluster all notes again from scratch.", unmatched * 100)
        } else if let position = allBatches.sorted(by: { $0.createdAt < $1.createdAt }).firstIndex(where: { $0.runID == batch.runID }),
                  (position + 1) % rebuildEvery == 0 {
            rebuild = "Every \(rebuildEvery) runs, cluster all notes again from scratch to check the list."
        }

        let matrix = TransitionMatrix.build(notes, phases: phases)
        let measured = bootstrap.first { $0.notesVersion == version }
        let agreement = measured?.phaseAgreement
        var hidden: String?
        if let agreement, agreement < phaseGate {
            hidden = String(format: "Hidden: the bootstrap's phase agreement for %@ is %.0f%%, below 70%%.", version ?? "these notes", agreement * 100)
        } else if agreement == nil {
            hidden = "Hidden: no bootstrap phase agreement for \(version ?? "these notes") yet; label and pair bootstrap sessions first."
        }
        let projectSessions = allBatches.filter { $0.filter.project == batch.filter.project }.flatMap(\.sessions).filter { $0.status == .done }
        return BatchReport(batchID: batch.runID, coverage: [done.count, batch.sessions.count], notesVersion: version,
                           notesRecall: measured?.recall, notesRecallCounts: measured?.recallCounts,
                           verifierRejection: modelNotes.isEmpty ? nil : Double(rejected) / Double(modelNotes.count),
                           verifierRejectionCounts: [rejected, modelNotes.count],
                           spotCheckPrecision: spotChecked.isEmpty ? nil : Double(spotAgreed) / Double(spotChecked.count),
                           spotCheckCounts: [spotAgreed, spotChecked.count],
                           routeAcceptance: [acceptance.accepted, acceptance.reviewed], modes: frequencies,
                           unmatchedShare: unmatched, newModes: newModes, projects: projects, rebuild: rebuild, matrix: matrix,
                           matrixHidden: hidden, showFunnel: Set(projectSessions.map(\.pick.sessionKey)).count < funnelBelow)
    }

    /// The phases of every step of the batch's sessions, by code.
    public static func phases(of batch: Batch) -> [String: SessionPhases] {
        var result: [String: SessionPhases] = [:]
        for session in batch.sessions where session.status == .done {
            result[session.pick.sessionKey] = PhaseClassifier.session(sessionKey: session.pick.sessionKey, transcript: session.pick.file)
        }
        return result
    }
}
