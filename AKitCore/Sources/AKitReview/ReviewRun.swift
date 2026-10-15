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

    /// One account per GitLab and per Azure DevOps address: `gitlab https://gitlab.corp.example`,
    /// `azure-devops https://dev.azure.com/org`. The whole origin is the name, so two hosts never
    /// share a token. nil for an address that isn't https (a token never goes out in clear text).
    public static func account(_ kind: Kind, for name: String) -> String {
        "\(kind.rawValue) \(origin(kind, name) ?? name.lowercased())"
    }

    /// `https://host[:port]` (lowercased, no path) for GitLab; for Azure DevOps an organization
    /// name means `https://dev.azure.com/<org>`, an address keeps its path (a Server collection).
    public static func origin(_ kind: Kind, _ name: String) -> String? {
        var text = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if kind == .azureDevOps, !text.contains("://") { text = "https://dev.azure.com/\(text)" }
        guard let url = URL(string: text), url.scheme?.lowercased() == "https", let host = url.host()?.lowercased(), !host.isEmpty else { return nil }
        let port = url.port.map { ":\($0)" } ?? ""
        var path = kind == .azureDevOps ? url.path() : ""
        while path.hasSuffix("/") { path.removeLast() }
        return "https://\(host)\(port)\(path.lowercased())"
    }

    public static func store() -> ReviewKeychain { ReviewKeychain() }
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
                             progress: @Sendable (String) -> Void = { _ in }) async throws -> ReviewGather.Result {
        let home = env.homeDirectory
        let catalog = ReviewCatalog.load(home: home, brain: brain)
        let profile = catalog.profile(for: mr, named: project)
        if let project, profile == nil { throw Failure(message: "There is no project profile \(project).") }
        let id = newID(for: mr)
        let (spec, roles) = try ReviewResolver.resolve(catalog: catalog, profile: profile, choices: choices, mergeRequest: mr, id: id)
        guard ReviewTokens.origin(.gitlab, mr.host) != nil else {
            throw Failure(message: "\(mr.host) is not https: AKit sends your GitLab token only over https.")
        }
        let gitlabAccount = ReviewTokens.account(.gitlab, for: mr.host)
        guard let gitlabToken = try tokens(gitlabAccount) else {
            throw Failure(message: "There is no GitLab token for \(mr.host). Add it in Review → Settings or with: akit review token gitlab \(mr.host)")
        }
        var azure: AzureDevOpsClient?
        if let tracker = profile?.tracker, ReviewTokens.origin(.azureDevOps, tracker.baseURL) != nil,
           let token = try tokens(ReviewTokens.account(.azureDevOps, for: tracker.baseURL)) {
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
