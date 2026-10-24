import AKitFoundation
import AKitLab
import Foundation

/// A short overview of the change for the user (R45–R47, `<run>/overview.json`): what happens,
/// the modules that change and why, and the flow as Mermaid, in the summary language. The brief
/// submits it with `akit_submit_overview`; AKit checks it. Never posted.
public struct ReviewOverview: Codable, Sendable, Hashable {
    public struct Module: Codable, Sendable, Hashable {
        public var name: String
        /// Only changed files of the run.
        public var files: [String]
        public var why: String

        public init(name: String, files: [String], why: String) {
            self.name = name
            self.files = files
            self.why = why
        }
    }

    public enum WhySource: String, Codable, Sendable, CaseIterable {
        case workItem = "work-item", description, notes, none
    }

    public enum FlowKind: String, Codable, Sendable {
        case flowchart, sequenceDiagram
    }

    /// 3–5 points on what happens (fewer: `notes` says the overview is short).
    public var points: [String]
    public var modules: [Module]
    /// Where the why comes from.
    public var whySources: [WhySource]
    /// The flow AKit shows: the model's, with the other repositories' uses added. nil when the
    /// brief gave none or AKit rejected it.
    public var flow: String?
    /// The flow as the brief gave it (masked), also when AKit rejected it.
    public var flowOriginal: String?
    public var flowKind: FlowKind?
    public var language: LabLanguage
    /// What AKit left out or changed, and why.
    public var notes: [String]

    public init(points: [String], modules: [Module], whySources: [WhySource], flow: String? = nil, flowOriginal: String? = nil,
                flowKind: FlowKind? = nil, language: LabLanguage, notes: [String] = []) {
        self.points = points
        self.modules = modules
        self.whySources = whySources
        self.flow = flow
        self.flowOriginal = flowOriginal
        self.flowKind = flowKind
        self.language = language
        self.notes = notes
    }

    // MARK: - Limits

    static let maxPoints = 5
    static let minPoints = 3
    static let maxPoint = 400
    static let maxModules = 20
    static let maxFiles = 50
    static let maxWhy = 400
    static let maxName = 120
    static let maxFlow = 6000
    static let maxNodes = 40
    /// Projects of other repositories AKit adds to the flow.
    static let maxProjects = 20

    // MARK: - Check

    /// AKit's check of `<run>/passes/overview.json`: nil when the brief submitted none.
    static func check(folder: URL, spec: ReviewRunSpec) -> ReviewOverview? {
        guard let object = FileWalk.jsonObject(folder.appending(path: "passes/overview.json")) else { return nil }
        let diffs = ReviewJSON.read(ReviewSnapshot.self, from: folder.appending(path: "gitlab/snapshot.json"))?.diffs ?? []
        let changed = Set(diffs.map { $0.deletedFile ? $0.oldPath : $0.newPath })
        let consumers = ReviewJSON.read([ReviewConsumer].self, from: folder.appending(path: "consumers.json")) ?? []
        let boundaries = ReviewJSON.read([ReviewBoundary].self, from: folder.appending(path: "boundaries.json")) ?? []
        return check(object, changed: changed, consumers: consumers, boundaries: boundaries, language: spec.overviewLanguage())
    }

