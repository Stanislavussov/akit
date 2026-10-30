import AKitFoundation
import AKitInsights
import AKitInstructions
import AKitLab
import AKitModel
import Foundation

/// Analyze… of the global instructions (docs/design/global-instructions.md): what each section
/// costs, where it repeats, and (steps 4–5) a model's review and the recorded sessions. Every
/// part gives findings of one shape, saved together in `~/.akit/lab/analysis/instructions.json`
/// (Lab's folder: the session part quotes the user's messages; never synced).
public enum InstructionAnalysis {
    /// One instruction text to analyze: a global file as the harnesses read it.
    public struct Text: Sendable, Hashable {
        /// `~/…`.
        public let path: String
        /// Harness ids as in the index (`claude`, `pi`, `codex`, `opencode`).
        public let harnesses: [String]
        public let text: String

        public init(path: String, harnesses: [String], text: String) {
            self.path = path
            self.harnesses = harnesses
            self.text = text
        }
    }

    /// A project's instruction files that load with the global ones.
    public struct Project: Sendable, Hashable {
        public let folder: String
        public let files: [Text]

        public init(folder: String, files: [Text]) {
            self.folder = folder
            self.files = files
        }
    }

    public enum Severity: String, Codable, Sendable, CaseIterable, Comparable {
        case nit, low, medium, high, critical

        public static func < (a: Self, b: Self) -> Bool { allCases.firstIndex(of: a)! < allCases.firstIndex(of: b)! }
    }

    public enum Part: String, Codable, Sendable, CaseIterable {
        /// Size and repeats: no model.
        case size
        /// A model reads the text.
        case review
        /// The recorded sessions: rules broken, things asked by hand.
        case sessions
    }

    public struct Finding: Codable, Sendable, Hashable, Identifiable {
        public let part: Part
        public let severity: Severity
        public let title: String
        public let why: String
        /// The section's heading (`## …`) or first line; nil for the whole text.
        public let section: String?
        /// The global file it is in (`~/…`), or `core` for the brain's text.
        public let file: String?
        /// Where else: project files, sessions (`claude:<id>`).
        public let places: [String]
        /// A new text for the section; empty: remove it; nil: no suggestion.
        public let suggestion: String?
        public let confidence: Double?

        public var id: String { "\(part.rawValue)|\(file ?? "")|\(section ?? "")|\(title)" }

        public init(part: Part, severity: Severity, title: String, why: String, section: String?, file: String?,
                    places: [String] = [], suggestion: String? = nil, confidence: Double? = nil) {
            self.part = part
            self.severity = severity
            self.title = title
            self.why = why
            self.section = section
            self.file = file
            self.places = places
            self.suggestion = suggestion
            self.confidence = confidence
        }
    }

    /// One section of one global file and what it costs.
    public struct Cost: Codable, Sendable, Hashable, Identifiable {
        public let file: String
        public let section: String
        public let bytes: Int
        /// ≈ tokens (bytes / 4, as the Instructions screen counts).
        public let tokens: Int
        /// Model requests recorded in the window by the harnesses that read the file.
        public let requests: Int
        public var sent: Int { tokens * requests }
        public var id: String { file + "|" + section }
    }

    public struct Report: Codable, Sendable {
        public var made: Date
        public var days: Int
        public var parts: [Part]
        public var costs: [Cost]
        public var findings: [Finding]
        public var notes: [String]

        public init(made: Date = .now, days: Int, parts: [Part] = [], costs: [Cost] = [], findings: [Finding] = [], notes: [String] = []) {
            self.made = made
            self.days = days
            self.parts = parts
            self.costs = costs
            self.findings = findings
            self.notes = notes
        }

        /// The part's findings and notes replace the earlier ones of that part (a note starts
        /// with its part's name: "review: …").
        public mutating func merge(_ part: Part, findings new: [Finding], notes more: [String] = []) {
            findings = findings.filter { $0.part != part } + new
            if !parts.contains(part) { parts.append(part) }
            notes = notes.filter { !$0.hasPrefix(part.rawValue + ": ") } + more.map { part.rawValue + ": " + $0 }
            made = .now
        }

        public var sorted: [Finding] { findings.sorted { $0.severity != $1.severity ? $0.severity > $1.severity : $0.title < $1.title } }
    }

    // MARK: - Size and repeats

    static func title(_ section: InstructionSection) -> String {
        if let heading = section.heading { return "## \(heading)" }
        if section.isAKitBlock { return "AKit block" }
        // The first line with words: not blank, not an HTML comment (another tool's marker).
        let first = InstructionText.lines(section.text).first { line in
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            return !trimmed.isEmpty && !(trimmed.hasPrefix("<!--") && trimmed.hasSuffix("-->"))
        } ?? ""
        return String(first.trimmingCharacters(in: .whitespacesAndNewlines).prefix(60))
    }

