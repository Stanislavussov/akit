import Foundation

/// When each skill's current description started: its counting window starts there, so a skill
/// whose description changed is judged only by sessions that saw the new text.
///
/// - Brain skills: the author date of the newest commit of `skills/<name>/SKILL.md` whose
///   description differs from the one before it. Author dates survive rebases, so every Mac gets
///   the same answer. Cached in `meta` per brain HEAD.
/// - Other skills: a window restarts only on a description hash never seen before for the skill,
///   here or on another Mac. Going back to an earlier text (harness versions that alternate
///   between two texts) never restarts it, and name-only listing lines (no hash) never do.
enum DescriptionWindow {
    /// A description hash another Mac saw first on `fromDay` (its local `yyyy-MM-dd`).
    struct OtherMacHash: Equatable {
        let fromDay: String
        let hash: String
    }

    struct Start: Equatable {
        let date: Date
        /// Distinct description texts seen (here and on other Macs); 0 when only names were listed.
        let versions: Int
    }

    /// The hash rule for every skill listed on this Mac (or on another one). The start is the first
    /// sight of the newest never-seen hash: the latest of each hash's first sight. A skill never
    /// listed with a description starts at its first listing.
    static func hashStarts(_ database: IndexDatabase, otherMacs: [String: [OtherMacHash]] = [:],
                           calendar: Calendar = .current) throws -> [String: Start] {
        var firstSeen: [String: [String: Date]] = [:]
        var firstListed: [String: Date] = [:]
        for row in try database.rows("SELECT skill, desc_hash, MIN(ts) FROM skill_listings WHERE ts IS NOT NULL GROUP BY skill, desc_hash") {
            guard let skill = row[0].text, let ts = row[2].double else { continue }
            let date = Date(timeIntervalSince1970: ts)
            firstListed[skill] = min(firstListed[skill] ?? date, date)
            if let hash = row[1].text { firstSeen[skill, default: [:]][hash] = date }
        }
        for (skill, hashes) in otherMacs {
            for entry in hashes {
                guard let date = day(entry.fromDay, calendar: calendar) else { continue }
                firstSeen[skill, default: [:]][entry.hash] = min(firstSeen[skill]?[entry.hash] ?? date, date)
            }
        }
        var starts: [String: Start] = [:]
        for skill in Set(firstListed.keys).union(firstSeen.keys) {
            let hashes = firstSeen[skill] ?? [:]
            if let newest = hashes.values.max() {
                starts[skill] = Start(date: newest, versions: hashes.count)
            } else if let first = firstListed[skill] {
                starts[skill] = Start(date: first, versions: 0)
            }
        }
        return starts
    }

    /// Start of a local `yyyy-MM-dd` day.
    static func day(_ text: String, calendar: Calendar) -> Date? {
        let parts = text.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }

    // MARK: - Brain skills

    static let cacheKey = "brainDescriptionWindows"
    /// Commits of one SKILL.md looked at, newest first.
    static let maxCommits = 200
    static let gitBudget: TimeInterval = 10
    static let callTimeout: TimeInterval = 5

    private struct Cache: Codable {
        let head: String
        var starts: [String: Double]
    }

    /// The brain rule for these brain skills (folder names). Skills git can't answer within the
    /// budget are missing (the caller falls back to the hash rule) and are tried again next time.
    static func brainStarts(brainRoot: URL, skills: Set<String>, database: IndexDatabase, env: HarnessEnvironment,
                            run: CommandRunner? = nil, budget: TimeInterval = gitBudget) async -> [String: Date] {
        guard !skills.isEmpty, let git = env.findExecutable("git") else { return [:] }
        let run = run ?? CaptureInstaller.liveRunner(env)
        let deadline = Date().addingTimeInterval(budget)
        func call(_ arguments: [String]) async -> String? {
            let left = deadline.timeIntervalSinceNow
            guard left > 0, let result = await run(git, arguments, brainRoot, min(callTimeout, left)), result.succeeded else { return nil }
            return result.output
        }
        guard let head = await call(["rev-parse", "HEAD"])?.trimmingCharacters(in: .whitespacesAndNewlines), !head.isEmpty else {
            return [:]
        }
        let stored = (try? database.value("SELECT value FROM meta WHERE key = ?", cacheKey))?.text
            .flatMap { try? JSONDecoder().decode(Cache.self, from: Data($0.utf8)) }
        var cache = stored?.head == head ? stored ?? Cache(head: head, starts: [:]) : Cache(head: head, starts: [:])
        var changed = false
        for skill in skills.sorted() where cache.starts[skill] == nil {
            guard let date = await descriptionChange(of: skill, call: call) else { continue }
            cache.starts[skill] = date.timeIntervalSince1970
            changed = true
        }
        if changed, let data = try? JSONEncoder().encode(cache) {
            _ = try? database.run("INSERT INTO meta(key, value) VALUES(?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                                  cacheKey, String(decoding: data, as: UTF8.self))
        }
        return cache.starts.filter { skills.contains($0.key) }.mapValues(Date.init(timeIntervalSince1970:))
    }

    /// Author date of the newest commit whose description differs from the commit before it in
    /// the file's history (or that created the file). nil when git gives no answer.
    private static func descriptionChange(of skill: String, call: (_ arguments: [String]) async -> String?) async -> Date? {
        let path = "skills/\(skill)/SKILL.md"
        guard let log = await call(["log", "-n", "\(maxCommits)", "--format=%H%x09%aI", "--", path]) else { return nil }
        let commits: [(hash: String, date: Date)] = log.split(whereSeparator: \.isNewline).compactMap { line in
            let parts = line.split(separator: "\t", maxSplits: 1).map(String.init)
            guard parts.count == 2, let date = ISO8601DateFormatter().date(from: parts[1]) else { return nil }
            return (parts[0], date)
        }
        guard !commits.isEmpty else { return nil }
        /// nil when git can't show the file in that commit.
        func description(at commit: String) async -> String? {
            await call(["show", "\(commit):\(path)"]).map { Frontmatter.parse($0)["description"] ?? "" }
        }
        guard var current = await description(at: commits[0].hash) else { return nil }
        for index in commits.indices {
            guard index + 1 < commits.count else { return commits[index].date }
            guard let older = await description(at: commits[index + 1].hash) else { return nil }
            if older != current { return commits[index].date }
            current = older
        }
        return commits.last?.date
    }
}
