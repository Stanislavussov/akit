import AKitFoundation
import AKitHarnesses
import AKitModel
import Foundation

/// How a harness offers a skill to the model, set in the harness's own settings, never in
/// the skill's files.
public enum SkillSwitchState: String, CaseIterable, Hashable, Sendable {
    /// Name and description are listed to the model; `/name` runs it.
    case on
    /// Claude Code only: listed by name, without the description.
    case nameOnly = "name-only"
    /// Claude Code's `user-invocable-only`: hidden from the model, `/name` still runs it.
    case manual = "user-invocable-only"
    /// Hidden from the model and from the `/` menu.
    case off

    public var title: String {
        switch self {
        case .on: "On"
        case .nameOnly: "Name Only"
        case .manual: "Manual"
        case .off: "Off"
        }
    }

    /// The word `akit skills set --state` takes.
    public var argument: String {
        switch self {
        case .on: "on"
        case .nameOnly: "name-only"
        case .manual: "manual"
        case .off: "off"
        }
    }

    public init?(argument: String) {
        guard let state = Self.allCases.first(where: { $0.argument == argument }) else { return nil }
        self = state
    }
}

/// Turning a skill on or off per harness (docs/design/harness-support.md, "Skill switches"):
/// Claude Code's `skillOverrides` in `~/.claude/settings.json`, Pi's `skills` entries in
/// `~/.pi/agent/settings.json` (or a project's `.pi/settings.json` for its own skills).
/// Only that one entry changes; every other byte of the file stays.
public enum SkillSwitches {
    /// The harnesses with a switch.
    public static let harnesses: [HarnessID] = [.claudeCode, .pi]

    public struct Failure: Error, LocalizedError {
        public let message: String
        public var errorDescription: String? { message }
    }

    /// What a harness offers for one skill.
    public struct Options: Hashable, Sendable {
        /// The states this harness supports for the skill; empty when `unavailable`.
        public let states: [SkillSwitchState]
        /// The settings file the switch writes.
        public let file: URL
        /// The key it writes, for tooltips: `skillOverrides."tdd"` or `skills: -skills/tdd/SKILL.md`.
        public let key: String
        /// Why there is no switch (a plugin skill, a Pi package skill).
        public let unavailable: String?
        /// Something to know before switching (the name applies everywhere, the file narrows the states).
        public let note: String?
    }

    /// nil when the harness doesn't see the skill or has no switch.
    public static func options(for skill: Skill, harness: HarnessID, in env: HarnessEnvironment) -> Options? {
        guard skill.visibleTo.contains(harness), let file = settingsFile(for: skill, harness: harness, in: env) else { return nil }
        switch harness {
        case .claudeCode:
            let key = "skillOverrides.\(JSONValue.string(skill.name).compact)"
            if case .plugin = skill.scope {
                return Options(states: [], file: file, key: key,
                               unavailable: "Claude Code ignores skillOverrides for plugin skills; turn the plugin on or off with /plugin.",
                               note: nil)
            }
            if skill.name == "__proto__" {
                return Options(states: [], file: file, key: key,
                               unavailable: "Claude Code can't store a setting for a skill with this name.", note: nil)
            }
            var notes = ["The entry is by name: it applies to every skill named \(skill.name), in every project (a project's own .claude/settings.json entry wins)."]
            var states = SkillSwitchState.allCases
            if skill.disablesModelInvocation {
                states = [.manual, .off]
                notes.append("Its SKILL.md sets disable-model-invocation, so Claude Code offers only Manual and Off.")
            }
            return Options(states: states, file: file, key: key, unavailable: nil, note: notes.joined(separator: " "))
        case .pi:
            guard let place = skill.places[.pi] else { return nil }
            let key = "skills: -\(place.relativePath)"
            if case .package = skill.scope {
                return Options(states: [], file: file, key: "packages",
                               unavailable: "A Pi package skill is switched in its package's entry (pi config); AKit doesn't change package entries.",
                               note: nil)
            }
            var note = "Pi has no name-only state: a skill is loaded or not."
            if case .global = skill.scope, place.relativePath.hasPrefix("skills/") {
                note += " The entry also covers a skill at the same path in the other personal folder (~/.agents and ~/.pi/agent)."
            }
            return Options(states: [.on, .off], file: file, key: key, unavailable: nil, note: note)
        default:
            return nil
        }
    }

    /// The file a switch of this skill writes; nil for a harness without one.
    public static func settingsFile(for skill: Skill, harness: HarnessID, in env: HarnessEnvironment) -> URL? {
        switch harness {
        case .claudeCode:
            return HarnessCatalog.configRoot(of: .claudeCode, in: env)?.appending(path: "settings.json")
        case .pi:
            // Pi applies the global entries to personal skills and a project's entries to its own skills.
            if case .project(let project) = skill.scope { return project.appending(path: ".pi/settings.json") }
            return HarnessCatalog.configRoot(of: .pi, in: env)?.appending(path: "settings.json")
        default:
            return nil
        }
    }

