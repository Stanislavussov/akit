import AKitFoundation
import Foundation
import IOKit

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
    /// Random, 16 hex characters: the key of this Mac's usage summaries while it is personal.
    public var id: String?
    /// `work-` and 6 random hex characters, made on the first switch to work and kept forever:
    /// the key of its usage summaries while it is a work Mac. Never derived from the host.
    public var pseudonym: String?
    /// When the kind last changed. A key's summary days start the local day after it, so a
    /// switched Mac never counts a day under two keys.
    public var kindSince: Date?
    /// SHA-256 of the Mac's hardware UUID; never published. A different one means this file
    /// was copied to another Mac (Migration Assistant, Time Machine), which gets its own keys.
    public var hardwareHash: String?
    /// When this Mac got keys of its own after being cloned from another one: the copied index
    /// holds that Mac's sessions up to here, so the new keys' days start the local day after it.
    public var idSince: Date?

    private enum CodingKeys: String, CodingKey { case kind, name, id, pseudonym, kindSince, hardwareHash, idSince }

    public init(kind: Kind = .personal, name: String? = nil) {
        self.kind = kind
        let trimmed = name?.trimmingCharacters(in: .whitespaces)
        self.name = trimmed?.isEmpty == false ? trimmed : nil
    }

    // Files written before the keys existed have only kind and name.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        kind = try container.decode(Kind.self, forKey: .kind)
        name = try container.decodeIfPresent(String.self, forKey: .name)
        id = try container.decodeIfPresent(String.self, forKey: .id)
        pseudonym = try container.decodeIfPresent(String.self, forKey: .pseudonym)
        hardwareHash = try container.decodeIfPresent(String.self, forKey: .hardwareHash)
        for key in [CodingKeys.kindSince, .idSince] {
            guard let since = try container.decodeIfPresent(String.self, forKey: key) else { continue }
            guard let date = ISO8601DateFormatter().date(from: since) else {
                throw DecodingError.dataCorruptedError(forKey: key, in: container, debugDescription: "Not an ISO 8601 date: \(since)")
            }
            if key == .kindSince { kindSince = date } else { idSince = date }
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind, forKey: .kind)
        try container.encodeIfPresent(name, forKey: .name)
        try container.encodeIfPresent(id, forKey: .id)
        try container.encodeIfPresent(pseudonym, forKey: .pseudonym)
        try container.encodeIfPresent(kindSince.map { ISO8601DateFormatter().string(from: $0) }, forKey: .kindSince)
        try container.encodeIfPresent(hardwareHash, forKey: .hardwareHash)
        try container.encodeIfPresent(idSince.map { ISO8601DateFormatter().string(from: $0) }, forKey: .idSince)
    }

    /// The key this Mac's machine summary is published under: the pseudonym on a work Mac, else the id.
    public var summaryKey: String? { isWork ? pseudonym : id }

    public var isWork: Bool { kind == .work }

    /// Where this Mac's summary days start: the later of the kind switch and the clone (`idSince`).
    public var summarySince: Date? {
        switch (kindSince, idSince) {
        case let (kind?, id?): max(kind, id)
        case let (kind, id): kind ?? id
        }
    }

    /// Name for this Mac's home record: the chosen name; on a work Mac never the host name.
    public var homeName: String? { name ?? (isWork ? "work" : nil) }

    /// Name for this Mac in usage summaries and evidence: the chosen name, else the host name without `.local`.
    public func displayName(hostName: String) -> String {
        name ?? (hostName.hasSuffix(".local") ? String(hostName.dropLast(".local".count)) : hostName)
    }

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

    /// Keys this Mac published usage summaries under, oldest first. Kept in the session index
    /// (`meta.own_machine_keys`), so a lost `machine.json` gets its keys back. The index travels
    /// with a clone (Migration Assistant, Time Machine), so each key also records the hardware that
    /// published it: a clone never takes the original Mac's keys for its own.
    public struct OwnKeys: Codable, Equatable, Sendable {
        public var ids: [String] = []
        public var pseudonyms: [String] = []
        /// Key → hardware hash of the Mac that published it. Keys published before this was kept have none.
        public var hardware: [String: String] = [:]
        /// Key → `idSince` of the Mac that published it (ISO 8601), so a lost `machine.json` gets it back.
        public var since: [String: String] = [:]

        public init(ids: [String] = [], pseudonyms: [String] = [], hardware: [String: String] = [:], since: [String: String] = [:]) {
            self.ids = ids
            self.pseudonyms = pseudonyms
            self.hardware = hardware
            self.since = since
        }

        private enum CodingKeys: String, CodingKey { case ids, pseudonyms, hardware, since }

        // Older indexes have only ids and pseudonyms.
        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            ids = try container.decodeIfPresent([String].self, forKey: .ids) ?? []
            pseudonyms = try container.decodeIfPresent([String].self, forKey: .pseudonyms) ?? []
            hardware = try container.decodeIfPresent([String: String].self, forKey: .hardware) ?? [:]
            since = try container.decodeIfPresent([String: String].self, forKey: .since) ?? [:]
        }

        public var all: Set<String> { Set(ids + pseudonyms) }

        /// The keys the Mac with this hardware published: those recorded with its hardware, and
        /// ones without a record unless the Mac is a clone (they may be the original's then).
        /// Without a hardware hash only the unrecorded ones count.
        public func published(by hardware: String?, cloned: Bool) -> OwnKeys {
            func mine(_ key: String) -> Bool {
                guard let recorded = self.hardware[key] else { return !cloned }
                return recorded == hardware
            }
            return OwnKeys(ids: ids.filter(mine), pseudonyms: pseudonyms.filter(mine),
                           hardware: self.hardware.filter { mine($0.key) }, since: since.filter { mine($0.key) })
        }

        func sinceDate(_ key: String) -> Date? { since[key].flatMap { ISO8601DateFormatter().date(from: $0) } }
    }

    /// Forgets why `machine.json` couldn't be read, for a profile about to be saved over it.
    public mutating func clearProblem() {
        problem = nil
    }

    /// Fills in what the profile lacks: the hardware hash, an id (the last one this Mac published
    /// under, else a new random one) and, on a work Mac, a pseudonym (likewise). A profile copied
    /// from another Mac (another hardware hash) gets a new id and a new pseudonym: the keys it
    /// carries belong to that Mac, and so do the sessions its copied index holds up to now, so
    /// `idSince` makes the new keys' days start after today. Returns whether anything changed.
    public mutating func identify(hardware: String?, own: OwnKeys, now: Date = Date()) -> Bool {
        let before = self
        if let hardware, let stored = hardwareHash, stored != hardware {
            // Keys this hardware published before (the file was copied back) are its own again.
            let mine = own.published(by: hardware, cloned: true)
            id = mine.ids.last
            pseudonym = mine.pseudonyms.last
            idSince = id.flatMap(own.sinceDate)
            if id == nil {
                id = Self.newID()
                idSince = now
            }
        }
        if let hardware { hardwareHash = hardware }
        if id == nil {
            let mine = own.published(by: hardwareHash, cloned: idSince != nil)
            if let last = mine.ids.last {
                id = last
                idSince = idSince ?? own.sinceDate(last)
            } else {
                id = Self.newID()
                // An index with keys of another Mac only: its sessions are that Mac's.
                if !own.ids.isEmpty, idSince == nil { idSince = now }
            }
        }
        if isWork, pseudonym == nil {
            pseudonym = own.published(by: hardwareHash, cloned: idSince != nil).pseudonyms.last ?? Self.newPseudonym()
        }
        return self != before
    }

    static func newID() -> String { randomHex(16) }
    static func newPseudonym() -> String { "work-" + randomHex(6) }

    private static func randomHex(_ count: Int) -> String {
        var generator = SystemRandomNumberGenerator()
        return String((0..<count).map { _ in Array("0123456789abcdef")[Int.random(in: 0..<16, using: &generator)] })
    }

    /// SHA-256 of this Mac's `IOPlatformUUID`; nil when IOKit doesn't give it.
    public static func currentHardwareHash() -> String? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        guard let uuid = IORegistryEntryCreateCFProperty(service, "IOPlatformUUID" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? String, !uuid.isEmpty else { return nil }
        return Checksum.sha256(Data(uuid.utf8))
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
    public func savedFile(id: String, _ name: String) -> URL? {
        let own = folder(id: id).appending(path: name)
        if FileManager.default.fileExists(atPath: own.path) { return own }
        guard let fallback = readFallback?.appending(path: id).appending(path: name),
              FileManager.default.fileExists(atPath: fallback.path) else { return nil }
        return fallback
    }

    /// Same place (fallbacks aside), however the paths are spelled.
    public func isSamePlace(as other: ProjectStore) -> Bool {
        root.standardizedFileURL.resolvingSymlinksInPath() == other.root.standardizedFileURL.resolvingSymlinksInPath()
            && isLocal == other.isLocal
    }

    /// Path of a project's folder for messages: `projects/<id>` inside the brain,
    /// else the full local path.
    public func describe(id: String) -> String {
        brain == nil ? folder(id: id).path : "projects/\(id)"
    }
}
