import Foundation

/// The rules, scenarios and open questions of requirement notes (K43), in the format of the
/// `acceptance-scenarios` skill: Gherkin in ```` ```gherkin ```` blocks, each item headed by a
/// comment line of `·`-separated fields.
///
/// ```gherkin
/// # R-ORD-01 · ADO 123456, 123457 · status: agreed
/// Rule: An order can be cancelled until it is shipped
///
///   # SC-ORD-001 · ADO 123456 · level: e2e · journey · status: agreed
///   # test: shop-e2e · tests/orders/cancel.spec.ts · cancel › refunds a paid order
///   Scenario: The customer cancels a paid order before shipping
///
/// # OPEN-ORD-001 · ADO 123457 rev. 3 · status: open
/// Question: Is a partly shipped order shipped?
/// ```
///
/// Only lines inside a gherkin block count, so a `## R-ORD-01 …` heading is no item. A scenario's
/// `# test:` lines link the tests that prove it (repository · file · test name): the link lives
/// here because scenario IDs never go into a repository. `akit kb scenarios` lists the items, the
/// flow runner reads them for its scenario gate, and lint checks the IDs and the links
/// (`scenario-*` rules).
public enum KnowledgeScenarios {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        case rule, scenario, question

        /// The ID prefix: `R`, `SC`, `OPEN`.
        public var prefix: String {
            switch self {
            case .rule: "R"
            case .scenario: "SC"
            case .question: "OPEN"
            }
        }

        /// The Gherkin keywords the line after the header starts with.
        var keywords: [String] {
            switch self {
            case .rule: ["Rule:"]
            case .scenario: ["Scenario:", "Scenario Outline:", "Scenario Template:", "Example:"]
            case .question: ["Question:"]
            }
        }

