import AKitBrain
import AKitFoundation
import AKitLab
import Foundation

/// Keychain accounts of review's tokens (service `AKit Review`). Only AKit's own requests read
/// them; they never go into a pass's environment, a file or the screen (R2, "Tokens").
public enum ReviewTokens {
    public enum Kind: String, Sendable, CaseIterable {
        case gitlab
        case azureDevOps = "azure-devops"

        public var title: String {
            switch self {
            case .gitlab: "GitLab"
            case .azureDevOps: "Azure DevOps"
            }
        }
    }

    /// One account per GitLab host and per Azure DevOps organization: `gitlab_gitlab_corp_example`.
    public static func account(_ kind: Kind, for name: String) -> String {
        let cleaned = name.lowercased()
            .replacingOccurrences(of: "https://", with: "").replacingOccurrences(of: "http://", with: "")
            .unicodeScalars.map { CharacterSet.alphanumerics.contains($0) && $0.isASCII ? String($0) : "_" }.joined()
        let prefix = kind == .gitlab ? "gitlab" : "azure_devops"
        return "\(prefix)_\(cleaned.trimmingCharacters(in: ["_"]))"
    }

    public static func store() -> KeychainSecretStore { KeychainSecretStore(service: KeychainSecretStore.reviewService) }
}

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
        return "\(formatter.string(from: now))-\(slug)-\(mr.iid)"
    }

    /// The configuration a run would use, without gathering anything (`akit review config show`).
    public static func plan(mr: MergeRequestRef?, project: String?, choices: ReviewRunChoices, home: URL, brain: URL?) throws -> ReviewRunSpec {
        let catalog = ReviewCatalog.load(home: home, brain: brain)
        let profile = catalog.profile(for: mr, named: project)
        if let project, profile == nil { throw Failure(message: "There is no project profile \(project) in \(ReviewPaths(home: home).projects.path).") }
        let ref = mr ?? profile.map { MergeRequestRef(host: $0.gitlabHost, projectPath: $0.gitlabProjectPath, iid: 1) }
            ?? MergeRequestRef(host: "https://gitlab.example.com", projectPath: "group/project", iid: 1)
        return try ReviewResolver.resolve(catalog: catalog, profile: profile, choices: choices, mergeRequest: ref, id: "preview").spec
    }

    /// Resolves the configuration, makes the run folder and gathers the context pack (steps 1–2).
    /// `tokens` reads a token by Keychain account; the app and the CLI pass the Keychain.
    public static func start(mr: MergeRequestRef, project: String?, choices: ReviewRunChoices, env: HarnessEnvironment, brain: URL?,
                             tokens: @Sendable (String) throws -> String?, fetch: @escaping ReviewFetch = ReviewHTTP.network,
                             progress: (String) -> Void = { _ in }) async throws -> ReviewGather.Result {
        let home = env.homeDirectory
        let catalog = ReviewCatalog.load(home: home, brain: brain)
        let profile = catalog.profile(for: mr, named: project)
        if let project, profile == nil { throw Failure(message: "There is no project profile \(project).") }
        let id = newID(for: mr)
        let (spec, roles) = try ReviewResolver.resolve(catalog: catalog, profile: profile, choices: choices, mergeRequest: mr, id: id)
        let gitlabAccount = ReviewTokens.account(.gitlab, for: mr.host)
        guard let gitlabToken = try tokens(gitlabAccount) else {
            throw Failure(message: "There is no GitLab token for \(mr.host). Add it in Review → Settings or with: akit review token gitlab \(mr.host)")
        }
        var azure: AzureDevOpsClient?
        if let tracker = profile?.tracker, let token = try tokens(ReviewTokens.account(.azureDevOps, for: tracker.org)) {
            azure = AzureDevOpsClient(tracker: tracker, token: token, fetch: fetch)
        }
        let folder = ReviewPaths(home: home).run(id)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try ReviewJSON.write(spec, to: folder.appending(path: "run.json"))
        try setStatus(.gathering, folder: folder)
        let settings = LabSettings.load(env: env)
        do {
            let result = try await ReviewGather.run(spec: spec, profile: profile, roles: roles, folder: folder,
                                                    sources: .init(gitlab: GitLabClient(host: mr.host, token: gitlabToken, fetch: fetch), azure: azure),
                                                    scrub: settings.scrub, env: env, progress: progress)
            try setStatus(.gathered, folder: folder)
            return result
        } catch {
            try? setStatus(.failed, message: error.localizedDescription, folder: folder)
            throw error
        }
    }

    public static func setStatus(_ stage: ReviewRunStatus.Stage, message: String? = nil, folder: URL) throws {
        try ReviewJSON.write(ReviewRunStatus(stage: stage, message: message), to: folder.appending(path: "status.json"))
    }

    /// Every run on this Mac, newest first.
    public static func list(home: URL) -> [(id: String, spec: ReviewRunSpec, status: ReviewRunStatus?)] {
        FileWalk.children(of: ReviewPaths(home: home).runs).compactMap { folder in
            guard let spec = ReviewJSON.read(ReviewRunSpec.self, from: folder.appending(path: "run.json")) else { return nil }
            return (folder.lastPathComponent, spec, ReviewJSON.read(ReviewRunStatus.self, from: folder.appending(path: "status.json")))
        }.sorted { $0.spec.created > $1.spec.created }
    }
}
