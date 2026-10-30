import AKitFoundation
import Foundation

/// Links from a role or a scenario to other skills (`skills:`): the brain's, Claude Code's, Pi's
/// or `~/.agents/skills`. A link is only a name: the skill stays where it is, and Gather copies
/// it into the run so every pass loads it with `--skill`.
public enum ReviewSkillLinks {
    public struct Failure: Error, LocalizedError {
        public let message: String
        public var errorDescription: String? { message }
    }

    /// At most this much of a skill's folder goes into a run; the rest is left out.
    static let maxFileBytes = 256 * 1024
    static let maxTotalBytes = 2 * 1024 * 1024

    /// The run's copies of the skills that were copied, as Pi's `--skill` flags.
    public static func flags(folder: URL, spec: ReviewRunSpec) -> [String] {
        (spec.skills ?? []).compactMap { skill in
            let copy = folder.appending(path: "skills/\(skill.name)")
            return FileManager.default.fileExists(atPath: copy.appending(path: "SKILL.md").path) ? copy.path : nil
        }.flatMap { ["--skill", $0] }
    }

    /// Copies a skill's folder: regular text files only (no links, no hidden files), each scrubbed,
    /// up to the size limits. Returns why it couldn't, else nil.
    static func copy(_ source: URL, to target: URL, scrub: Scrubber.OwnPatterns) -> String? {
        let manager = FileManager.default
        // A skill folder is often a link (~/.claude/skills/x → ~/.agents/skills/x): walk the real one.
        let source = source.resolvingSymlinksInPath()
        guard let skill = try? String(contentsOf: source.appending(path: "SKILL.md"), encoding: .utf8) else {
            return "Can't read its SKILL.md."
        }
        guard skill.utf8.count <= maxFileBytes else { return "Its SKILL.md is over 256 KB, so the passes run without it." }
        try? manager.removeItem(at: target)
        var total = 0
        var skipped = 0
        func put(_ text: String, _ relative: String) throws {
            let url = target.appending(path: relative)
            try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(Scrubber.scrub(text, own: scrub).text.utf8).write(to: url)
            total += text.utf8.count
        }
        do {
            try put(skill, "SKILL.md")
            let root = source.resolvingSymlinksInPath().path
            let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
            let walk = manager.enumerator(at: source, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])
            while let url = walk?.nextObject() as? URL {
                let values = try? url.resourceValues(forKeys: Set(keys))
                guard values?.isSymbolicLink != true else {
                    walk?.skipDescendants()
                    continue
                }
                guard values?.isRegularFile == true else { continue }
                let path = url.resolvingSymlinksInPath().path
                guard path.hasPrefix(root + "/") else { continue }
                let relative = String(path.dropFirst(root.count + 1))
                guard relative != "SKILL.md" else { continue }
                let size = values?.fileSize ?? 0
                // Over the total the rest is left out unread (a node_modules would take long).
                guard total < maxTotalBytes else {
                    skipped += 1
                    break
                }
                guard size <= maxFileBytes, total + size <= maxTotalBytes,
                      let text = try? String(contentsOf: url, encoding: .utf8) else {
                    skipped += 1
                    continue
                }
                try put(text, relative)
            }
        } catch {
            return "Couldn't copy it into the run: \(error.localizedDescription)"
        }
        return skipped > 0 ? "\(skipped) of its files were left out (binary or too big); the passes read SKILL.md and the rest." : nil
    }

    /// The text of a role (`kind` .role) or a scenario with `skills:` set to `names` (none takes
    /// the key out); the rest of the file as it was. Throws when the result doesn't read back so.
    public static func setting(_ names: [String], kind: ReviewConfigEditor.Kind, in text: String) throws -> String {
        for name in names where !ReviewYAML.isSkillName(name) { throw Failure(message: "\(name) is not a skill name.") }
        let value = names.isEmpty ? nil : "[" + names.joined(separator: ", ") + "]"
        let result: String
        switch kind {
        case .role:
            guard let header = ReviewYAML.frontmatter(text) else { throw Failure(message: "The role has no --- frontmatter.") }
            let edited = ReviewConfigEditor.settingKey("skills", value, block: "akit-review", in: header)
            guard let range = text.range(of: header) else { throw Failure(message: "AKit couldn't find the frontmatter.") }
            result = text.replacingCharacters(in: range, with: edited.hasSuffix("\n") ? String(edited.dropLast()) : edited)
            guard (try? ReviewRole.parse(result, source: .brain))?.skills == names else {
                throw Failure(message: "AKit couldn't set skills: in the role by itself. Set akit-review: skills: \(value ?? "[]") in the text.")
            }
        case .scenario:
            result = ReviewConfigEditor.settingTopLevel("skills", value, in: text)
            guard (try? ReviewScenario.parse(result, source: .brain))?.skills == names else {
                throw Failure(message: "AKit couldn't set skills: in the scenario by itself. Set skills: \(value ?? "[]") in the text.")
            }
        case .defaults, .profile:
            throw Failure(message: "Only a role or a scenario links skills.")
        }
        return result
    }
}