        public var statuses: [String] { self == .question ? ["open", "answered"] : ["draft", "agreed", "dropped"] }
    }

    public static let levels = ["e2e", "unit"]

    /// A `# test: repo · path · name` line under a scenario's header.
    public struct TestLink: Codable, Sendable, Equatable, Hashable {
        /// The repository: its folder name in the projects folder, or its git remote.
        public let repo: String
        /// The file, relative to the repository's top.
        public let path: String
        /// The `describe` titles and the test's title as the source writes them.
        public let names: [String]
        public let line: Int

        /// `cancel › refunds a paid order`.
        public var name: String { names.joined(separator: " › ") }
    }

    public struct Item: Codable, Sendable, Equatable {
        public let id: String
        public let kind: Kind
        /// The feature code: `ORD` in `SC-ORD-001`.
        public let feature: String
        public let number: Int
        /// The text after `Rule:`, `Scenario:` or `Question:`; nil when the header has no such line.
        public let title: String?
        public let status: String?
        /// Scenarios only: `e2e` or `unit` as written.
        public let level: String?
        public let journey: Bool
        /// Scenarios only: the rule above it in the note.
        public let rule: String?
        /// The ADO IDs the header's sources name.
        public let workItems: [String]
        /// The header's other fields, as written: `ADO 123456 rev. 3 · Figma 9:99`.
        public let sources: String
        /// Scenarios only: the tests that prove it.
        public let tests: [TestLink]
        /// Scenarios only: the `Given` / `When` / `Then` / `And` / `But` lines, trimmed.
        public let steps: [String]
        /// Scenario outlines only: the rows of the `Examples:` tables, without their header rows.
        public let examples: [String]
        /// The note's id.
        public let note: String
        /// The header's line, from 1.
        public let line: Int
    }

    /// Something in an item's header that the format doesn't allow.
    public struct Problem: Sendable, Equatable {
        public let id: String
        public let line: Int
        public let message: String
        public let fix: String
    }

    public struct Parsed: Sendable, Equatable {
        public var items: [Item] = []
        public var problems: [Problem] = []
    }

    /// An item's header: `# SC-ORD-001 · …`, indented or not.
    static var header: Regex<(Substring, Substring, Substring, Substring, Substring)> {
        /^\s*#\s*(R|SC|OPEN)-([A-Z][A-Z0-9]*)-([0-9]+)(?![A-Za-z0-9-])(.*)$/
    }
    /// An ID anywhere in a text, like `SC-ORD-001` in a plan or a task note.
    static var reference: Regex<(Substring, Substring, Substring, Substring)> {
        /(R|SC|OPEN)-([A-Z][A-Z0-9]*)-([0-9]+)(?![A-Za-z0-9-])/
    }
    /// `ADO 123456` and the numbers listed after it (`ADO 123456, 123457`); a number after other
    /// words (`rev. 3`, `Figma 56:7890`) is no work item.
    static var adoList: Regex<(Substring, Substring)> { /ADO\s+([0-9]+(?:\s*,\s*[0-9]+(?![0-9:]))*)/ }

    /// The items of one note's gherkin blocks, in the order they are written.
    public static func parse(_ text: String, note: String) -> Parsed {
        var parsed = Parsed()
        let lines = text.components(separatedBy: "\n").map { $0.hasSuffix("\r") ? String($0.dropLast()) : $0 }
        var fence: String?
        var inGherkin = false
        var rule: String?
        var index = 0
        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let open = fence {
                if trimmed.hasPrefix(open), trimmed.drop(while: { String($0) == String(open.first!) }).trimmingCharacters(in: .whitespaces).isEmpty {
                    fence = nil
                    inGherkin = false
                }
            } else if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                let mark = trimmed.first!
                let ticks = String(trimmed.prefix { $0 == mark })
                fence = ticks
                inGherkin = trimmed.dropFirst(ticks.count).trimmingCharacters(in: .whitespaces).lowercased().hasPrefix("gherkin")
                index += 1
                continue
            }
            guard inGherkin, let match = line.wholeMatch(of: header) else {
                index += 1
                continue
            }
            let kind = Kind.allCases.first { $0.prefix == String(match.1) }!
            let feature = String(match.2)
            let id = "\(kind.prefix)-\(feature)-\(match.3)"
            var status: String?, level: String?, journey = false
            var sources: [String] = []
            for field in match.4.split(separator: "·").map({ $0.trimmingCharacters(in: .whitespaces) }) where !field.isEmpty {
                let lower = field.lowercased()
                if lower.hasPrefix("status:") {
                    status = field.dropFirst("status:".count).trimmingCharacters(in: .whitespaces)
                } else if lower.hasPrefix("level:") {
                    level = field.dropFirst("level:".count).trimmingCharacters(in: .whitespaces)
                } else if lower == "journey" {
                    journey = true
                } else {
                    sources.append(field)
                }
            }
            var workItems: [String] = []
            for source in sources {
                for list in source.matches(of: adoList) {
                    for number in list.output.1.split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces) })
                    where !number.isEmpty && !workItems.contains(number) {
                        workItems.append(number)
                    }
                }
            }
            // The title: the next line that is no comment, tag or blank, if it starts with the kind's keyword.
            // `# test:` lines between the header and the title are the scenario's links.
            var title: String?
            var tests: [TestLink] = []
            var badLinks: [Int] = []
            var next = index + 1
            while next < lines.count {
                let candidate = lines[next].trimmingCharacters(in: .whitespaces)
                if candidate.hasPrefix("#"), candidate.dropFirst().trimmingCharacters(in: .whitespaces).lowercased().hasPrefix("test:") {
                    let body = candidate.dropFirst().trimmingCharacters(in: .whitespaces).dropFirst("test:".count)
                    let fields = body.split(separator: "·", maxSplits: 2).map { $0.trimmingCharacters(in: .whitespaces) }
                    let names = fields.count == 3 ? fields[2].components(separatedBy: "›").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } : []
                    if fields.count == 3, !fields[0].isEmpty, !fields[1].isEmpty, !names.isEmpty {
                        tests.append(TestLink(repo: fields[0], path: fields[1], names: names, line: next + 1))
                    } else {
                        badLinks.append(next + 1)
                    }
                    next += 1
                    continue
                }
                if candidate.isEmpty || candidate.hasPrefix("@") || (candidate.hasPrefix("#") && candidate.wholeMatch(of: header) == nil) {
                    next += 1
                    continue
                }
                if let keyword = kind.keywords.first(where: { candidate.hasPrefix($0) }) {
                    title = candidate.dropFirst(keyword.count).trimmingCharacters(in: .whitespaces)
                }
                break
            }
            let body = title != nil && kind == .scenario ? scenarioBody(lines, after: next) : (steps: [], examples: [])
            func problem(_ message: String, _ fix: String) {
                parsed.problems.append(Problem(id: id, line: index + 1, message: message, fix: fix))
            }
            for line in badLinks {
                parsed.problems.append(Problem(id: id, line: line, message: "The test link of \(id) on line \(line) is not “# test: repository · file · test name”.",
                                               fix: "Write the repository's folder name, the file from the repository's top and the test's name (describe titles › title), separated by ·."))
            }
            if kind != .scenario, !tests.isEmpty {
                problem("\(id) is a \(kind.rawValue): tests are linked to scenarios.", "Move the # test: lines under the scenario the test proves.")
            }
            if title == nil {
                problem("\(id) is not followed by a “\(kind.keywords[0])” line.", "Put the \(kind.keywords[0]) line right under the comment line of \(id).")
            }
            if let value = status {
                if !kind.statuses.contains(value) {
                    problem("\(id) has the status “\(value)”; a \(kind.rawValue) is \(kind.statuses.joined(separator: ", ")).",
                            "Write one of them: · status: \(kind.statuses[0]).")
                }
            } else {
                problem("\(id) has no status.", "Add · status: \(kind.statuses[0]) to its comment line.")
            }
            if kind == .scenario {
                if let value = level {
                    if !levels.contains(value) {
                        problem("\(id) has the level “\(value)”; a scenario is \(levels.joined(separator: " or ")).", "Write · level: unit or · level: e2e.")
                    }
                } else {
                    problem("\(id) has no level.", "Add · level: unit or · level: e2e to its comment line.")
                }
                if rule == nil {
                    problem("\(id) comes before any rule of the note.", "Move it under the Rule it belongs to.")
                }
            } else if level != nil || journey {
                problem("\(id) is a \(kind.rawValue): level and journey are for scenarios.", "Remove them from its comment line.")
            }
            if kind == .rule { rule = id }
            parsed.items.append(Item(id: id, kind: kind, feature: feature, number: Int(match.3) ?? 0, title: title, status: status,
                                     level: kind == .scenario ? level : nil, journey: kind == .scenario && journey,
                                     rule: kind == .scenario ? rule : nil, workItems: workItems, sources: sources.joined(separator: " · "),
                                     tests: kind == .scenario ? tests : [], steps: body.steps, examples: body.examples,
                                     note: note, line: index + 1))
            index += 1
        }
        return parsed
    }

    static let stepKeywords = ["Given ", "When ", "Then ", "And ", "But ", "* "]

    /// A scenario's steps and its examples' rows: the lines after its title up to the next item's
    /// header or the end of the gherkin block.
    static func scenarioBody(_ lines: [String], after title: Int) -> (steps: [String], examples: [String]) {
        var steps: [String] = [], examples: [String] = []
        var table: Bool?
        for line in lines.dropFirst(title + 1) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") || line.wholeMatch(of: header) != nil { break }
            if stepKeywords.contains(where: trimmed.hasPrefix) {
                steps.append(trimmed)
            } else if trimmed.hasPrefix("Examples:") || trimmed.hasPrefix("Scenarios:") {
                table = false
            } else if trimmed.hasPrefix("|"), let seen = table {
                // The first row of a table names its columns.
                if seen { examples.append(trimmed) } else { table = true }
            } else if !trimmed.isEmpty, !trimmed.hasPrefix("#"), !trimmed.hasPrefix("@") {
                table = nil
            }
        }
        return (steps, examples)
    }

    /// The IDs a text mentions anywhere (a plan, a task note, a test title), each once, in order.
    public static func references(in text: String) -> [String] {
        var seen: [String] = []
        for match in text.matches(of: reference) {
            // No lookbehind in Swift regexes: the character before the ID must not continue a word.
            if match.range.lowerBound > text.startIndex {
                let before = text[text.index(before: match.range.lowerBound)]
                if before.isLetter || before.isNumber || before == "-" { continue }
            }
            let id = "\(match.1)-\(match.2)-\(match.3)"
            if !seen.contains(id) { seen.append(id) }
        }
        return seen
    }

    /// The items of every note of the base (only notes with a gherkin item), by note and line.
    public static func all(in base: KnowledgeBase) -> [Item] {
        var items: [Item] = []
        for file in KnowledgeBase.files(in: base.areasFolder) where file.pathExtension == "md" {
            guard let note = KnowledgeNote.load(file), note.text.contains("gherkin") else { continue }
            items += parse(note.text, note: KnowledgeBase.id(of: file, areas: base.areasFolder)).items
        }
        return items
    }

    /// `items` with `workItem` among their own ADO IDs and with `status`, when given.
    public static func filter(_ items: [Item], workItem: String? = nil, status: String? = nil) -> [Item] {
        items.filter { item in
            (workItem.map { item.workItems.contains($0) } ?? true) && (status.map { item.status == $0 } ?? true)
        }
    }

    /// `akit kb scenarios --json`.
    public struct Answer: Encodable, Sendable {
        public let base: String
        public let note: String?
        public let items: [Item]

        public init(base: String, note: String?, items: [Item]) {
            self.base = base
            self.note = note
            self.items = items
        }
    }
}
