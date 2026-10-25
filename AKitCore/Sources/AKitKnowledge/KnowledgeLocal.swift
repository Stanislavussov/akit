import AKitBrain
import AKitFoundation
import Foundation

/// Where a note's system is on this Mac (K27), so an agent that reads the note can go and read
/// the code or the documents there: the note's `path:`, else its `repo:` when that is a `~/` or
/// absolute path, else the local copy of its `repo:` remote among the known projects (K12).
/// Only folders that exist count.
public struct KnowledgeLocal: Sendable {
    public let projects: KnowledgeLint.Projects
    public let home: URL

    public init(projects: KnowledgeLint.Projects, home: URL) {
        self.projects = projects
        self.home = home
    }

    /// The folder of the note's system on this Mac, or nil.
    public func folder(of note: KnowledgeNote) -> URL? {
        for value in [note.path, note.repo].compactMap(\.self) {
            if let url = Self.url(value, home: home) {
                if FileWalk.isDirectory(url) { return url }
            } else if value == note.repo, let id = ProjectRecords.normalizedRemote(value), let copy = projects.copies[id] {
                return copy
            }
        }
        return nil
    }

    /// The folder as an agent reads it: `~/Projects/orders-api`.
    public func label(of note: KnowledgeNote) -> String? {
        folder(of: note).map { FileWalk.tilde($0, home: home) }
    }

    /// A `~`, `~/…` or absolute path as a URL; nil for a remote or anything else.
    public static func url(_ value: String, home: URL) -> URL? {
        if value == "~" { return home }
        if value.hasPrefix("~/") { return home.appending(path: String(value.dropFirst(2))) }
        if value.hasPrefix("/") { return URL(filePath: value) }
        return nil
    }
}
