import Foundation

/// ≈ tokens of text that sits in every request, from its length. Only an estimate: characters / k,
/// with k per script. Recorded token counts are never replaced by it.
enum ContextSize {
    enum Script: String {
        case latin, cyrillic
    }

    /// An estimated token count. Always approximate, so every output marks it with “≈”.
    struct Estimate: Equatable {
        let tokens: Int
        var isApprox: Bool { true }
    }

    /// Characters per token for each script, and where the numbers come from.
    struct Calibration: Equatable {
        let latin: Double
        let cyrillic: Double
        /// Before/after pairs the numbers come from; 0 for the defaults.
        let pairs: Int

        var isCalibrated: Bool { pairs >= ContextSize.minimumPairs }

        func k(_ script: Script) -> Double {
            switch script {
            case .latin: latin
            case .cyrillic: cyrillic
            }
        }

        /// Which k an output used.
        var describe: String {
            let values = "k \(String(format: "%.1f", latin)) Latin, \(String(format: "%.1f", cyrillic)) Cyrillic"
            return isCalibrated ? "\(values), calibrated from \(pairs) before/after pairs"
                : "\(values), defaults until before/after measurements calibrate them"
        }
    }

    static let defaults = Calibration(latin: 4.0, cyrillic: 2.5, pairs: 0)
    /// A calibration is used only when it rests on at least this many pairs.
    static let minimumPairs = 2

    /// `meta` keys `k.latin`, `k.cyrillic`, `k.pairs` (written by the before/after calibration);
    /// the defaults when missing, not positive or from fewer than two pairs.
    static func calibration(_ database: IndexDatabase) throws -> Calibration {
        var values: [String: Double] = [:]
        for row in try database.rows("SELECT key, value FROM meta WHERE key IN ('k.latin', 'k.cyrillic', 'k.pairs')") {
            if let key = row[0].text, let value = row[1].text.flatMap(Double.init) { values[key] = value }
        }
        guard let latin = values["k.latin"], let cyrillic = values["k.cyrillic"], let pairs = values["k.pairs"],
              latin > 0, cyrillic > 0, Int(pairs) >= minimumPairs else { return defaults }
        return Calibration(latin: latin, cyrillic: cyrillic, pairs: Int(pairs))
    }

    /// Cyrillic when at least half of the letters are Cyrillic, else Latin.
    static func script(of text: String) -> Script {
        var letters = 0, cyrillic = 0
        for scalar in text.unicodeScalars where scalar.properties.isAlphabetic {
            letters += 1
            if (0x0400...0x052F).contains(scalar.value) { cyrillic += 1 }
        }
        return letters > 0 && cyrillic * 2 >= letters ? .cyrillic : .latin
    }

    static func approxTokens(chars: Int, script: Script, calibration: Calibration = defaults) -> Estimate {
        Estimate(tokens: chars <= 0 ? 0 : Int((Double(chars) / calibration.k(script)).rounded()))
    }
}
