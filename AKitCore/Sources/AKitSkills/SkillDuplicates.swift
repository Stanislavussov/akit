import AKitModel
import Foundation

/// Skills with one name in more than one place that one harness loads together: two global
/// copies, a global copy and a project's, or two copies in one project. Copies of one name in
/// two different projects are not duplicates (no session sees both). Plugin, claude.ai,
/// bundled and package skills carry their own namespace or can't be changed, so only global and
/// project copies count. One copy per real folder: a link and its target are one copy.
///
/// Claude Code keeps one copy (personal before project); Pi and the others may list both. Either
/// way the copy that reaches the agent is not obvious, so the Skills screen offers Resolve
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
            guard seen.insert(skill.realFolder.standardizedFileURL.path).inserted else { continue }
            byName[key(skill), default: []].append(skill)
        }
        return byName.compactMap { name, copies -> Group? in
            guard copies.count > 1 else { return nil }
            let harnesses = Set(copies.flatMap(\.visibleTo)).filter { harness in
                let seen = copies.filter { $0.visibleTo.contains(harness) }
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

    /// The copy Resolve Duplicate… keeps unless you pick another: the global one (Claude Code
    /// already prefers it), else the first.
    public static func preferred(_ group: Group) -> Skill? {
        group.copies.first { $0.scope == .global } ?? group.copies.first
    }

    /// The copy's SKILL.md text; nil when it can't be read.
    public static func text(_ skill: Skill) -> String? {
        try? String(contentsOf: skill.realFile, encoding: .utf8)
    }
}
