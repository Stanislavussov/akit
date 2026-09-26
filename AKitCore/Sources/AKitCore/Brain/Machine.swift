import Foundation

/// This Mac's role, kept in `~/.akit/machine.json` and never in the brain.
/// On a work Mac nothing about its projects goes into the brain, because the brain is
/// pushed to a personal remote: project ids, answers and locks name the employer's repos.
public struct MachineProfile: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        case personal, work

        /// `work`, `Work`, ` WORK ` → `.work`.
        public init?(name: String) {
            self.init(rawValue: name.trimmingCharacters(in: .whitespaces).lowercased())
        }
    }

    public var kind: Kind
    /// Name used instead of the host name (which may name the employer), e.g. `work`.
    public var name: String?
    /// Set when `machine.json` exists but can't be read. Such a Mac counts as a work Mac
    /// (fail closed): a broken file must never send work projects to the brain.
    public private(set) var problem: String?

    private enum CodingKeys: String, CodingKey { case kind, name }

    public init(kind: Kind = .personal, name: String? = nil) {
        self.kind = kind
        let trimmed = name?.trimmingCharacters(in: .whitespaces)
        self.name = trimmed?.isEmpty == false ? trimmed : nil
    }

    public var isWork: Bool { kind == .work }

    /// Name for this Mac's home record: the chosen name; on a work Mac never the host name.
    public var homeName: String? { name ?? (isWork ? "work" : nil) }

    public static func file(home: URL) -> URL { home.appending(path: ".akit/machine.json") }

    /// No file means a personal Mac, as before this setting existed. A file that can't be
    /// read means a work Mac, with `problem` saying why.
    public static func load(home: URL) -> MachineProfile {
        let url = file(home: home)
        guard FileManager.default.fileExists(atPath: url.path) else { return MachineProfile() }
        do {
            return try JSONDecoder().decode(MachineProfile.self, from: Data(contentsOf: url))
        } catch {
            var profile = MachineProfile(kind: .work, name: "work")
            profile.problem = "\(url.path) can't be read, so this Mac counts as a work Mac. Fix it with akit machine work|personal."
            return profile
        }
    }

    public func save(home: URL) throws {
        let url = Self.file(home: home)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }

    /// Saves a new role for this Mac and says what that means. The home record follows
    /// the Mac: from the brain it is copied into the local store (a copy: the brain's one is
    /// history, maybe pushed already), inside the local store it is renamed, so
    /// `akit apply --home` still knows which files it wrote.
    public static func change(to profile: MachineProfile, brain brainRoot: URL, home: URL,
                              hostName: String = ProcessInfo.processInfo.hostName) throws -> [String] {
        let old = load(home: home)
        // A broken file says nothing about where records were kept; assume the brain, as before the file.
        let oldStore = old.problem == nil ? ProjectStore.current(brain: brainRoot, home: home, machine: old) : .brain(brainRoot)
        let oldHome = ProjectSetup.homeID(hostName: hostName, machineName: old.homeName)
        try profile.save(home: home)
        let newHome = ProjectSetup.homeID(hostName: hostName, machineName: profile.homeName)
        let local = ProjectStore.local(home: home)

        guard profile.isWork else {
            var notes = ["Personal Mac: from now on project ids, answers and locks are committed in the brain and reach its remote on the next sync."]
            if old.isWork { notes.append("Records kept on this Mac stay in \(local.root.path); AKit no longer reads them.") }
            return notes
        }
        var notes = ["Work Mac: answers and locks of projects stay in \(local.root.path); the brain gets nothing about them."]
        let fm = FileManager.default
        let from = oldStore.folder(id: oldHome), to = local.folder(id: newHome)
        if from != to, fm.fileExists(atPath: from.path), !fm.fileExists(atPath: to.path) {
            do {
                try fm.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
                if oldStore.isLocal {
                    try fm.moveItem(at: from, to: to)
                    notes.append("Renamed this Mac's home record from \(oldHome) to \(newHome).")
                } else {
                    try fm.copyItem(at: from, to: to)
                    notes.append("Copied this Mac's home record (projects/\(oldHome)) to the local folder.")
                }
            } catch {
                notes.append("Couldn't move this Mac's home record to \(to.path): \(error.localizedDescription). akit apply --home will treat its files as not written by AKit.")
            }
        }
        if !oldStore.isLocal {
            let earlier = BrainRemove.savedAnswers(in: .brain(brainRoot)).map(\.id)
            if !earlier.isEmpty {
                notes.append("""
                    The brain still has records saved before (by any Mac): \(earlier.joined(separator: ", ")). \
                    AKit reads them here when this Mac has none of its own, but never writes them. \
                    Remove work ones before the next sync: git -C \(brainRoot.path) rm -r projects/<id>, then commit. \
                    Ones already pushed stay in the remote's history.
                    """)
            }
        }
        if !hasOwnGitIdentity(brainRoot) {
            notes.append("""
                Skill and layer commits made on this Mac carry your global git name and email, which may be your work \
                ones. Give the brain its own: git -C \(brainRoot.path) config user.email <personal email> \
                (and user.name).
                """)
        }
        return notes
    }

    /// The brain repo sets `user.email` in its own `.git/config`.
    static func hasOwnGitIdentity(_ brainRoot: URL) -> Bool {
        guard let text = try? String(contentsOf: brainRoot.appending(path: ".git/config"), encoding: .utf8) else { return true }
        var inUser = false
        for raw in text.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") { inUser = line.lowercased() == "[user]" }
            else if inUser, line.lowercased().hasPrefix("email") { return true }
        }
        return false
    }
}

