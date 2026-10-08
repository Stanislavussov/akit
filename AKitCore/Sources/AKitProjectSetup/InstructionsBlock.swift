import AKitBrain
import AKitFoundation
import AKitRender
import Foundation

/// The core layer's AGENTS.md text as a marked block in a harness's global instructions file
/// (`~/.claude/CLAUDE.md`, the file Pi reads in its config folder). The file is the user's, and
/// other tools write their own blocks there: AKit owns only the text between its markers, and
/// the bytes around them stay as they are. Works on bytes, so CRLF files, a BOM or a file
/// without a final newline come back unchanged when the block goes again.
public enum InstructionsBlock {
    public static let start = "<!-- akit:core:start -->"
    public static let end = "<!-- akit:core:end -->"
    /// The files Pi reads as its global instructions, in its order: the first that exists
    /// wins (Pi's `loadContextFileFromDir`). On macOS `AGENTS.MD` is `AGENTS.md`.
    static let piCandidates = ["AGENTS.override.md", "AGENTS.md", "AGENTS.MD", "CLAUDE.md", "CLAUDE.MD"]
    static let claudePath = ".claude/CLAUDE.md"

    // MARK: - Finding the block

    /// Where AKit's block sits in a file, by byte offsets.
    enum Found: Equatable {
        case none
        /// `range` covers both marker lines and the end marker's line ending; `inner` is the
        /// bytes between the marker lines.
        case block(range: Range<Int>, inner: [UInt8])
        /// Markers AKit can't pair up: nothing is written.
        case broken(String)
    }

    /// A marker counts only as a whole line (at most 3 spaces or tabs before it, any after it,
    /// and `\r`), and never inside a fenced code block, so examples and quotes of it don't count.
    /// A fence that never closes is no fence: the markers after its opening line count (the
    /// block AKit appended after it must stay findable). One pass over the file.
    static func find(in bytes: [UInt8]) -> Found {
        var starts: [Line] = [], ends: [Line] = []
        // Markers inside the fence open now: dropped when it closes, counted if it never does.
        var fencedStarts: [Line] = [], fencedEnds: [Line] = []
        var fence: (char: Character, length: Int)?
        var index = 0
        while index < bytes.count {
            let newline = bytes[index...].firstIndex(of: 0x0A)
            let next = newline.map { $0 + 1 } ?? bytes.count
            var line = String(decoding: bytes[index..<(newline ?? bytes.count)], as: UTF8.self)
            // A BOM before the first line is not part of it, nor of the block's range.
            var lineStart = index
            if index == 0, line.unicodeScalars.first == "\u{FEFF}" {
                line.unicodeScalars.removeFirst()
                lineStart = 3
            }
            while let last = line.unicodeScalars.last, last == "\r" || last == " " || last == "\t" { line.unicodeScalars.removeLast() }
            let indent = line.prefix { $0 == " " || $0 == "\t" }.count
            let bare = indent <= 3 ? line.dropFirst(indent) : ""
            if let open = fence {
                if fenceRun(line).map({ $0.char == open.char && $0.length >= open.length && $0.rest.isEmpty }) == true {
                    fence = nil
                    fencedStarts = []
                    fencedEnds = []
                } else if bare == start {
                    fencedStarts.append((lineStart, next))
                } else if bare == end {
                    fencedEnds.append((lineStart, next))
                }
            } else if let run = fenceRun(line) {
                fence = (run.char, run.length)
            } else if bare == start {
                starts.append((lineStart, next))
            } else if bare == end {
                ends.append((lineStart, next))
            }
            index = next
        }
        if fence != nil {
            starts += fencedStarts
            ends += fencedEnds
        }
        return pair(starts, ends, in: bytes)
    }

    private typealias Line = (start: Int, next: Int)

    private static func pair(_ starts: [Line], _ ends: [Line], in bytes: [UInt8]) -> Found {
        if starts.isEmpty && ends.isEmpty { return .none }
        if starts.count > 1 { return .broken("it has \(starts.count) \(start) lines") }
        if ends.count > 1 { return .broken("it has \(ends.count) \(end) lines") }
        guard let open = starts.first else { return .broken("it has \(end) without \(start)") }
        guard let close = ends.first else { return .broken("it has \(start) without \(end)") }
        guard open.next <= close.start else { return .broken("\(end) comes before \(start)") }
        return .block(range: open.start..<close.next, inner: Array(bytes[open.next..<close.start]))
    }

