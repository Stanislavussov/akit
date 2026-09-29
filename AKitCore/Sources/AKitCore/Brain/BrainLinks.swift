import Foundation

/// How an installed skill relates to the brain: a copy AKit rendered from a layer, or not.
public enum BrainLink: Hashable, Sendable {
    /// Rendered by AKit from the brain skill `skill` for these layers (per the project's lock).
    /// `edited`: SKILL.md changed by hand since; the next apply asks before overwriting it.
    case rendered(skill: String, layers: [String], edited: Bool)
    /// Not rendered by AKit, but the brain has a skill with this name.
    case sameName
    /// The brain has no skill with this name.
    case notInBrain

    public var isRendered: Bool { if case .rendered = self { true } else { false } }
}

public enum BrainLinks {
    /// Links for your own skills (global and project ones). Plugin, synced and bundled skills
    /// are managed elsewhere and get none. `folders`: project id → its folder on this Mac.
    /// `store`: where this Mac keeps its locks (a work Mac's local store); default the brain's.
    public static func links(for skills: [Skill], brain: Brain, folders: [String: URL],
                             store: ProjectStore? = nil) -> [Skill.ID: BrainLink] {
        let store = store ?? .brain(brain.root)
        struct Rendered { let skill: String, layers: [String], sha256: String? }
        var rendered: [String: Rendered] = [:]
        let prefix = ProjectBundle.skillsFolder + "/"
        let ids = Set(brain.projects.map(\.id) + BrainRemove.savedAnswers(in: store).map(\.id))
        for id in ids.sorted() {
            guard let folder = folders[id], let lock = ProjectRecords.savedLock(id: id, in: store) else { continue }
            for (path, entry) in lock.files where path.hasPrefix(prefix) && path.hasSuffix("/SKILL.md") {
                let parts = path.dropFirst(prefix.count).split(separator: "/")
                guard parts.count == 2 else { continue }
                rendered[key(folder.appending(path: path))] = Rendered(skill: String(parts[0]), layers: entry.layers, sha256: entry.sha256)
            }
        }

        let inBrain = Set(brain.skills.map(\.name))
        var links: [Skill.ID: BrainLink] = [:]
        for skill in skills {
            switch skill.scope {
            case .global, .project: break
            case .synced, .plugin, .bundled: continue
            }
            if let found = rendered[key(skill.realFile)] {
                let current = (try? Data(contentsOf: skill.realFile)).map(Checksum.sha256)
                links[skill.id] = .rendered(skill: found.skill, layers: found.layers,
                                            edited: found.sha256 != nil && current != found.sha256)
            } else {
                links[skill.id] = inBrain.contains(skill.name) ? .sameName : .notInBrain
            }
        }
        return links
    }

    private static func key(_ url: URL) -> String { url.resolvingSymlinksInPath().standardizedFileURL.path }
}
