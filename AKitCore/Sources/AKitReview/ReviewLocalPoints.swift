import AKitFoundation
import Foundation

/// A point of a local review's range: a branch, a remote branch, a tag or a commit the user can
/// give as the base or the head.
public struct ReviewLocalPoint: Codable, Sendable, Hashable, Identifiable {
    public enum Kind: String, Codable, Sendable {
        case branch, remote, tag, commit
    }

    public var kind: Kind
    /// What goes into Base or Head (`--base`, `--head`): the ref name, or a short commit id.
    public var name: String
    public var sha: String
    /// The subject of the commit the point is at; an annotated tag's own message.
    public var subject: String
    public var author: String
    public var date: String
    public var id: String { "\(kind.rawValue):\(name)" }
}

extension ReviewLocal {
    static let maxSearchedCommits = 1000

    /// The branches, remote branches, tags and commits of a workspace that match `query`: each
    /// word of it is in the name, the commit's subject or author, or starts the commit id. Refs
    /// come first, the most recent first (a tag by its own date), then the commits of all branches,
    /// newest first.
    /// An empty query gives the most recent ones.
    public static func points(path: URL, query: String = "", limit: Int = 30, env: HarnessEnvironment) async throws -> [ReviewLocalPoint] {
        guard let git = env.findExecutable("git") else { throw Failure(message: "git is not installed.") }
        func run(_ arguments: [String]) async -> String? {
            let result = await ProcessRunner.run(git, arguments: ["-C", path.path] + arguments, environment: env.gitVariables, timeout: 60)
            return result?.succeeded == true ? result!.output : nil
        }
        guard FileManager.default.fileExists(atPath: path.path), await run(["rev-parse", "--show-toplevel"]) != nil else {
            throw Failure(message: "\(path.path) is not a git workspace.")
        }
        let words = query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        func matches(_ point: ReviewLocalPoint) -> Bool {
            let text = "\(point.name) \(point.subject) \(point.author)".lowercased()
            return words.allSatisfy { text.contains($0) || point.sha.hasPrefix($0) }
        }

        var found: [ReviewLocalPoint] = []
        let refs = await run(["for-each-ref", "--sort=-creatordate",
                              "--format=%(refname)%1f%(refname:short)%1f%(objectname)%1f%(subject)%1f%(authorname)%1f%(committerdate:short)%1f%(*objectname)%1f%(*authorname)%1f%(*committerdate:short)%1f%(objecttype)%1f%(*objecttype)",
                              "refs/heads", "refs/remotes", "refs/tags"]) ?? ""
        for line in refs.split(separator: "\n") {
            let parts = line.split(separator: "\u{1F}", omittingEmptySubsequences: false).map(String.init)
            // A tag on a tree or a blob is no point of a range.
            guard parts.count == 11, (parts[10].isEmpty ? parts[9] : parts[10]) == "commit" else { continue }
            let full = parts[0]
            // `origin/HEAD` only names another branch.
            if full.hasPrefix("refs/remotes/"), full.hasSuffix("/HEAD") { continue }
            let kind: ReviewLocalPoint.Kind = full.hasPrefix("refs/heads/") ? .branch : full.hasPrefix("refs/tags/") ? .tag : .remote
            // An annotated tag points at a tag object: the commit, its author and date are `*…`;
            // the subject stays the tag's message.
            let tagged = !parts[6].isEmpty
            let point = ReviewLocalPoint(kind: kind, name: parts[1], sha: tagged ? parts[6] : parts[2], subject: parts[3],
                                         author: tagged ? parts[7] : parts[4], date: tagged ? parts[8] : parts[5])
            if matches(point) { found.append(point) }
        }

        var commits = await run(["log", "--branches", "--remotes", "--tags", "HEAD", "-n", String(maxSearchedCommits), "--date=short",
                                 "--format=%H%x1f%s%x1f%an%x1f%ad"]) ?? ""
        // An older commit by its id: the log above doesn't go that far back.
        if let word = words.first, words.count == 1, word.count >= 4, word.range(of: "^[0-9a-f]+$", options: .regularExpression) != nil,
           !commits.contains("\n\(word)"), !commits.hasPrefix(word),
           let one = await run(["log", "-1", "--date=short", "--format=%H%x1f%s%x1f%an%x1f%ad", "\(word)^{commit}", "--"]) {
            commits += "\n" + one
        }
        for line in commits.split(separator: "\n") {
            let parts = line.split(separator: "\u{1F}", omittingEmptySubsequences: false).map(String.init)
            guard parts.count == 4 else { continue }
            let point = ReviewLocalPoint(kind: .commit, name: String(parts[0].prefix(12)), sha: parts[0], subject: parts[1], author: parts[2], date: parts[3])
            if matches(point) { found.append(point) }
        }
        return Array(found.prefix(limit))
    }
}
