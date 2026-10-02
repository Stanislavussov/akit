import Foundation

/// Small-sample statistics of error analysis. Plain functions: the numbers in the design
/// (Wilson bounds, Fisher's p, Beta posteriors) are checked against them in tests.
public enum Stats {
    public struct Interval: Codable, Hashable, Sendable {
        public let low: Double
        public let high: Double

        public init(low: Double, high: Double) {
            self.low = low
            self.high = high
        }
    }

    /// The Wilson score interval of k successes in n (95% by default). n = 0 gives [0, 1].
    public static func wilson(_ k: Int, _ n: Int, z: Double = 1.959964) -> Interval {
        guard n > 0 else { return Interval(low: 0, high: 1) }
        let p = Double(k) / Double(n)
        let n = Double(n)
        let denominator = 1 + z * z / n
        let centre = (p + z * z / (2 * n)) / denominator
        let half = z * ((p * (1 - p) / n + z * z / (4 * n * n)).squareRoot()) / denominator
        return Interval(low: max(0, centre - half), high: min(1, centre + half))
    }

    /// log of n choose k.
    static func logChoose(_ n: Int, _ k: Int) -> Double {
        lgamma(Double(n + 1)) - lgamma(Double(k + 1)) - lgamma(Double(n - k + 1))
    }

    /// Two-sided Fisher's exact test of a 2×2 table: a of n1 against b of n2. The p-value sums
    /// the tables with the same margins that are no more likely than the observed one.
    public static func fisherExact(_ a: Int, _ n1: Int, _ b: Int, _ n2: Int) -> Double {
        let total = a + b
        let n = n1 + n2
        func probability(_ x: Int) -> Double {
            exp(logChoose(n1, x) + logChoose(n2, total - x) - logChoose(n, total))
        }
        let observed = probability(a)
        let low = max(0, total - n2)
        let high = min(total, n1)
        guard low <= high else { return 1 }
        var p = 0.0
        for x in low...high {
            let value = probability(x)
            if value <= observed * (1 + 1e-7) { p += value }
        }
        return min(1, p)
    }

    /// P(rate_after < rate_before) with Beta(1,1) priors: k failures of n before and after.
    /// The exact finite sum for integer Beta parameters (Evan Miller's formula for
    /// P(p_B > p_A)), in log space, so it holds for thousands of sessions and rates near 0.
    public static func probabilityLower(after kAfter: Int, of nAfter: Int, before kBefore: Int, of nBefore: Int) -> Double {
        // B = before, A = after: P(p_B > p_A).
        let aA = Double(kAfter + 1), bA = Double(nAfter - kAfter + 1)
        let aB = kBefore + 1
        let bB = Double(nBefore - kBefore + 1)
        var total = 0.0
        for i in 0..<aB {
            let i = Double(i)
            total += exp(logBeta(aA + i, bA + bB) - log(bB + i) - logBeta(1 + i, bB) - logBeta(aA, bA))
        }
        return min(1, max(0, total))
    }

    static func logBeta(_ a: Double, _ b: Double) -> Double { lgamma(a) + lgamma(b) - lgamma(a + b) }

    // MARK: Frequencies

    /// One sampled session's check result and its inclusion probability.
    public struct Observation: Codable, Hashable, Sendable {
        public var positive: Bool
        public var inclusion: Double
        /// The sampling group it was drawn in (`random`, `stratum:…`): bootstrap resamples within it.
        public var group: String

        public init(positive: Bool, inclusion: Double, group: String) {
            self.positive = positive
            self.inclusion = inclusion
            self.group = group
        }
    }

    /// The share of positives weighted by inverse inclusion probability (Horvitz–Thompson,
    /// in its ratio form: Σ y/π ÷ Σ 1/π). nil without observations.
    public static func weightedShare(_ observations: [Observation]) -> Double? {
        let weights = observations.map { 1 / max($0.inclusion, 1e-9) }
        let total = weights.reduce(0, +)
        guard total > 0 else { return nil }
        return zip(observations, weights).filter { $0.0.positive }.map(\.1).reduce(0, +) / total
    }

    public static func unweightedShare(_ observations: [Observation]) -> Double? {
        observations.isEmpty ? nil : Double(observations.filter(\.positive).count) / Double(observations.count)
    }

