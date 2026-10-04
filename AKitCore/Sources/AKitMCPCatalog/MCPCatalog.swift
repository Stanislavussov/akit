import Foundation

/// The catalog as the app uses it: the directory list and registry searches, kept on disk
/// for a day so the slow registry is asked once per query.
public enum MCPCatalog {
    public struct Directory: Sendable {
        public var servers: [CatalogServer]
        /// When the list was downloaded; nil when there is none.
        public var savedAt: Date?
        /// Why the list is old or missing.
        public var problem: String?
    }

    /// The directory list: the saved copy while it is fresh, else a new download. When the
    /// download fails, the old copy is returned together with the reason.
    public static func directory(home: URL, now: Date = .now, refresh: Bool = false,
                                 fetch: MCPCatalogClient.Fetch = MCPCatalogClient.network) async -> Directory {
        var cache = MCPCatalogCache.load(home: home)
        if !refresh, let saved = cache.directory, cache.isFresh(saved, now: now) {
            return Directory(servers: saved.servers, savedAt: saved.savedAt, problem: nil)
        }
        do {
            let servers = try await MCPCatalogClient.directory(fetch: fetch)
            cache.directory = MCPCatalogCache.Entry(savedAt: now, servers: servers)
            try? cache.save(home: home)
            return Directory(servers: servers, savedAt: now, problem: nil)
        } catch {
            return Directory(servers: cache.directory?.servers ?? [], savedAt: cache.directory?.savedAt,
                             problem: error.localizedDescription)
        }
    }

    /// Registry servers for a query, from the saved copy while it is fresh.
    public static func registry(matching query: String, home: URL, now: Date = .now,
                                fetch: MCPCatalogClient.Fetch = MCPCatalogClient.network) async throws -> [CatalogServer] {
        let key = MCPCatalogCache.key(for: query)
        guard key.count >= MCPCatalogClient.minimumQueryLength else { return [] }
        let cache = MCPCatalogCache.load(home: home)
        if let saved = cache.searches[key], cache.isFresh(saved, now: now) { return saved.servers }
        let servers = try await MCPCatalogClient.searchRegistry(key, fetch: fetch)
        // Read again: another search may have been saved while this one waited.
        var latest = MCPCatalogCache.load(home: home)
        latest.remember(search: key, servers: servers, now: now)
        try? latest.save(home: home)
        return servers
    }

    /// Servers matching every word of the query, best match first; all of them for an empty query.
    /// A match in the title or name counts more than one in the description; deprecated entries go last.
    public static func search(_ servers: [CatalogServer], query: String) -> [CatalogServer] {
        let words = query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        let whole = words.joined(separator: " ")
        func score(_ server: CatalogServer) -> Int? {
            let title = server.title.lowercased()
            let names = [title, server.name.lowercased(), server.configName.lowercased()]
            let summary = server.summary.lowercased()
            guard words.allSatisfy({ word in names.contains { $0.contains(word) } || summary.contains(word) }) else { return nil }
            // One step down for every word found only in the description.
            var score = 2 + words.count { word in !names.contains { $0.contains(word) } }
            if title.hasPrefix(whole) || server.configName.lowercased().hasPrefix(whole) { score = 1 }
            if title == whole || server.configName.lowercased() == whole { score = 0 }
            return score + (server.isDeprecated ? 10 : 0)
        }
        return servers.compactMap { server in score(server).map { (server, $0) } }
            .sorted { ($0.1, $0.0.title.lowercased(), $0.0.name) < ($1.1, $1.0.title.lowercased(), $1.0.name) }
            .map(\.0)
    }
}

/// `~/.akit/cache/mcp-catalog.json`: catalog answers, safe to delete.
struct MCPCatalogCache: Codable, Sendable {
    struct Entry: Codable, Sendable {
        var savedAt: Date
        var servers: [CatalogServer]
    }

    var directory: Entry?
    var searches: [String: Entry] = [:]

    static let lifetime: TimeInterval = 24 * 60 * 60
    static let maximumSearches = 40

    static func file(home: URL) -> URL { home.appending(path: ".akit/cache/mcp-catalog.json") }

    static func key(for query: String) -> String {
        query.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// An unreadable or missing file is an empty cache.
    static func load(home: URL) -> MCPCatalogCache {
        guard let data = try? Data(contentsOf: file(home: home)) else { return MCPCatalogCache() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(MCPCatalogCache.self, from: data)) ?? MCPCatalogCache()
    }

    func save(home: URL) throws {
        let file = Self.file(home: home)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(self).write(to: file, options: .atomic)
    }

    func isFresh(_ entry: Entry, now: Date) -> Bool {
        let age = now.timeIntervalSince(entry.savedAt)
        return age >= 0 && age < Self.lifetime
    }

    /// Keeps the newest searches only.
    mutating func remember(search key: String, servers: [CatalogServer], now: Date) {
        searches[key] = Entry(savedAt: now, servers: servers)
        let extra = searches.count - Self.maximumSearches
        guard extra > 0 else { return }
        for old in searches.sorted(by: { $0.value.savedAt < $1.value.savedAt }).prefix(extra) { searches[old.key] = nil }
    }
}
