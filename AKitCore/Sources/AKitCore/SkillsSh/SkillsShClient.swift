import Foundation

/// A skill listed on skills.sh (the directory behind `npx skills`).
public struct RemoteSkill: Identifiable, Hashable, Sendable, Codable {
    /// `owner/repo/skillId`, also the page path on skills.sh.
    public let id: String
    /// `owner/repo` for GitHub; a domain for skills served from a website.
    public let source: String
    /// Slug of the skill name, e.g. `tdd`.
    public let skillId: String
    /// Name from the skill's SKILL.md, e.g. `tdd` or `Test-Driven Development (TDD)`.
    public let name: String
    public let installs: Int

    public init(id: String, source: String, skillId: String, name: String, installs: Int) {
        self.id = id
        self.source = source
        self.skillId = skillId
        self.name = name
        self.installs = installs
    }

    /// `owner/repo` when the source is a GitHub repository, nil otherwise.
    public var gitHubRepo: (owner: String, repo: String)? {
        let parts = source.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2,
              parts[0].range(of: "^[A-Za-z0-9-]+$", options: .regularExpression) != nil,
              parts[1].range(of: "^[A-Za-z0-9._-]+$", options: .regularExpression) != nil,
              parts[1] != ".", parts[1] != ".." else { return nil }
        return (parts[0], parts[1])
    }

    public var pageURL: URL { SkillsShClient.base.appending(path: id) }

    public var repoURL: URL? {
        gitHubRepo.map { URL(string: "https://github.com/\($0.owner)/\($0.repo)")! }
    }
}

/// Search on skills.sh. The same public endpoint `npx skills find` uses.
public enum SkillsShClient {
    public static let base = URL(string: "https://skills.sh")!
    /// skills.sh refuses shorter queries.
    public static let minimumQueryLength = 2

    public enum Failure: LocalizedError {
        case server(String)

        public var errorDescription: String? {
            switch self {
            case .server(let message): "skills.sh: \(message)"
            }
        }
    }

    public static func searchURL(query: String, limit: Int = 50) -> URL {
        var parts = URLComponents(url: base.appending(path: "api/search"), resolvingAgainstBaseURL: false)!
        parts.queryItems = [URLQueryItem(name: "q", value: query), URLQueryItem(name: "limit", value: String(limit))]
        return parts.url!
    }

    /// Parses the search response. Results come sorted by installs, most first.
    public static func decode(_ data: Data) throws -> [RemoteSkill] {
        struct Response: Decodable {
            let skills: [Entry]?
            let error: String?
        }
        struct Entry: Decodable {
            let id: String
            let source: String?
            let skillId: String?
            let name: String?
            let installs: Int?
        }
        let response = try JSONDecoder().decode(Response.self, from: data)
        if let error = response.error { throw Failure.server(error) }
        return (response.skills ?? []).map { entry in
            let skillId = entry.skillId ?? String(entry.id.split(separator: "/").last ?? "")
            return RemoteSkill(id: entry.id, source: entry.source ?? "", skillId: skillId,
                               name: entry.name ?? skillId, installs: entry.installs ?? 0)
        }
        .sorted { $0.installs > $1.installs }
    }

    public static func search(_ query: String, limit: Int = 50, session: URLSession = .shared) async throws -> [RemoteSkill] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard q.count >= minimumQueryLength else { return [] }
        let (data, _) = try await session.data(from: searchURL(query: q, limit: limit))
        return try decode(data)
    }
}
