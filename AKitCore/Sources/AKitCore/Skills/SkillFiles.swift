import Foundation

/// Files inside a skill folder, for the detail screen.
public enum SkillFiles {
    /// Relative paths, hidden files skipped, at most `limit` entries.
    public static func list(_ skill: Skill, limit: Int = 200) -> [String] {
        if skill.isSingleFile { return [skill.file.lastPathComponent] }
        let folder = skill.realFolder
        guard let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey],
                                                          options: [.skipsHiddenFiles]) else { return [] }
        var result: [String] = []
        let prefix = folder.path.hasSuffix("/") ? folder.path : folder.path + "/"
        for case let url as URL in walker {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
            result.append(String(url.path.dropFirst(prefix.count)))
            if result.count >= limit { break }
        }
        return result.sorted()
    }

    /// Text of the skill file; nil if unreadable. Files over `maxBytes` are cut
    /// (a huge Text freezes the UI) with a note at the end.
    public static func text(of skill: Skill, maxBytes: Int = 64_000) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: skill.realFile) else { return nil }
        defer { try? handle.close() }
        let data = (try? handle.read(upToCount: maxBytes + 1)) ?? Data()
        guard data.count > maxBytes else { return String(decoding: data, as: UTF8.self) }
        return String(decoding: data.prefix(maxBytes), as: UTF8.self)
            + "\n\n… truncated, open the file in an editor to see all of it."
    }
}
