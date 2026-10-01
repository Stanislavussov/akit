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
    /// Numerical integration over the "before" density; exact enough for n up to thousands.
    public static func probabilityLower(after kAfter: Int, of nAfter: Int, before kBefore: Int, of nBefore: Int,
                                        steps: Int = 4000) -> Double {
        let aA = Double(kAfter + 1), bA = Double(nAfter - kAfter + 1)
        let aB = Double(kBefore + 1), bB = Double(nBefore - kBefore + 1)
        // ∫ f_before(x) · F_after(x) dx, midpoint rule.
        var total = 0.0
        let h = 1.0 / Double(steps)
        for i in 0..<steps {
            let x = (Double(i) + 0.5) * h
            total += betaDensity(x, aB, bB) * regularizedIncompleteBeta(x, aA, bA) * h
        }
        return min(1, max(0, total))
    }

    static func betaDensity(_ x: Double, _ a: Double, _ b: Double) -> Double {
        exp((a - 1) * log(x) + (b - 1) * log(1 - x) - logBeta(a, b))
    }

    static func logBeta(_ a: Double, _ b: Double) -> Double { lgamma(a) + lgamma(b) - lgamma(a + b) }

    /// I_x(a, b) by its continued fraction (Numerical Recipes, betacf).
    static func regularizedIncompleteBeta(_ x: Double, _ a: Double, _ b: Double) -> Double {
        if x <= 0 { return 0 }
        if x >= 1 { return 1 }
        let front = exp(a * log(x) + b * log(1 - x) - logBeta(a, b))
        if x < (a + 1) / (a + b + 2) { return front * continuedFraction(x, a, b) / a }
        return 1 - front * continuedFraction(1 - x, b, a) / b
    }

    private static func continuedFraction(_ x: Double, _ a: Double, _ b: Double) -> Double {
        let tiny = 1e-300
        var c = 1.0
        var d = 1 - (a + b) * x / (a + 1)
        if abs(d) < tiny { d = tiny }
        d = 1 / d
        var result = d
        for m in 1...300 {
            let m = Double(m)
            var numerator = m * (b - m) * x / ((a + 2 * m - 1) * (a + 2 * m))
            d = 1 + numerator * d
            if abs(d) < tiny { d = tiny }
            c = 1 + numerator / c
            if abs(c) < tiny { c = tiny }
            d = 1 / d
            result *= d * c
            numerator = -(a + m) * (a + b + m) * x / ((a + 2 * m) * (a + 2 * m + 1))
            d = 1 + numerator * d
            if abs(d) < tiny { d = tiny }
            c = 1 + numerator / c
            if abs(c) < tiny { c = tiny }
            d = 1 / d
            let step = d * c
            result *= step
            if abs(step - 1) < 1e-12 { break }
        }
        return result
    }
}
