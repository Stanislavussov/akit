import Foundation

/// Deletes a skill by moving it to the Trash, so it can always be put back.
public enum SkillRemover {
    public enum Failure: LocalizedError {
        case readOnly
        case notASkill(URL)
        case linkedSkillFile(URL)

        public var errorDescription: String? {
            switch self {
            case .readOnly: "This skill is managed elsewhere and can't be deleted here."
            case .notASkill(let url): "\(url.path) doesn't look like a single skill folder, nothing was deleted."
            case .linkedSkillFile(let url): "SKILL.md is a link to \(url.path). Delete it by hand, AKit won't touch the folder it points into."
            }
        }
    }

    /// What will be moved to the Trash.
    /// - A skill folder that is itself a symlink (`skills/x -> ~/library/x`): only the
    ///   link goes; the folder it points to is left alone.
    /// - Otherwise the real skill folder (or single `.md` file), which must sit inside
    ///   the skill folder it was found in and contain SKILL.md.
    public static func items(for skill: Skill) throws -> [URL] {
        guard !skill.isReadOnly else { throw Failure.readOnly }
        let seen = skill.isSingleFile ? skill.file : skill.folder
        if isSymlink(seen) {
            return [seen]
        }
        let target = skill.realFolder
        // SKILL.md linked from somewhere else: its real parent is not this skill's folder.
        if !skill.isSingleFile, skill.realFile.deletingLastPathComponent().path != target.path {
            throw Failure.linkedSkillFile(skill.realFile)
        }
        // Safety net: never trash anything that isn't clearly one skill inside its skill folder.
        let rootPath = skill.root.path.hasSuffix("/") ? skill.root.path : skill.root.path + "/"
        let insideRoot = target.path.hasPrefix(rootPath) && target.path.count > rootPath.count
        let looksLikeSkill = skill.isSingleFile
            ? target.pathExtension == "md"
            : SkillScanner.hasSkillFile(target)
        guard insideRoot, looksLikeSkill, target.pathComponents.count > 3 else { throw Failure.notASkill(target) }
        return [target]
    }

    /// true when the skill entry is only a link: deleting removes the link, not the files.
    public static func removesOnlyLink(_ skill: Skill) -> Bool {
        isSymlink(skill.isSingleFile ? skill.file : skill.folder)
    }

    static func isSymlink(_ url: URL) -> Bool {
        (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) != nil
    }

    /// Moves the skill to the Trash. Returns where the items ended up.
    /// `trash` is replaceable so tests don't fill the real Trash.
    @discardableResult
    public static func moveToTrash(_ skill: Skill,
                                   trash: (URL) throws -> URL? = Trash.move) throws -> [URL] {
        try items(for: skill).compactMap { try trash($0) }
    }
}
