import Foundation

/// Safe edits of a harness's JSON settings file that the harness may rewrite at any time
/// (`~/.claude/settings.json`, `~/.claude.json`, Pi's settings and MCP files): strict reading,
/// a check that a text edit did exactly the intended change, a preview of only the changed part,
/// and a write that refuses when the file changed since the preview, backs it up first and
/// replaces it in one step with its mode and extended attributes.
public enum SettingsFile {
    public struct Failure: Error, LocalizedError {
        public let message: String
        public var errorDescription: String? { message }
        public init(_ message: String) { self.message = message }
    }

    /// The file's bytes and its JSON object; nil when there is no file. `limit`: the largest
    /// file AKit reads (Claude Code's `~/.claude.json` can hold megabytes of history).
    public static func read(_ url: URL, home: URL, limit: Int = 4 << 20) throws(Failure) -> (data: Data, value: JSONValue)? {
        let fm = FileManager.default
        if (try? fm.destinationOfSymbolicLink(atPath: url.path)) != nil, !fm.fileExists(atPath: url.path) {
            throw Failure("\(FileWalk.tilde(url, home: home)) is a link to a missing file.")
        }
        guard fm.fileExists(atPath: url.path) else { return nil }
        guard FileWalk.isRegularFile(url), let data = FileWalk.head(of: url, limit: limit + 1) else {
            throw Failure("\(FileWalk.tilde(url, home: home)) can't be read.")
        }
        guard data.count <= limit else { throw Failure("\(FileWalk.tilde(url, home: home)) is larger than AKit reads (\(limit >> 20) MB).") }
        let value: JSONValue
        do {
            value = try JSONValue.parse(data)
        } catch {
            throw Failure("\(FileWalk.tilde(url, home: home)) is not valid JSON (\(error.message)). AKit won't change it; fix the file first.")
        }
        guard case .object = value else { throw Failure("\(FileWalk.tilde(url, home: home)) is not a JSON object. AKit won't change it; fix the file first.") }
        return (data, value)
    }

    /// Parses the edited text strictly and checks it is exactly `expected` (the old value with
    /// the intended change applied as a tree): a text edit can never change anything else.
    public static func checked(_ text: String, expected: JSONValue, file: URL, home: URL) throws(Failure) -> Data {
        let data = Data(text.utf8)
        let value: JSONValue
        do {
            value = try JSONValue.parse(data)
        } catch {
            throw Failure("The edit of \(FileWalk.tilde(file, home: home)) would not be valid JSON (\(error.message)); nothing was written.")
        }
        guard value == expected else {
            throw Failure("The edit of \(FileWalk.tilde(file, home: home)) would change more than the one entry; nothing was written.")
        }
        return data
    }

    /// A preview of only the changed part: the value at `path` inside its parent objects, with
    /// `env`/`headers` values and token-shaped strings hidden. Neighbouring keys never appear.
    public static func preview(old: JSONValue?, new: JSONValue, at path: [String]) -> [TextDiff.Line] {
        func excerpt(_ tree: JSONValue?) -> String {
            guard let value = tree?.value(at: path) else { return "" }
            var wrapped = value
            for key in path.reversed() { wrapped = .object([key: wrapped]) }
            return String(wrapped.masked.mappingStrings(SecretFilter.masked).pretty.dropLast())
        }
        return TextDiff.lines(from: excerpt(old), to: excerpt(new))
    }

    // MARK: - Edits checked again at Apply

    /// One change to a JSON file: a value set at a key path, or a key path removed.
    public enum Edit: Hashable, Sendable {
        case set([String], JSONValue)
        case remove([String])

        public var path: [String] {
            switch self {
            case .set(let path, _), .remove(let path): path
            }
        }
    }

    /// A planned change of one file, for a file its harness rewrites all the time
    /// (`~/.claude.json`): Apply reads the file again, refuses when a value the edits touch
    /// changed since the plan, then makes the same edits on the fresh text and checks them.
    public struct Change: Sendable {
        public let file: URL
        public let edits: [Edit]
        /// Only the changed part, secrets hidden.
        public let diff: [TextDiff.Line]
        /// The file doesn't exist yet.
        public let creates: Bool
        /// The value at each edited key path when the plan was made (nil = absent).
        let snapshot: [[String]: JSONValue?]
        let limit: Int
    }

