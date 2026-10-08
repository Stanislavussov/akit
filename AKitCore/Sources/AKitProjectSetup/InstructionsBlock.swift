import AKitBrain
import AKitFoundation
import Foundation

/// The core layer's AGENTS.md text as a marked block in a harness's global instructions file
/// (`~/.claude/CLAUDE.md`, `~/.pi/agent/AGENTS.md`). The file is the user's, and other tools
/// write their own blocks there: AKit owns only the text between its markers, and the text
/// around them stays byte for byte.
enum InstructionsBlock {
    static let start = "<!-- akit:core:start -->"
    static let end = "<!-- akit:core:end -->"

    /// Where AKit's block sits in a file's text.
    enum Found: Equatable {
        case none
        /// `range` covers both markers; `inner` is the text between them.
        case block(range: Range<String.Index>, inner: String)
        /// Markers AKit can't pair up: nothing is written.
        case broken(String)
    }

    static func find(in text: String) -> Found {
        let starts = text.ranges(of: start), ends = text.ranges(of: end)
        if starts.isEmpty && ends.isEmpty { return .none }
        if starts.count > 1 { return .broken("it has \(starts.count) \(start) markers") }
        if ends.count > 1 { return .broken("it has \(ends.count) \(end) markers") }
        guard let open = starts.first else { return .broken("it has \(end) without \(start)") }
        guard let close = ends.first else { return .broken("it has \(start) without \(end)") }
        guard open.upperBound <= close.lowerBound else { return .broken("\(end) comes before \(start)") }
        var inner = text[open.upperBound..<close.lowerBound]
        if inner.hasPrefix("\n") { inner = inner.dropFirst() }
        return .block(range: open.lowerBound..<close.upperBound, inner: String(inner))
    }

    /// The block for `text` (which ends with a newline), without a newline after the end marker.
    static func block(_ text: String) -> String {
        "\(start)\n\(text.hasSuffix("\n") || text.isEmpty ? text : text + "\n")\(end)"
    }

    /// `text` with the block appended (after one blank line), put in place of the old one, or
    /// taken out (`inner` nil, together with the blank line AKit put before it).
    static func written(_ inner: String?, into text: String, found: Found) -> String {
        switch found {
        case .block(let range, _):
            guard let inner else {
                var before = String(text[..<range.lowerBound])
                var after = String(text[range.upperBound...])
                if after.hasPrefix("\n") { after.removeFirst() }
                // At the end of the file: the blank line AKit added before the block goes too.
                if after.isEmpty, before.hasSuffix("\n\n") { before.removeLast() }
                return before + after
            }
            return text.replacingCharacters(in: range, with: block(inner))
        case .none, .broken:
            guard let inner else { return text }
            let separator = text.isEmpty || text.hasSuffix("\n\n") ? "" : text.hasSuffix("\n") ? "\n" : "\n\n"
            return text + separator + block(inner) + "\n"
        }
    }

    struct Result {
        /// nil: nothing to show.
        var kind: ProjectSetup.Change.Kind?
        var oldText: String?
        var newText: String?
        /// The bytes Apply writes.
        var write: Data?
        /// What the lock keeps when the change is applied, and when it is not (left out, an
        /// offer not taken, nothing to do).
        var record: ProjectRecords.Lock.Block?
        var kept: ProjectRecords.Lock.Block?
        var warnings: [String] = []
        var blocker: String?
    }

    /// `text`: the layers' AGENTS.md text, or nil when the block should go (an empty render,
    /// a target no longer chosen, Forget).
    static func plan(path: String, url: URL, text: String?, layers: [String], previous: ProjectRecords.Lock.Block?) -> Result {
        let fm = FileManager.default
        // A problem only stops Apply while AKit wants to write the block; otherwise the file
        // is left alone and keeps its record.
        func cannotWrite(_ problem: String) -> Result {
            text != nil ? Result(blocker: problem) : Result(kept: previous, warnings: previous == nil ? [] : [problem])
        }
        if (try? fm.destinationOfSymbolicLink(atPath: url.path)) != nil {
            return cannotWrite("\(path) is a link; AKit writes its block only into a plain file.")
        }
        var isFolder: ObjCBool = false
        var current: String?
        if fm.fileExists(atPath: url.path, isDirectory: &isFolder) {
            if isFolder.boolValue { return cannotWrite("\(path) is a folder; AKit wants to write its block into a file there.") }
            guard let data = try? Data(contentsOf: url), let decoded = String(data: data, encoding: .utf8) else {
                return cannotWrite("\(path) can't be read as text; AKit won't write its block into it.")
            }
            current = decoded
        }
        let found = current.map(find) ?? Found.none
        if case .broken(let reason) = found {
            return cannotWrite("\(path): AKit's block markers are broken (\(reason)). AKit won't write it; fix the markers or remove them first.")
        }
        let hash = text.map { Checksum.sha256(Data($0.utf8)) }
        var inner: String?
        if case .block(_, let found) = found { inner = found }
        let edited = inner.map { previous?.sha256 != Checksum.sha256(Data($0.utf8)) } ?? false

        guard let text, let hash else {
            // The block goes: only AKit's own, untouched text; an edited one is kept.
            guard let previous, let current, inner != nil else { return Result() }
            if edited { return Result(kind: .keepEdited, oldText: current, record: previous, kept: previous) }
            let after = written(nil, into: current, found: found)
            return Result(kind: .update, oldText: current, newText: after, write: Data(after.utf8), record: nil, kept: previous)
        }
        let after = written(text, into: current ?? "", found: found)
        let applied = ProjectRecords.Lock.Block(sha256: hash, offered: hash, layers: layers)
        if inner == text {
            return Result(kind: .same, oldText: current, newText: current, record: applied, kept: applied)
        }
        // Edited inside the block, or the block (or the whole file) removed since AKit wrote it:
        // the user's choice. Kept; the layers' text is only offered, unticked.
        if edited || (inner == nil && previous != nil) {
            let offer: ProjectSetup.Change.Kind = previous?.offered == hash ? .own : .suggest
            let seen = ProjectRecords.Lock.Block(sha256: previous?.sha256, offered: hash, layers: layers)
            var result = Result(kind: offer, oldText: current, newText: after, write: Data(after.utf8), record: applied, kept: seen)
            if inner == nil {
                result.warnings.append("\(path): AKit's block was removed by hand, so AKit doesn't add it again. Tick it in the preview (or akit apply --include \(path)) to take the layers' text.")
            }
            return result
        }
        // A new block (appended, or a new file with only the block), or AKit's untouched one updated.
        return Result(kind: current == nil ? .create : .update, oldText: current, newText: after, write: Data(after.utf8),
                      record: applied, kept: previous)
    }
}
