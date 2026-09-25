import Foundation

/// The brain repo: your skill library, layers and project metadata.
/// No harness reads it; AKit renders from it. Read-only for now.
public struct Brain: Sendable {
    /// A skill in `brain/skills/<name>/SKILL.md`.
    public struct Skill: Identifiable, Hashable, Sendable {
        public var id: String { name }
        /// The folder name, used by layers to refer to it.
        public let name: String
        public let description: String
        public let folder: URL
        public var file: URL { folder.appending(path: "SKILL.md") }
    }

    /// Something wrong in the brain, shown next to what it belongs to.
    public struct Problem: Hashable, Sendable {
        /// The layer it belongs to; nil for the brain as a whole.
        public let layer: String?
        public let message: String
    }

    public let root: URL
    public let skills: [Skill]
    public let layers: [Layer]
    public let problems: [Problem]

    /// Default location; overridable in Settings.
    public static func defaultRoot(home: URL) -> URL {
        home.appending(path: ".akit/registry", directoryHint: .isDirectory)
    }

    /// Fields every layer can use without declaring them.
    public static let builtInFields: Set = ["project_name", "target"]

    public func problems(of layer: String) -> [Problem] { problems.filter { $0.layer == layer } }

    /// nil when there is no folder at `root`.
    public static func load(from root: URL) -> Brain? {
        let fm = FileManager.default
        var isFolder: ObjCBool = false
        guard fm.fileExists(atPath: root.path, isDirectory: &isFolder), isFolder.boolValue else { return nil }

        var problems: [Problem] = []
        let skills = subfolders(of: root.appending(path: "skills")).compactMap { folder -> Skill? in
            let file = folder.appending(path: "SKILL.md")
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { return nil }
            let header = Frontmatter.parse(text)
            return Skill(name: folder.lastPathComponent, description: header["description"] ?? "", folder: folder)
        }

        var layers: [Layer] = []
        for folder in subfolders(of: root.appending(path: "layers")) {
            let name = folder.lastPathComponent
            guard let text = try? String(contentsOf: folder.appending(path: "layer.yaml"), encoding: .utf8) else {
                problems.append(Problem(layer: nil, message: "layers/\(name) has no layer.yaml."))
                continue
            }
            do {
                let parsed = try LayerManifest.parse(text, folder: folder)
                layers.append(parsed.layer)
                problems += parsed.problems.map { Problem(layer: name, message: $0) }
            } catch {
                problems.append(Problem(layer: nil, message: "layers/\(name): \(error.message)"))
            }
        }

        problems += validate(layers, skills: Set(skills.map(\.name)))
        return Brain(root: root, skills: skills, layers: layers, problems: problems)
    }

    // MARK: - Checks across layers

    static func validate(_ layers: [Layer], skills: Set<String>) -> [Problem] {
        let byName = Dictionary(layers.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        var problems: [Problem] = []

        for layer in layers {
            func add(_ message: String) { problems.append(Problem(layer: layer.name, message: message)) }

            for name in layer.requires where byName[name] == nil { add("Requires “\(name)”, which doesn't exist.") }
            for name in layer.conflicts where byName[name] == nil { add("Conflicts with “\(name)”, which doesn't exist.") }
            for name in layer.requires where layer.conflicts.contains(name) { add("Both requires and conflicts with “\(name)”.") }

            for id in duplicates(layer.fields.map(\.id)) { add("Field “\(id)” is declared twice.") }
            for id in layer.fields.map(\.id) where builtInFields.contains(id) { add("Field “\(id)” is built in; pick another id.") }
            for name in duplicates(layer.skills.map(\.name)) { add("Skill “\(name)” is listed twice.") }
            for skill in layer.skills where !skills.contains(skill.name) { add("Skill “\(skill.name)” is not in skills/.") }

            let fm = FileManager.default
            for file in layer.files where !fm.fileExists(atPath: layer.templates.appending(path: file.template).path) {
                add("Template “\(file.template)” is missing in templates/.")
            }

            // A `when` may use this layer's fields, fields of layers it requires, and built-ins.
            let visible = builtInFields.union(requiredClosure(of: layer.name, in: byName).flatMap { byName[$0]?.fields.map(\.id) ?? [] })
            let conditions = layer.skills.flatMap(\.when) + layer.files.flatMap(\.when)
            for field in Set(conditions.map(\.field)).sorted() where !visible.contains(field) {
                add("when uses “\(field)”, which is not a field of this layer or the layers it requires.")
            }
        }

        for cycle in cycles(in: byName) {
            problems.append(Problem(layer: cycle[0], message: "requires goes in a circle: \(cycle.joined(separator: " → ")) → \(cycle[0])."))
        }
        return problems
    }

    /// The layer and everything it requires, directly or not.
    static func requiredClosure(of name: String, in layers: [String: Layer]) -> Set<String> {
        var seen: Set<String> = []
        var queue = [name]
        while let next = queue.popLast() {
            guard seen.insert(next).inserted else { continue }
            queue += layers[next]?.requires ?? []
        }
        return seen
    }

    /// Each `requires` cycle once, starting from its alphabetically first layer.
    static func cycles(in layers: [String: Layer]) -> [[String]] {
        var found: Set<[String]> = []
        func walk(_ name: String, _ path: [String]) {
            if let start = path.firstIndex(of: name) {
                let cycle = Array(path[start...])
                let first = cycle.firstIndex(of: cycle.min()!)!
                found.insert(Array(cycle[first...] + cycle[..<first]))
                return
            }
            for next in layers[name]?.requires ?? [] where layers[next] != nil { walk(next, path + [name]) }
        }
        for name in layers.keys { walk(name, []) }
        return found.sorted { $0.joined() < $1.joined() }
    }

    private static func duplicates(_ items: [String]) -> [String] {
        var seen: Set<String> = [], dup: [String] = []
        for item in items where !seen.insert(item).inserted && !dup.contains(item) { dup.append(item) }
        return dup
    }

    private static func subfolders(of folder: URL) -> [URL] {
        let items = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.isDirectoryKey], options: .skipsHiddenFiles)) ?? []
        return items
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
}
