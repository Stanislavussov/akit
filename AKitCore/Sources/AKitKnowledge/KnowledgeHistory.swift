import AKitFoundation
import Foundation

/// The history of a note or a map (K40), read from the base's git: every commit that touched its
/// file, renames followed, newest first. Nothing in a base is lost: every write commits (at once,
/// or through the commit queue), and Restore is a new commit too, so it can be undone the same way.
public struct KnowledgeHistory: Sendable, Equatable, Encodable {
    public struct Version: Sendable, Equatable, Encodable, Identifiable {
        public enum Change: String, Sendable, Encodable { case added, changed, renamed, deleted }

        /// The full commit hash.
        public let commit: String
        public let date: Date
        /// The commit's subject (`Edit payments/billing`, `Commit 2 edits`…).
        public let message: String
        /// The file's base-relative path in that commit.
        public let path: String
        public let change: Change
        /// For a rename: the path before it.
        public let from: String?

        public var id: String { commit }
        public var short: String { String(commit.prefix(7)) }

        private enum CodingKeys: String, CodingKey { case commit, short, date, message, path, change, from }

        public func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(commit, forKey: .commit)
            try container.encode(short, forKey: .short)
            try container.encode(ISO8601DateFormatter().string(from: date), forKey: .date)
            try container.encode(message, forKey: .message)
            try container.encode(path, forKey: .path)
            try container.encode(change, forKey: .change)
            try container.encodeIfPresent(from, forKey: .from)
        }
    }

    public let kind: KnowledgeBase.Item.Kind
    /// The note or map id.
    public let id: String
    /// The file's base-relative path now (for a removed file, its last path).
    public let path: String
    /// The file is in the base now.
    public let exists: Bool
    /// The file differs from its last commit: edits waiting in the commit queue.
    public let pending: Bool
    /// The file's modification date; nil when it is gone.
    public let modified: Date?
    /// Newest first.
    public let versions: [Version]

    /// The first commit of the file.
    public var created: Date? { versions.last?.date }
    /// The last change: the file's own date while edits are pending, else the last commit's.
    public var changed: Date? { pending ? (modified ?? versions.first?.date) : versions.first?.date }

    private enum CodingKeys: String, CodingKey { case kind, id, path, exists, pending, created, changed, versions }

    public func encode(to encoder: any Encoder) throws {
        let iso = ISO8601DateFormatter()
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind, forKey: .kind)
        try container.encode(id, forKey: .id)
        try container.encode(path, forKey: .path)
        try container.encode(exists, forKey: .exists)
        try container.encode(pending, forKey: .pending)
        try container.encode(created.map(iso.string(from:)), forKey: .created)
        try container.encode(changed.map(iso.string(from:)), forKey: .changed)
        try container.encode(versions, forKey: .versions)
    }

    /// The version a commit hash (or a prefix of 4 characters or more) names.
    public func version(_ rev: String) throws(KnowledgeBase.Failure) -> Version {
        let wanted = rev.trimmingCharacters(in: .whitespaces).lowercased()
        let found = wanted.count >= 4 ? versions.filter { $0.commit.hasPrefix(wanted) } : []
        guard let version = found.first else {
            throw KnowledgeBase.Failure(message: "No version “\(rev)” in the history of \(id) (see akit kb history \(id)).")
        }
        guard found.count == 1 else { throw KnowledgeBase.Failure(message: "“\(rev)” fits more than one version of \(id); give more of the hash.") }
        return version
    }

    /// `git log --format=%x1e%H%x1f%aI%x1f%s --name-status`: one record per commit, its first line
    /// the hash, date and subject, then `M\tpath`, `A\tpath`, `D\tpath` or `R100\told\tnew`.
    static func parse(log: String) -> [Version] {
        log.split(separator: "\u{1e}").compactMap { record in
            let lines = record.split(separator: "\n", omittingEmptySubsequences: true)
            guard let head = lines.first else { return nil }
            let fields = head.split(separator: "\u{1f}", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
            guard fields.count == 3, let date = try? Date(fields[1], strategy: .iso8601) else { return nil }
            guard let status = lines.dropFirst().map({ $0.split(separator: "\t").map(String.init) }).first(where: { $0.count >= 2 }) else { return nil }
            let change: Version.Change, path: String, from: String?
            switch status[0].first {
            case "A": (change, path, from) = (.added, status[1], nil)
            case "D": (change, path, from) = (.deleted, status[1], nil)
            default:
                let renamed = ["R", "C"].contains(status[0].first) && status.count >= 3
                (change, path, from) = renamed ? (.renamed, status[2], status[1]) : (.changed, status[status.count - 1], nil)
            }
            return Version(commit: fields[0], date: date, message: fields[2], path: path, change: change, from: from)
        }
    }
}

/// What Restore would write (nothing is written).
public struct KnowledgeRestorePlan: Sendable, Equatable {
    public let history: KnowledgeHistory
    public let version: KnowledgeHistory.Version
    /// The file's bytes now; nil for a removed file.
    public let original: Data?
    public let restored: Data

    public var path: String { history.path }
    public var changes: Bool { original != restored }

    /// `diff -u` style lines, the path first; a map's as its blocks and arrows.
    public var diff: String {
        func text(_ data: Data?) -> String {
            guard let data else { return "" }
            if history.kind == .map, case .success(let scene) = ExcalidrawFile.parse(data) { return KnowledgeInbox.mapSummary(scene) }
            return String(decoding: data, as: UTF8.self)
        }
        let lines = TextDiff.unified(TextDiff.lines(from: text(original), to: text(restored)))
        return ([original == nil ? "\(path) (removed now)" : path] + lines).joined(separator: "\n")
    }
}

