import Foundation

/// The two public catalogs of MCP servers. Both answer in the MCP Registry format and need no key.
public enum MCPCatalogClient {
    /// Anthropic's connector directory. Small enough to download whole (4 pages on 2026-10-04).
    public static let directoryBase = URL(string: "https://api.anthropic.com/mcp-registry/v0/servers")!
    /// The official MCP Registry. Its search matches server names only.
    public static let registryBase = URL(string: "https://registry.modelcontextprotocol.io/v0/servers")!
    /// Shorter queries match most of the registry.
    public static let minimumQueryLength = 2
    /// A registry search took 15–50 s on 2026-10-04.
    static let registryTimeout: TimeInterval = 90
    static let directoryTimeout: TimeInterval = 20
    /// Stops the paging if the directory keeps handing out cursors.
    static let maximumDirectoryPages = 20

    public typealias Fetch = @Sendable (URLRequest) async throws -> Data

    public enum Failure: LocalizedError {
        case server(String)

        public var errorDescription: String? {
            switch self {
            case .server(let message): message
            }
        }
    }

    public static func directoryURL(cursor: String? = nil) -> URL {
        var parts = URLComponents(url: directoryBase, resolvingAgainstBaseURL: false)!
        parts.queryItems = [URLQueryItem(name: "version", value: "latest"),
                            URLQueryItem(name: "visibility", value: "commercial"),
                            URLQueryItem(name: "limit", value: "100")]
        if let cursor { parts.queryItems?.append(URLQueryItem(name: "cursor", value: cursor)) }
        return parts.url!
    }

    public static func registrySearchURL(query: String, limit: Int = 50) -> URL {
        var parts = URLComponents(url: registryBase, resolvingAgainstBaseURL: false)!
        parts.queryItems = [URLQueryItem(name: "search", value: query),
                            URLQueryItem(name: "version", value: "latest"),
                            URLQueryItem(name: "limit", value: String(limit))]
        return parts.url!
    }

    /// Servers of one answer page. Entries AKit can't read or connect to are left out.
    public static func decode(_ data: Data, source: CatalogSource) throws -> [CatalogServer] {
        try CatalogDecoder.decode(data, source: source).servers
    }

    /// The whole directory, page by page.
    public static func directory(fetch: Fetch = network) async throws -> [CatalogServer] {
        var servers: [CatalogServer] = []
        var names: Set<String> = []
        var cursors: Set<String> = []
        var cursor: String?
        for _ in 0..<maximumDirectoryPages {
            let request = URLRequest(url: directoryURL(cursor: cursor), timeoutInterval: directoryTimeout)
            let page = try CatalogDecoder.decode(try await fetch(request), source: .directory)
            servers += page.servers.filter { names.insert($0.name).inserted }
            // A cursor seen before would loop forever.
            guard let next = page.nextCursor, cursors.insert(next).inserted else { break }
            cursor = next
        }
        return servers
    }

    /// Registry servers whose name contains the query. Slow: see `registryTimeout`.
    public static func searchRegistry(_ query: String, fetch: Fetch = network) async throws -> [CatalogServer] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard q.count >= minimumQueryLength else { return [] }
        let request = URLRequest(url: registrySearchURL(query: q), timeoutInterval: registryTimeout)
        return try CatalogDecoder.decode(try await fetch(request), source: .registry).servers
    }

    /// Plain download. An HTTP error with a readable body is left to the decoder, which shows its text.
    public static let network: Fetch = { request in
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode), data.first != UInt8(ascii: "{") {
            throw Failure.server("\(request.url?.host() ?? "The catalog") answered HTTP \(http.statusCode).")
        }
        return data
    }
}
