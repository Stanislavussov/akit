import AKitFoundation
import Foundation

/// What the user is asked after each run (`docs/design/error-analysis.md`, "Human in the
/// loop"): only candidates, merge or split proposals, low-confidence routes, checks' tough
/// calls and a few random notes for a precision spot check. Confirmed modes with familiar
/// exemplars aren't asked again.
public struct ReviewQueue: Sendable {
    public struct ToughCall: Hashable, Sendable {
        public let modeID: String
        public let sessionKey: String
        public let verdict: CheckVerdict
    }

    /// A seed that takes an unusually large share of the routed notes: maybe an umbrella.
    public struct Umbrella: Hashable, Sendable {
        public let modeID: String
        public let notes: Int
        public let share: Double
    }

    public var candidates: [Mode]
    public var routes: [(ref: NoteRef, route: Route)]
    public var toughCalls: [ToughCall]
    public var spotChecks: [NoteRef]
    public var umbrellas: [Umbrella]

    public var isEmpty: Bool { candidates.isEmpty && routes.isEmpty && toughCalls.isEmpty && spotChecks.isEmpty && umbrellas.isEmpty }
    public var count: Int { candidates.count + routes.count + toughCalls.count + spotChecks.count + umbrellas.count }

    /// A seed is flagged when it absorbs more than this share of at least `umbrellaMinimum` notes.
    public static let umbrellaShare = 0.3
    public static let umbrellaMinimum = 10

    /// `spotCheck` are the notes picked for the latest run's precision spot check.
    public static func build(modes: [Mode], pool: [SessionNotes], checks: [CheckResults], book: LabelBook, spotCheck: [NoteRef] = [])
        -> ReviewQueue {
        let tough = checks.flatMap { results in
            results.verdicts.filter { key, verdict in verdict.toughCall && book.toughCalls["\(results.modeID)|\(key)"] == nil }
                .map { ToughCall(modeID: results.modeID, sessionKey: $0.key, verdict: $0.value) }
        }.sorted { ($0.modeID, $0.sessionKey) < ($1.modeID, $1.sessionKey) }
        let seen = Matching.seen(pool, modes: modes).byMode
        let routed = seen.values.map(\.count).reduce(0, +)
        let umbrellas = modes.filter { $0.origin.isSeed && $0.isCurrent }.compactMap { mode -> Umbrella? in
            let count = seen[mode.id]?.count ?? 0
            guard routed > 0, count >= umbrellaMinimum else { return nil }
            let share = Double(count) / Double(routed)
            return share > umbrellaShare ? Umbrella(modeID: mode.id, notes: count, share: share) : nil
        }
        return ReviewQueue(candidates: modes.filter { $0.status == .candidate },
                           routes: Matching.waitingRoutes(pool), toughCalls: tough,
                           spotChecks: spotCheck.filter { book.spotChecks[$0.description] == nil }, umbrellas: umbrellas)
    }

    /// 5–10 random accepted model notes of a run, for the precision spot check.
    public static func pickSpotCheck<G: RandomNumberGenerator>(_ pool: [SessionNotes], count: Int = 8, using generator: inout G) -> [NoteRef] {
        let refs = pool.flatMap { notes in notes.accepted.filter { $0.source == .model }.map { NoteRef(sessionKey: notes.sessionKey, noteID: $0.id) } }
        return Array(refs.sorted().shuffled(using: &generator).prefix(count))
    }
}
