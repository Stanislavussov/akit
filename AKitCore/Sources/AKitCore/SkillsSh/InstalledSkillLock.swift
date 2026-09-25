import Foundation

/// `~/.akit/skills-lock.json`: skills AKit installed from skills.sh and where they came from.
/// Your own copies are recorded too, as "based on", so they are never treated as the author's.
/// Kept by AKit itself; the `npx skills` lock (`~/.agents/.skill-lock.json`) is never written.
public struct InstalledSkillLock: Codable, Sendable, Equatable {
    public struct Entry: Codable, Sendable, Equatable {
        /// Real path of the installed skill folder.
        public var path: String
        /// `owner/repo`.
        public var source: String
        public var skillId: String
        /// Folder inside the repository, e.g. `skills/tdd`.
        public var pathInRepo: String
        /// The SKILL.md was edited or renamed before installing.
        public var modified: Bool
        public var installedAt: String
        /// Saved as your own skill, based on the source (nil in files from before own copies).
        public var ownCopy: Bool?

        public init(path: String, source: String, skillId: String, pathInRepo: String, modified: Bool,
                    installedAt: String, ownCopy: Bool = false) {
            self.path = path
            self.source = source
            self.skillId = skillId
            self.pathInRepo = pathInRepo
            self.modified = modified
            self.installedAt = installedAt
            self.ownCopy = ownCopy
        }
    }

    public var version = 1
    public var entries: [Entry] = []

    public enum Failure: LocalizedError {
        case unreadable(String)

        public var errorDescription: String? {
            switch self {
            case .unreadable(let reason):
                "~/.akit/skills-lock.json could not be read (\(reason)). Fix or remove it first; AKit won't overwrite it."
            }
        }
    }

    public static func url(in env: HarnessEnvironment) -> URL {
        env.homeDirectory.appending(path: ".akit/skills-lock.json")
    }

    /// A missing file is an empty lock; a broken one is an error.
    public static func load(in env: HarnessEnvironment) throws -> InstalledSkillLock {
        let url = url(in: env)
        guard FileManager.default.fileExists(atPath: url.path) else { return InstalledSkillLock() }
        do {
            return try JSONDecoder().decode(InstalledSkillLock.self, from: Data(contentsOf: url))
        } catch {
            throw Failure.unreadable(error.localizedDescription)
        }
    }

    public static func save(_ lock: InstalledSkillLock, in env: HarnessEnvironment) throws {
        let url = url(in: env)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(lock).write(to: url, options: .atomic)
    }

    /// Where a skill folder came from: `skills.sh · mattpocock/skills`, or for your own copy
    /// `Your copy of mattpocock/skills`.
    func origin(forSkillFolder folder: URL) -> String? {
        let path = folder.resolvingSymlinksInPath().path
        guard let entry = entries.last(where: { $0.path == path }) else { return nil }
        if entry.ownCopy == true { return Self.ownCopyOrigin(entry.source) }
        return Self.publishedOrigin(entry.source) + (entry.modified ? " (renamed)" : "")
    }

    public static func publishedOrigin(_ source: String) -> String { "skills.sh · \(source)" }
    public static func ownCopyOrigin(_ source: String) -> String { "Your copy of \(source)" }
}