    /// Rogan–Gladen: the true share from the observed one and the check's TPR and TNR,
    /// θ = (p_obs + TNR − 1) / (TPR + TNR − 1), clipped to [0, 1]. nil when the check is no
    /// better than chance.
    public static func roganGladen(observed: Double, tpr: Double, tnr: Double) -> Double? {
        let denominator = tpr + tnr - 1
        guard denominator > 1e-9 else { return nil }
        return min(1, max(0, (observed + tnr - 1) / denominator))
    }

    /// p_obs at or below the check's false positive rate: no number can be told from noise.
    public static func belowDetectionThreshold(observed: Double, tnr: Double) -> Bool { observed <= 1 - tnr }

    /// The test labels behind a validated check's TPR and TNR: verdicts on sessions the human
    /// labeled positive, and on ones labeled negative (true = the check said positive).
    public struct CheckLabels: Codable, Hashable, Sendable {
        public var onPositives: [Bool]
        public var onNegatives: [Bool]

        public init(onPositives: [Bool], onNegatives: [Bool]) {
            self.onPositives = onPositives
            self.onNegatives = onNegatives
        }

        public var tpr: Double? { onPositives.isEmpty ? nil : Double(onPositives.filter { $0 }.count) / Double(onPositives.count) }
        public var tnr: Double? { onNegatives.isEmpty ? nil : Double(onNegatives.filter { !$0 }.count) / Double(onNegatives.count) }
    }

    /// A 95% interval by bootstrap: resamples the batch within its sampling groups and, for a
    /// validated check, the test labels behind TPR and TNR, then takes the 2.5th and 97.5th
    /// percentiles of the (corrected) weighted share.
    public static func bootstrapInterval(_ observations: [Observation], labels: CheckLabels? = nil, iterations: Int = 2000,
                                         seed: UInt64 = 1) -> Interval? {
        guard !observations.isEmpty, iterations > 0 else { return nil }
        var generator = SeededGenerator(seed: seed)
        let groups = resamplingGroups(observations)
        var estimates: [Double] = []
        estimates.reserveCapacity(iterations)
        func resample<T>(_ values: [T]) -> [T] {
            (0..<values.count).map { _ in values[Int.random(in: 0..<values.count, using: &generator)] }
        }
        for _ in 0..<iterations {
            let sample = groups.flatMap { resample($0) }
            guard var estimate = weightedShare(sample) else { continue }
            if let labels {
                let positives = resample(labels.onPositives)
                let negatives = resample(labels.onNegatives)
                guard let tpr = CheckLabels(onPositives: positives, onNegatives: negatives).tpr,
                      let tnr = CheckLabels(onPositives: positives, onNegatives: negatives).tnr else { continue }
                // A resample whose check is no better than chance clips instead of being
                // dropped, which would narrow the interval.
                let denominator = max(tpr + tnr - 1, 1e-6)
                estimate = min(1, max(0, (estimate + tnr - 1) / denominator))
            }
            estimates.append(estimate)
        }
        guard !estimates.isEmpty else { return nil }
        estimates.sort()
        func percentile(_ p: Double) -> Double { estimates[min(estimates.count - 1, max(0, Int((p * Double(estimates.count)).rounded(.down))))] }
        return Interval(low: percentile(0.025), high: percentile(0.975))
    }

    /// The sampling groups the bootstrap resamples within, in a fixed order so the same seed
    /// gives the same interval. A group of one never varies when resampled, and stratified
    /// picks spread over many strata leave most groups that small, so the interval would come
    /// out too narrow. Groups with fewer than 2 picks are collapsed into one (the collapsed
    /// strata method of survey sampling for strata with a single unit); a collapsed group
    /// that is still alone joins the smallest other group.
    static func resamplingGroups(_ observations: [Observation]) -> [[Observation]] {
        let sorted = Dictionary(grouping: observations, by: \.group).sorted { $0.key < $1.key }.map(\.value)
        var groups = sorted.filter { $0.count >= 2 }
        let collapsed = sorted.filter { $0.count < 2 }.flatMap { $0 }
        if collapsed.count == 1, let smallest = groups.indices.min(by: { groups[$0].count < groups[$1].count }) {
            groups[smallest] += collapsed
        } else if !collapsed.isEmpty {
            groups.append(collapsed)
        }
        return groups
    }
}
