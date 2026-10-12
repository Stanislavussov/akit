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

/// A switch as read from the settings: a state, or why it can't be known (the file can't be
/// read, or holds an entry AKit can't read).
public enum SkillSwitchReading: Hashable, Sendable {
    case state(SkillSwitchState)
    case unknown(String)

    public var state: SkillSwitchState? {
        if case .state(let state) = self { return state }
        return nil
    }

    public var title: String {
        switch self {
        case .state(let state): state.title
        case .unknown: "Unknown"
        }
    }
}

/// Turning a skill on or off per harness (docs/design/harness-support.md, "Skill switches"):
/// Claude Code's `skillOverrides` in `~/.claude/settings.json`, Pi's `skills` entries in
/// `~/.pi/agent/settings.json` (or a project's `.pi/settings.json` for its own skills).
/// Only that one entry changes; every other byte of the file stays (`SettingsFile`).
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

    /// The name Claude Code gives the skill and keys `skillOverrides` by: the folder name it
    /// reaches the skill through (not the SKILL.md `name`; Claude Code 2.1.296 passes the directory
    /// entry's name), `anthropic-skills:<folder>` for a skill synced from claude.ai.
    public static func claudeName(of skill: Skill) -> String? {
        guard skill.visibleTo.contains(.claudeCode) else { return nil }
        let folder = skill.places[.claudeCode]?.folderName ?? skill.folder.lastPathComponent
        return skill.scope == .synced ? "anthropic-skills:" + folder : folder
    }

    /// The names an entry for the skill can be under, the one AKit writes first: a claude.ai
    /// skill also answers to its bare folder name (unless that name is reserved).
    static func claudeNames(of skill: Skill) -> [String] {
        guard let name = claudeName(of: skill) else { return [] }
        guard skill.scope == .synced, name.hasPrefix("anthropic-skills:") else { return [name] }
        return [name, String(name.dropFirst("anthropic-skills:".count))]
    }

    /// nil when the harness doesn't see the skill or has no switch.
    public static func options(for skill: Skill, harness: HarnessID, in env: HarnessEnvironment) -> Options? {
        guard skill.visibleTo.contains(harness), let file = settingsFile(for: skill, harness: harness, in: env) else { return nil }
        switch harness {
        case .claudeCode:
            guard let name = claudeName(of: skill) else { return nil }
            let key = "skillOverrides.\(JSONValue.string(name).compact)"
            if case .plugin = skill.scope {
                return Options(states: [], file: file, key: key,
                               unavailable: "Claude Code ignores skillOverrides for plugin skills; turn the plugin on or off with /plugin.",
                               note: nil)
            }
            if name == "__proto__" {
                return Options(states: [], file: file, key: key,
                               unavailable: "Claude Code can't store a setting for a skill with this name.", note: nil)
            }
            var notes = ["The entry is by name: it applies to every skill named \(name), in every project (a project's own .claude/settings.json entry wins)."]
            if name != skill.name {
                notes.append("Claude Code names the skill \(name) (its folder), not \(skill.name) (the name in its SKILL.md).")
            }
            var states = SkillSwitchState.allCases
            if skill.disablesModelInvocation {
                states = [.manual, .off]
                notes.append("Its SKILL.md sets disable-model-invocation, so Claude Code offers only Manual and Off.")
            }
            return Options(states: states, file: file, key: key, unavailable: nil, note: notes.joined(separator: " "))
        case .pi:
            guard let place = skill.places[.pi] else { return nil }
            let key = "skills: -\(place.relativePath)"
            if case .package = place.scope {
                return Options(states: [], file: file, key: "packages",
                               unavailable: "A Pi package skill is switched in its package's entry (pi config); AKit doesn't change package entries.",
                               note: nil)
            }
            var note = "Pi has no name-only state: a skill is loaded or not."
            if case .project = place.scope {
                note += " Pi reads a project's .pi/settings.json only when it starts in that folder (not in a subfolder); the entry covers the skill in the project's .pi/skills and .agents/skills."
            } else {
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
            // Pi applies the global entries to the skills of personal folders and a project's entries
            // to that project's: what counts is the folder Pi found the skill in, not where a link leads.
            if case .project(let project)? = skill.places[.pi]?.scope { return project.appending(path: ".pi/settings.json") }
            return HarnessCatalog.configRoot(of: .pi, in: env)?.appending(path: "settings.json")
        default:
            return nil
        }
    }

    // MARK: - Reading

    /// Each skill's switch per harness that has one for it. Reads every settings file once; a
    /// file that can't be read makes its skills Unknown, with the reason.
    public static func states(of skills: [Skill], in env: HarnessEnvironment) -> [Skill.ID: [HarnessID: SkillSwitchReading]] {
        var cache: [URL: Result<JSONValue, SettingsFile.Failure>] = [:]
        func settings(_ url: URL) -> Result<JSONValue, SettingsFile.Failure> {
            if let cached = cache[url] { return cached }
            let value: Result<JSONValue, SettingsFile.Failure>
            do { value = .success(try SettingsFile.read(url, home: env.homeDirectory)?.value ?? .object([:])) } catch { value = .failure(error) }
            cache[url] = value
            return value
        }
        var result: [Skill.ID: [HarnessID: SkillSwitchReading]] = [:]
        for skill in skills {
            for harness in harnesses {
                guard let options = options(for: skill, harness: harness, in: env), options.unavailable == nil else { continue }
                switch settings(options.file) {
                case .success(let value): result[skill.id, default: [:]][harness] = reading(of: skill, harness: harness, settings: value)
                case .failure(let error): result[skill.id, default: [:]][harness] = .unknown(error.message)
                }
            }
        }
        return result
    }

    /// The state without an entry in the settings: Manual for a Claude Code skill whose SKILL.md
    /// sets `disable-model-invocation`, else On.
    public static func defaultState(of skill: Skill, harness: HarnessID) -> SkillSwitchState {
        harness == .claudeCode && skill.disablesModelInvocation ? .manual : .on
    }

    /// The state Claude Code's `skillOverrides` entry gives the skill, whatever its SKILL.md says;
    /// nil without an entry, or when the settings can't be read.
    public static func claudeEntry(for skill: Skill, in env: HarnessEnvironment) -> SkillSwitchState? {
        guard let file = settingsFile(for: skill, harness: .claudeCode, in: env),
              case .object(let entries)? = (try? SettingsFile.read(file, home: env.homeDirectory))?.value.value(at: ["skillOverrides"]) else { return nil }
        let found = claudeNames(of: skill).lazy.compactMap { name in entries.first(where: { $0.key.unicodeScalars.elementsEqual(name.unicodeScalars) }) }.first
        guard case .string(let text)? = found?.value else { return nil }
        return SkillSwitchState(rawValue: text)
    }

    /// One skill's switch in one harness's settings.
    static func reading(of skill: Skill, harness: HarnessID, settings: JSONValue) -> SkillSwitchReading {
        switch harness {
        case .claudeCode:
            let names = claudeNames(of: skill)
            guard !names.isEmpty else { return .state(.on) }
            var written = SkillSwitchState.on
            switch settings.value(at: ["skillOverrides"]) {
            case nil: break
            case .object(let entries)?:
                let found = names.lazy.compactMap { name in entries.first(where: { $0.key.unicodeScalars.elementsEqual(name.unicodeScalars) }) }.first
                let name = found?.key ?? names[0]
                switch found?.value {
                case nil: break
                case .string(let text)? where SkillSwitchState(rawValue: text) != nil: written = SkillSwitchState(rawValue: text)!
                case let other?: return .unknown("skillOverrides.\(name) is \(other.compact), not one of on, name-only, user-invocable-only, off.")
                }
            default:
                return .unknown("skillOverrides in the settings is not an object.")
            }
            // A SKILL.md with disable-model-invocation is Manual at most (Claude Code 2.1.296, `$C`).
            if skill.disablesModelInvocation { return .state(written == .off ? .off : .manual) }
            return .state(written)
        case .pi:
            guard let place = skill.places[.pi] else { return .state(.on) }
            let list: [String]
            do { list = try entries(in: settings) } catch { return .unknown(error.message) }
            guard let enabled = PiSkillFilter.isEnabled(place, entries: list) else {
                return .unknown("Set by a pattern AKit can't read: \(PiSkillFilter.unreadable(list).joined(separator: ", ")).")
            }
            return .state(enabled ? .on : .off)
        default:
            return .state(.on)
        }
    }

    /// The string entries of Pi's `skills` list (other values are ignored, as Pi's filters do).
    static func entries(in settings: JSONValue) throws(Failure) -> [String] {
        switch settings.value(at: ["skills"]) {
        case nil: return []
        case .array(let items)?: return items.compactMap { if case .string(let text) = $0 { text } else { nil } }
        default: throw Failure(message: "skills in Pi's settings is not a list.")
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
        /// The preview: only the changed object (`skillOverrides`, Pi's `skills`), secrets hidden.
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
        let home = env.homeDirectory
        let current: (data: Data, value: JSONValue)?
        do { current = try SettingsFile.read(file, home: home) } catch { throw Failure(message: error.message) }
        let settings = current?.value ?? .object([:])
        guard let from = reading(of: skill, harness: harness, settings: settings).state else {
            if case .unknown(let reason) = reading(of: skill, harness: harness, settings: settings) {
                throw Failure(message: "\(reason) Change it by hand, or with pi config.")
            }
            throw Failure(message: "The current state can't be read.")
        }
        let text = current.map { String(decoding: $0.data, as: UTF8.self) } ?? "{}\n"
        var after = text
        var expected = settings
        let changed: [String]
        do {
            switch harness {
            case .claudeCode:
                guard let name = claudeName(of: skill) else { throw Failure(message: "Claude Code doesn't see \(skill.name).") }
                changed = ["skillOverrides"]
                if let overrides = settings.value(at: ["skillOverrides"]), overrides.objectMembers == nil {
                    throw Failure(message: "skillOverrides in \(FileWalk.tilde(file, home: home)) is not an object. AKit won't replace it.")
                }
                // Other names of the same skill (a claude.ai skill's bare name) go, so one entry decides.
                let others = claudeNames(of: skill).dropFirst().filter { settings.value(at: ["skillOverrides", $0]) != nil }
                for other in others {
                    after = try JSONTextEdit.removing(at: ["skillOverrides", other], in: after)
                    expected.remove(at: ["skillOverrides", other])
                }
                if state == defaultState(of: skill, harness: harness) {
                    let had = settings.value(at: ["skillOverrides", name]) != nil || !others.isEmpty
                    after = try JSONTextEdit.removing(at: ["skillOverrides", name], in: after)
                    expected.remove(at: ["skillOverrides", name])
                    // An entry list left empty goes too, like a key that was never set.
                    if expected.value(at: ["skillOverrides"]) == .object([:]), had {
                        after = try JSONTextEdit.removing(at: ["skillOverrides"], in: after)
                        expected.remove(at: ["skillOverrides"])
                    }
                } else {
                    after = try JSONTextEdit.setting(.string(state.rawValue), at: ["skillOverrides", name], in: after)
                    expected.set(.string(state.rawValue), at: ["skillOverrides", name])
                }
            case .pi:
                guard let place = skill.places[.pi] else { throw Failure(message: "Pi doesn't see \(skill.name).") }
                changed = ["skills"]
                let old = try entries(in: settings)
                guard let new = PiSkillFilter.entries(old, setting: place, enabled: state == .on) else {
                    throw Failure(message: "Pi's skills list has a pattern AKit can't read (\(PiSkillFilter.unreadable(old).joined(separator: ", "))). Change it by hand, or with pi config.")
                }
                if new == old {
                    break
                } else if new.isEmpty, case .array(let all)? = settings.value(at: ["skills"]), all.allSatisfy({ if case .string = $0 { true } else { false } }) {
                    after = try JSONTextEdit.removing(at: ["skills"], in: text)
                    expected.remove(at: ["skills"])
                } else {
                    // Entries that aren't strings (Pi ignores them) stay, after the strings.
                    var items = new.map(JSONValue.string)
                    if case .array(let all)? = settings.value(at: ["skills"]) {
                        items += all.filter { if case .string = $0 { false } else { true } }
                    }
                    after = try JSONTextEdit.setting(.array(items), at: ["skills"], in: text)
                    expected.set(.array(items), at: ["skills"])
                }
            default:
                throw Failure(message: "\(harness.displayName) has no switch.")
            }
        } catch let error as JSONTextEdit.Failure {
            throw Failure(message: "\(FileWalk.tilde(file, home: home)): \(error.message)")
        } catch let error as Failure {
            throw error
        } catch {
            throw Failure(message: error.localizedDescription)
        }
        if current == nil, !after.hasSuffix("\n") { after += "\n" }
        let data: Data
        do { data = try SettingsFile.checked(after, expected: expected, file: file, home: home) } catch { throw Failure(message: error.message) }
        var notes: [String] = []
        if current == nil { notes.append("Creates \(FileWalk.tilde(file, home: home)).") }
        notes.append("Only this entry changes; the rest of the file stays as it is. The preview shows only \(changed[0]).")
        if harness == .claudeCode { notes.append("Claude Code picks the change up in new sessions.") }
        if harness == .pi { notes.append("Pi picks the change up in new sessions (or after /reload).") }
        return Plan(skill: skill.name, harness: harness, from: from, to: state, file: file,
                    diff: SettingsFile.preview(old: current?.value, new: expected, at: changed), notes: notes,
                    before: current?.data, after: data)
    }

    /// Writes the plan (`SettingsFile.write`): refuses if the file changed since the plan was made
    /// (the harness may have rewritten it), backs it up into `~/.akit/backups`, then replaces it
    /// keeping its mode. Returns the backup, nil for a new file or no change.
    @discardableResult
    public static func apply(_ plan: Plan, home: URL) throws(Failure) -> URL? {
        do {
            return try SettingsFile.write(plan.after, to: plan.file, expecting: plan.before, home: home)
        } catch {
            throw Failure(message: error.message)
        }
    }
}