    // MARK: - Reading

    /// Each skill's state per harness that has a switch for it. Reads every settings file once;
    /// a file that is missing or can't be read counts as "every skill on".
    public static func states(of skills: [Skill], in env: HarnessEnvironment) -> [Skill.ID: [HarnessID: SkillSwitchState]] {
        var cache: [URL: JSONValue] = [:]
        func settings(_ url: URL) -> JSONValue {
            if let cached = cache[url] { return cached }
            let value = (try? read(url))?.value ?? .object([:])
            cache[url] = value
            return value
        }
        var result: [Skill.ID: [HarnessID: SkillSwitchState]] = [:]
        for skill in skills {
            for harness in harnesses {
                guard let options = options(for: skill, harness: harness, in: env), options.unavailable == nil else { continue }
                result[skill.id, default: [:]][harness] = state(of: skill, harness: harness, settings: settings(options.file))
            }
        }
        return result
    }

    /// The state without an entry in the settings: Manual for a Claude Code skill whose SKILL.md
    /// sets `disable-model-invocation`, else On.
    public static func defaultState(of skill: Skill, harness: HarnessID) -> SkillSwitchState {
        harness == .claudeCode && skill.disablesModelInvocation ? .manual : .on
    }

    /// One skill's state in one harness's settings.
    static func state(of skill: Skill, harness: HarnessID, settings: JSONValue) -> SkillSwitchState {
        switch harness {
        case .claudeCode:
            let written = settings.value(at: ["skillOverrides", skill.name]).flatMap { value -> SkillSwitchState? in
                if case .string(let text) = value { return SkillSwitchState(rawValue: text) }
                return nil
            } ?? .on
            // A SKILL.md with disable-model-invocation is Manual at most (Claude Code 2.1.296, `$C`).
            if skill.disablesModelInvocation { return written == .off ? .off : .manual }
            return written
        case .pi:
            guard let place = skill.places[.pi] else { return .on }
            return PiSkillFilter.isEnabled(place, entries: entries(in: settings)) ? .on : .off
        default:
            return .on
        }
    }

    /// The string entries of Pi's `skills` list (other values are ignored, as Pi's filters do).
    static func entries(in settings: JSONValue) -> [String] {
        guard case .array(let items)? = settings.value(at: ["skills"]) else { return [] }
        return items.compactMap { if case .string(let text) = $0 { text } else { nil } }
    }

