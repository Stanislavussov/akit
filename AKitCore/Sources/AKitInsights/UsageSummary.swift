import AKitBrain
import Foundation

/// Per-machine usage summaries: counts per local day that other Macs read from the brain, so
/// recommendations sum skill use over every Mac. Nothing but counts, skill names and
/// description hashes: no paths, branches, prompts or session ids.
///
/// - `insights/machines/<id>.json` (personal Mac): every session, with first-request context
///   and the description hashes it saw (they feed `DescriptionWindow` on the other Macs).
/// - `insights/machines/<pseudonym>.json` (work Mac): only skills that are in the brain, only
///   their listed sessions and calls.
/// - `<ProjectStore>/<project>/usage/<id>.json`: the sessions bound to one project, like the
///   personal machine file. On a work Mac that store is local, so they never reach the brain.
///
/// A day's `skills` keep `[listed, model, user]`, where listed counts every listing, as older akit
/// versions read it. Only described exposures count toward a denominator, so each day also has
/// `described`: sessions that listed the skill with its description. A day without `described`
/// (written before it existed) is read like Pi data: its calls protect skills, its listings never
/// demote one. The version stays 1, so older and newer akit keep reading each other's files.
///
/// Days are local `yyyy-MM-dd`, the last 120 of them. After a kind switch a key's days start the
/// local day after `kindSince`; days up to it stay as that key's file had them, so a switched Mac
/// never counts a day under two keys. A clone's new keys start the local day after `idSince`:
/// the index it copied holds the original Mac's sessions, which that Mac publishes itself.
enum UsageSummary {
    static let version = 1
    static let retentionDays = 120
    static let ownKeysMeta = "own_machine_keys"

    /// One local day. Work summaries have only `skills` and `described`.
    struct Day: Codable, Equatable {
        var sessions: Int?
        /// Recorded context (input + cache read + cache write) of the first main request of the
        /// sessions started that day, and how many of them had one.
        var firstContextSum: Int?
        var firstContextN: Int?
        /// `[listedSessions, modelCalls, userCalls]`; all-zero entries are left out.
        var skills: [String: [Int]]
        /// Main sessions that listed the skill with its description, counted on the day of that first
        /// listing; zero entries are left out. `{}` on a day with listings but none described; nil
        /// in files of older akit versions, and on days with no listing at all.
        var described: [String: Int]?
    }

    /// Sessions that listed `skill` with its description that day; 0 on a day without `described`.
    static func described(_ day: Day, skill: String) -> Int { day.described?[skill] ?? 0 }

    struct File: Codable, Equatable {
        var version: Int
        /// The key: id or pseudonym.
        var machine: String
        /// Personal machine files only: the Mac's chosen name or host name.
        var name: String?
        /// ISO 8601 time of the publish; not compared when deciding whether anything changed.
        var updated: String?
        var days: [String: Day]
        /// Personal machine files only: `{skill: [[fromDay, hash], …]}`, each hash once with its first local day.
        var descHashes: [String: [[String]]]?

        /// Same counts, whenever they were published.
        func sameContent(as other: File?) -> Bool {
            guard var other else { return false }
            other.updated = updated
            return self == other
        }
    }

    // MARK: - Building