    /// A Markdown code fence opening or closing on this line: at most 3 spaces, then 3 or more
    /// backticks or tildes; `rest` is what follows them.
    private static func fenceRun(_ line: String) -> (char: Character, length: Int, rest: String)? {
        let indent = line.prefix { $0 == " " }.count
        guard indent <= 3 else { return nil }
        let body = line.dropFirst(indent)
        guard let char = body.first, char == "`" || char == "~" else { return nil }
        let length = body.prefix { $0 == char }.count
        guard length >= 3 else { return nil }
        return (char, length, body.dropFirst(length).trimmingCharacters(in: .whitespaces))
    }

    // MARK: - Writing

    static let bom: [UInt8] = [0xEF, 0xBB, 0xBF]

    /// Writes the file atomically, keeping its permissions and extended attributes (an atomic
    /// write makes a new file, which would lose them).
    static func write(_ data: Data, to url: URL) throws {
        let fm = FileManager.default
        let permissions = (try? fm.attributesOfItem(atPath: url.path))?[.posixPermissions]
        var attributes: [(String, [UInt8])] = []
        url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return }
            let size = listxattr(path, nil, 0, XATTR_NOFOLLOW)
            guard size > 0 else { return }
            var names = [CChar](repeating: 0, count: size)
            guard listxattr(path, &names, size, XATTR_NOFOLLOW) == size else { return }
            for name in names.split(separator: 0).map({ String(decoding: $0.map(UInt8.init(bitPattern:)), as: UTF8.self) }) {
                let length = getxattr(path, name, nil, 0, 0, XATTR_NOFOLLOW)
                guard length >= 0 else { continue }
                var value = [UInt8](repeating: 0, count: length)
                if length == 0 || getxattr(path, name, &value, length, 0, XATTR_NOFOLLOW) == length { attributes.append((name, value)) }
            }
        }
        try data.write(to: url, options: .atomic)
        if let permissions { try? fm.setAttributes([.posixPermissions: permissions], ofItemAtPath: url.path) }
        url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return }
            for (name, value) in attributes { _ = setxattr(path, name, value, value.count, 0, XATTR_NOFOLLOW) }
        }
    }

    /// The file's own line ending: CRLF when it has one, else LF.
    static func lineEnding(of bytes: [UInt8]) -> [UInt8] {
        zip(bytes, bytes.dropFirst()).contains { $0 == 0x0D && $1 == 0x0A } ? [0x0D, 0x0A] : [0x0A]
    }

    /// The layers' text as it goes between the markers: with the file's line ending, ending with one.
    static func inner(_ text: String, lineEnding: [UInt8]) -> [UInt8] {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false)
        var bytes: [UInt8] = []
        for (index, line) in lines.enumerated() {
            bytes += Array(line.utf8)
            if index < lines.count - 1 { bytes += lineEnding }
        }
        if !bytes.isEmpty, !bytes.ends(with: lineEnding) { bytes += lineEnding }
        return bytes
    }

    /// The block with its marker lines, ending with a line ending.
    static func block(_ inner: [UInt8], lineEnding: [UInt8]) -> [UInt8] {
        Array(start.utf8) + lineEnding + inner + Array(end.utf8) + lineEnding
    }

    /// `bytes` with the block appended (`separator` before it: a blank line, unless the file is
    /// empty or already ends with one), put in place of the old one, or taken out (`inner` nil,
    /// together with the separator AKit put before it; an unknown separator: a blank line
    /// before a block at the end). Returns the separator a new block got.
    static func written(_ inner: [UInt8]?, into bytes: [UInt8], found: Found, separator: [UInt8]?) -> (bytes: [UInt8], separator: [UInt8]?) {
        let eol = lineEnding(of: bytes)
        switch found {
        case .block(let range, _):
            guard let inner else {
                var before = Array(bytes[..<range.lowerBound])
                let after = Array(bytes[range.upperBound...])
                if let separator, !separator.isEmpty {
                    // Only while it is still there as AKit put it: a lone line ending after a line
                    // that had one (so a blank line), or the blank line after text without one.
                    if separator == eol ? before.ends(with: eol + eol) : before.ends(with: separator) {
                        before.removeLast(separator.count)
                    }
                } else if separator == nil, after.isEmpty, before.ends(with: eol + eol) {
                    before.removeLast(eol.count)
                }
                // Never join the user's line before the block with their text after it.
                let bom = before.starts(with: Self.bom) ? Self.bom.count : 0
                if !after.isEmpty, before.count > bom, !before.ends(with: [0x0A]) { before += eol }
                return (before + after, nil)
            }
            return (Array(bytes[..<range.lowerBound]) + block(inner, lineEnding: eol) + Array(bytes[range.upperBound...]), separator)
        case .none, .broken:
            guard let inner else { return (bytes, nil) }
            let content = bytes.starts(with: Self.bom) ? Array(bytes.dropFirst(Self.bom.count)) : bytes
            let separator = content.isEmpty || content.ends(with: eol + eol) ? [] : content.ends(with: eol) ? eol : eol + eol
            return (bytes + separator + block(inner, lineEnding: eol), separator)
        }
    }

    // MARK: - One file

    struct Result {
        /// nil: nothing to show.
        var kind: ProjectSetup.Change.Kind?
        /// Shown instead of the kind's usual words ("edited by hand", "removed by hand", …).
        var note: String?
        var oldText: String?
        var newText: String?
        /// The bytes Apply writes.
        var write: Data?
        /// What the lock keeps when the change is applied, and when it is not (left out, an
        /// offer not taken, nothing to do).
        var record: ProjectRecords.Lock.Block?
        var kept: ProjectRecords.Lock.Block?
        /// The file's bytes as read (nil: missing): the preview's snapshot.
        var snapshot: Data?
        var warnings: [String] = []
        var blocker: String?
        /// AKit wanted to write or take out its block but left the file alone (a link, …).
        var skipped = false
        var action: ProjectSetup.Change.BlockAction?
    }

    /// `text`: the layers' AGENTS.md text, or nil when the block should go (an empty render, a
    /// target no longer chosen, Forget). `moved`: the harness now reads another file, so the
    /// block here is only offered for taking out (unticked).
    static func plan(path: String, url: URL, text: String?, layers: [String], target: String,
                     previous: ProjectRecords.Lock.Block?, moved: String? = nil) -> Result {
        let fm = FileManager.default
        // A file AKit can't safely write is left alone with a warning (it keeps its record), so
        // the rest of the home folder still updates.
        func skip(_ problem: String) -> Result {
            guard text != nil || previous != nil else { return Result() }
            return Result(kept: previous, warnings: [problem + (text != nil ? " AKit's block is not written there." : "")], skipped: true)
        }
        if (try? fm.destinationOfSymbolicLink(atPath: url.path)) != nil {
            return skip("\(path) is a link; AKit writes its block only into a plain file.")
        }
        var isFolder: ObjCBool = false
        var current: [UInt8]?
        if fm.fileExists(atPath: url.path, isDirectory: &isFolder) {
            if isFolder.boolValue { return skip("\(path) is a folder.") }
            // Writing atomically replaces the file, which would cut a hard link.
            if let links = (try? fm.attributesOfItem(atPath: url.path))?[.referenceCount] as? Int, links > 1 {
                return skip("\(path) has \(links) hard links; AKit writes its block only into a file with one.")
            }
            guard let data = try? Data(contentsOf: url) else { return skip("\(path) can't be read.") }
            if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]) || data.starts(with: [0, 0, 0xFE, 0xFF]) || data.contains(0) {
                return skip("\(path) is not UTF-8 text (a UTF-16 or UTF-32 byte order mark, or NUL bytes); AKit writes its block only into UTF-8 text.")
            }
            current = Array(data)
        }
        let bytes = current ?? []
        let found = current.map(find) ?? Found.none
        let shownOld = current.map { String(decoding: $0, as: UTF8.self) }
        let snapshot = current.map { Data($0) }
        if case .broken(let reason) = found {
            let problem = "\(path): AKit's block markers are broken (\(reason)). AKit won't write it; fix the markers or remove them first."
            if text != nil { return Result(blocker: problem) }
            return skip(problem)
        }
        var foundInner: [UInt8]?
        if case .block(_, let inner) = found { foundInner = inner }
        let eol = lineEnding(of: bytes)
        // Recorded with the line ending the file had then: in this file's own one now.
        let separator = previous?.separator.map {
            Array($0.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\n", with: String(decoding: eol, as: UTF8.self)).utf8)
        }
        let edited = foundInner.map { previous?.sha256 != Checksum.sha256($0) } ?? false

        guard let text else {
            // The block goes: only AKit's own, untouched text; an edited one is kept.
            guard foundInner != nil else { return Result(snapshot: snapshot) }
            let after = written(nil, into: bytes, found: found, separator: separator).bytes
            var result = Result(kind: .update, oldText: shownOld, newText: String(decoding: after, as: UTF8.self),
                                write: Data(after), record: nil, kept: previous, snapshot: snapshot, action: .takeOut)
            // A Pi file AKit created, empty without the block: an empty file would still be the
            // one Pi reads (hiding a CLAUDE.md next to it), so it goes to the Trash.
            let content = after.starts(with: Self.bom) ? after.dropFirst(Self.bom.count) : after[...]
            if previous?.created == true, target == "pi", content.allSatisfy({ [0x20, 0x09, 0x0D, 0x0A].contains($0) }) {
                result.kind = .remove
                result.action = .trash
                result.newText = nil
                result.write = nil
            }
            if previous == nil {
                result.kind = .suggest
                result.note = "AKit's block, no record of it · tick to take it out"
            } else if edited {
                result.kind = .keepEdited
                result.newText = shownOld
                result.write = nil
                result.action = nil
                if let moved {
                    result.note = "edited by hand · Pi no longer reads this file"
                    result.warnings.append("\(path) has AKit's block, edited by hand, but Pi now reads \(moved). AKit leaves it; take it out by hand if you no longer need it.")
                }
            } else if let moved {
                result.kind = .suggest
                result.note = "AKit's old block · tick to take it out"
                result.warnings.append("\(path) has AKit's block, but Pi now reads \(moved). Tick \(path) in the preview (or akit apply --include \(path)) to take the old block out.")
            }
            return result
        }

        let wanted = inner(text, lineEnding: eol)
        let new = written(wanted, into: bytes, found: found, separator: separator)
        let offered = Checksum.sha256(Data(text.utf8))
        let applied = ProjectRecords.Lock.Block(sha256: Checksum.sha256(wanted), offered: offered, layers: layers,
                                                separator: new.separator.map { String(decoding: $0, as: UTF8.self) }, target: target,
                                                created: current == nil ? true : previous?.created)
        if foundInner == wanted {
            return Result(kind: .same, oldText: shownOld, newText: shownOld, record: applied, kept: applied, snapshot: snapshot)
        }
        var result = Result(kind: current == nil ? .create : .update, oldText: shownOld, newText: String(decoding: new.bytes, as: UTF8.self),
                            write: Data(new.bytes), record: applied, kept: previous, snapshot: snapshot,
                            action: foundInner == nil ? .add : .update)
        // Edited inside the block, or the block (or the whole file) removed since AKit wrote it:
        // the user's choice. Kept; the layers' text is only offered, unticked, once per version.
        if edited || (foundInner == nil && previous != nil) {
            let changed = previous?.offered != offered
            result.kind = changed ? .suggest : .own
            result.kept = ProjectRecords.Lock.Block(sha256: previous?.sha256, offered: offered, layers: layers,
                                                    separator: previous?.separator, target: target, created: previous?.created)
            if foundInner == nil {
                result.note = changed ? "removed by hand · layers changed" : "removed by hand"
                result.warnings.append("\(path): AKit's block was removed by hand, so AKit doesn't add it again. Tick it in the preview (or akit apply --include \(path)) to take the layers' text.")
            } else {
                result.note = changed ? "edited by hand · layers changed" : "edited by hand"
            }
        }
        return result
    }

    // MARK: - The home folder

    /// What the home render does with instruction blocks.
    struct HomePlan {
        var changes: [ProjectSetup.Change] = []
        var errors: [String] = []
        var blockers: [String] = []
        var warnings: [String] = []
        var urls: [String: URL] = [:]
        var writes: [String: Data] = [:]
        var records: [String: ProjectRecords.Lock.Block] = [:]
        var kept: [String: ProjectRecords.Lock.Block] = [:]
        var snapshot: [String: Data?] = [:]
        /// Files whose block AKit had to leave alone (a link, broken markers when only taking out).
        var skipped: [String] = []
        /// Pi's config folder used (absolute), for the lock.
        var piAgentDir: String?
    }

    /// Pi's config folder as Pi resolves it: PI_CODING_AGENT_DIR (`~` and `file://` expanded),
    /// else `~/.pi/agent`. With `remember` (the app, which doesn't see the shell's variables) a
    /// folder the last home render used wins over the default while it exists, and the preview
    /// says so. A relative setting is resolved by Pi from the folder it starts in, so AKit can't
    /// know it: nil and a warning.
    static func piDirectory(setting: String?, recorded: String?, remember: Bool, home: URL) -> (url: URL?, warning: String?) {
        if let setting, !setting.isEmpty {
            if setting == "~" { return (home, nil) }
            if setting.hasPrefix("~/") { return (home.appending(path: String(setting.dropFirst(2))), nil) }
            if setting.hasPrefix("file://"), let url = URL(string: setting), url.isFileURL { return (url, nil) }
            if setting.hasPrefix("/") { return (URL(filePath: setting, directoryHint: .isDirectory), nil) }
            return (nil, "PI_CODING_AGENT_DIR is a relative path (\(setting)); Pi resolves it from the folder it starts in, so AKit doesn't know which file Pi reads and leaves Pi's instructions alone.")
        }
        let standard = home.appending(path: ".pi/agent", directoryHint: .isDirectory)
        var isFolder: ObjCBool = false
        if remember, let recorded, recorded.hasPrefix("/"), recorded != standard.standardizedFileURL.path,
           FileManager.default.fileExists(atPath: recorded, isDirectory: &isFolder), isFolder.boolValue {
            return (URL(filePath: recorded, directoryHint: .isDirectory),
                    "Pi's folder: \(recorded) (remembered from an earlier render; the app doesn't see PI_CODING_AGENT_DIR from your shell).")
        }
        return (standard, nil)
    }

    /// The file Pi reads in `folder`: the first candidate that is there (a file, or a link to
    /// one), else `AGENTS.md`, which AKit creates.
    static func piFile(in folder: URL) -> URL {
        let fm = FileManager.default
        for name in piCandidates {
            var isFolder: ObjCBool = false
            let url = folder.appending(path: name)
            if fm.fileExists(atPath: url.path, isDirectory: &isFolder), !isFolder.boolValue { return url }
        }
        return folder.appending(path: "AGENTS.md")
    }

    /// A file's path in a plan: relative to the home folder when it is inside it, else absolute.
    static func homePath(_ url: URL, home: URL) -> String {
        let base = home.standardizedFileURL.path, full = url.standardizedFileURL.path
        return full.hasPrefix(base + "/") ? String(full.dropFirst(base.count + 1)) : full
    }

    /// The core layer's AGENTS.md text, rendered once per target harness (so a section with
    /// `when: target == pi` reaches only Pi's file), as a block in each target's file. Blocks
    /// of an earlier render come out where they are no longer wanted.
    static func planHome(home: URL, answers: ProjectAnswers, brain: Brain, previous: ProjectRecords.Lock?,
                         otherPaths: [String], piAgentDirSetting: String?, rememberPiAgentDir: Bool) -> HomePlan {
        var plan = HomePlan()
        let pi = piDirectory(setting: piAgentDirSetting, recorded: previous?.piAgentDir, remember: rememberPiAgentDir, home: home)
        let piChosen = answers.targets.contains("pi")
        if piChosen, let warning = pi.warning { plan.warnings.append(warning) }
        if piChosen { plan.piAgentDir = pi.url?.standardizedFileURL.path }

        var wanted: [String: (url: URL, target: String)] = [:]
        if answers.targets.contains("claude") { wanted[claudePath] = (home.appending(path: claudePath), "claude") }
        let piPath = pi.url.map { homePath(piFile(in: $0), home: home) }
        if piChosen, let folder = pi.url, let piPath { wanted[piPath] = (piFile(in: folder), "pi") }

        // Only instruction files are taken from the lock: CLAUDE.md under ~/.claude, or a file
        // Pi reads (in any folder, so a block in a folder Pi used earlier can still come out).
        // Any other key is dropped from the lock.
        var records: [String: ProjectRecords.Lock.Block] = [:]
        for (path, record) in previous?.blocks ?? [:] {
            if path == claudePath || (record.target ?? "pi") == "pi" && piCandidates.contains((path as NSString).lastPathComponent) {
                records[path] = record
            } else {
                plan.warnings.append("The lock names \(path) as an instructions file AKit wrote; it is not one, so AKit forgets it and leaves the file alone.")
            }
        }

        // One rendered text per target.
        var texts: [String: (text: String, layers: [String])] = [:]
        for target in Set(wanted.values.map(\.target)) {
            var only = answers
            only.targets = [target]
            let result = Render.render(ProjectBundle.resolve(only, brain: brain, projectName: home.lastPathComponent), forHome: true)
            for error in result.errors where !plan.errors.contains(error) { plan.errors.append(error) }
            guard let output = result.outputs.first(where: \.instructionsBlock), let text = output.text else { continue }
            if text.contains(start) || text.contains(end) {
                let error = "The core layer's AGENTS.md text holds \(text.contains(start) ? start : end), which marks AKit's block. Take it out of the layer."
                if !plan.errors.contains(error) { plan.errors.append(error) }
                continue
            }
            texts[target] = (text, output.layers)
        }

        // Pi reads only the first file there: say which ones next to it it doesn't read.
        if texts["pi"] != nil, let folder = pi.url, let chosen = piPath.map({ ($0 as NSString).lastPathComponent }),
           let rank = piCandidates.firstIndex(of: chosen) {
            var seen: Set<String> = [chosen.lowercased()]
            let unread = piCandidates[(rank + 1)...].filter { name in
                var isFolder: ObjCBool = false
                return FileManager.default.fileExists(atPath: folder.appending(path: name).path, isDirectory: &isFolder) && !isFolder.boolValue
                    && seen.insert(name.lowercased()).inserted
            }
            if !unread.isEmpty, FileManager.default.fileExists(atPath: folder.appending(path: chosen).path) {
                plan.warnings.append("Pi reads \(piPath!) and gets AKit's block there; \(unread.joined(separator: " and ")) next to it \(unread.count == 1 ? "is" : "are") not read by Pi.")
            }
        }

        for path in Set(wanted.keys).union(records.keys).sorted() {
            let url = wanted[path]?.url ?? (path.hasPrefix("/") ? URL(filePath: path) : home.appending(path: path))
            let record = records[path]
            let target = wanted[path]?.target ?? record?.target ?? (path == claudePath ? "claude" : "pi")
            // Pi's folder unknown (a relative setting): its files are left as they are.
            if target == "pi", piChosen, pi.url == nil {
                if let record { plan.kept[path] = record }
                continue
            }
            let text = wanted[path] != nil ? texts[target] : nil
            if text != nil, otherPaths.contains(where: { $0.lowercased() == path.lowercased() }) {
                plan.blockers.append("\(path) comes from a template of the core layer and also gets AKit's instructions block. Send that template elsewhere.")
                continue
            }
            let moved = wanted[path] == nil && target == "pi" && piChosen ? piPath : nil
            let layers = text?.layers ?? record?.layers ?? []
            let result = InstructionsBlock.plan(path: path, url: url, text: text?.text, layers: layers, target: target,
                                                previous: record, moved: moved)
            plan.warnings += result.warnings
            if let blocker = result.blocker {
                plan.blockers.append(blocker)
                continue
            }
            if result.skipped { plan.skipped.append(path) }
            plan.urls[path] = url
            if let record = result.record { plan.records[path] = record }
            if let kept = result.kept { plan.kept[path] = kept }
            if let write = result.write { plan.writes[path] = write }
            guard let kind = result.kind else { continue }
            var change = ProjectSetup.Change(path: path, kind: kind, oldText: result.oldText, newText: result.newText,
                                             replacesUnmanaged: false, layers: layers)
            change.block = true
            change.blockNote = result.note
            change.blockAction = result.action
            plan.changes.append(change)
            plan.snapshot[path] = result.snapshot
        }
        return plan
    }
}

private extension Array where Element == UInt8 {
    func ends(with suffix: [UInt8]) -> Bool { count >= suffix.count && Array(self[(count - suffix.count)...]) == suffix }
}
