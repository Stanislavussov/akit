import AKitFoundation
import AKitInsights
import Foundation

/// Which sessions a batch looks at (`docs/design/error-analysis.md`, "Sampling"): a random
/// share so quiet failures are still seen, the rest stratified by the cheap signals, the
/// harness and the model. Every pick records its inclusion probability, so reports can weight
/// it back (Horvitz–Thompson).
public enum Sampling {
    /// Strata of sessions whose ad-hoc review (not a batch) found accepted notes: where the
    /// next batch should look for more like them.
    public static func hintedStrata(pool: [SessionNotes], batches: [Batch], sessions: [IndexedSession],
                                    signals: [String: SessionSignals]) -> Set<String> {
        let batchRuns = Set(batches.map(\.runID))
        let flagged = Set(pool.filter { !$0.noFailures && !($0.runID.map(batchRuns.contains) ?? false) }.map(\.sessionKey))
        return Set(sessions.filter { flagged.contains($0.key) }.map { stratum($0, signals[$0.key]) })
    }

    public struct Filter: Codable, Hashable, Sendable {
        /// A bound project id, or a folder the session ran in (prefix).
        public var project: String?
        public var from: Date?
        public var to: Date?
        /// The harness that ran the sessions, as the index names it: `claude` or `pi`.
        public var harness: String?

        public init(project: String? = nil, from: Date? = nil, to: Date? = nil, harness: String? = nil) {
            self.project = project
            self.from = from
            self.to = to
            self.harness = harness
        }
    }

    /// One picked session.
    public struct Pick: Codable, Hashable, Sendable {
        public var sessionKey: String
        public var file: String
        /// The probability that this sampling design picks the session.
        public var inclusion: Double
        /// `random`, or `stratum:<key>`: how it was chosen. Bootstrap intervals resample
        /// within these groups (those with a single pick collapsed into one).
        public var sampling: String
        /// The stratum the session belongs to (also for random picks).
        public var stratum: String
        public var projectID: String?
    }

    /// Sessions with fewer requests are skipped: too short to go wrong in interesting ways.
    public static let minimumRequests = 5
    public static let randomShare = 0.25

    /// The stratum of a session: harness, model family and the strongest signal it raises.
    public static func stratum(_ session: IndexedSession, _ signals: SessionSignals?) -> String {
        let model = session.model.map(family) ?? "unknown"
        let signal: String
        if let signals {
            if signals.interrupts > 0 || signals.pushbacks > 0 {
                signal = "pushback"
            } else if signals.unverifiedDone {
                signal = "unverified-done"
            } else if signals.repeatedCalls > 0 {
                signal = "repeats"
            } else if signals.toolErrors > 0 {
                signal = "tool-errors"
            } else {
                signal = "quiet"
            }
        } else {
            signal = "no-signals"
        }
        return "\(session.harness)|\(model)|\(signal)"
    }

    /// `claude-opus-5-5` → `claude-opus`, `github-copilot/gpt-6.1-sol` → `gpt`: strata by family,
    /// not by every version. Bedrock's region and provider go first:
    /// `us.anthropic.claude-opus-4-v1:0` → `claude-opus`.
    static func family(_ model: String) -> String {
        var name = model.split(separator: "/").last.map(String.init) ?? model
        while let match = name.prefixMatch(of: /[A-Za-z]+\.(?=[A-Za-z])/) { name = String(name[match.range.upperBound...]) }
        let parts = name.split(separator: "-")
        guard let first = parts.first else { return name }
        if first == "claude", parts.count > 1 { return "claude-\(parts[1])" }
        return String(first.prefix { $0.isLetter })
    }

    /// The sessions a filter allows, before sampling.
    public static func population(_ sessions: [IndexedSession], filter: Filter, reserved: Set<String>) -> [IndexedSession] {
        sessions.filter { session in
            guard session.file != nil, session.requests >= minimumRequests, !reserved.contains(session.key) else { return false }
            if let harness = filter.harness, session.harness != harness { return false }
            if let project = filter.project {
                let bound = session.projectID == project
                let ranThere = session.cwd.map { $0 == project || $0.hasPrefix(project.hasSuffix("/") ? project : project + "/") } ?? false
                guard bound || ranThere else { return false }
            }
            let date = session.started ?? session.lastActivity
            if let from = filter.from, let date, date < from { return false }
            if let to = filter.to, let date, date > to { return false }
            return true
        }
    }

    /// Picks up to `size` sessions: `randomShare` of them uniformly from the population, the
    /// rest spread evenly over the strata (rare strata get as many as common ones, up to their
    /// size). Inclusion probability of a session in stratum h of size N_h, with r random picks
    /// of M sessions and n_h stratified picks: π ≈ r/M + n_h/N_h (capped at 1).
    /// `hinted`: strata in which ad-hoc reviews found failures; each gets one stratified pick
    /// first, so the next batch adds sessions like them.
    public static func sample<G: RandomNumberGenerator>(_ population: [IndexedSession], signals: [String: SessionSignals], size: Int,
                                                        hinted: Set<String> = [], using generator: inout G) -> [Pick] {
        guard size > 0, !population.isEmpty else { return [] }
        let size = min(size, population.count)
        let strata = Dictionary(grouping: population) { stratum($0, signals[$0.key]) }
        let random = min(size, max(1, Int((Double(size) * randomShare).rounded())))
        var chosen: [String: String] = [:] // key → how it was chosen
        for session in population.shuffled(using: &generator).prefix(random) { chosen[session.key] = "random" }

        // Even allocation, then whatever a small stratum can't use goes to the others.
        var left = size - random
        var allocation = Dictionary(uniqueKeysWithValues: strata.keys.map { ($0, 0) })
        for key in hinted.sorted() where left > 0 {
            guard let members = strata[key], members.contains(where: { chosen[$0.key] == nil }) else { continue }
            allocation[key, default: 0] += 1
            left -= 1
        }
        var open = strata.keys.sorted()
        while left > 0, !open.isEmpty {
            var progressed = false
            for key in open where left > 0 {
                let available = strata[key]!.filter { chosen[$0.key] == nil }.count
                if allocation[key]! < available {
                    allocation[key]! += 1
                    left -= 1
                    progressed = true
                }
            }
            open = open.filter { key in allocation[key]! < strata[key]!.filter { chosen[$0.key] == nil }.count }
            if !progressed { break }
        }
        // Strata in a fixed order, so the same seed gives the same sample.
        for (key, members) in strata.sorted(by: { $0.key < $1.key }) {
            let candidates = members.filter { chosen[$0.key] == nil }.shuffled(using: &generator)
            for session in candidates.prefix(allocation[key] ?? 0) { chosen[session.key] = "stratum:\(key)" }
        }

        let total = Double(population.count)
        return population.compactMap { session -> Pick? in
            guard let how = chosen[session.key], let file = session.file else { return nil }
            let key = stratum(session, signals[session.key])
            let size = Double(strata[key]?.count ?? 1)
            let inclusion = min(1, Double(random) / total + Double(allocation[key] ?? 0) / size)
            return Pick(sessionKey: session.key, file: file, inclusion: inclusion, sampling: how, stratum: key, projectID: session.projectID)
        }
    }
}

/// A random generator with a seed, so a batch's sample (and a bootstrap) can be reproduced.
public struct SeededGenerator: RandomNumberGenerator, Sendable {
    private var state: UInt64

    public init(seed: UInt64) { state = seed == 0 ? 0x9E37_79B9_7F4A_7C15 : seed }

    /// SplitMix64.
    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
