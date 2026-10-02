import AKitFoundation
import Foundation

/// What error analysis keeps current after every session import: the cheap signals, and the
/// code checks of active modes over the new sessions. Local, nothing is sent. Does nothing
/// until error analysis is in use (its modes repository exists).
public enum AnalysisUpkeep {
    /// A line for the import's output, or nil when nothing ran.
    public static func afterImport(env: HarnessEnvironment) async -> String? {
        guard FileManager.default.fileExists(atPath: AnalysisPaths(env: env).modesFile.path) else { return nil }
        do {
            try SignalScanner.refresh(env: env)
            let active = try await ModeStore(env: env).list().filter { $0.isCurrent && $0.status == .active }
            let checks = active.compactMap { mode in CodeChecks.check(for: mode.id).map { (mode, $0) } }
            guard !checks.isEmpty else { return nil }
            try CheckRunner.run(checks.map(\.1), modeVersions: Dictionary(uniqueKeysWithValues: checks.map { ($0.0.id, $0.0.version) }), env: env)
            return "Ran the code checks of \(checks.count) active modes over new sessions."
        } catch {
            return "Error analysis upkeep failed: \(error.localizedDescription)"
        }
    }
}
