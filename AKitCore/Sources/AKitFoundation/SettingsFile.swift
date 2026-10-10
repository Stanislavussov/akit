import Foundation

/// Safe edits of a harness's JSON settings file that the harness may rewrite at any time
/// (`~/.claude/settings.json`, `~/.claude.json`, Pi's settings and MCP files): strict reading,
/// a check that a text edit did exactly the intended change, a preview of only the changed part,
/// and a write that refuses when the file changed since the preview, backs it up first and
/// replaces it in one step with its mode, extended attributes and ACL.
public enum SettingsFile {
    public struct Failure: Error, LocalizedError {
        public let message: String
        /// The file's bytes changed between reading and writing (worth a retry when the values
        /// the change touches are still the same).
        public let changedMeanwhile: Bool
        public var errorDescription: String? { message }
        public init(_ message: String, changedMeanwhile: Bool = false) {
            self.message = message
            self.changedMeanwhile = changedMeanwhile
        }
    }

    /// Backups kept per file in `~/.akit/backups`; older ones are deleted (they may hold tokens).
    public static let keptBackups = 20

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
    /// the intended change applied as a tree), keys compared by Unicode scalars as harnesses
    /// compare them: a text edit can never change anything else.
    public static func checked(_ text: String, expected: JSONValue, file: URL, home: URL) throws(Failure) -> Data {
        let data = Data(text.utf8)
        let value: JSONValue
        do {
            value = try JSONValue.parse(data)
        } catch {
            throw Failure("The edit of \(FileWalk.tilde(file, home: home)) would not be valid JSON (\(error.message)); nothing was written.")
        }
        guard value.compact.unicodeScalars.elementsEqual(expected.compact.unicodeScalars) else {
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
        /// Only the changed part (each edit's key path), secrets hidden.
        public let diff: [TextDiff.Line]
        /// The file doesn't exist yet.
        public let creates: Bool
        /// The value at each edited key path when the plan was made (nil = absent).
        let snapshot: [[String]: JSONValue?]
        let limit: Int
        /// The lock the harness itself takes to write the file (`~/.claude.json.lock`).
        let lock: URL?
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

    /// A change of `file` by `edits`; the preview shows each edit's key path. `lock`: the lock
    /// directory the harness takes for this file, held while writing.
    public static func change(_ file: URL, edits: [Edit], home: URL, limit: Int = 4 << 20, lock: URL? = nil) throws(Failure) -> Change {
        let current = try read(file, home: home, limit: limit)
        let value = current?.value ?? .object([:])
        let text = current.map { String(decoding: $0.data, as: UTF8.self) } ?? "{}\n"
        let result = try edited(text, value: value, edits: edits, file: file, home: home)
        var snapshot: [[String]: JSONValue?] = [:]
        for edit in edits { snapshot.updateValue(value.value(at: edit.path), forKey: edit.path) }
        let diff = edits.flatMap { preview(old: current?.value, new: result.value, at: $0.path) }
        return Change(file: file, edits: edits, diff: diff, creates: current == nil, snapshot: snapshot, limit: limit, lock: lock)
    }

    /// Applies a change on the file as it is now (see `Change`), under the harness's lock when
    /// it has one. When the file's bytes change between reading and the final rename but the
    /// touched values don't, it tries again (3 times). Afterwards it reads the file again and
    /// checks the edited values are there. Returns the backup, if any.
    @discardableResult
    public static func apply(_ change: Change, home: URL) throws(Failure) -> URL? {
        let held = try change.lock.map { lock throws(Failure) in try Lock.acquire(lock, file: change.file, home: home) }
        defer { held?.release() }
        var expected = JSONValue.object([:])
        var backup: URL?
        var attempt = 0
        while true {
            attempt += 1
            let current = try read(change.file, home: home, limit: change.limit)
            let value = current?.value ?? .object([:])
            for (path, old) in change.snapshot where value.value(at: path) != old {
                throw Failure("\(FileWalk.tilde(change.file, home: home)) changed after the preview (\(JSONValue.display(path))). Check the change again.")
            }
            let text = current.map { String(decoding: $0.data, as: UTF8.self) } ?? "{}\n"
            var result = try edited(text, value: value, edits: change.edits, file: change.file, home: home)
            if current == nil, result.data.last != UInt8(ascii: "\n") { result.data.append(UInt8(ascii: "\n")) }
            do {
                backup = try write(result.data, to: change.file, expecting: current?.data, home: home)
                expected = result.value
                break
            } catch where error.changedMeanwhile && attempt < 3 {
                continue
            }
        }
        // The harness may write right after: say so if the change isn't there any more.
        let written = (try? read(change.file, home: home, limit: change.limit))?.value
        for edit in change.edits where written?.value(at: edit.path) != expected.value(at: edit.path) {
            throw Failure("\(FileWalk.tilde(change.file, home: home)) was written, but \(JSONValue.display(edit.path)) changed again right after (the harness rewrote the file). Check it and try again.")
        }
        return backup
    }

    /// Writes `data` to `file` (through a link, to the real file). Refuses when the file's bytes
    /// are no longer `before` (nil = the file must still be missing). Order: back up `before`
    /// from memory, prepare and sync the new file next to it, compare the bytes once more, then
    /// rename: the compare and the rename are the last two steps. Returns the backup, nil for a
    /// new file or no change.
    @discardableResult
    public static func write(_ data: Data, to file: URL, expecting before: Data?, home: URL) throws(Failure) -> URL? {
        func now() -> Data? {
            FileManager.default.fileExists(atPath: file.path) ? (try? Data(contentsOf: file)) ?? Data() : nil
        }
        let changed = Failure("\(FileWalk.tilde(file, home: home)) changed after the preview. Check the change again.", changedMeanwhile: true)
        guard now() == before else { throw changed }
        guard before != data else { return nil }
        var backup: URL?
        do {
            if let before {
                backup = try Backup.save(before, as: file, home: home)
                Backup.prune(file, home: home, keep: keptBackups)
            }
        } catch {
            throw Failure("Couldn't back up \(FileWalk.tilde(file, home: home)): \(error.localizedDescription)")
        }
        let real = file.resolvingSymlinksInPath()
        let temporary: URL
        do {
            temporary = try prepare(data, replacing: real)
        } catch let error as Failure {
            throw error
        } catch {
            throw Failure("Couldn't write \(FileWalk.tilde(file, home: home)): \(error.localizedDescription)")
        }
        guard now() == before else {
            unlink(temporary.path)
            if let backup { try? FileManager.default.removeItem(at: backup) }
            throw changed
        }
        guard rename(temporary.path, real.path) == 0 else {
            let reason = String(cString: strerror(errno))
            unlink(temporary.path)
            throw Failure("Couldn't replace \(FileWalk.tilde(file, home: home)) (\(reason)).")
        }
        return backup
    }

    /// A temporary file next to `real` with `data`, created with the old file's mode (so a 0600
    /// file never has a readable copy), given its extended attributes and ACL, synced to disk.
    static func prepare(_ data: Data, replacing real: URL) throws -> URL {
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
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        _ = fchmod(descriptor, mode)
        try handle.write(contentsOf: data)
        try handle.synchronize()
        try handle.close()
        if exists, copyfile(real.path, temporary.path, nil, copyfile_flags_t(COPYFILE_XATTR | COPYFILE_SECURITY)) != 0 {
            throw Failure("can't copy the extended attributes and permissions of \(real.path) (\(String(cString: strerror(errno)))); nothing was written")
        }
        done = true
        return temporary
    }

    // MARK: - The harness's lock

    /// Claude Code writes `~/.claude.json` under a proper-lockfile lock: a directory
    /// `~/.claude.json.lock`, stale after 10 s without an update (2.1.296: `lockfilePath:
    /// \`${e}.lock\``, `stale:1e4`). AKit takes the same directory while it writes, waits for it at
    /// most a few seconds, and removes it when done.
    struct Lock {
        let url: URL
        static let stale: TimeInterval = 10
        static let wait: TimeInterval = 6

        static func acquire(_ url: URL, file: URL, home: URL, wait: TimeInterval = Lock.wait) throws(Failure) -> Lock {
            let deadline = Date.now.addingTimeInterval(wait)
            var delay: UInt32 = 100_000
            while true {
                if mkdir(url.path, 0o755) == 0 { return Lock(url: url) }
                guard errno == EEXIST else {
                    throw Failure("Couldn't take \(FileWalk.tilde(url, home: home)) (\(String(cString: strerror(errno)))).")
                }
                // A lock nobody updated for `stale` seconds belongs to a process that is gone.
                if let modified = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date,
                   Date.now.timeIntervalSince(modified) > stale, rmdir(url.path) == 0 {
                    continue
                }
                guard Date.now < deadline else {
                    throw Failure("Claude Code is writing \(FileWalk.tilde(file, home: home)) (\(FileWalk.tilde(url, home: home)) is held). Try again in a moment.")
                }
                usleep(delay)
                delay = min(delay * 2, 800_000)
            }
        }

        func release() { rmdir(url.path) }
    }
}
