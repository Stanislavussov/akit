import AKitModel
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
    /// `disable-model-invocation: true` in its frontmatter: only `/name` runs it.
    public internal(set) var disablesModelInvocation = false
    /// Per harness: where that harness's first root reached the skill, as it sees the path.
    public internal(set) var places: [HarnessID: Place] = [:]

    /// A skill file as one harness reaches it: `base` is the parent of the skill root
    /// (`~/.agents` for `~/.agents/skills`), `file` lies under it (links not resolved), `scope`
    /// is the scope of that root (a link from a personal folder into a project is still personal).
    public struct Place: Hashable, Sendable {
        public let file: URL
        public let base: URL
        public let scope: SkillScope

        public init(file: URL, base: URL, scope: SkillScope) {
            self.file = file
            self.base = base
            self.scope = scope
        }

        /// The folder name the harness sees (`~/.claude/skills/<this>/SKILL.md`), links not resolved.
        public var folderName: String { file.deletingLastPathComponent().lastPathComponent }
        /// `skills/tdd/SKILL.md`: the file relative to `base`.
        public var relativePath: String {
            let prefix = base.path.hasSuffix("/") ? base.path : base.path + "/"
            return file.path.hasPrefix(prefix) ? String(file.path.dropFirst(prefix.count)) : file.lastPathComponent
        }
    }

    /// The skill folder (or the file itself for a single-file skill).
    public var folder: URL { isSingleFile ? file : file.deletingLastPathComponent() }
    /// The skill folder with symlinks resolved on the folder itself (a symlinked
    /// SKILL.md does not move the folder somewhere else).
    public var realFolder: URL { isSingleFile ? realFile : folder.resolvingSymlinksInPath() }
}
