import AKitBrain
import AKitFoundation
import AKitLab
import Foundation

/// A run's progress, beside `run.json` (`<run>/status.json`).
public struct ReviewRunStatus: Codable, Sendable, Hashable {
    public enum Stage: String, Codable, Sendable {
        case gathering, gathered, estimating, passes, planned, failed, stopped
    }

    public var stage: Stage
    public var message: String?
    public var updated: Date

    public init(stage: Stage, message: String? = nil, updated: Date = .now) {
        self.stage = stage
        self.message = message
        self.updated = updated
    }
}

/// Starting a run: the id and folder, the resolved spec, Gather.
public enum ReviewRuns {
    public struct Failure: Error, LocalizedError {
        public let message: String
        public var errorDescription: String? { message }
    }

    /// `20261015-143000-orders-service-12`.
    public static func newID(for mr: MergeRequestRef, now: Date = .now) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let project = mr.projectPath.split(separator: "/").last.map(String.init) ?? "mr"
        let slug = project.lowercased().unicodeScalars.map { CharacterSet.alphanumerics.contains($0) && $0.isASCII ? String($0) : "-" }.joined()
        return "\(formatter.string(from: now))-\(slug)-\(mr.isLocal ? "local" : String(mr.iid))"
    }

    /// The configuration a run would use, without gathering anything (`akit review config show`).
    public static func plan(mr: MergeRequestRef?, project: String?, choices: ReviewRunChoices, env: HarnessEnvironment, brain: URL?) throws -> ReviewRunSpec {
        let home = env.homeDirectory
        let catalog = ReviewCatalog.load(home: home, brain: brain)
        let profile = catalog.profile(for: mr, named: project)
        if let project, profile == nil { throw Failure(message: "There is no project profile \(project) in \(ReviewPaths(home: home).projects.path).") }
        let ref = mr ?? profile.map { MergeRequestRef(host: $0.gitlabHost, projectPath: $0.gitlabProjectPath, iid: 1) }
            ?? MergeRequestRef(host: "https://gitlab.example.com", projectPath: "group/project", iid: 1)
        return try ReviewResolver.resolve(catalog: catalog, profile: profile, choices: choices, mergeRequest: ref, id: "preview",
                                          pi: ReviewPiLibrary.load(env: env)).spec
    }

    /// Resolves the configuration, makes the run folder and gathers the context pack (steps 1–2):
    /// the fetch pass reads the merge request through Pi's MCP servers.
    public static func start(mr: MergeRequestRef, project: String?, choices: ReviewRunChoices, env: HarnessEnvironment, brain: URL?,
                             options: ReviewPasses.Options = .init()) async throws -> ReviewGather.Result {
        let home = env.homeDirectory
        let catalog = ReviewCatalog.load(home: home, brain: brain)
        let profile = catalog.profile(for: mr, named: project)
        if let project, profile == nil { throw Failure(message: "There is no project profile \(project).") }
        let id = newID(for: mr)
        var (spec, roles) = try ReviewResolver.resolve(catalog: catalog, profile: profile, choices: choices, mergeRequest: mr, id: id,
                                                       pi: ReviewPiLibrary.load(env: env))
        if let commit = choices.fromCommit, !ReviewLinked.isCommit(commit) {
            throw Failure(message: "\(commit) is not a commit id (7–40 hex characters).")
        }
        spec.fromCommit = choices.fromCommit
        let linked = try ReviewLinked.checked([ReviewMergeRequestEntry(mergeRequest: mr, fromCommit: choices.fromCommit)] + choices.linked)
            .dropFirst()
        if !linked.isEmpty {
            let keys = ReviewLinked.keys(main: mr, linked: linked.map(\.mergeRequest))
            spec.linked = zip(keys, linked).map { key, entry in
                ReviewLinkedChange(key: key, mergeRequest: entry.mergeRequest, project: catalog.profile(for: entry.mergeRequest)?.slug,
                                   fromCommit: entry.fromCommit)
            }
        }
        // No run folder for a run that can't finish (R25).
        if let problem = spec.verifierProblem { throw Failure(message: problem) }
        let folder = ReviewPaths(home: home).run(id)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try ReviewJSON.write(spec, to: folder.appending(path: "run.json"))
        try setStatus(.gathering, folder: folder)
        let settings = LabSettings.load(env: env)
        do {
            var linkedProfiles: [String: ReviewProfile] = [:]
            for change in spec.linked ?? [] {
                if let slug = change.project, let found = catalog.profiles.first(where: { $0.slug == slug }) { linkedProfiles[change.key] = found }
            }
            let result = try await ReviewGather.run(spec: spec, profile: profile, roles: roles, folder: folder, scrub: settings.scrub, env: env,
                                                    options: options, linkedProfiles: linkedProfiles)
            try setStatus(.gathered, folder: folder)
            return result
        } catch {
            try? setStatus(.failed, message: error.localizedDescription, folder: folder)
            throw error
        }
    }

    /// A review of a local workspace (Orca, herdr, any clone): the commits since the base, the
    /// uncommitted changes, or both. No fetch pass and nothing for GitLab: the findings stay in AKit.
    public static func startLocal(_ target: ReviewLocalTarget, project: String?, choices: ReviewRunChoices, env: HarnessEnvironment,
                                  brain: URL?, options: ReviewPasses.Options = .init()) async throws -> ReviewGather.Result {
        let home = env.homeDirectory
        let catalog = ReviewCatalog.load(home: home, brain: brain)
        let profile = project.flatMap { name in catalog.profiles.first { $0.slug == name } }
        if let project, profile == nil { throw Failure(message: "There is no project profile \(project).") }
        let ref = MergeRequestRef.local(target.repository)
        let id = newID(for: ref)
        var (spec, roles) = try ReviewResolver.resolve(catalog: catalog, profile: profile, choices: choices, mergeRequest: ref, id: id,
                                                       pi: ReviewPiLibrary.load(env: env))
        spec.local = target
        if let problem = spec.verifierProblem { throw Failure(message: problem) }
        let folder = ReviewPaths(home: home).run(id)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try ReviewJSON.write(spec, to: folder.appending(path: "run.json"))
        try setStatus(.gathering, folder: folder)
        do {
            let result = try await ReviewGather.run(spec: spec, profile: profile, roles: roles, folder: folder, scrub: LabSettings.load(env: env).scrub,
                                                    env: env, options: options)
            try setStatus(.gathered, folder: folder)
            return result
        } catch {
            try? setStatus(.failed, message: error.localizedDescription, folder: folder)
            throw error
        }
    }

    /// Only the title of `gitlab/snapshot.json`.
    private struct SnapshotTitle: Decodable {
        struct MergeRequest: Decodable { var title: String }
        var mergeRequest: MergeRequest
    }

    public static func setStatus(_ stage: ReviewRunStatus.Stage, message: String? = nil, folder: URL) throws {
        try ReviewJSON.write(ReviewRunStatus(stage: stage, message: message), to: folder.appending(path: "status.json"))
    }

    /// Every run on this Mac, newest first. `titles`: a run made before titles were saved gets
    /// its title from its snapshot, a large file; only lists people read ask for it.
    public static func list(home: URL, titles: Bool = false) -> [(id: String, spec: ReviewRunSpec, status: ReviewRunStatus?)] {
        FileWalk.children(of: ReviewPaths(home: home).runs).compactMap { folder in
            guard var spec = ReviewJSON.read(ReviewRunSpec.self, from: folder.appending(path: "run.json")) else { return nil }
            if titles, spec.title == nil,
               let title = ReviewJSON.read(SnapshotTitle.self, from: folder.appending(path: "gitlab/snapshot.json"))?.mergeRequest.title {
                spec.title = ReviewRunSpec.readableTitle(Scrubber.scrub(title).text)
            }
            return (folder.lastPathComponent, spec, ReviewJSON.read(ReviewRunStatus.self, from: folder.appending(path: "status.json")))
        }.sorted { $0.spec.created > $1.spec.created }
    }
}
