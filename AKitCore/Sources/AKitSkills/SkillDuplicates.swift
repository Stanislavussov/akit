import AKitModel
import Foundation

/// Skills with one name in more than one place that one harness loads together: two global
/// copies, a global copy and a project's, or two copies in one project. Copies of one name in
/// two different projects are not duplicates (no session sees both). Plugin, claude.ai,
/// bundled and package skills carry their own namespace or can't be changed, so only global and
/// project copies count, and so do only folders (a lone Pi `.md` file is left out). One copy per
/// real folder: a link and its target are one copy. Claude Code keys a skill on its folder name;
/// the others on the header's `name`, so for them a copy counts only when the two agree (a
/// folder `foo-old` named `foo` is not found here; the scanner's collision warning names it).
/// Nested projects (a session in `mono/app` also loading `mono`'s skills) are not checked.
///
/// Claude Code keeps the personal copy; Pi keeps the first it finds, a trusted project's before the
/// global one, with a collision warning (Pi 1.0.4 `core/skills.js`). So two harnesses may run two
/// different copies, and the Skills screen offers Resolve
/// Duplicate…: keep one copy, the others go (Remove Everywhere with the kept copy unticked).
public enum SkillDuplicates {
    public struct Group: Identifiable, Hashable, Sendable {
        /// The folder name (Claude Code's key).
        public let name: String
        /// Every global and project copy of the name, global first.
        public let copies: [Skill]
        /// The harnesses that load more than one of them together.
        public let harnesses: [HarnessID]
        public var id: String { name }
    }

    /// The name harnesses key a skill on: its folder name (a lone file's name without `.md`).
    public static func key(_ skill: Skill) -> String {
        skill.isSingleFile ? skill.file.deletingPathExtension().lastPathComponent : skill.folder.lastPathComponent
    }

    public static func groups(_ skills: [Skill]) -> [Group] {
        var byName: [String: [Skill]] = [:]
        var seen: Set<String> = []
        for skill in skills {
            switch skill.scope {
            case .global, .project: break
            default: continue
            }
            if skill.isSingleFile { continue }
            guard seen.insert(skill.realFolder.standardizedFileURL.path).inserted else { continue }
            byName[key(skill), default: []].append(skill)
        }
        return byName.compactMap { name, copies -> Group? in
            guard copies.count > 1 else { return nil }
            let harnesses = Set(copies.flatMap(\.visibleTo)).filter { harness in
                let seen = copies.filter { loads($0, harness) }
                let global = seen.filter { $0.scope == .global }.count
                var projects: [URL: Int] = [:]
                for copy in seen { if case .project(let folder) = copy.scope { projects[folder.standardizedFileURL, default: 0] += 1 } }
                return global > 1 || (global == 1 && !projects.isEmpty) || projects.values.contains { $0 > 1 }
            }
            guard !harnesses.isEmpty else { return nil }
            let sorted = copies.sorted { ($0.scope.sortRank, $0.folder.path) < ($1.scope.sortRank, $1.folder.path) }
            return Group(name: name, copies: sorted, harnesses: harnesses.sorted { $0.rawValue < $1.rawValue })
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// The harness loads the copy under the group's name.
    static func loads(_ skill: Skill, _ harness: HarnessID) -> Bool {
        skill.visibleTo.contains(harness) && (harness == .claudeCode || skill.name == key(skill))
    }

    /// The harnesses that load `other` where `kept` would not take its place: they don't load
    /// `kept`, or `kept` is in another project than `other`. Empty: removing `other` leaves
    /// every harness and project that had it with the kept copy.
    public static func uncovered(by kept: Skill, _ other: Skill) -> [HarnessID] {
        let context = kept.scope == .global || kept.scope == other.scope
        return other.visibleTo.filter { !context || !loads(kept, $0) }
    }

    /// The copy Resolve Duplicate… keeps unless you pick another: the one whose keeping lets
    /// most other copies go, the global one first among equals (Claude Code already prefers it).
    public static func preferred(_ group: Group) -> Skill? {
        group.copies.enumerated().max { a, b in
            let left = group.copies.filter { $0.id != a.element.id && uncovered(by: a.element, $0).isEmpty }.count
            let right = group.copies.filter { $0.id != b.element.id && uncovered(by: b.element, $0).isEmpty }.count
            // Equal counts: the earlier copy (global first) wins.
            return left != right ? left < right : a.offset > b.offset
        }?.element
    }

    /// The copy's SKILL.md text; nil when it can't be read.
    public static func text(_ skill: Skill) -> String? {
        try? String(contentsOf: skill.realFile, encoding: .utf8)
    }
}
