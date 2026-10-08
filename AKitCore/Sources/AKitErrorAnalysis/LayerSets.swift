import AKitBrain
import AKitFoundation
import Foundation

/// A brain layer's task set (`docs/design/layer-evals.md`, "Tasks and layer sets"): the
/// control tasks an eval of the layer runs, and the field answers it renders the layer with.
/// `~/.akit/lab/evals/sets/<layer>.json`, local only: nothing of a set goes into the brain.
public struct LayerSet: Codable, Sendable, Hashable, Identifiable {
    public static let schemaVersion = 1

    public var schema = LayerSet.schemaVersion
    public var layer: String
    /// Control task ids, in the order they were added. A task may be in several sets.
    public var tasks: [String]
    /// Field answers of the layer and the layers it requires; they win over the project's
    /// saved answers and the layer's defaults.
    public var answers: [String: FieldValue]
    public var createdAt: Date
    public var updatedAt: Date

    public var id: String { layer }

    public init(layer: String, tasks: [String] = [], answers: [String: FieldValue] = [:], createdAt: Date = .now) {
        self.layer = layer
        self.tasks = tasks
        self.answers = answers
        self.createdAt = createdAt
        self.updatedAt = createdAt
    }
}

/// Reading and changing layer sets. Every change happens under the file's lock, so the app
/// and `akit` never save over each other's change.
public enum LayerSets {
    public struct Failure: Error, LocalizedError {
        public let message: String
        public var errorDescription: String? { message }
        public init(message: String) { self.message = message }
    }

    /// The set of a layer; nil when it has none, or when a newer AKit wrote it.
    public static func load(_ layer: String, env: HarnessEnvironment) -> LayerSet? {
        try? read(EvalPaths(env: env).set(layer))
    }

    /// Every readable set, by layer name.
    public static func list(env: HarnessEnvironment) -> [LayerSet] {
        FileWalk.children(of: EvalPaths(env: env).sets)
            .filter { $0.pathExtension == "json" }
            .compactMap { try? read($0) }
            .sorted { $0.layer < $1.layer }
    }

    /// Adds tasks to the layer's set, making the set when the layer has none. v1 keeps one
    /// repository per set (`project_name` and the project's answers come from it): a task of
    /// another repository is refused. Tasks already in the set stay where they are.
    @discardableResult
    public static func add(_ tasks: [ControlTask], to layer: String, now: Date = .now, env: HarnessEnvironment) throws -> LayerSet {
        guard !tasks.isEmpty else { throw Failure(message: "Pick at least one task.") }
        if let gone = tasks.first(where: { !$0.repositoryExists }) {
            throw Failure(message: "The repository of \(gone.id) is gone from this Mac (\(gone.mainFolder.path)).")
        }
        // Worktrees of one repository count as one, also after the worktree is removed.
        let repositories = Set(tasks.map(\.mainFolder.path))
        guard repositories.count == 1, let repo = repositories.first else {
            throw Failure(message: "A layer set takes the tasks of one repository for now; these come from \(names(repositories)).")
        }
        return try update(layer, now: now, env: env) { set in
            // The set's repository: that of the tasks it holds that still exist, on this Mac.
            let held = Set(set.tasks.compactMap { ControlTasks.load($0, env: env) }.filter(\.repositoryExists).map(\.mainFolder.path))
            if let other = held.first(where: { $0 != repo }) {
                throw Failure(message: "The \(layer) set holds tasks of \(URL(filePath: other).lastPathComponent); "
                                  + "a set takes the tasks of one repository for now, so tasks of \(URL(filePath: repo).lastPathComponent) can't join it.")
            }
            for task in tasks where !set.tasks.contains(task.id) { set.tasks.append(task.id) }
        }
    }

    /// An empty set for the layer (Brain → layer → Create Layer Set…); a set it has stays as it is.
    @discardableResult
    public static func create(_ layer: String, now: Date = .now, env: HarnessEnvironment) throws -> LayerSet {
        if let set = load(layer, env: env) { return set }
        return try update(layer, now: now, env: env) { _ in }
    }

