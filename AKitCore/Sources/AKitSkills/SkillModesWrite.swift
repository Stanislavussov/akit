import AKitFoundation
import Foundation

/// Changing `~/.akit/local/skill-modes.json`: one entry set or taken out, or a whole project
/// taken out. Through `SettingsFile`: a strict read (a file AKit can't read is never rewritten),
/// a minimal text edit checked against the intended tree, a preview of only the changed part,
/// a backup into `~/.akit/backups`, and a refusal when the touched values changed since the
/// preview. Hand edits are fine: every write reads the file again.
extension SkillModes {
    public struct Failure: Error, LocalizedError {
        public let message: String
        public var errorDescription: String? { message }
        public init(_ message: String) { self.message = message }
    }

    /// A planned change; `apply` carries it out.
    public struct Plan: Sendable {
        public let file: URL
        /// One line: what the change does, e.g. "tdd in github.com/o/r: Auto (was Manual)".
        public let summary: String
        /// The changed part only.
        public let diff: [TextDiff.Line]
        /// The file doesn't exist yet.
        public let creates: Bool
        /// Nothing to do (the entry is already so, or there is none to take out).
        public var changesNothing: Bool { change == nil }
        let change: SettingsFile.Change?
    }

    /// Sets `name`'s mode in `project`.
    public static func plan(set mode: SkillMode, name: String, project: String, home: URL) throws(Failure) -> Plan {
        try checkName(name)
        let file = file(home: home)
        let current = try readForWrite(file, home: home)
        let old = current.value(at: ["projects", project, name])
        let summary = "\(name) in \(project): \(mode.title)\(old.flatMap(modeTitle).map { " (was \($0))" } ?? " (was: its SKILL.md)")"
        if old == .string(mode.rawValue) { return Plan(file: file, summary: summary, diff: [], creates: false, change: nil) }
        var edits: [SettingsFile.Edit] = []
        if current.value(at: ["version"]) == nil { edits.append(.set(["version"], .number(String(version)))) }
        edits.append(.set(["projects", project, name], .string(mode.rawValue)))
        return try plan(file, edits: edits, summary: summary, home: home)
    }

    /// Takes `name`'s entry out of `project` (its SKILL.md decides again); the project too when
    /// that was its last entry.
    public static func plan(reset name: String, project: String, home: URL) throws(Failure) -> Plan {
        let file = file(home: home)
        let current = try readForWrite(file, home: home)
        guard let old = current.value(at: ["projects", project, name]) else {
            return Plan(file: file, summary: "\(name) has no entry in \(project); its SKILL.md decides already.", diff: [], creates: false, change: nil)
        }
        let others = (current.value(at: ["projects", project])?.objectMembers ?? [:]).count - 1
        let summary = "\(name) in \(project): back to its SKILL.md (was \(modeTitle(old) ?? old.compact))"
        return try plan(file, edits: [.remove(others > 0 ? ["projects", project, name] : ["projects", project])], summary: summary, home: home)
    }

    /// Takes every entry of `project` out.
    public static func plan(resetProject project: String, home: URL) throws(Failure) -> Plan {
        let file = file(home: home)
        let current = try readForWrite(file, home: home)
        guard let entries = current.value(at: ["projects", project]) else {
            return Plan(file: file, summary: "\(project) has no entries.", diff: [], creates: false, change: nil)
        }
        let count = entries.objectMembers?.count ?? 0
        return try plan(file, edits: [.remove(["projects", project])],
                        summary: "\(project): \(count) entr\(count == 1 ? "y" : "ies") taken out; the skills' SKILL.md decide again", home: home)
    }

    /// Writes the change (backup first). Refused when a value it touches changed since the plan.
    /// Returns the backup, nil for a new file or no change.
    @discardableResult
    public static func apply(_ plan: Plan, home: URL) throws(Failure) -> URL? {
        guard let change = plan.change else { return nil }
        let folder = plan.file.deletingLastPathComponent()
        do {
            // A new ~/.akit/local is the user's only (work project ids); an existing one is left as it is.
            if !FileManager.default.fileExists(atPath: folder.path) {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            }
        } catch {
            throw Failure("Couldn't create \(FileWalk.tilde(folder, home: home)): \(error.localizedDescription)")
        }
        // Checked again right before the write: a file someone broke since the plan stays as it is.
        _ = try readForWrite(plan.file, home: home)
        let backup: URL?
        do {
            backup = try SettingsFile.apply(change, home: home)
        } catch {
            throw Failure(error.message)
        }
        // Only the user reads it (work project ids); later writes keep the file's mode.
        if change.creates { chmod(plan.file.path, 0o600) }
        return backup
    }

    // MARK: - Pieces

    static func plan(_ file: URL, edits: [SettingsFile.Edit], summary: String, home: URL) throws(Failure) -> Plan {
        do {
            let change = try SettingsFile.change(file, edits: edits, home: home, limit: limit)
            // A new file: its whole text, not one excerpt per edit.
            let diff = change.creates ? TextDiff.lines(from: "", to: change.text.hasSuffix("\n") ? String(change.text.dropLast()) : change.text) : change.diff
            return Plan(file: file, summary: summary, diff: diff, creates: change.creates, change: change)
        } catch {
            throw Failure(error.message)
        }
    }

    /// The file's tree, or an empty object when there is none; refused when AKit can't read it
    /// (not JSON, another version): AKit never rewrites such a file.
    static func readForWrite(_ file: URL, home: URL) throws(Failure) -> JSONValue {
        let current: (data: Data, value: JSONValue)?
        do {
            current = try SettingsFile.read(file, home: home, limit: limit)
        } catch {
            throw Failure(error.message)
        }
        guard let current else { return .object([:]) }
        let reading = read(data: current.data, shown: FileWalk.tilde(file, home: home))
        if !reading.usable { throw Failure(reading.problems.first?.message ?? "\(FileWalk.tilde(file, home: home)) can't be read.") }
        if let projects = current.value.value(at: ["projects"]), projects.objectMembers == nil {
            throw Failure("\(FileWalk.tilde(file, home: home)) has a \"projects\" that is not an object. AKit won't change it; fix the file first.")
        }
        return current.value
    }

    static func checkName(_ name: String) throws(Failure) {
        guard !name.isEmpty, !name.contains("/"), name.trimmingCharacters(in: .whitespacesAndNewlines) == name else {
            throw Failure("“\(name)” is not a skill name.")
        }
    }

    static func modeTitle(_ value: JSONValue) -> String? {
        guard case .string(let word) = value, let mode = SkillMode(rawValue: word) else { return nil }
        return mode.title
    }
}
