import Foundation

/// k (characters per token) per script from before/after pairs: the median over the accepted
/// pairs of that script, stored in the index's `meta` (read by `ContextSize.calibration`). A
/// script with fewer than two accepted pairs keeps its default.
public enum ContextCalibration {
    /// A pair counts only when this many description characters changed, so the noise of the
    /// sessions' own first requests doesn't decide k.
    static let minChars = 400
    /// k outside this range is noise, not a tokenizer.
    static let plausible = 1.0...10.0

    /// The pairs that calibrate: measured, with a k, enough characters changed and a plausible k.
    static func accepted(_ changes: [ChangesReport.Change]) -> [(script: ContextSize.Script, k: Double)] {
        changes.compactMap { change in
            guard change.isMeasured, let k = change.k, abs(change.deltaChars ?? 0) >= minChars, plausible.contains(k),
                  let script = change.script.flatMap(ContextSize.Script.init(rawValue:)) else { return nil }
            return (script, k)
        }
    }

    public static func calibration(from changes: [ChangesReport.Change]) -> ContextSize.Calibration {
        let pairs = accepted(changes)
        let latin = pairs.filter { $0.script == .latin }.map(\.k), cyrillic = pairs.filter { $0.script == .cyrillic }.map(\.k)
        let enough = ContextSize.minimumPairs
        let used = (latin.count >= enough ? latin.count : 0) + (cyrillic.count >= enough ? cyrillic.count : 0)
        guard used > 0 else {
            return .init(latin: ContextSize.defaults.latin, cyrillic: ContextSize.defaults.cyrillic, pairs: 0, latinPairs: latin.count,
                         cyrillicPairs: cyrillic.count)
        }
        return .init(latin: latin.count >= enough ? median(latin) : ContextSize.defaults.latin,
                     cyrillic: cyrillic.count >= enough ? median(cyrillic) : ContextSize.defaults.cyrillic,
                     pairs: used, latinPairs: latin.count, cyrillicPairs: cyrillic.count)
    }

    /// Replaces the stored calibration; without calibrated scripts the defaults apply again.
    public static func save(_ calibration: ContextSize.Calibration, database: IndexDatabase) throws {
        try database.transaction {
            try database.run("DELETE FROM meta WHERE key IN ('k.latin', 'k.cyrillic', 'k.pairs', 'k.latin.pairs', 'k.cyrillic.pairs')")
            guard calibration.isCalibrated else { return }
            let values: [(String, String)] = [
                ("k.latin", "\(calibration.latin)"), ("k.cyrillic", "\(calibration.cyrillic)"), ("k.pairs", "\(calibration.pairs)"),
                ("k.latin.pairs", "\(calibration.latinPairs ?? 0)"), ("k.cyrillic.pairs", "\(calibration.cyrillicPairs ?? 0)"),
            ]
            for (key, value) in values { try database.run("INSERT INTO meta(key, value) VALUES(?, ?)", key, value) }
        }
    }

    /// For the report: the k in use and each script's accepted pairs.
    public static func summary(_ calibration: ContextSize.Calibration) -> ChangesReport.Calibration {
        .init(latin: calibration.latin, cyrillic: calibration.cyrillic, pairs: calibration.pairs,
              latinPairs: calibration.latinPairs ?? calibration.pairs, cyrillicPairs: calibration.cyrillicPairs ?? calibration.pairs,
              source: calibration.isCalibrated ? "calibrated" : "defaults")
    }

    static func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return 0 }
        let middle = sorted.count / 2
        let value = sorted.count % 2 == 1 ? sorted[middle] : (sorted[middle - 1] + sorted[middle]) / 2
        return (value * 100).rounded() / 100
    }
}
