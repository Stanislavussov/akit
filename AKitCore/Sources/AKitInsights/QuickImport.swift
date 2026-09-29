import AKitFoundation
import Foundation

/// `stats` and `recommend` first bring the index up to date: an import and project bindings
/// with a short time budget under the import lock (checked between lines: a large file is read over several runs). When another importer holds the lock, the index is read as
/// it is and a note says how old it is.
public enum QuickImport {
    public static let budget: TimeInterval = 5

    public struct Outcome: Equatable {
        /// For the reader: a running import, files left for later, files skipped.
        public let notes: [String]
        /// Another importer held the lock; the index was read as it was.
        public let running: Bool
    }

    public static func run(env: HarnessEnvironment, projectsRoot: URL, database: IndexDatabase, budget: TimeInterval = budget,
                    now: Date = Date()) async throws -> Outcome {
        guard let lock = try ImportLock.acquire(InsightsPaths(env: env).lock) else {
            let last = try database.value("SELECT MAX(imported_at) FROM sources")?.double
            return Outcome(notes: ["import running; data up to \(last.map { Date(timeIntervalSince1970: $0).formatted(.iso8601) } ?? "no import yet")"],
                           running: true)
        }
        defer { withExtendedLifetime(lock) {} }
        let report = try await SessionImporter.importAndBind(env: env, projectsRoot: projectsRoot, database: database, now: now,
                                                             budget: budget)
        var notes: [String] = []
        if report.pending > 0 {
            notes.append("import stopped after \(Int(budget)) s; \(report.pending) files left, run akit sessions import")
        }
        if report.bindingsPending > 0 {
            notes.append("\(report.bindingsPending) sessions not bound to a project yet; run akit sessions import")
        }
        notes += report.skipped.map { "skipped \($0.path): \($0.reason)" }
        return Outcome(notes: notes, running: false)
    }
}
