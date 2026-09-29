import Foundation

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
    /// The skill folder this skill was found in (symlinks resolved), e.g. `~/.agents/skills`.
    public let root: URL

    /// The skill folder (or the file itself for a single-file skill).
    public var folder: URL { isSingleFile ? file : file.deletingLastPathComponent() }
    /// The skill folder with symlinks resolved on the folder itself (a symlinked
    /// SKILL.md does not move the folder somewhere else).
    public var realFolder: URL { isSingleFile ? realFile : folder.resolvingSymlinksInPath() }
}
