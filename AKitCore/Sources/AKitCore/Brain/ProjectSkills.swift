import Foundation

/// A project's own skills: folders in its `.agents/skills` that AKit didn't write. They
/// are committed with the project, and a render never overwrites or removes them.
public enum ProjectSkills {
    public struct Skill: Identifiable, Hashable, Sendable {
        public var id: String { name }
        public let name: String
        public let description: String
        public let folder: URL
        public var file: URL { folder.appending(path: "SKILL.md") }
    }

    public struct Failure: Error, LocalizedError {
        public let message: String
        public var errorDescription: String? { message }
    }

    public static func folder(of project: URL) -> URL {
        project.appending(path: ProjectBundle.skillsFolder, directoryHint: .isDirectory)
    }

    /// `.agents/skills` resolves inside the project (it may be a link to a shared folder,
    /// which AKit must not treat as the project's own).
    static func isInside(_ project: URL) -> Bool {
        let base = project.resolvingSymlinksInPath().standardizedFileURL.path
        return folder(of: project).resolvingSymlinksInPath().standardizedFileURL.path.hasPrefix(base + "/")
    }

    public static func list(in project: URL, id: String, store: ProjectStore) -> [Skill] {
        names(in: project, lock: ProjectRecords.savedLock(id: id, in: store)).map { name in
            let folder = folder(of: project).appending(path: name)
            let text = (try? String(contentsOf: folder.appending(path: "SKILL.md"), encoding: .utf8)) ?? ""
            return Skill(name: name, description: Frontmatter.parse(text)["description"] ?? "", folder: folder)
        }
    }

    /// Skill folders (with a SKILL.md) in `.agents/skills` with no file from the last render.
    static func names(in project: URL, lock: ProjectRecords.Lock?) -> [String] {
        guard isInside(project) else { return [] }
        let prefix = ProjectBundle.skillsFolder + "/"
        let written = Set((lock?.files ?? [:]).keys.compactMap { path -> String? in
            guard path.hasPrefix(prefix) else { return nil }
            return path.dropFirst(prefix.count).split(separator: "/").first.map(String.init)
        })
        let items = (try? FileManager.default.contentsOfDirectory(at: folder(of: project), includingPropertiesForKeys: nil,
                                                                  options: .skipsHiddenFiles)) ?? []
        return items.filter { FileManager.default.fileExists(atPath: $0.appending(path: "SKILL.md").path) }
            .map(\.lastPathComponent).filter { !written.contains($0) }.sorted()
    }

    /// Why the name can't be used, or nil.
    public static func nameProblem(_ name: String, in project: URL) -> String? {
        if name.isEmpty { return "Give the skill a name." }
        guard isInside(project) else { return "\(ProjectBundle.skillsFolder) is a link out of the project; add skills where it points." }
        guard name.allSatisfy({ ($0.isLowercase && $0.isASCII) || $0.isNumber || $0 == "-" }), name.first?.isLetter == true else {
            return "Use lowercase letters, digits and -, starting with a letter."
        }
        if FileManager.default.fileExists(atPath: folder(of: project).appending(path: name).path) {
            return "The project already has a skill named \(name)."
        }
        return nil
    }

    /// Creates `.agents/skills/<name>/SKILL.md` with a header; returns the file.
    @discardableResult
    public static func create(_ name: String, description: String, instructions: String = "", in project: URL) throws(Failure) -> URL {
        if let problem = nameProblem(name, in: project) { throw Failure(message: problem) }
        let summary = description.split(whereSeparator: \.isNewline).joined(separator: " ").trimmingCharacters(in: .whitespaces)
        guard !summary.isEmpty else { throw Failure(message: "Say when the agent should use it (the description).") }
        let header: String
        do {
            header = "---\nname: \(try LayerWriter.scalar(name))\ndescription: \(try LayerWriter.scalar(summary))\n---\n"
        } catch {
            throw Failure(message: error.message)
        }
        let body = instructions.trimmingCharacters(in: .whitespacesAndNewlines)
        let folder = folder(of: project).appending(path: name)
        let file = folder.appending(path: "SKILL.md")
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data((header + "\n" + (body.isEmpty ? "# \(name)\n" : body + "\n")).utf8).write(to: file, options: .withoutOverwriting)
        } catch {
            throw Failure(message: "Couldn't create \(ProjectBundle.skillsFolder)/\(name): \(error.localizedDescription)")
        }
        return file
    }

    /// Moves one of the project's own skills to the Trash.
    public static func remove(_ name: String, in project: URL, id: String, store: ProjectStore,
                              trash: (URL) throws -> URL? = Trash.move) throws(Failure) {
        guard isInside(project), let skill = list(in: project, id: id, store: store).first(where: { $0.name == name }) else {
            throw Failure(message: "\(name) is not one of the project's own skills.")
        }
        do {
            _ = try trash(skill.folder)
        } catch {
            throw Failure(message: "Couldn't move \(ProjectBundle.skillsFolder)/\(name) to the Trash: \(error.localizedDescription)")
        }
    }
}
