import AKitBrain
import AKitFoundation
import Foundation

/// The brain sync of `akit sync` and the app's Sync button: a quick import, this Mac's usage
/// summaries published to the brain, then pull and push. A publish that fails or is refused
/// (a work Mac without the brain's own git identity, a broken machine.json) is only a warning:
/// the pull and push still run. The hourly import never publishes.
public enum InsightsSync {
    /// The publish half, before the pull and push.
    public struct Published: Equatable {
        /// nil when nothing was published.
        public var outcome: SummaryPublisher.Outcome?
        /// Why the summaries were not published.
        public var problem: String?
    }

    public struct Outcome: Equatable {
        public var published: Published
        public var sync: BrainSync.Outcome
    }

    /// Imports the new session lines, then writes and commits this Mac's summaries. Never throws:
    /// a problem is returned, so the caller can still pull and push.
    public static func publish(env: HarnessEnvironment, brain: Brain, projectsRoot: URL,
                               hostName: String = ProcessInfo.processInfo.hostName,
                               hardware: String? = MachineProfile.currentHardwareHash()) async -> Published {
        do {
            let database = try IndexSchema.open(InsightsPaths(env: env).database)
            _ = try await QuickImport.run(env: env, projectsRoot: projectsRoot, database: database)
            return Published(outcome: try await SummaryPublisher.publish(env: env, brain: brain, database: database,
                                                                         hostName: hostName, hardware: hardware))
        } catch {
            return Published(problem: error.localizedDescription)
        }
    }

    /// `publish`, then `BrainSync.sync`. Throws only when the pull or push fails; a commit the
    /// publish made then waits in the brain for the next sync.
    public static func run(env: HarnessEnvironment, brain: Brain, projectsRoot: URL,
                           hostName: String = ProcessInfo.processInfo.hostName,
                           hardware: String? = MachineProfile.currentHardwareHash()) async throws(BrainSync.Failure) -> Outcome {
        let published = await publish(env: env, brain: brain, projectsRoot: projectsRoot, hostName: hostName, hardware: hardware)
        return Outcome(published: published, sync: try await BrainSync.sync(brain.root, env: env))
    }
}

extension InsightsSync.Published {
    /// Lines for the app's Sync result; empty when the summaries were already up to date.
    public var lines: [String] {
        if let problem { return ["Usage summaries not published: \(problem)"] }
        guard let outcome else { return [] }
        var lines: [String] = []
        if !outcome.committed.isEmpty {
            let files = "\(outcome.committed.count) file\(outcome.committed.count == 1 ? "" : "s")"
            lines.append(outcome.isWork
                ? "Published this work Mac's usage summary (\(files)): only brain-skill counts, under its pseudonym \(outcome.key)."
                : "Published this Mac's usage summaries (\(files)).")
        }
        return lines + outcome.notes
    }
}
