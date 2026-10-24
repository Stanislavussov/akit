import Foundation
import Yams

/// An area's settings (K24): the optional, committed `areas/<name>/area.yaml` with a title, a
/// description and the projects the area is about (git remotes, `~/` paths, globs), so focus and
/// Review find the area of a new clone or folder without setup.
///
/// ```yaml
/// title: Payments
/// description: Orders, billing and refunds.
/// projects: [git@example.com:shop/orders-api.git, ~/Projects/billing, ~/work/pay-*]
/// ```
///
/// AKit writes this file whole; a file with keys AKit doesn't know is never rewritten.
public struct KnowledgeArea: Sendable, Equatable, Encodable {
    public typealias Failure = KnowledgeBase.Failure

    public static let fileName = "area.yaml"

    public var title: String?
    public var description: String?
    public var projects: [String]
    /// Keys of the file AKit doesn't know: such a file is read but never rewritten.
    public private(set) var unknownKeys: [String] = []

    public init(title: String? = nil, description: String? = nil, projects: [String] = []) {
        self.title = title
        self.description = description
        self.projects = projects
    }

    private enum CodingKeys: String, CodingKey { case title, description, projects }

    // Unset values are null, so every area has the same keys.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(title, forKey: .title)
        try container.encode(description, forKey: .description)
        try container.encode(projects, forKey: .projects)
    }

    public var isEmpty: Bool { title == nil && description == nil && projects.isEmpty }

    /// `folder`'s `area.yaml`; empty settings when it doesn't exist.
    public static func load(folder: URL) throws(Failure) -> KnowledgeArea {
        let file = folder.appending(path: fileName)
        guard FileManager.default.fileExists(atPath: file.path) else { return KnowledgeArea() }
        guard let data = try? Data(contentsOf: file), let text = String(data: data, encoding: .utf8) else {
            throw Failure(message: "Can't read \(file.path) as UTF-8 text.")
        }
        return try parse(text)
    }

    public static func parse(_ text: String) throws(Failure) -> KnowledgeArea {
        let loaded: Any?
        do { loaded = try Yams.load(yaml: text) } catch {
            throw Failure(message: "\(fileName) is not valid YAML: \(error)")
        }
        guard let loaded else { return KnowledgeArea() }
        guard let map = loaded as? [String: Any] else { throw Failure(message: "\(fileName) must be a map (title:, description:, projects:).") }
        var area = KnowledgeArea()
        for (key, value) in map {
            switch key {
            case "title": area.title = string(value)
            case "description": area.description = string(value)
            case "projects":
                switch value {
                case let list as [Any]: area.projects = list.map { "\($0)" }
                case let one as String where !one.isEmpty: area.projects = [one]
                default: break
                }
            default: area.unknownKeys.append(key)
            }
        }
        area.unknownKeys.sort()
        return area
    }

    private static func string(_ value: Any) -> String? {
        let text = "\(value)".trimmingCharacters(in: .whitespacesAndNewlines)
        return value is NSNull || text.isEmpty ? nil : text
    }

    /// The file's text: only the keys that are set.
    public var text: String {
        var lines: [String] = []
        if let title { lines.append("title: " + KnowledgeNote.PropertyValue.scalar(title)) }
        if let description { lines.append("description: " + KnowledgeNote.PropertyValue.scalar(description)) }
        if !projects.isEmpty {
            lines.append("projects: [" + projects.map(KnowledgeNote.PropertyValue.flowItem).joined(separator: ", ") + "]")
        }
        return lines.map { $0 + "\n" }.joined()
    }

    /// Writes `folder/area.yaml` atomically; refused when the file has keys AKit doesn't know.
    func write(folder: URL) throws(Failure) {
        if !unknownKeys.isEmpty {
            throw Failure(message: "\(Self.fileName) has keys AKit doesn't know (\(unknownKeys.joined(separator: ", "))), so AKit doesn't rewrite it. Edit it by hand.")
        }
        do { try Data(text.utf8).write(to: folder.appending(path: Self.fileName), options: .atomic) } catch {
            throw Failure(message: "Couldn't write \(Self.fileName): \(error.localizedDescription)")
        }
    }

    /// Trimmed values; an empty title or description unset; projects without blanks and repeats.
    func cleaned() -> KnowledgeArea {
        var copy = self
        copy.title = title?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        copy.description = description?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        var seen: [String] = []
        for project in projects.map({ $0.trimmingCharacters(in: .whitespaces) }) where !project.isEmpty && !seen.contains(project) {
            seen.append(project)
        }
        copy.projects = seen
        return copy
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