    /// Takes task ids out of the set; the tasks themselves stay.
    @discardableResult
    public static func remove(_ ids: [String], from layer: String, now: Date = .now, env: HarnessEnvironment) throws -> LayerSet {
        guard FileManager.default.fileExists(atPath: EvalPaths(env: env).set(layer).path) else {
            throw Failure(message: "The layer \(layer) has no set.")
        }
        return try update(layer, now: now, env: env) { set in
            let unknown = ids.filter { !set.tasks.contains($0) }
            guard unknown.isEmpty else { throw Failure(message: "Not in the \(layer) set: \(unknown.joined(separator: ", ")).") }
            set.tasks.removeAll { ids.contains($0) }
        }
    }

    /// Sets one field answer, or removes it (nil): the project's answer or the default applies again.
    @discardableResult
    public static func setAnswer(_ field: String, _ value: FieldValue?, in layer: String, now: Date = .now,
                                 env: HarnessEnvironment) throws -> LayerSet {
        try update(layer, now: now, env: env) { set in set.answers[field] = value }
    }

    /// Moves the set's file to the Trash; its tasks stay.
    public static func delete(_ layer: String, env: HarnessEnvironment, trash: (URL) throws -> URL? = Trash.move) throws {
        let file = EvalPaths(env: env).set(layer)
        // Under the lock: a writer in the middle of a change never brings the set back half-way.
        try JSONFile.locked(file) {
            guard FileManager.default.fileExists(atPath: file.path) else { throw Failure(message: "The layer \(layer) has no set.") }
            _ = try trash(file)
        }
    }

    /// The sets a task is in, by layer name.
    public static func layers(holding id: String, in sets: [LayerSet]) -> [String] {
        sets.filter { $0.tasks.contains(id) }.map(\.layer)
    }

    /// The set's tasks that still exist, and the ids that are gone (shown as missing, skipped).
    public static func tasks(of set: LayerSet, env: HarnessEnvironment) -> (found: [ControlTask], missing: [String]) {
        var found: [ControlTask] = []
        var missing: [String] = []
        for id in set.tasks {
            if let task = ControlTasks.load(id, env: env) { found.append(task) } else { missing.append(id) }
        }
        return (found, missing)
    }

    /// Why a layer's set file can't be read, for a message; nil when it reads or doesn't exist.
    public static func problem(_ layer: String, env: HarnessEnvironment) -> String? {
        let url = EvalPaths(env: env).set(layer)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            _ = try read(url)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    /// Reads, changes and writes the set under its lock. A file a newer AKit wrote, or one that
    /// can't be read, is never replaced.
    private static func update(_ layer: String, now: Date, env: HarnessEnvironment, _ change: (inout LayerSet) throws -> Void) throws -> LayerSet {
        guard layer != "core" else {
            throw Failure(message: "The core layer is the home folder's layer: it can't be evaluated, so it has no set.")
        }
        let url = EvalPaths(env: env).set(layer)
        return try JSONFile.locked(url) {
            var set = FileManager.default.fileExists(atPath: url.path) ? try read(url) : LayerSet(layer: layer, createdAt: now)
            try change(&set)
            set.updatedAt = now
            try AnalysisJSON.encoder.encode(set).write(to: url, options: .atomic)
            return set
        }
    }

    /// Throws when there is no file, and `Failure` when it can't be used.
    private static func read(_ url: URL) throws -> LayerSet {
        let data = try Data(contentsOf: url)
        struct Header: Decodable { let schema: Int? }
        if let header = try? JSONDecoder().decode(Header.self, from: data), (header.schema ?? 1) > LayerSet.schemaVersion {
            throw Failure(message: "\(url.lastPathComponent) was written by a newer AKit; install the app and akit together.")
        }
        guard let set = try? AnalysisJSON.decoder.decode(LayerSet.self, from: data) else {
            throw Failure(message: "\(url.path) can't be read; fix or move it before AKit changes it.")
        }
        return set
    }

    private static func names(_ repositories: Set<String>) -> String {
        repositories.sorted().map { URL(filePath: $0).lastPathComponent }.joined(separator: ", ")
    }
}