    /// The file's bytes and its JSON; nil when there is no file.
    static func read(_ url: URL) throws(Failure) -> (data: Data, value: JSONValue)? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        guard FileWalk.isRegularFile(url), let data = FileWalk.head(of: url, limit: 4 << 20 + 1), data.count <= 4 << 20 else {
            throw Failure(message: "\(url.lastPathComponent) can't be read as a settings file.")
        }
        do {
            let value = try JSONValue.parse(data)
            guard case .object = value else { throw Failure(message: "\(url.path) is not a JSON object. AKit won't change it; fix the file first.") }
            return (data, value)
        } catch let error as Failure {
            throw error
        } catch {
            throw Failure(message: "\(url.path) is not valid JSON (\(error.localizedDescription)). AKit won't change it; fix the file first.")
        }
    }

    // MARK: - Plan and apply

    /// One switch change, ready to show and apply.
    public struct Plan: Sendable {
        public let skill: String
        public let harness: HarnessID
        public let from: SkillSwitchState
        public let to: SkillSwitchState
        public let file: URL
        /// The masked diff for the preview (`env` and `headers` values as `••••`, sorted keys).
        public let diff: [TextDiff.Line]
        public let notes: [String]
        /// The file's bytes when the plan was made; nil = no file. Apply refuses if they changed.
        let before: Data?
        let after: Data
        public var changesNothing: Bool { before == after }
    }

    public static func plan(_ skill: Skill, harness: HarnessID, to state: SkillSwitchState,
                            in env: HarnessEnvironment) throws(Failure) -> Plan {
        guard let options = options(for: skill, harness: harness, in: env) else {
            throw Failure(message: "\(harness.displayName) has no switch for \(skill.name).")
        }
        if let reason = options.unavailable { throw Failure(message: reason) }
        guard options.states.contains(state) else {
            throw Failure(message: "\(harness.displayName) offers \(options.states.map(\.title).joined(separator: ", ")) for \(skill.name), not \(state.title).")
        }
        let file = options.file
        if (try? FileManager.default.destinationOfSymbolicLink(atPath: file.path)) != nil,
           !FileManager.default.fileExists(atPath: file.path) {
            throw Failure(message: "\(file.path) is a link to a missing file.")
        }
        let current = try read(file)
        let settings = current?.value ?? .object([:])
        let from = Self.state(of: skill, harness: harness, settings: settings)
        let text = current.map { String(decoding: $0.data, as: UTF8.self) } ?? "{}\n"
        var after: String
        do {
            switch harness {
            case .claudeCode:
                if state == defaultState(of: skill, harness: harness) {
                    after = try JSONTextEdit.removing(at: ["skillOverrides", skill.name], in: text)
                    // An entry list left empty goes too, like a key that was never set.
                    if case .object(let left)? = try? JSONValue.parse(Data(after.utf8)).value(at: ["skillOverrides"]), left.isEmpty {
                        after = try JSONTextEdit.removing(at: ["skillOverrides"], in: after)
                    }
                } else {
                    after = try JSONTextEdit.setting(.string(state.rawValue), at: ["skillOverrides", skill.name], in: text)
                }
            case .pi:
                guard let place = skill.places[.pi] else { throw Failure(message: "Pi doesn't see \(skill.name).") }
                let old = entries(in: settings)
                let new = PiSkillFilter.entries(old, setting: place, enabled: state == .on)
                if new == old {
                    after = text
                } else if new.isEmpty {
                    after = try JSONTextEdit.removing(at: ["skills"], in: text)
                } else {
                    // Entries that aren't strings (Pi ignores them) stay where they were dropped from: at the end.
                    var items = new.map(JSONValue.string)
                    if case .array(let all)? = settings.value(at: ["skills"]) {
                        items += all.filter { if case .string = $0 { false } else { true } }
                    }
                    after = try JSONTextEdit.setting(.array(items), at: ["skills"], in: text)
                }
            default:
                throw Failure(message: "\(harness.displayName) has no switch.")
            }
        } catch let error as JSONTextEdit.Failure {
            throw Failure(message: "\(file.path): \(error.message)")
        } catch let error as Failure {
            throw error
        } catch {
            throw Failure(message: error.localizedDescription)
        }
        if current == nil, !after.hasSuffix("\n") { after += "\n" }
        let newValue = (try? JSONValue.parse(Data(after.utf8))) ?? .object([:])
        let diff = TextDiff.lines(from: current.map { shown($0.value) } ?? "", to: shown(newValue))
        var notes: [String] = []
        if current == nil { notes.append("Creates \(FileWalk.tilde(file, home: env.homeDirectory)).") }
        notes.append("Only this entry changes; the rest of the file stays as it is. The preview shows the file with sorted keys and env/headers values hidden.")
        if harness == .claudeCode { notes.append("Claude Code picks the change up in new sessions.") }
        if harness == .pi { notes.append("Pi picks the change up in new sessions (or after /reload).") }
        let before = current?.data
        return Plan(skill: skill.name, harness: harness, from: from, to: state, file: file, diff: diff, notes: notes,
                    before: before, after: Data(after.utf8))
    }

    /// Writes the plan: refuses if the file changed since the plan was made (the harness may
    /// have rewritten it), backs it up into `~/.akit/backups`, then writes it in place
    /// (through a link, keeping its permissions). Returns the backup, nil for a new file.
    @discardableResult
    public static func apply(_ plan: Plan, home: URL) throws(Failure) -> URL? {
        let fm = FileManager.default
        let now: Data? = fm.fileExists(atPath: plan.file.path) ? (try? Data(contentsOf: plan.file)) ?? Data() : nil
        guard now == plan.before else {
            throw Failure(message: "\(FileWalk.tilde(plan.file, home: home)) changed after the preview. Check the change again.")
        }
        guard !plan.changesNothing else { return nil }
        do {
            var backup: URL?
            if now != nil { backup = try Backup.copy(plan.file, into: try Backup.newFolder(home: home), home: home) }
            let real = plan.file.resolvingSymlinksInPath()
            let permissions = (try? fm.attributesOfItem(atPath: real.path))?[.posixPermissions]
            try fm.createDirectory(at: real.deletingLastPathComponent(), withIntermediateDirectories: true)
            try plan.after.write(to: real, options: .atomic)
            if let permissions { try fm.setAttributes([.posixPermissions: permissions], ofItemAtPath: real.path) }
            return backup
        } catch {
            throw Failure(message: "Couldn't write \(FileWalk.tilde(plan.file, home: home)): \(error.localizedDescription)")
        }
    }

    /// A settings file as the preview shows it: sorted keys, secrets masked.
    static func shown(_ value: JSONValue) -> String {
        String(value.masked.mappingStrings(SecretFilter.masked).pretty.dropLast())
    }
}