    static func check(_ raw: [String: Any], changed: Set<String>, consumers: [ReviewConsumer], boundaries: [ReviewBoundary],
                      language: LabLanguage) -> ReviewOverview {
        var notes: [String] = []
        func clean(_ value: Any?, _ limit: Int) -> String {
            String(SecretFilter.masked(value as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines).prefix(limit))
        }
        var points = (raw["points"] as? [Any] ?? []).map { clean($0, maxPoint) }.filter { !$0.isEmpty }
        if points.count > maxPoints { points = Array(points.prefix(maxPoints)) }
        if points.count < minPoints { notes.append("The overview is short: \(points.count) point\(points.count == 1 ? "" : "s") instead of 3–5.") }

        var modules: [Module] = []
        var unknown = 0
        for item in (raw["modules"] as? [Any] ?? []).compactMap({ $0 as? [String: Any] }).prefix(maxModules) {
            let given = (item["files"] as? [Any] ?? []).compactMap { $0 as? String }.prefix(maxFiles)
                .map { $0.hasPrefix("./") ? String($0.dropFirst(2)) : $0 }
            var files: [String] = []
            for file in given where !files.contains(file) {
                if changed.contains(file) { files.append(file) } else { unknown += 1 }
            }
            let name = clean(item["name"], maxName)
            guard !files.isEmpty, !name.isEmpty else { continue }
            modules.append(Module(name: name, files: files, why: clean(item["why"], maxWhy)))
        }
        if unknown > 0 { notes.append("Left out \(unknown) file\(unknown == 1 ? "" : "s") the change doesn't touch.") }

        var sources: [WhySource] = []
        for value in raw["why_sources"] as? [Any] ?? [] {
            if let source = (value as? String).flatMap(WhySource.init), !sources.contains(source) { sources.append(source) }
        }
        if sources.count > 1 { sources.removeAll { $0 == .none } }

        var overview = ReviewOverview(points: points, modules: modules, whySources: sources, language: language, notes: notes)
        let text = SecretFilter.masked(raw["flow"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return overview }
        overview.flowOriginal = String(text.prefix(maxFlow * 2))
        switch flowCheck(text) {
        case .failure(let problem):
            overview.notes.append("The flow is left out: \(problem.reason).")
        case .success(let kind):
            overview.flowKind = kind
            overview.flow = kind == .flowchart ? withOtherRepositories(text, consumers: consumers, boundaries: boundaries) : text
        }
        return overview
    }

    struct FlowProblem: Error { let reason: String }

    /// Constructs a flow may not have: links and callbacks, a config block, scripts, frames.
    static let forbidden: [(pattern: String, name: String)] = [
        (#"(?i)\bclick\b"#, "click"), (#"(?i)href"#, "href"), (#"(?i)\bcall\s+[A-Za-z_$][\w$.]*\s*\("#, "call"),
        (#"%%\{"#, "%%{"), (#"(?i)<\s*script"#, "<script"), (#"(?i)javascript\s*:"#, "javascript:"), (#"(?i)<\s*iframe"#, "<iframe"),
    ]

    /// Whether AKit may show the flow: a `flowchart`, `graph` or `sequenceDiagram`, within the
    /// limits, with no forbidden construct and no HTML but `<br/>`.
    static func flowCheck(_ text: String) -> Result<FlowKind, FlowProblem> {
        guard text.count <= maxFlow else { return .failure(FlowProblem(reason: "it has over \(maxFlow) characters")) }
        let first = text.split(whereSeparator: \.isNewline).first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        let kind: FlowKind
        if first.hasPrefix("flowchart") || first.hasPrefix("graph") { kind = .flowchart }
        else if first.hasPrefix("sequenceDiagram") { kind = .sequenceDiagram }
        else { return .failure(FlowProblem(reason: "it doesn't start with flowchart, graph or sequenceDiagram")) }
        for (pattern, name) in forbidden where text.range(of: pattern, options: .regularExpression) != nil {
            return .failure(FlowProblem(reason: "it has `\(name)`"))
        }
        if let tag = htmlTags(in: text).first(where: { $0.range(of: #"(?i)^<br\s*/?>$"#, options: .regularExpression) == nil }) {
            return .failure(FlowProblem(reason: "it has the HTML tag `\(tag.prefix(40))`"))
        }
        let nodes = nodeCount(text, kind: kind)
        if nodes > maxNodes { return .failure(FlowProblem(reason: "it has about \(nodes) nodes, over \(maxNodes)")) }
        return .success(kind)
    }

    static func htmlTags(in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: #"<\s*/?\s*[A-Za-z][^<>]*>"#) else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { Range($0.range, in: text).map { String(text[$0]) } }
    }

    static let keywords: Set<String> = ["flowchart", "graph", "subgraph", "end", "direction", "TB", "TD", "BT", "RL", "LR", "classDef", "class",
                                        "style", "linkStyle", "sequenceDiagram", "participant", "actor", "as", "loop", "alt", "else", "opt",
                                        "par", "and", "rect", "note", "Note", "over", "left", "right", "of", "activate", "deactivate",
                                        "autonumber", "critical", "break", "box"]

    /// A rough count of the nodes: a flowchart's distinct ids outside labels, a sequence
    /// diagram's distinct participants.
    static func nodeCount(_ text: String, kind: FlowKind) -> Int {
        var names: Set<String> = []
        for raw in text.split(whereSeparator: \.isNewline).dropFirst() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("%%") { continue }
            switch kind {
            case .flowchart:
                if ["classDef", "class ", "style ", "linkStyle", "subgraph", "direction"].contains(where: { line.hasPrefix($0) }) || line == "end" { continue }
                for word in identifiers(in: withoutLabels(line)) where !keywords.contains(word) { names.insert(word) }
            case .sequenceDiagram:
                if line.hasPrefix("participant ") || line.hasPrefix("actor ") {
                    let rest = line.split(separator: " ", maxSplits: 1).dropFirst().first.map(String.init) ?? ""
                    if let name = rest.components(separatedBy: " as ").first?.trimmingCharacters(in: .whitespaces), !name.isEmpty { names.insert(name) }
                } else if let colon = line.firstIndex(of: ":"), line.range(of: #"-[-)x>]"#, options: .regularExpression) != nil,
                          !line.lowercased().hasPrefix("note") {
                    let head = String(line[..<colon]).replacingOccurrences(of: #"<<?-{1,2}>>?|-{1,2}(?:>>|>|x|\))"#, with: "\u{0}",
                                                                           options: .regularExpression)
                    for part in head.split(separator: "\u{0}") {
                        let name = part.trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "+-")))
                        if !name.isEmpty { names.insert(name) }
                    }
                }
            }
        }
        return names.count
    }

    /// A line with its labels, quoted texts and edge texts blanked.
    static func withoutLabels(_ line: String) -> String {
        var text = line.replacingOccurrences(of: #""[^"]*""#, with: " ", options: .regularExpression)
        for pattern in [#"\|[^|]*\|"#, #"\[[^\]]*\]"#, #"\([^)]*\)"#, #"\{[^}]*\}"#, #"--\s[^->]*-->"#, #">[^\]]*\]"#] {
            text = text.replacingOccurrences(of: pattern, with: " ", options: .regularExpression)
        }
        return text.replacingOccurrences(of: #":::\w+"#, with: " ", options: .regularExpression)
    }

    static func identifiers(in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: #"[A-Za-z_][\w]*"#) else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { Range($0.range, in: text).map { String(text[$0]) } }
    }

    /// The flowchart with the other repositories that use the change (`consumers.json`) in a
    /// subgraph of AKit's own ids and escaped labels; a dashed edge goes from it to the node whose
    /// label names a used boundary's file, when there is one.
    static func withOtherRepositories(_ flow: String, consumers: [ReviewConsumer], boundaries: [ReviewBoundary]) -> String {
        guard !consumers.isEmpty else { return flow }
        var projects: [String] = []
        for consumer in consumers where !projects.contains(consumer.project) { projects.append(consumer.project) }
        var lines = [flow, "  subgraph akit_others[\"Other repositories\"]"]
        for (index, project) in projects.prefix(maxProjects).enumerated() {
            let uses = consumers.filter { $0.project == project }
            let breaks = uses.contains(where: \.breaks) ? " · breaks" : ""
            lines.append("    akit_c\(index + 1)[\"\(ReviewMap.escaped(project)) · \(uses.count) use\(uses.count == 1 ? "" : "s")\(breaks)\"]")
        }
        if projects.count > maxProjects { lines.append("    akit_more[\"+\(projects.count - maxProjects) more\"]") }
        lines.append("  end")
        let labels = nodeLabels(in: flow)
        var targets: [String] = []
        for id in Set(consumers.map(\.boundary)).sorted() {
            guard let file = boundaries.first(where: { $0.id == id })?.file else { continue }
            let base = (file as NSString).lastPathComponent.lowercased()
            guard !base.isEmpty, let node = labels.first(where: { $0.label.lowercased().contains(base) })?.id, !targets.contains(node) else { continue }
            targets.append(node)
        }
        lines += targets.map { "  akit_others -.-> \($0)" }
        return lines.joined(separator: "\n") + "\n"
    }

    /// The flowchart's nodes with a label: `id[label]`, `id(label)`, `id{label}`, `id>label]` and their doubled forms.
    static func nodeLabels(in flow: String) -> [(id: String, label: String)] {
        guard let regex = try? NSRegularExpression(pattern: #"([A-Za-z_][\w-]*)\s*(?:\[\[|\[\(|\(\(|\(\[|\{\{|\[|\(|\{|>)\s*"?([^\]\)\}"]*)"#)
        else { return [] }
        return regex.matches(in: flow, range: NSRange(flow.startIndex..., in: flow)).compactMap { match in
            guard let id = Range(match.range(at: 1), in: flow), let label = Range(match.range(at: 2), in: flow) else { return nil }
            return (String(flow[id]), String(flow[label]))
        }
    }

    // MARK: - Files

    public static func load(folder: URL) -> ReviewOverview? {
        ReviewJSON.read(ReviewOverview.self, from: folder.appending(path: "overview.json"))
    }

    public func save(in folder: URL) throws {
        try ReviewJSON.write(self, to: folder.appending(path: "overview.json"))
    }

    // MARK: - Text

    /// The overview for a terminal: points, modules, sources, notes, then the flow's source.
    public var text: String {
        var lines = ["Overview (\(language.name))"]
        lines += points.map { "  • \($0)" }
        if !modules.isEmpty {
            lines.append("Modules")
            for module in modules {
                lines.append("  \(module.name)" + (module.why.isEmpty ? "" : ": \(module.why)"))
                lines += module.files.map { "    \($0)" }
            }
        }
        lines.append("Why from: " + (whySources.isEmpty ? "not said" : whySources.map(\.rawValue).joined(separator: ", ")))
        if !notes.isEmpty { lines.append("Notes"); lines += notes.map { "  - \($0)" } }
        if let flow {
            lines.append("Flow (\(flowKind?.rawValue ?? "mermaid"))")
            lines.append(flow.trimmingCharacters(in: .newlines))
        } else {
            lines.append("Flow: none")
        }
        return lines.joined(separator: "\n") + "\n"
    }
}
