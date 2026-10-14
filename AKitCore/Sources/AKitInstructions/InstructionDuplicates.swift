import Foundation

/// Sections that reach the model twice in one session (docs/design/instructions.md, step 2):
/// the same text after normalizing (decided D13) in two loaded files of one harness, or twice in
/// one file. Sections with the same `##` heading and other text are listed apart as "differs":
/// the model gets both versions. AKit's core block counts by the `##` parts inside it, so a
/// project file that repeats a core rule is found too. Reads only.
public struct InstructionDuplicate: Identifiable, Hashable, Sendable {
    public struct Place: Hashable, Sendable {
        public let file: URL
        public let section: InstructionSection
    }

    public enum Kind: Hashable, Sendable {
        /// The same text.
        case same
        /// The same heading, other text.
        case differs
    }

    public let kind: Kind
    /// In the order the model gets them.
    public let places: [Place]
    /// The heading the places share (the first place that has one: `# X` and `## X` count the
    /// same); nil for leads only.
    public var heading: String? { places.lazy.compactMap(\.section.heading).first }
    public var id: String { "\(kind)|" + places.map { "\($0.file.path):\($0.section.line)" }.joined(separator: ",") }

    /// The places other than those in this file.
    public func others(than file: URL) -> [Place] { places.filter { $0.file != file } }
}

extension InstructionText {
    /// The parts compared for duplicates: the file's sections, with AKit's block split into the
    /// `##` parts inside it (each still marked `isAKitBlock`, its line in the file).
    public static func units(_ text: String) -> [InstructionSection] {
        sections(text).flatMap { section -> [InstructionSection] in
            guard section.isAKitBlock else { return [section] }
            // Only the block's own first and last lines are markers; a quoted marker inside stays.
            var lines = Self.lines(section.text)
            lines.removeFirst()
            if lines.last?.trimmingCharacters(in: .whitespacesAndNewlines) == akitEnd { lines.removeLast() }
            let inner = lines.joined(separator: "\n")
            // The block's first line is its start marker, so inner line n is file line start + n.
            return sections(inner).map {
                InstructionSection(heading: $0.heading, text: $0.text, isAKitBlock: true, line: section.line + $0.line)
            }
        }
    }

    /// The normalized text without its heading line: empty means a heading alone.
    static func body(_ section: InstructionSection) -> String {
        let text = normalized(section)
        guard section.heading != nil else { return text }
        return Self.lines(text).dropFirst().joined(separator: "\n")
    }
}

extension InstructionView {
    /// Same-text groups first, then same-heading groups whose texts differ; each in the order the
    /// model gets the places. Only loaded files; a heading alone is never a duplicate.
    public var duplicates: [InstructionDuplicate] {
        var units: [(file: URL, section: InstructionSection, order: Int)] = []
        for entry in loaded {
            // What the model gets: a file Codex cuts counts only up to the cut.
            let text = entry.limit.map { String(decoding: entry.text.utf8.prefix($0), as: UTF8.self) } ?? entry.text
            for section in InstructionText.units(text) where !InstructionText.body(section).isEmpty {
                units.append((entry.file, section, units.count))
            }
        }
        var same: [String: [Int]] = [:]
        for (index, unit) in units.enumerated() { same[InstructionText.normalized(unit.section), default: []].append(index) }
        let sameGroups = same.values.filter { $0.count > 1 }
        var result = sameGroups.map { indices in
            InstructionDuplicate(kind: .same, places: indices.sorted().map { .init(file: units[$0].file, section: units[$0].section) })
        }

        var byHeading: [String: [Int]] = [:]
        for (index, unit) in units.enumerated() {
            guard let heading = unit.section.heading?.lowercased().trimmingCharacters(in: .whitespaces), !heading.isEmpty else { continue }
            byHeading[heading, default: []].append(index)
        }
        for indices in byHeading.values where indices.count > 1 {
            let texts = Set(indices.map { InstructionText.normalized(units[$0].section) })
            guard texts.count > 1 else { continue }
            result.append(InstructionDuplicate(kind: .differs, places: indices.sorted().map { .init(file: units[$0].file, section: units[$0].section) }))
        }
        let firstIndex: (InstructionDuplicate) -> Int = { group in
            units.firstIndex { $0.file == group.places[0].file && $0.section == group.places[0].section } ?? 0
        }
        return result.sorted { ($0.kind == .same ? 0 : 1, firstIndex($0)) < ($1.kind == .same ? 0 : 1, firstIndex($1)) }
    }
}
