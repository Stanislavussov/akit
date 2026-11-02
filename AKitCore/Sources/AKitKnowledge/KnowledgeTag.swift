import Foundation

/// A badge on a note: free text kept in the note's `tags:` frontmatter list, as Obsidian keeps
/// tags. Its color comes from its text, so a tag has the same color on every note and every Mac.
public enum KnowledgeTag {
    /// The number of colors a tag can get (`colorIndex`).
    public static let colorCount = 10

    /// The tag as written: trimmed, without a leading `#`, spaces as `-` (Obsidian tags have no
    /// spaces). nil when nothing is left.
    public static func normalize(_ text: String) -> String? {
        var tag = text.trimmingCharacters(in: .whitespacesAndNewlines)
        while tag.hasPrefix("#") { tag.removeFirst() }
        tag = tag.split(whereSeparator: \.isWhitespace).joined(separator: "-")
        tag = tag.filter { $0 != "," }
        return tag.isEmpty ? nil : tag.precomposedStringWithCanonicalMapping
    }

    /// The tags in order, a repeat (case aside) left out.
    public static func unique(_ tags: [String]) -> [String] {
        var seen = Set<String>()
        return tags.filter { seen.insert($0.lowercased()).inserted }
    }

    /// A stable color slot in `0..<colorCount`: FNV-1a over the lowercased text, so `Payments`
    /// and `payments` look the same.
    public static func colorIndex(_ tag: String) -> Int {
        var hash: UInt32 = 2_166_136_261
        for byte in tag.lowercased().utf8 {
            hash ^= UInt32(byte)
            hash = hash &* 16_777_619
        }
        return Int(hash % UInt32(colorCount))
    }

    /// The tags used in the notes, most used first, then by name: the suggestions of Add Tag.
    /// A tag counts once per note, case aside; its spelling is the first one seen.
    public static func usage(of notes: [[String]]) -> [(tag: String, notes: Int)] {
        var counts: [String: (tag: String, notes: Int)] = [:]
        for tags in notes {
            for tag in unique(tags) {
                let key = tag.lowercased()
                counts[key] = (counts[key]?.tag ?? tag, (counts[key]?.notes ?? 0) + 1)
            }
        }
        return counts.values.sorted { $0.notes != $1.notes ? $0.notes > $1.notes : $0.tag.lowercased() < $1.tag.lowercased() }
    }

    /// Suggestions for the typed text: used tags that contain it (those that start with it
    /// first), without the ones the note has.
    public static func suggestions(for typed: String, among used: [String], excluding: [String]) -> [String] {
        let have = Set(excluding.map { $0.lowercased() })
        let query = (normalize(typed) ?? "").lowercased()
        let left = used.filter { !have.contains($0.lowercased()) }
        guard !query.isEmpty else { return left }
        let hits = left.filter { $0.lowercased().contains(query) }
        return hits.filter { $0.lowercased().hasPrefix(query) } + hits.filter { !$0.lowercased().hasPrefix(query) }
    }
}