    /// The edits made on the text (each one checked as a tree edit) and the tree they give.
    static func edited(_ text: String, value: JSONValue, edits: [Edit], file: URL, home: URL) throws(Failure) -> (data: Data, value: JSONValue) {
        var text = text
        var expected = value
        do {
            for edit in edits {
                switch edit {
                case .set(let path, let new):
                    text = try JSONTextEdit.setting(new, at: path, in: text)
                    expected.set(new, at: path)
                case .remove(let path):
                    text = try JSONTextEdit.removing(at: path, in: text)
                    expected.remove(at: path)
                }
            }
        } catch {
            throw Failure("\(FileWalk.tilde(file, home: home)): \(error.message)")
        }
        return (try checked(text, expected: expected, file: file, home: home), expected)
    }

    /// A change of `file` by `edits`; the preview shows the values under `preview` (key paths).
    public static func change(_ file: URL, edits: [Edit], preview: [[String]], home: URL, limit: Int = 4 << 20) throws(Failure) -> Change {
        let current = try read(file, home: home, limit: limit)
        let value = current?.value ?? .object([:])
        let text = current.map { String(decoding: $0.data, as: UTF8.self) } ?? "{}\n"
        let result = try edited(text, value: value, edits: edits, file: file, home: home)
        var snapshot: [[String]: JSONValue?] = [:]
        for edit in edits { snapshot.updateValue(value.value(at: edit.path), forKey: edit.path) }
        let diff = preview.flatMap { path in self.preview(old: current?.value, new: result.value, at: path) }
        return Change(file: file, edits: edits, diff: diff, creates: current == nil, snapshot: snapshot, limit: limit)
    }

    /// Applies a change on the file as it is now (see `Change`). Returns the backup, if any.
    @discardableResult
    public static func apply(_ change: Change, home: URL) throws(Failure) -> URL? {
        let current = try read(change.file, home: home, limit: change.limit)
        let value = current?.value ?? .object([:])
        for (path, old) in change.snapshot where value.value(at: path) != old {
            throw Failure("\(FileWalk.tilde(change.file, home: home)) changed after the preview (\(JSONValue.display(path))). Check the change again.")
        }
        let text = current.map { String(decoding: $0.data, as: UTF8.self) } ?? "{}\n"
        var result = try edited(text, value: value, edits: change.edits, file: change.file, home: home)
        if current == nil, result.data.last != UInt8(ascii: "\n") { result.data.append(UInt8(ascii: "\n")) }
        return try write(result.data, to: change.file, expecting: current?.data, home: home)
    }

    /// Writes `data` to `file` (through a link, to the real file). Refuses when the file's bytes
    /// are no longer `before` (nil = the file must still be missing). Backs an existing file up into
    /// `~/.akit/backups` first. Returns the backup, nil for a new file.
    @discardableResult
    public static func write(_ data: Data, to file: URL, expecting before: Data?, home: URL) throws(Failure) -> URL? {
        let fm = FileManager.default
        let now: Data? = fm.fileExists(atPath: file.path) ? (try? Data(contentsOf: file)) ?? Data() : nil
        guard now == before else {
            throw Failure("\(FileWalk.tilde(file, home: home)) changed after the preview. Check the change again.")
        }
        guard now != data else { return nil }
        do {
            var backup: URL?
            if now != nil { backup = try Backup.copy(file, into: try Backup.newFolder(home: home), home: home) }
            try replace(file.resolvingSymlinksInPath(), with: data)
            return backup
        } catch let error as Failure {
            throw error
        } catch {
            throw Failure("Couldn't write \(FileWalk.tilde(file, home: home)): \(error.localizedDescription)")
        }
    }

    /// A temporary file next to `real`, created with the old file's mode (so a 0600 file never
    /// has a readable copy), given its extended attributes, then renamed over it.
    static func replace(_ real: URL, with data: Data) throws {
        let fm = FileManager.default
        let folder = real.deletingLastPathComponent()
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        var info = stat()
        let exists = stat(real.path, &info) == 0
        let mode: mode_t = exists ? info.st_mode & 0o7777 : 0o644
        let temporary = folder.appending(path: ".\(real.lastPathComponent).akit-\(UUID().uuidString.prefix(8))")
        let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, mode)
        guard descriptor >= 0 else { throw Failure("can't create a file in \(folder.path) (\(String(cString: strerror(errno))))") }
        var done = false
        defer { if !done { unlink(temporary.path) } }
        do {
            let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
            _ = fchmod(descriptor, mode)
            try handle.write(contentsOf: data)
            try handle.synchronize()
            try handle.close()
        }
        if exists { _ = copyfile(real.path, temporary.path, nil, copyfile_flags_t(COPYFILE_XATTR)) }
        guard rename(temporary.path, real.path) == 0 else { throw Failure("can't replace \(real.path) (\(String(cString: strerror(errno))))") }
        done = true
    }
}
