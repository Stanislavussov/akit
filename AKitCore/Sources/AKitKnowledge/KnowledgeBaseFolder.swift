import AKitBrain
import AKitFoundation
import Foundation

/// Where a world's base lives (K25): `~/.akit/local/knowledge/bases.json` (this Mac only, never in
/// the brain) maps a world to its folder, like one in the user's Obsidian vault; a world without
/// an entry has its base in `~/.akit/local/knowledge/<world>`. Any local folder is allowed except
/// inside the brain, in a synced folder, or a repo with a remote.
extension KnowledgeBase {
    /// `{"bases": {"work": "~/Notes/Vault/kb"}}`: a `~/` or absolute path per world.
    public struct Folders: Codable, Equatable, Sendable {
        public var bases: [String: String]

        public init(bases: [String: String] = [:]) { self.bases = bases }

        /// Empty when the file is missing; throws when it exists but can't be read, so a broken file
        /// is never overwritten with less.
        public static func load(home: URL) throws(Failure) -> Folders {
            let file = basesFile(home: home)
            guard FileManager.default.fileExists(atPath: file.path) else { return Folders() }
            do {
                return try JSONDecoder().decode(Folders.self, from: Data(contentsOf: file))
            } catch {
                throw Failure(message: "\(FileWalk.tilde(file, home: home)) can't be read (\(error.localizedDescription)). Fix it or remove it.")
            }
        }

        /// For readers: a broken file counts as empty (the doctor reports it).
        static func loadOrEmpty(home: URL) -> Folders { (try? load(home: home)) ?? Folders() }

        func save(home: URL) throws(Failure) {
            let file = basesFile(home: home)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            do {
                try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try (try encoder.encode(self) + Data("\n".utf8)).write(to: file, options: .atomic)
            } catch {
                throw Failure(message: "Couldn't write \(FileWalk.tilde(file, home: home)): \(error.localizedDescription)")
            }
        }

        /// The folder set for `world`, `~/` expanded; nil without an entry or for a relative path.
        public func url(of world: String, home: URL) -> URL? {
            guard let path = bases[world] else { return nil }
            if path == "~" { return home }
            if path.hasPrefix("~/") { return home.appending(path: String(path.dropFirst(2))).standardized }
            return path.hasPrefix("/") ? URL(filePath: path).standardized : nil
        }
    }

    /// `~/.akit/local/knowledge/bases.json`.
    public static func basesFile(home: URL) -> URL { folder(home: home).appending(path: "bases.json") }

    /// The folder of a world's base: the one set in `bases.json`, else `~/.akit/local/knowledge/<world>`.
    /// It may not exist or not be a base yet.
    public static func root(world: String, home: URL) -> URL {
        Folders.loadOrEmpty(home: home).url(of: world, home: home) ?? Self.world(world, home: home)
    }

    /// Whether `bases.json` sets the folder of `world`.
    public static func isConfigured(world: String, home: URL) -> Bool {
        Folders.loadOrEmpty(home: home).bases[world] != nil
    }

    /// The worlds Settings shows: every world set in `bases.json`, every base's world, and this
    /// Mac's kind (so a base can get its folder before it exists), sorted.
    public static func worlds(home: URL) -> [String] {
        let set = Folders.loadOrEmpty(home: home).bases.keys.filter(validWorld)
        let found = all(home: home).compactMap(\.world)
        return Array(Set(set + found + [MachineProfile.load(home: home).kind.rawValue])).sorted()
    }

    // MARK: - Allowed folders

    /// Folders a sync client uploads, under the home folder.
    static let syncedFolders = ["Library/Mobile Documents", "Library/CloudStorage", "Dropbox", "Google Drive"]

