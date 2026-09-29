import AKitBrain
import AKitFoundation
import Foundation

/// When each layer first applied in a project: a skill a layer brings starts counting there from
/// that date, so sessions from before the layer never speak for or against it.
///
/// - This Mac's first `applies` row with the layer (the spool line `akit apply` leaves) wins.
/// - Before such a row exists, the brain's history of `projects/<id>/answers.json` fills in: the
///   author date of the oldest commit whose answers bring the layer (its `requires` included).
///   Only when the project store is the brain; a work Mac's local store has no history.
/// - Unknown (neither): no extra restriction.
enum LayerHistory {
    /// Commits of one answers.json looked at, newest first.
    static let maxCommits = 200
    static let gitBudget: TimeInterval = 10
    static let callTimeout: TimeInterval = 5

    static func starts(project: String, database: IndexDatabase, store: ProjectStore, brain: Brain?, env: HarnessEnvironment,
                       run: CommandRunner? = nil, budget: TimeInterval = gitBudget) async throws -> [String: Date] {
        var starts = try localStarts(project: project, database: database)
        guard let brainRoot = store.brain, let git = env.findExecutable("git") else { return starts }
        let run = run ?? CaptureInstaller.liveRunner(env)
        let deadline = Date().addingTimeInterval(budget)
        func call(_ arguments: [String]) async -> String? {
            let left = deadline.timeIntervalSinceNow
            guard left > 0, let result = await run(git, arguments, brainRoot, min(callTimeout, left)), result.succeeded else { return nil }
            return result.output
        }
        let path = "projects/\(project)/answers.json"
        guard UsageSummary.isSafeProjectID(project),
              let log = await call(["log", "-n", "\(maxCommits)", "--format=%H%x09%aI", "--", path]) else { return starts }
        let byName = Dictionary((brain?.layers ?? []).map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        let commits = log.split(whereSeparator: \.isNewline).compactMap { line -> (hash: String, date: Date)? in
            let parts = line.split(separator: "\t", maxSplits: 1).map(String.init)
            guard parts.count == 2, let date = ISO8601DateFormatter().date(from: parts[1]) else { return nil }
            return (parts[0], date)
        }
        var fromGit: [String: Date] = [:]
        // Oldest first: the first commit bringing a layer is when it was added.
        for commit in commits.reversed() {
            guard let text = await call(["show", "\(commit.hash):\(path)"]),
                  let answers = try? JSONDecoder().decode(ProjectAnswers.self, from: Data(text.utf8)) else { continue }
            let layers = answers.layers.reduce(into: Set<String>()) { $0.formUnion(Brain.requiredClosure(of: $1, in: byName)) }
            for layer in layers where fromGit[layer] == nil { fromGit[layer] = commit.date }
        }
        for (layer, date) in fromGit where starts[layer] == nil { starts[layer] = date }
        return starts
    }

    /// First local `applies` row per layer of the project.
    static func localStarts(project: String, database: IndexDatabase) throws -> [String: Date] {
        var starts: [String: Date] = [:]
        for row in try database.rows("SELECT ts, layers FROM applies WHERE project_id = ? ORDER BY ts", project) {
            guard let ms = row[0].int, let text = row[1].text,
                  let layers = try? JSONDecoder().decode([String].self, from: Data(text.utf8)) else { continue }
            for layer in layers where starts[layer] == nil { starts[layer] = Date(timeIntervalSince1970: Double(ms) / 1000) }
        }
        return starts
    }
}
