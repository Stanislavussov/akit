import AKitBrain
import AKitFoundation
import Foundation

/// What `akit recommend` and the Insights screen share, so both show the same report.
extension Recommender {
    /// The index, opened and brought up to date, with everything the rule needs besides it.
    public static func prepare(env: HarnessEnvironment, brain: Brain?, project: String?, projectsRoot: URL, hostName: String,
                               hardware: String?, run: CommandRunner? = nil) async throws -> (database: IndexDatabase, inputs: Inputs) {
        let database = try IndexSchema.open(InsightsPaths(env: env).database)
        let imported = try await QuickImport.run(env: env, projectsRoot: projectsRoot, database: database)
        var inputs = try await inputs(env: env, database: database, brain: brain, project: project, projectsRoot: projectsRoot,
                                      hostName: hostName, hardware: hardware, run: run)
        inputs.stats.importNotes = imported.notes
        return (database, inputs)
    }

    /// The Insights screen's data.
    public struct Loaded: Sendable {
        /// Every recommendation of the scope (no top N).
        public let report: RecommendReport
        /// Projects the scope picker offers.
        public let projects: [String]
        public let lastImport: Date?
    }

    /// A quick import, then the report of a scope (`project` nil: every session on every Mac).
    public static func load(env: HarnessEnvironment, brain: Brain?, project: String?, projectsRoot: URL,
                            hostName: String = ProcessInfo.processInfo.hostName,
                            hardware: String? = MachineProfile.currentHardwareHash(), run: CommandRunner? = nil) async throws -> Loaded {
        let (database, inputs) = try await prepare(env: env, brain: brain, project: project, projectsRoot: projectsRoot,
                                                   hostName: hostName, hardware: hardware, run: run)
        let options = Options(project: project, top: nil)
        return Loaded(report: try recommend(database, options: options, inputs: inputs),
                      projects: try knownProjects(database, brain: brain, home: env.homeDirectory, bindings: options.bindings),
                      lastImport: inputs.lastImport)
    }

    /// Projects whose layers bring this one (the brain's and this Mac's records), home folders included:
    /// a layer patch takes effect there only after they are set up again.
    public static func projectsUsing(_ layer: String, brain: Brain, home: URL) -> [String] {
        let saved = BrainRemove.savedAnswers(brain: brain, home: home)
        return Set(saved.filter { brain.layers(of: Brain.Project(id: $0.id, answers: $0.answers, brainCommit: nil)).contains(layer) }
            .map(\.id)).sorted()
    }
}
