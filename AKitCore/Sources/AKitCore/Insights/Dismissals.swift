import Foundation

/// Recommendations the user said no to. A layer skill is dismissed in its `layer.yaml`
/// (`keep_auto: true`, see `LayerPatch`); advice outside layers is kept here with the ≈ context
/// space it had, and shows again once that has doubled.
///
/// - Global advice: `insights/dismissed.json` in the brain, committed. On a work Mac (or without a
///   brain) `~/.akit/local/insights/dismissed.json` instead, never committed; a work Mac still
///   reads the brain's.
/// - Per-project advice: `<ProjectStore.current>/<id>/dismissed.json`, committed only when that
///   store is the brain's (so a work Mac's stay local).
enum Dismissals {
    struct Entry: Codable, Equatable {
        let id: String
        /// ISO 8601.
        let at: String
        let approxContextSpace: Int
    }

    struct File: Codable, Equatable {
        var version = 1
        var dismissed: [Entry] = []
    }

    struct Failure: Error, LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static let brainPath = "insights/dismissed.json"

    static func localURL(home: URL) -> URL { home.appending(path: ".akit/local/insights/dismissed.json") }

    /// Where global dismissals are written on this Mac.
    static func globalURL(brain: URL?, home: URL, machine: MachineProfile) -> URL {
        if let brain, !machine.isWork { return brain.appending(path: brainPath) }
        return localURL(home: home)
    }

    static func projectURL(_ project: String, store: ProjectStore) -> URL {
        store.folder(id: project).appending(path: "dismissed.json")
    }

    /// Dismissals that apply to a scope, by id: the global ones, or the project's.
    static func load(project: String?, brain: URL?, home: URL, store: ProjectStore) -> [String: Entry] {
        var urls: [URL] = []
        if let project {
            if UsageSummary.isSafeProjectID(project), let url = store.savedFile(id: project, "dismissed.json") { urls.append(url) }
        } else {
            if let brain { urls.append(brain.appending(path: brainPath)) }
            urls.append(localURL(home: home))
        }
        var entries: [String: Entry] = [:]
        for url in urls {
            for entry in read(url).dismissed { entries[entry.id] = entry }
        }
        return entries
    }

    /// Hidden while the ≈ context space is under twice what it was when dismissed.
    static func hides(_ entry: Entry, approxContextSpace: Int) -> Bool {
        approxContextSpace < 2 * max(entry.approxContextSpace, 1)
    }

    static func read(_ url: URL) -> File {
        guard let data = try? Data(contentsOf: url), let file = try? JSONDecoder().decode(File.self, from: data) else { return File() }
        return file
    }

    /// The file with the entry added (an older entry with the same id replaced), sorted by id.
    static func adding(_ entry: Entry, to file: File) -> Data {
        var file = file
        file.dismissed.removeAll { $0.id == entry.id }
        file.dismissed.append(entry)
        file.dismissed.sort { $0.id < $1.id }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return ((try? encoder.encode(file)) ?? Data("{}".utf8)) + Data("\n".utf8)
    }

    /// Writes the dismissal and, when the file is in a brain git repo (a personal Mac), commits it
    /// alone. Returns the file written.
    @discardableResult
    static func dismiss(_ entry: Entry, project: String?, brain: URL?, home: URL, machine: MachineProfile,
                        env: HarnessEnvironment) async throws(Failure) -> URL {
        let url: URL
        let commitRoot: URL?
        let existing: File
        if let project {
            guard UsageSummary.isSafeProjectID(project) else { throw Failure(message: "“\(project)” is not a project id AKit can store.") }
            let store = brain.map { ProjectStore.current(brain: $0, home: home, machine: machine) } ?? .local(home: home)
            url = projectURL(project, store: store)
            commitRoot = store.brain
            // A work Mac's store reads the brain's older entries; they are carried into its own file.
            existing = read(store.savedFile(id: project, "dismissed.json") ?? url)
        } else {
            url = globalURL(brain: brain, home: home, machine: machine)
            commitRoot = brain != nil && !machine.isWork ? brain : nil
            existing = read(url)
        }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try adding(entry, to: existing).write(to: url, options: .atomic)
        } catch {
            throw Failure(message: "Couldn't write \(url.path): \(error.localizedDescription)")
        }
        guard let root = commitRoot, FileManager.default.fileExists(atPath: root.appending(path: ".git").path) else { return url }
        let path = String(url.standardizedFileURL.path.dropFirst(root.standardizedFileURL.path.count + 1))
        guard let git = env.findExecutable("git") else { throw Failure(message: "Saved, but git was not found, so nothing was committed.") }
        let environment = env.variables.merging(["PATH": env.pathForChildProcesses, "GIT_TERMINAL_PROMPT": "0"]) { $1 }
        for arguments in [["add", "--", path], ["commit", "--quiet", "-m", "Dismiss recommendation \(entry.id)", "--", path]] {
            let result = await ProcessRunner.run(git, arguments: arguments, directory: root, environment: environment, timeout: 30)
            guard let result, result.succeeded else {
                throw Failure(message: "Saved, but git \(arguments[0]) failed: \(result?.output.trimmingCharacters(in: .whitespacesAndNewlines) ?? "couldn't start")")
            }
        }
        return url
    }
}