    /// The K25 refusals that need no git: inside the brain (`brainRoot`, default `~/.akit/registry`),
    /// in a synced folder (iCloud Drive, CloudStorage, Dropbox, Google Drive, a folder holding
    /// `.dropbox`), not on a local disk.
    public static func check(folder root: URL, home: URL, brainRoot: URL? = nil) throws(Failure) {
        let root = root.standardized
        let brain = brainRoot ?? Brain.defaultRoot(home: home)
        if isWithin(root, brain) {
            throw Failure(message: "\(root.path) is inside the brain (\(brain.path)), which goes to a remote. Pick a folder outside it, like \(world("work", home: home).path).")
        }
        for synced in syncedFolders where isWithin(root, home.appending(path: synced)) {
            throw Failure(message: "\(root.path) is in a synced folder (~/\(synced)), so its notes would leave this Mac. Pick a folder that isn't synced.")
        }
        let parts = resolved(root).split(separator: "/").map(String.init)
        for count in stride(from: parts.count, through: 0, by: -1) {
            let folder = "/" + parts.prefix(count).joined(separator: "/")
            if FileManager.default.fileExists(atPath: (folder as NSString).appendingPathComponent(".dropbox")) {
                throw Failure(message: "\(root.path) is in a Dropbox folder (\(folder)), so its notes would leave this Mac. Pick a folder that isn't synced.")
            }
        }
        var existing = URL(filePath: resolved(root))
        while !FileManager.default.fileExists(atPath: existing.path), existing.pathComponents.count > 1 {
            existing = existing.deletingLastPathComponent()
        }
        if (try? existing.resourceValues(forKeys: [.volumeIsLocalKey]))?.volumeIsLocal == false {
            throw Failure(message: "\(root.path) is not on a local disk (a network volume). Pick a folder on this Mac.")
        }
    }

    // MARK: - Set, reset, move

    /// What `setFolder` did.
    public struct FolderChange: Sendable, Equatable {
        public let base: KnowledgeBase
        /// A new base was made in the folder (`create(at:)`); false when it was one already.
        public let created: Bool
        /// The world's earlier base, which stays where it is and is no longer used.
        public let previous: URL?
    }

    /// `akit kb path WORLD --set PATH`, Settings → Knowledge → Choose…: `folder` becomes the base of
    /// `world`. A base already is used as it is; any other allowed folder becomes one in place
    /// (`create(at:)`: an empty folder, an Obsidian vault, a repo without a remote). The world's
    /// earlier base is left as it is. The default folder removes the entry.
    @discardableResult
    public static func setFolder(world: String, to folder: URL, env: HarnessEnvironment, brainRoot: URL? = nil) async throws(Failure) -> FolderChange {
        let home = env.homeDirectory
        let target = try checked(world: world, folder: folder)
        var set = try Folders.load(home: home)
        if let other = all(home: home).first(where: { $0.root == KnowledgeBase(root: target).root && $0.world != world }) {
            throw Failure(message: "\(target.path) is the base of the world \(other.name) already.")
        }
        let old = root(world: world, home: home)
        let previous = isBase(old) && KnowledgeBase(root: old) != KnowledgeBase(root: target) ? old : nil
        let created: Bool
        if isBase(target) {
            try check(folder: target, home: home, brainRoot: brainRoot)
            if let remotes = await KnowledgeGit(base: target, env: env).remotes(), !remotes.isEmpty {
                throw Failure(message: "\(target.path) is a git repo with a remote (\(remotes.joined(separator: ", "))); a knowledge base never has one. Pick another folder.")
            }
            created = false
        } else {
            _ = try await create(at: target, env: env, brainRoot: brainRoot)
            created = true
        }
        set.bases[world] = KnowledgeBase(root: target) == KnowledgeBase(root: Self.world(world, home: home)) ? nil : FileWalk.tilde(target, home: home)
        do { try set.save(home: home) } catch {
            throw Failure(message: (created ? "The base was created in \(target.path), but " : "") + error.message)
        }
        return FolderChange(base: KnowledgeBase(root: target, world: world), created: created, previous: previous)
    }

    /// `akit kb path WORLD --reset`, Reset to Default: removes the world's entry, so its base is
    /// `~/.akit/local/knowledge/<world>` again. Nothing is moved or deleted. Returns that folder.
    @discardableResult
    public static func resetFolder(world: String, home: URL) throws(Failure) -> URL {
        guard validWorld(world) else { throw Failure(message: "“\(world)” can't name a world: use letters, digits, - and _.") }
        var set = try Folders.load(home: home)
        if set.bases.removeValue(forKey: world) != nil { try set.save(home: home) }
        return Self.world(world, home: home)
    }

