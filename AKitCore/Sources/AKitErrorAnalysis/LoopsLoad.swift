import AKitFoundation
import AKitInsights
import Foundation

/// The stuck loops report for `akit stats loops` and the Insights screen: the signals scan first
/// (it finds the loops of files changed since the last scan), then the report. When another
/// import holds the lock, the report reads the index as it is.
public enum LoopsLoad {
    public static func report(env: HarnessEnvironment, days: Int = InsightsStats.defaultDays, range: DayRange? = nil,
                              project: String? = nil, bindings: BindingSet = .default, now: Date = Date()) throws -> LoopsReport {
        let paths = InsightsPaths(env: env)
        if let lock = try ImportLock.acquire(paths.lock) {
            defer { withExtendedLifetime(lock) {} }
            try SignalScanner.refresh(env: env)
        }
        guard let database = try AnalysisIndex.open(env: env) else {
            return .empty(days: range?.days() ?? days, project: project)
        }
        return try LoopsReport.report(database, days: days, range: range, project: project, bindings: bindings, now: now)
    }
}
