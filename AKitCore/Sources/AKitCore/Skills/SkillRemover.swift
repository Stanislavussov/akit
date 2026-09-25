import Foundation

/// Deletes a skill by moving it to the Trash, so it can always be put back.
public enum SkillRemover {
    public enum Failure: LocalizedError {
        case readOnly
        case notASkill(URL)

        public var errorDescription: String? {
            switch self {
            case .readOnly: "This skill is managed elsewhere and can't be deleted here."
            case .notASkill(let url): "\(url.path) doesn't look like a skill folder, nothing was deleted."
            }
        }
    }

    /// What will be moved to the Trash: the real skill folder (or file) and, if the
    /// harness reaches it through its own per-skill symlink, that link too.
    public static func items(for skill: Skill) throws -> [URL] {
        guard !skill.isReadOnly else { throw Failure.readOnly }
        let target = skill.isSingleFile ? skill.realFile : skill.realFolder
        // Safety net: never trash anything that isn't clearly one skill.
        let looksLikeSkill = skill.isSingleFile
            ? target.pathExtension == "md"
            : SkillScanner.hasSkillFile(target) && target.pathComponents.count > 3
        guard looksLikeSkill else { throw Failure.notASkill(target) }

        var items = [target]
        let seen = skill.isSingleFile ? skill.file : skill.folder
        if seen.path != target.path,
           (try? FileManager.default.destinationOfSymbolicLink(atPath: seen.path)) != nil {
            items.append(seen)
        }
        return items
    }

    /// Moves the skill to the Trash. Returns where the items ended up.
    /// `trash` is replaceable so tests don't fill the real Trash.
    @discardableResult
    public static func moveToTrash(_ skill: Skill,
                                   trash: (URL) throws -> URL? = defaultTrash) throws -> [URL] {
        try items(for: skill).compactMap { try trash($0) }
    }

    public static func defaultTrash(_ url: URL) throws -> URL? {
        var result: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &result)
        return result as URL?
    }
}