extension KnowledgeBase {
    /// The history of the note or map `name`: as `item` finds it, else a removed one by its id or
    /// path (`payments/old-api`, `areas/payments/old-api.md`). `limit` keeps the newest versions.
    public func history(_ name: String, limit: Int? = nil, env: HarnessEnvironment) async throws(Failure) -> KnowledgeHistory {
        let git = KnowledgeGit(base: root, env: env)
        let kind: Item.Kind, id: String, path: String
        if let item = try? item(name) {
            guard item.kind != .area else {
                throw Failure(message: "\(item.id) is a space: a history is a note's or a map's (akit kb history NOTE|MAP).")
            }
            (kind, id, path) = (item.kind, item.id, item.path)
        } else {
            var value = Self.nfc(name.trimmingCharacters(in: .whitespaces))
            if value.hasPrefix("areas/") { value.removeFirst("areas/".count) }
            let candidates: [(Item.Kind, String, String)] = value.hasSuffix(".md") ? [(.note, String(value.dropLast(3)), "areas/\(value)")]
                : value.hasSuffix(".excalidraw") ? [(.map, String(value.dropLast(".excalidraw".count)), "areas/\(value)")]
                : [(.note, value, "areas/\(value).md"), (.map, value, "areas/\(value).excalidraw")]
            var found: (Item.Kind, String, String)?
            for candidate in candidates where KnowledgeGit.isInside(candidate.2) {
                if !((try? await git.run(["log", "-1", "--format=%H", "--", candidate.2])) ?? "").isEmpty { found = candidate; break }
            }
            guard let found else { throw Failure(message: "No note or map “\(name)” in the base, now or in its history.") }
            (kind, id, path) = found
        }
        let log: String
        do {
            log = try await git.run(["-c", "core.quotePath=false", "log", "--follow", "-M", "--name-status",
                                     "--format=%x1e%H%x1f%aI%x1f%s"] + (limit.map { ["-n", String($0)] } ?? []) + ["--", path])
        } catch {
            throw Failure(message: error.message)
        }
        let file = root.appending(path: path)
        let exists = FileWalk.isRegularFile(file)
        let status = (try? await git.run(["status", "--porcelain=v1", "--untracked-files=all", "--", path], extra: ["GIT_OPTIONAL_LOCKS": "0"])) ?? ""
        let modified = exists ? (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate : nil
        return KnowledgeHistory(kind: kind, id: id, path: path, exists: exists, pending: !status.isEmpty, modified: modified,
                                versions: KnowledgeHistory.parse(log: log))
    }

    /// The file's bytes in a version. Refused for a version that removed it.
    public func contents(of version: KnowledgeHistory.Version, env: HarnessEnvironment) async throws(Failure) -> Data {
        guard version.change != .deleted else {
            throw Failure(message: "\(version.short) removed \(version.path), so it holds no text; pick the version before it.")
        }
        do { return Data(try await KnowledgeGit(base: root, env: env).run(["cat-file", "blob", "\(version.commit):\(version.path)"]).utf8) } catch {
            throw Failure(message: error.message)
        }
    }

    /// What Restore of `name` to the version `rev` would write.
    public func planRestore(_ name: String, to rev: String, env: HarnessEnvironment) async throws(Failure) -> KnowledgeRestorePlan {
        let history = try await history(name, env: env)
        let version = try history.version(rev)
        let restored = try await contents(of: version, env: env)
        return KnowledgeRestorePlan(history: history, version: version, original: try? Data(contentsOf: root.appending(path: history.path)),
                                    restored: restored)
    }

    /// Writes a planned Restore: commits the pending edits first (U2), backs the file up
    /// (`~/.akit/local/backups/knowledge/<world>/<time>/`), writes the version's bytes (a removed
    /// file comes back) and commits "Restore ID to SHORT (DATE)". Refused when the file changed
    /// since the plan; on a commit failure the file is put back. Returns the backup.
    @discardableResult
    public func restore(_ plan: KnowledgeRestorePlan, env: HarnessEnvironment, now: Date = .now) async throws(Failure) -> URL? {
        guard plan.changes else { return nil }
        _ = await KnowledgeCommitQueue(base: root, env: env).flush()
        let file = root.appending(path: plan.path)
        guard (try? Data(contentsOf: file)) == plan.original else {
            throw Failure(message: "\(plan.path) changed after the restore was planned; nothing was written. Look at it again.")
        }
        var backup: URL?
        if let original = plan.original {
            do { backup = try backupNote(original, path: plan.path, home: env.homeDirectory, now: now) } catch {
                throw Failure(message: "Couldn't back up \(plan.path) (\(error.localizedDescription)); nothing was written.")
            }
        }
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try plan.restored.write(to: file, options: .atomic)
        } catch {
            throw Failure(message: "Couldn't write \(plan.path) (\(error.localizedDescription)); the file is as it was.")
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        let message = "Restore \(plan.history.id) to \(plan.version.short) (\(formatter.string(from: plan.version.date)))"
        do { try await KnowledgeGit(base: root, env: env).commit(paths: [plan.path], message: message) } catch {
            if let original = plan.original { try? original.write(to: file, options: .atomic) } else { try? fm.removeItem(at: file) }
            throw Failure(message: "Couldn't commit \(plan.path) (\(error.message)); the file is as it was.")
        }
        return backup
    }
}