/// Where AKit keeps what it knows about projects: `<id>/answers.json` and `<id>/lock.json`.
/// On a personal Mac that is the brain's `projects/` folder, committed with the brain;
/// on a work Mac it is `~/.akit/local/projects/`, outside any git repo.
public struct ProjectStore: Hashable, Sendable {
    /// Folder holding `<id>/`.
    public let root: URL
    /// The brain repo when `root` is its `projects/` folder, so changes are committed
    /// there. nil for the local store: nothing is committed or pushed.
    public let brain: URL?
    /// Read, never written, when this store has nothing for a project: on a work Mac the
    /// brain's records from before the switch, so earlier renders stay known.
    public let readFallback: URL?

    public static func brain(_ brainRoot: URL) -> ProjectStore {
        ProjectStore(root: brainRoot.appending(path: "projects", directoryHint: .isDirectory), brain: brainRoot, readFallback: nil)
    }

    public static func local(home: URL, readingBrain brainRoot: URL? = nil) -> ProjectStore {
        ProjectStore(root: home.appending(path: ".akit/local/projects", directoryHint: .isDirectory), brain: nil,
                     readFallback: brainRoot.map { $0.appending(path: "projects", directoryHint: .isDirectory) })
    }

    /// The store for this Mac: local on a work Mac (or when `machine.json` is broken), else the brain's.
    public static func current(brain brainRoot: URL, home: URL) -> ProjectStore {
        current(brain: brainRoot, home: home, machine: MachineProfile.load(home: home))
    }

    public static func current(brain brainRoot: URL, home: URL, machine: MachineProfile) -> ProjectStore {
        machine.isWork ? local(home: home, readingBrain: brainRoot) : brain(brainRoot)
    }

    public var isLocal: Bool { brain == nil }

    public func folder(id: String) -> URL { root.appending(path: id, directoryHint: .isDirectory) }

    /// A saved file of a project: this store's, else the read-only fallback's.
    func savedFile(id: String, _ name: String) -> URL? {
        let own = folder(id: id).appending(path: name)
        if FileManager.default.fileExists(atPath: own.path) { return own }
        guard let fallback = readFallback?.appending(path: id).appending(path: name),
              FileManager.default.fileExists(atPath: fallback.path) else { return nil }
        return fallback
    }

    /// Same place (fallbacks aside), however the paths are spelled.
    func isSamePlace(as other: ProjectStore) -> Bool {
        root.standardizedFileURL.resolvingSymlinksInPath() == other.root.standardizedFileURL.resolvingSymlinksInPath()
            && isLocal == other.isLocal
    }

    /// Path of a project's folder for messages: `projects/<id>` inside the brain,
    /// else the full local path.
    public func describe(id: String) -> String {
        brain == nil ? folder(id: id).path : "projects/\(id)"
    }
}
