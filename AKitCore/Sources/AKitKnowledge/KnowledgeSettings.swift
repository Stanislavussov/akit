import AKitFoundation
import Foundation

/// The base's settings (K24): kinds in `kb.yaml`, a note's properties (frontmatter keys), an
/// area's `area.yaml`. The writes here save files only; the caller commits them: the CLI at once
/// (`commit(_:message:env:)`), the app through the commit queue (U2). Renaming a kind commits
/// itself, because it is all or nothing over many notes.
extension KnowledgeBase {
    /// The kinds in `kb.yaml`; the defaults when the base has no such file.
    public func kinds() throws(Failure) -> KnowledgeKinds { try KnowledgeKinds.load(base: root) }

    /// Writes `kb.yaml` and returns its base-relative path.
    @discardableResult
    public func save(kinds: KnowledgeKinds) throws(Failure) -> String {
        try kinds.write(base: root)
        return KnowledgeKinds.fileName
    }

    /// A note id from what a person or agent typed (P1): an id, a `[[link]]`, a unique name.
    public func noteID(_ name: String) throws(Failure) -> String {
        switch linkTargets().resolve(name, from: "") {
        case .note(let id): return id
        case .ambiguous(let ids): throw Failure(message: "“\(name)” matches several notes: \(ids.joined(separator: ", ")). Give the area too, like \(ids[0]).")
        case .map, .missing: throw Failure(message: "No note “\(name)” in \(root.path).")
        }
    }

    /// Sets and removes frontmatter keys of a note, one line each, every other byte kept (P4),
    /// and saves it when anything changed. The note's base-relative path and whether it changed.
    @discardableResult
    public func setProperties(note id: String, set: [(key: String, value: KnowledgeNote.PropertyValue)],
                              unset: [String] = []) throws(Failure) -> (path: String, changed: Bool) {
        let path = notePath(id)
        guard KnowledgeGit.isInside(path), let original = KnowledgeNote.load(noteFile(id)) else {
            throw Failure(message: "No note \(id) in \(root.path), or it isn't UTF-8 text.")
        }
        var note = original
        do {
            for (key, value) in set { note = try note.setting(key, to: value) }
        } catch {
            throw Failure(message: "\(id): \(error.message)")
        }
        for key in unset { note = note.removing(key) }
        guard note != original else { return (path, false) }
        try save(note: id, text: note.text)
        return (path, true)
    }

    /// Renames a kind in `kb.yaml` and in the `kind:` line of every note that has it, all or
    /// nothing: every new text is made first, then written; a failed write puts back the files
    /// already written. Pending in-app edits are committed first, then the rename is one commit.
    /// The changed paths (`kb.yaml` first).
    @discardableResult
    public func renameKind(_ old: String, to new: String, env: HarnessEnvironment) async throws(Failure) -> [String] {
        let kinds = try self.kinds().renaming(old, to: new)
        if !kinds.unknownKeys.isEmpty {
            throw Failure(message: "\(KnowledgeKinds.fileName) has keys AKit doesn't know (\(kinds.unknownKeys.joined(separator: ", "))), so AKit doesn't rewrite it. Edit it by hand.")
        }
        guard old != new else { return [] }
        _ = await KnowledgeCommitQueue(base: root, env: env).flush()

        var planned: [(id: String, old: String, new: String)] = []
        for entry in try notes() where entry.kind == old {
            guard let note = KnowledgeNote.load(noteFile(entry.id)) else {
                throw Failure(message: "Can't read \(entry.path), so no kind was renamed.")
            }
            do {
                planned.append((entry.id, note.text, try note.setting("kind", to: .string(new)).text))
            } catch {
                throw Failure(message: "\(entry.path): \(error.message) No kind was renamed.")
            }
        }
        let kindsFile = root.appending(path: KnowledgeKinds.fileName)
        let oldKinds = try? Data(contentsOf: kindsFile)

        var written: [(id: String, old: String)] = []
        do {
            for change in planned {
                try save(note: change.id, text: change.new)
                written.append((change.id, change.old))
            }
            try save(kinds: kinds)
        } catch {
            for change in written { _ = try? save(note: change.id, text: change.old) }
            if let oldKinds { try? oldKinds.write(to: kindsFile, options: .atomic) } else { try? FileManager.default.removeItem(at: kindsFile) }
            throw Failure(message: "\(error.message) Nothing was renamed: the files written are back as they were.")
        }
        let paths = [KnowledgeKinds.fileName] + planned.map { notePath($0.id) }
        try await commit(paths, message: "Rename kind \(old) to \(new)" + (planned.isEmpty ? "" : " in \(planned.count) note\(planned.count == 1 ? "" : "s")"), env: env)
        return paths
    }

    /// The folder of an existing area.
    func areaFolder(_ name: String) throws(Failure) -> URL {
        let name = Self.nfc(name)
        guard Self.validName(name), let folder = FileWalk.children(of: areasFolder).filter(FileWalk.isDirectory)
            .first(where: { Self.nfc($0.lastPathComponent) == name }) else {
            throw Failure(message: "No area “\(name)” in \(root.path). Areas: \(areas().map(\.name).joined(separator: ", ")).")
        }
        return folder
    }

    /// An area's `area.yaml` (empty settings without one).
    public func settings(area name: String) throws(Failure) -> KnowledgeArea {
        try KnowledgeArea.load(folder: areaFolder(name))
    }

    /// Writes an area's `area.yaml` (trimmed, repeats dropped) and returns its base-relative path.
    @discardableResult
    public func save(area name: String, settings: KnowledgeArea) throws(Failure) -> String {
        let folder = try areaFolder(name)
        try settings.cleaned().write(folder: folder)
        return "areas/\(folder.lastPathComponent)/\(KnowledgeArea.fileName)"
    }

    /// Commits base-relative paths at once (one commit, P8), for the CLI's writes.
    public func commit(_ paths: [String], message: String, env: HarnessEnvironment) async throws(Failure) {
        do { try await KnowledgeGit(base: root, env: env).commit(paths: paths, message: message) } catch {
            throw Failure(message: "\(paths.joined(separator: ", ")) \(paths.count == 1 ? "was" : "were") written, but not committed: \(error.message)")
        }
    }
}