    /// `akit kb path WORLD --move PATH`, Move Base…: moves the world's base to `folder` (missing or
    /// an empty folder) and sets it in `bases.json`. The pending edits are committed first; when
    /// they can't be (the lock is held, git fails) nothing moves. On the same disk the folder is
    /// renamed; across disks it is copied, the copy compared byte for byte, and the old folder
    /// goes to the Trash. All or nothing: a failure leaves the base where it was.
    @discardableResult
    public static func move(world: String, to folder: URL, env: HarnessEnvironment, brainRoot: URL? = nil,
                            trash: (URL) throws -> URL? = Trash.move, copy forceCopy: Bool = false) async throws(Failure) -> KnowledgeBase {
        let home = env.homeDirectory, fm = FileManager.default
        let target = try checked(world: world, folder: folder)
        var set = try Folders.load(home: home)
        let current = KnowledgeBase(root: root(world: world, home: home)).root
        guard isBase(current) else {
            throw Failure(message: "The world \(world) has no base at \(current.path) to move. Set a folder with akit kb path \(world) --set PATH.")
        }
        guard !isWithin(target, current) else { throw Failure(message: "\(target.path) is inside the base itself.") }
        try check(folder: target, home: home, brainRoot: brainRoot)
        if fm.fileExists(atPath: target.path) {
            let contents = (try? fm.contentsOfDirectory(atPath: target.path)) ?? ["?"]
            guard FileWalk.isDirectory(target), contents.allSatisfy({ $0 == ".DS_Store" }) else {
                throw Failure(message: "\(target.path) exists and is not an empty folder. Pick a new or empty folder.")
            }
        }

        // U2/P8: the pending edits go into git first, then the lock keeps new ones out while it moves.
        let queue = KnowledgeCommitQueue(base: current, env: env)
        switch await queue.flush() {
        case .busy: throw Failure(message: "Another AKit is committing in the base; nothing was moved. Try again in a moment.")
        case .failed(let message): throw Failure(message: "The pending edits couldn't be committed first (\(message)); nothing was moved.")
        case .nothing, .committed: break
        }
        let lock: FileLock?
        do { lock = try FileLock.acquire(current.appending(path: queueLockName), timeout: 2) } catch {
            throw Failure(message: "Couldn't lock the base: \(error.localizedDescription); nothing was moved.")
        }
        guard let lock else { throw Failure(message: "Another AKit is committing in the base; nothing was moved. Try again in a moment.") }
        defer { lock.release() }
        guard queue.pending().isEmpty else { throw Failure(message: "New edits wait for their commit; nothing was moved. Try again in a moment.") }

        set.bases[world] = KnowledgeBase(root: target) == KnowledgeBase(root: Self.world(world, home: home)) ? nil : FileWalk.tilde(target, home: home)
        do {
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            if fm.fileExists(atPath: target.path) { try fm.removeItem(at: target) }
        } catch {
            throw Failure(message: "Couldn't prepare \(target.path): \(error.localizedDescription); nothing was moved.")
        }
        if !forceCopy, sameVolume(current, target.deletingLastPathComponent()) {
            do { try fm.moveItem(at: current, to: target) } catch {
                throw Failure(message: "Couldn't move \(current.path) to \(target.path): \(error.localizedDescription)")
            }
            do { try set.save(home: home) } catch {
                try? fm.moveItem(at: target, to: current)
                throw Failure(message: error.message + " The base stays in \(current.path).")
            }
        } else {
            do {
                try fm.copyItem(at: current, to: target)
                guard fm.contentsEqual(atPath: current.path, andPath: target.path) else {
                    throw Failure(message: "the copy differs from the base")
                }
                try set.save(home: home)
            } catch {
                try? fm.removeItem(at: target)
                throw Failure(message: "Couldn't copy the base to \(target.path) (\((error as? Failure)?.message ?? error.localizedDescription)); it stays in \(current.path).")
            }
            do { _ = try trash(current) } catch {
                // The copy is the base now; the old folder is only a leftover.
                throw Failure(message: "The base is in \(target.path) now, but the old folder couldn't go to the Trash: \(error.localizedDescription). Remove \(current.path) by hand.")
            }
        }
        return KnowledgeBase(root: target, world: world)
    }

    /// A valid world and an absolute folder, standardized.
    private static func checked(world: String, folder: URL) throws(Failure) -> URL {
        guard validWorld(world) else { throw Failure(message: "“\(world)” can't name a world: use letters, digits, - and _ (like work or personal).") }
        guard folder.path.hasPrefix("/") else { throw Failure(message: "\(folder.path) is not an absolute path.") }
        return URL(filePath: folder.standardized.path, directoryHint: .notDirectory)
    }

    /// Both folders are on one disk, so a rename moves the base.
    static func sameVolume(_ a: URL, _ b: URL) -> Bool {
        func volume(_ url: URL) -> NSObject? {
            var existing = url
            while !FileManager.default.fileExists(atPath: existing.path), existing.pathComponents.count > 1 {
                existing = existing.deletingLastPathComponent()
            }
            return (try? existing.resourceValues(forKeys: [.volumeIdentifierKey]))?.volumeIdentifier as? NSObject
        }
        guard let first = volume(a), let second = volume(b) else { return false }
        return first.isEqual(second)
    }
}