    /// Local `yyyy-MM-dd`.
    static func day(_ date: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    /// Start of the oldest local day kept.
    static func cutoff(now: Date, calendar: Calendar) -> Date {
        calendar.date(byAdding: .day, value: -(retentionDays - 1), to: calendar.startOfDay(for: now)) ?? now
    }

    /// Counts per local day from `from` on: every session, or those bound to `project` at a confidence of `bindings`.
    static func days(_ database: IndexDatabase, from: Date, project: String? = nil,
                     bindings: BindingSet = .default) throws -> [String: Day] {
        let local = "'unixepoch', 'localtime'"
        func join(_ column: String) -> String {
            project == nil ? "" : "JOIN bindings b ON b.session_key = \(column) AND b.project_id = ? AND b.confidence IN \(bindings.sqlList)"
        }
        let start = from.timeIntervalSince1970
        let values: [any SQLBindable] = (project.map { [$0] } ?? []) + [start]
        var days: [String: Day] = [:]
        func update(_ day: String?, _ change: (inout Day) -> Void) {
            guard let day else { return }
            var entry = days[day] ?? Day(sessions: 0, firstContextSum: 0, firstContextN: 0, skills: [:], described: [:])
            change(&entry)
            days[day] = entry
        }
        for row in try database.rows("""
            SELECT date(s.started, \(local)), COUNT(*), SUM(s.first), COUNT(s.first) FROM (
              SELECT s.started, (SELECT COALESCE(r.input, 0) + COALESCE(r.cache_read, 0) + COALESCE(r.cache_write, 0)
                FROM requests r WHERE r.session_key = s.key AND r.is_subagent = 0 ORDER BY r.ts IS NULL, r.ts LIMIT 1) AS first
              FROM sessions s \(join("s.key")) WHERE s.started >= ?) s GROUP BY 1
            """, values) {
            update(row[0].text) {
                $0.sessions = row[1].int ?? 0
                $0.firstContextSum = row[2].int ?? 0
                $0.firstContextN = row[3].int ?? 0
            }
        }
        // A main session counts on the day it first listed the skill.
        for row in try database.rows("""
            SELECT date(f.first, \(local)), f.skill, COUNT(*) FROM (
              SELECT l.session_key, l.skill, MIN(l.ts) AS first FROM skill_listings l \(join("l.session_key"))
              WHERE l.is_subagent = 0 AND l.ts IS NOT NULL GROUP BY l.session_key, l.skill) f
            WHERE f.first >= ? GROUP BY 1, 2
            """, values) {
            guard let skill = row[1].text, let count = row[2].int else { continue }
            update(row[0].text) { $0.skills[skill, default: [0, 0, 0]][0] += count }
        }
        // The same with its description: on the day it was first listed with one.
        for row in try database.rows("""
            SELECT date(f.first, \(local)), f.skill, COUNT(*) FROM (
              SELECT l.session_key, l.skill, MIN(l.ts) AS first FROM skill_listings l \(join("l.session_key"))
              WHERE l.is_subagent = 0 AND l.ts IS NOT NULL AND l.desc_hash IS NOT NULL GROUP BY l.session_key, l.skill) f
            WHERE f.first >= ? GROUP BY 1, 2
            """, values) {
            guard let skill = row[1].text, let count = row[2].int else { continue }
            update(row[0].text) { $0.described?[skill, default: 0] += count }
        }
        // Calls by the model (subagents and Pi included) and skill calls by the user (not built-in commands).
        for row in try database.rows("""
            SELECT date(c.ts, \(local)), c.skill, c.by, COUNT(*) FROM skill_calls c \(join("c.session_key"))
            WHERE c.ts >= ? AND c.skill IS NOT NULL
              AND \(InsightsStats.countedCallsSQL)
            GROUP BY 1, 2, 3
            """, values) {
            guard let skill = row[1].text, let count = row[3].int else { continue }
            let slot = row[2].text == "model" ? 1 : 2
            update(row[0].text) { $0.skills[skill, default: [0, 0, 0]][slot] += count }
        }
        return days.mapValues(withoutZeroSkills)
    }

    /// Leaves out all-zero skills and zero `described` entries; `described` stays (maybe `{}`) only
    /// on a day that lists a skill, so a reader can tell "none described" from "not recorded".
    static func withoutZeroSkills(_ day: Day) -> Day {
        var day = day
        day.skills = day.skills.filter { $0.value.contains { $0 != 0 } }
        day.described = day.described?.filter { $0.value > 0 }
        if day.described?.isEmpty == true, !day.skills.values.contains(where: { ($0.first ?? 0) > 0 }) { day.described = nil }
        return day
    }

    /// Every description hash per skill with the local day it was first listed, oldest first.
    static func descHashes(_ database: IndexDatabase) throws -> [String: [[String]]] {
        var hashes: [String: [[String]]] = [:]
        for row in try database.rows("""
            SELECT skill, desc_hash, date(MIN(ts), 'unixepoch', 'localtime') FROM skill_listings
            WHERE desc_hash IS NOT NULL AND ts IS NOT NULL GROUP BY skill, desc_hash
            """) {
            guard let skill = row[0].text, let hash = row[1].text, let day = row[2].text else { continue }
            hashes[skill, default: []].append([day, hash])
        }
        return hashes.mapValues { $0.sorted { ($0[0], $0[1]) < ($1[0], $1[1]) } }
    }

    /// The days of a key's file: the index's after `kindSince`, the old file's up to it, the last 120 only.
    static func merged(_ fresh: [String: Day], existing: File?, key: String, since: Date?, now: Date,
                       calendar: Calendar) -> [String: Day] {
        let oldest = day(cutoff(now: now, calendar: calendar), calendar: calendar)
        guard let since else { return fresh.filter { $0.key >= oldest } }
        let switchDay = day(since, calendar: calendar)
        var days = fresh.filter { $0.key > switchDay && $0.key >= oldest }
        if let existing, existing.machine == key {
            for (day, entry) in existing.days where day <= switchDay && day >= oldest { days[day] = entry }
        }
        return days
    }

    /// This Mac's machine file: the personal shape under its id, the work shape under its pseudonym.
    static func machineFile(_ database: IndexDatabase, profile: MachineProfile, name: String?, brainSkills: Set<String>,
                            existing: File?, now: Date, calendar: Calendar = .current) throws -> File? {
        guard let key = profile.summaryKey else { return nil }
        let fresh = try days(database, from: cutoff(now: now, calendar: calendar))
        var days = merged(fresh, existing: existing, key: key, since: profile.summarySince, now: now, calendar: calendar)
        let updated = now.formatted(.iso8601)
        guard profile.isWork else {
            return File(version: version, machine: key, name: name, updated: updated, days: days,
                        descHashes: try descHashes(database))
        }
        // Work: skills in the brain, their listed and described sessions and calls; nothing else.
        days = days.compactMapValues { day in
            let skills = day.skills.filter { brainSkills.contains($0.key) && $0.value.count == 3 && $0.value.contains { $0 != 0 } }
            let entry = withoutZeroSkills(Day(skills: skills, described: day.described?.filter { brainSkills.contains($0.key) }))
            return entry.skills.isEmpty && entry.described?.isEmpty != false ? nil : entry
        }
        return File(version: version, machine: key, updated: updated, days: days)
    }

    /// One project's file under this Mac's id.
    static func projectFile(_ database: IndexDatabase, project: String, profile: MachineProfile, existing: File?,
                            bindings: BindingSet = .default, now: Date, calendar: Calendar = .current) throws -> File? {
        guard let id = profile.id else { return nil }
        let fresh = try days(database, from: cutoff(now: now, calendar: calendar), project: project, bindings: bindings)
        return File(version: version, machine: id, updated: now.formatted(.iso8601),
                    days: merged(fresh, existing: existing, key: id, since: profile.summarySince, now: now, calendar: calendar))
    }

    /// Projects with sessions bound at `bindings`. Ids that could leave the store's folder are skipped.
    static func boundProjects(_ database: IndexDatabase, bindings: BindingSet = .default) throws -> [String] {
        try database.rows("""
            SELECT DISTINCT project_id FROM bindings WHERE project_id IS NOT NULL AND confidence IN \(bindings.sqlList) ORDER BY 1
            """).compactMap { $0[0].text }.filter(isSafeProjectID)
    }

    static func isSafeProjectID(_ id: String) -> Bool {
        !id.isEmpty && !id.hasPrefix("/") && !id.contains("\\") && !id.split(separator: "/", omittingEmptySubsequences: false)
            .contains { $0.isEmpty || $0 == "." || $0 == ".." }
    }

    // MARK: - Files

    /// Sorted keys, one day (and one skill's hashes) per line, so git diffs stay small and bytes stable.
    static func encode(_ file: File) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        func json(_ value: some Encodable) -> String { (try? encoder.encode(value)).map { String(decoding: $0, as: UTF8.self) } ?? "null" }
        func block<Value: Encodable>(_ entries: [String: Value]) -> String {
            guard !entries.isEmpty else { return "{}" }
            return "{\n" + entries.keys.sorted().map { "  \(json($0)): \(json(entries[$0]))" }.joined(separator: ",\n") + "\n}"
        }
        var fields = ["\"days\": " + block(file.days)]
        if let hashes = file.descHashes { fields.append("\"descHashes\": " + block(hashes)) }
        fields.append("\"machine\": " + json(file.machine))
        if let name = file.name { fields.append("\"name\": " + json(name)) }
        if let updated = file.updated { fields.append("\"updated\": " + json(updated)) }
        fields.append("\"version\": \(file.version)")
        return Data(("{\n" + fields.joined(separator: ",\n") + "\n}\n").utf8)
    }