    /// Costs per section and findings: a section 1 000+ tokens or a quarter of its file; a
    /// section a project file repeats (the model gets it twice there) or has in another version;
    /// a section that two global files of one harness both have.
    public static func sizeAndRepeats(globals: [Text], projects: [Project], requests: [String: Int]) -> (costs: [Cost], findings: [Finding]) {
        var costs: [Cost] = [], findings: [Finding] = []
        for global in globals {
            let units = InstructionText.units(global.text).filter { !$0.isBlank }
            let total = max(1, units.reduce(0) { $0 + $1.bytes })
            let calls = global.harnesses.reduce(0) { $0 + (requests[$1] ?? 0) }
            for unit in units {
                let name = title(unit)
                costs.append(Cost(file: global.path, section: name, bytes: unit.bytes, tokens: unit.bytes / 4, requests: calls))
                if unit.bytes / 4 >= 1000 || (unit.bytes * 4 >= total && unit.bytes >= 1200) {
                    findings.append(Finding(part: .size, severity: .low, title: "Large section",
                                            why: "\(name) is ≈ \(unit.bytes / 4) tokens (\(unit.bytes * 100 / total)% of the file), sent in every request" +
                                                (calls > 0 ? ": ≈ \((unit.bytes / 4 * calls).formatted()) tokens in \(calls.formatted()) requests of the window." : "."),
                                            section: name, file: global.path))
                }
                let own = InstructionText.normalized(unit)
                var same: [String] = [], other: [String] = []
                for project in projects {
                    for file in project.files where !Set(file.harnesses).isDisjoint(with: global.harnesses) {
                        for theirs in InstructionText.units(file.text) {
                            if InstructionText.normalized(theirs) == own {
                                same.append("\(file.path):\(theirs.line)")
                            } else if let heading = unit.heading?.lowercased(), theirs.heading?.lowercased() == heading {
                                other.append("\(file.path):\(theirs.line)")
                            }
                        }
                    }
                }
                if !same.isEmpty {
                    findings.append(Finding(part: .size, severity: .low, title: "Repeated in projects",
                                            why: "\(same.count) project file\(same.count == 1 ? "" : "s") repeat \(name): the model gets it twice there. Keep one place.",
                                            section: name, file: global.path, places: same))
                }
                if !other.isEmpty {
                    findings.append(Finding(part: .size, severity: .medium, title: "Another version in projects",
                                            why: "\(other.count) project file\(other.count == 1 ? "" : "s") have \(name) with other text: the model gets both and can't tell which wins.",
                                            section: name, file: global.path, places: other))
                }
            }
        }
        // The same section in two global files that one harness both reads.
        for (index, a) in globals.enumerated() {
            for b in globals[(index + 1)...] where !Set(a.harnesses).isDisjoint(with: b.harnesses) {
                let theirs = Set(InstructionText.units(b.text).map(InstructionText.normalized))
                for unit in InstructionText.units(a.text) where !unit.isBlank && theirs.contains(InstructionText.normalized(unit)) {
                    findings.append(Finding(part: .size, severity: .low, title: "Twice in global files",
                                            why: "\(title(unit)) is in \(a.path) and \(b.path), and \(Set(a.harnesses).intersection(b.harnesses).sorted().joined(separator: ", ")) read both.",
                                            section: title(unit), file: a.path, places: [b.path]))
                }
            }
        }
        return (costs, findings)
    }

    // MARK: - Inputs

    /// Main model requests per harness (`claude`, `pi`) recorded in the last `days` days, and the
    /// folders those sessions ran in, busiest first. Empty without an index.
    public static func recorded(days: Int, env: HarnessEnvironment, now: Date = .now) -> (requests: [String: Int], folders: [String]) {
        guard let database = try? AnalysisIndex.open(env: env), let sessions = try? AnalysisIndex.sessions(database) else { return ([:], []) }
        let since = now.addingTimeInterval(-Double(days) * 86_400)
        var requests: [String: Int] = [:], folders: [String: Int] = [:]
        for session in sessions where (session.lastActivity ?? session.started ?? .distantPast) >= since {
            requests[session.harness, default: 0] += session.requests
            if let cwd = session.cwd { folders[cwd, default: 0] += session.requests }
        }
        return (requests, folders.sorted { $0.value > $1.value }.map(\.key))
    }

    // MARK: - Saved report

    public static func file(env: HarnessEnvironment) -> URL {
        LabPaths(env: env).folder.appending(path: "analysis/instructions.json")
    }

    public static func load(env: HarnessEnvironment) -> Report? {
        guard let data = try? Data(contentsOf: file(env: env)) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(Report.self, from: data)
    }

    public static func save(_ report: Report, env: HarnessEnvironment) throws {
        let url = file(env: env)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(report).write(to: url, options: .atomic)
    }
}
