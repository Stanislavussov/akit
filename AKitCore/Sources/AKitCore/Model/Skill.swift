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

    /// Group order in the list: global, projects, synced, plugins.
    public var sortRank: Int {
        switch self {
        case .global: 0
        case .project: 1
        case .synced: 2
        case .plugin: 3
        case .bundled: 4
        }
    }
}

/// One skill (a folder with SKILL.md, or a single .md file for Pi), merged across
/// harnesses: the shared `~/.agents/skills` folder is seen by both Claude and Pi
/// but is listed once.
public struct Skill: Identifiable, Hashable, Sendable {
    /// Real path of the skill file (symlinks resolved). Unique per skill.
    public var id: String { realFile.path }

    public let name: String
    public let description: String
    /// Path as the harness sees it (e.g. `~/.claude/skills/x/SKILL.md`).
    public let file: URL
    /// Same file with symlinks resolved (e.g. `~/.agents/skills/x/SKILL.md`).
    public let realFile: URL
    /// true = a lone `.md` file (Pi only), false = a folder with SKILL.md.
    public let isSingleFile: Bool
    public let scope: SkillScope
    public internal(set) var visibleTo: [HarnessID]
    public let isReadOnly: Bool
    /// Where it was installed from, e.g. `vercel-labs/skills`, `claude.ai`, `oh-my-claudecode 4.15.2`.
    public internal(set) var origin: String?
    public internal(set) var warnings: [String]

    /// The skill folder (or the file itself for a single-file skill).
    public var folder: URL { isSingleFile ? file : file.deletingLastPathComponent() }
    public var realFolder: URL { isSingleFile ? realFile : realFile.deletingLastPathComponent() }
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