    static func read(_ url: URL) -> File? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(File.self, from: data)
    }

    static func machineFolder(brain: URL) -> URL { brain.appending(path: "insights/machines", directoryHint: .isDirectory) }

    static func machinePath(_ key: String) -> String { "insights/machines/\(key).json" }

    static func projectURL(_ project: String, key: String, in store: ProjectStore) -> URL {
        store.folder(id: project).appending(path: "usage/\(key).json")
    }

    /// Projects with a summary file of this key in the store, by project id.
    static func projectsWithFile(of key: String, in store: ProjectStore) -> [String] {
        let base = store.root.standardizedFileURL.path
        guard let walker = FileManager.default.enumerator(at: store.root, includingPropertiesForKeys: nil) else { return [] }
        var found: [String] = []
        for case let url as URL in walker where url.lastPathComponent == "\(key).json"
            && url.deletingLastPathComponent().lastPathComponent == "usage" {
            let folder = url.deletingLastPathComponent().deletingLastPathComponent().standardizedFileURL.path
            guard folder.count > base.count + 1 else { continue }
            found.append(String(folder.dropFirst(base.count + 1)))
        }
        return found.sorted()
    }

    /// This key's project summary files, as `projects/<id>/usage/<key>.json` (brain) or full paths (local store).
    static func projectFiles(of key: String, in store: ProjectStore) -> [String] {
        projectsWithFile(of: key, in: store).map { "\(store.describe(id: $0))/usage/\(key).json" }
    }

    /// Other Macs' summaries: machine files by key and project files by project, then key.
    struct Others: Equatable {
        var machines: [String: File] = [:]
        var projects: [String: [String: File]] = [:]

        /// Description hashes other Macs saw, for `DescriptionWindow`.
        var descHashes: [String: [DescriptionWindow.OtherMacHash]] {
            var hashes: [String: [DescriptionWindow.OtherMacHash]] = [:]
            for file in machines.values {
                for (skill, pairs) in file.descHashes ?? [:] {
                    hashes[skill, default: []] += pairs.compactMap { $0.count == 2 ? .init(fromDay: $0[0], hash: $0[1]) : nil }
                }
            }
            return hashes
        }
    }

    /// Which summary keys are this Mac's, for reading the other Macs' files.
    struct Ownership: Equatable {
        /// Left out: this Mac's own keys (its index has those days).
        var own: Set<String> = []
        /// Keys of the Mac this one was cloned from, with the last local day of theirs the copied
        /// index holds: only their later days are read.
        var copied: [String: String] = [:]
    }

    /// `machine` is taken as the next publish will identify it (in memory, never saved, and not while
    /// `machine.json` is broken): a Mac cloned since its last publish still carries the original's id
    /// and hardware, so without this it would take the original's key for its own and hide that Mac's later days.
    static func ownership(_ database: IndexDatabase, machine: MachineProfile, hardware: String?, now: Date = Date(),
                          calendar: Calendar = .current) -> Ownership {
        let keys = ownKeys(database)
        var machine = machine
        if machine.problem == nil { _ = machine.identify(hardware: hardware, own: keys, now: now) }
        let own = keys.published(by: machine.hardwareHash, cloned: machine.idSince != nil).all
            .union([machine.id, machine.pseudonym].compactMap { $0 })
        let foreign = keys.all.subtracting(own)
        // Without the clone's day it's unknown which of their days the index holds: all of them are left out.
        guard let since = machine.idSince else { return Ownership(own: own.union(foreign)) }
        let cloneDay = day(since, calendar: calendar)
        return Ownership(own: own, copied: Dictionary(uniqueKeysWithValues: foreign.map { ($0, cloneDay) }))
    }

    /// Reads the other Macs' files, the last 120 days of them. This Mac's own keys are left out by
    /// key, never by name (two Macs may share a name); a copied key's days only after its day.
    /// Files whose key doesn't match their name are skipped.
    static func load(brain: URL, store: ProjectStore?, ownership: Ownership, now: Date = Date(),
                     calendar: Calendar = .current) -> Others {
        var others = Others()
        let fm = FileManager.default
        let oldest = day(cutoff(now: now, calendar: calendar), calendar: calendar)
        func current(_ file: File, key: String) -> File {
            var file = file
            let after = ownership.copied[key]
            file.days = file.days.filter { entry in entry.key >= oldest && after.map { entry.key > $0 } ?? true }
            return file
        }
        let keys = ownership.own
        let folder = machineFolder(brain: brain)
        for name in (try? fm.contentsOfDirectory(atPath: folder.path)) ?? [] where name.hasSuffix(".json") {
            let key = String(name.dropLast(5))
            guard !keys.contains(key), let file = read(folder.appending(path: name)), file.version == version, file.machine == key else { continue }
            others.machines[key] = current(file, key: key)
        }
        guard let store, let walker = fm.enumerator(at: store.root, includingPropertiesForKeys: nil) else { return others }
        let base = store.root.standardizedFileURL.path
        for case let url as URL in walker where url.pathExtension == "json" && url.deletingLastPathComponent().lastPathComponent == "usage" {
            let key = url.deletingPathExtension().lastPathComponent
            let folder = url.deletingLastPathComponent().deletingLastPathComponent().standardizedFileURL.path
            guard !keys.contains(key), folder.count > base.count + 1, let file = read(url), file.version == version,
                  file.machine == key else { continue }
            others.projects[String(folder.dropFirst(base.count + 1)), default: [:]][key] = current(file, key: key)
        }
        return others
    }

    // MARK: - Own keys

    static func ownKeys(_ database: IndexDatabase) -> MachineProfile.OwnKeys {
        guard let text = try? database.meta(ownKeysMeta),
              let keys = try? JSONDecoder().decode(MachineProfile.OwnKeys.self, from: Data(text.utf8)) else { return .init() }
        return keys
    }

    /// Own keys from this Mac's index, if it has one; never creates it.
    static func ownKeys(home: URL) -> MachineProfile.OwnKeys {
        let url = InsightsPaths(home: home).database
        guard FileManager.default.fileExists(atPath: url.path), let database = try? IndexSchema.open(url) else { return .init() }
        return ownKeys(database)
    }

    /// Adds keys this Mac published under (kept in publish order, each once), with its hardware
    /// hash and `idSince`.
    static func remember(id: String, pseudonym: String?, hardware: String?, since: Date?, in database: IndexDatabase) throws {
        var keys = ownKeys(database)
        func add(_ key: String, to list: inout [String]) {
            list.removeAll { $0 == key }
            list.append(key)
        }
        add(id, to: &keys.ids)
        if let pseudonym { add(pseudonym, to: &keys.pseudonyms) }
        for key in [id, pseudonym].compactMap({ $0 }) {
            if let hardware { keys.hardware[key] = hardware }
            if let since { keys.since[key] = ISO8601DateFormatter().string(from: since) }
        }
        let text = String(decoding: try JSONEncoder().encode(keys), as: UTF8.self)
        try database.setMeta(ownKeysMeta, text)
    }
}
