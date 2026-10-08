import Foundation

/// Where a skill comes from. Also the group it is shown under.
public enum SkillScope: Hashable, Sendable {
    /// Your own global skills (`~/.agents/skills`, `~/.claude/skills`, `~/.pi/agent/skills`).
    case global
    /// Skills inside a project folder.
    case project(URL)
    /// Pushed down from claude.ai into `skills/synced/`. Managed by Claude, read-only.
    case synced
    /// Shipped by an enabled Claude Code plugin. Read-only.
    case plugin(name: String)
    /// Bundled with a harness itself (e.g. Codex's `.system` skills). Read-only.
    case bundled(HarnessID)
    /// Shipped by a Pi package (`packages` in Pi's settings). `project` is nil for the global
    /// settings, else the project whose `.pi/settings.json` lists it. Read-only.
    case package(name: String, project: URL?)

    /// Group order in the list: global, projects, synced, plugins and packages.
    public var sortRank: Int {
        switch self {
        case .global: 0
        case .project: 1
        case .synced: 2
        case .plugin, .package: 3
        case .bundled: 4
        }
    }
}

/// A folder a harness reads skills from.
public struct SkillRoot: Sendable {
    public enum Layout: Sendable {
        /// Claude Code: `<root>/<name>/SKILL.md`.
        /// `rootMayBeSkill`: a root that itself contains SKILL.md is one skill (plugin skill paths).
        case flat(rootMayBeSkill: Bool = false)
        /// Pi: any depth; a folder with SKILL.md is a skill and is not descended further.
        /// `rootMarkdown`: loose `.md` files directly in the root are skills too.
        case recursive(rootMarkdown: Bool)
        /// Pi package: exactly these skill files (a `SKILL.md`, or a single `.md` skill),
        /// already chosen by the package's manifest and filters.
        case listed([URL])
    }

    public let url: URL
    public let harness: HarnessID
    public let scope: SkillScope
    public let layout: Layout
    public let isReadOnly: Bool
    public let origin: String?
    /// Claude's `skills/synced` folder with claude.ai skills: `synced/<bucket>/<name>/SKILL.md`.
    public let syncedFolder: URL?

    public init(url: URL, harness: HarnessID, scope: SkillScope, layout: Layout,
                isReadOnly: Bool = false, origin: String? = nil, syncedFolder: URL? = nil) {
        self.url = url
        self.harness = harness
        self.scope = scope
        self.layout = layout
        self.isReadOnly = isReadOnly
        self.origin = origin
        self.syncedFolder = syncedFolder
    }
}
