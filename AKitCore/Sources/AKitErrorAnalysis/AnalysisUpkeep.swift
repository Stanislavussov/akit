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
            let checked = try runChecks(of: try await ModeStore(env: env).list(), env: env)
            guard !checked.isEmpty else { return nil }
            return "Ran the code checks of \(checked.count) active modes over new sessions."
        } catch {
            return "Error analysis upkeep failed: \(error.localizedDescription)"
        }
    }

    /// Runs the code checks of the current, active modes (after an import and at the end of a
    /// batch), each at its mode's version. Returns the ids of the modes checked.
    static func runChecks(of modes: [Mode], env: HarnessEnvironment) throws -> [String] {
        let checks = activeChecks(modes)
        guard !checks.isEmpty else { return [] }
        try CheckRunner.run(checks.map(\.check), modeVersions: Dictionary(uniqueKeysWithValues: checks.map { ($0.mode.id, $0.mode.version) }),
                            env: env)
        return checks.map(\.mode.id)
    }

    /// Merged and rejected modes have no checks of their own.
    static func activeChecks(_ modes: [Mode]) -> [(mode: Mode, check: CodeCheck)] {
        modes.filter { $0.isCurrent && $0.status == .active }.compactMap { mode in CodeChecks.check(for: mode.id).map { (mode, $0) } }
    }
}
