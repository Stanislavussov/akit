import AKitBrain
import AKitFoundation
import AKitInstructions
import Foundation

/// Remove This Copy… on the Instructions screen (docs/design/instructions.md, step 3): one `##`
/// section leaves one instruction file, so the model stops getting it twice. A diff first, then
/// a backup and a write that is refused when the file changed since the preview. A project's
/// file that git tracks may change (decided D12): the change shows in `git status`, AKit never
/// commits. Never: AKit's core block (it changes in the brain), a file AKit rendered from the
/// brain into a project (the next Apply would bring the section back).
public enum InstructionEdit {
    public struct Failure: Error, LocalizedError {
        public let message: String
        public var errorDescription: String? { message }
    }

    public struct Plan: Sendable {
        public let file: URL
        public let heading: String?
        public let line: Int
        public let diff: [TextDiff.Line]
        public let notes: [String]
        let before: Data
        let after: Data
    }

    /// The real paths of the files AKit rendered into the brain's projects on this Mac (their
    /// locks), so a section in them changes through the brain.
    public static func renderedFiles(projects: [String: URL], store: ProjectStore) -> Set<String> {
        var paths: Set<String> = []
        for (id, folder) in projects {
            guard let lock = ProjectRecords.savedLock(id: id, in: store) else { continue }
            for path in lock.files.keys { paths.insert(realPath(folder.appending(path: path))) }
        }
        return paths
    }

    /// Why this section can't be removed here; nil when it can.
    public static func unavailable(_ section: InstructionSection, in file: URL, rendered: Set<String>) -> String? {
        if section.isAKitBlock {
            return "This is AKit's block of the core layer. Change it in the brain (Brain → core → Edit Layer…), then Update Home Folder."
        }
        if rendered.contains(realPath(file)) {
            return "AKit renders this file from the brain's layers; the next Apply would bring the section back. Change the layer on the Brain screen."
        }
        if !FileManager.default.isWritableFile(atPath: file.path) { return "\(file.lastPathComponent) can't be written." }
        return nil
    }

    /// What removing the section would change. Only reads (and `git ls-files` for the note).
    /// `others`: the files of the other places that hold the section; one that is this file
    /// (a link to it, a hard link) is refused, since the write would take it from there too.
    public static func removing(_ section: InstructionSection, from file: URL, others: [URL] = [], rendered: Set<String>,
                                env: HarnessEnvironment) throws(Failure) -> Plan {
        let shown = FileWalk.tilde(file, home: env.homeDirectory)
        if let same = others.first(where: { isSameFile($0, file) }) {
            throw Failure(message: "\(FileWalk.tilde(same, home: env.homeDirectory)) and \(shown) are one file (a link), read twice. Removing the section would take it from both. Remove the link instead, so the file is read once.")
        }
        guard let before = try? Data(contentsOf: file), let text = String(data: before, encoding: .utf8) else {
            throw Failure(message: "\(shown) can't be read as text.")
        }
        // The section as the file has it now: the same text at the same line, or the screen is stale.
        guard let fresh = InstructionText.units(text).first(where: { $0.line == section.line }), fresh.text == section.text else {
            throw Failure(message: "\(shown) changed since the screen read it: line \(section.line) no longer holds \(section.heading.map { "## \($0)" } ?? "that section") as it was. Look at the screen again.")
        }
        if let reason = unavailable(fresh, in: file, rendered: rendered) { throw Failure(message: reason) }
        if fresh.heading == nil, fresh.text.split(separator: "\n").contains(where: { $0.hasPrefix("---") || $0.hasPrefix("# ") }) {
            throw Failure(message: "The text before the first ## heading of \(shown) holds its header or title. AKit doesn't remove it; edit the file by hand.")
        }
        if hasOpenFence(fresh.text) {
            throw Failure(message: "This section of \(shown) opens a code fence that never closes, so AKit can't tell where the section ends. Edit the file by hand.")
        }
        guard let after = removed(fresh, from: text) else {
            throw Failure(message: "\(shown) changed since the screen read it. Look at the screen again.")
        }
        var notes: [String] = []
        let folder = file.deletingLastPathComponent()
        if LocalOnly.tracked([file.lastPathComponent], in: folder, env: env)?.isEmpty == false {
            notes.append("git tracks \(file.lastPathComponent): the change shows in git status there. AKit doesn't commit it.")
        }
        if after.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            notes.append("Nothing else is left in \(file.lastPathComponent). The empty file stays; delete it yourself if it should go.")
        }
        return Plan(file: file, heading: section.heading, line: section.line, diff: TextDiff.lines(from: text, to: after), notes: notes,
                    before: before, after: Data(after.utf8))
    }

    /// Backs the file up and writes it; refused when it changed since the plan. The backup, if made.
    @discardableResult
    public static func apply(_ plan: Plan, env: HarnessEnvironment) throws(Failure) -> URL? {
        do {
            return try SettingsFile.write(plan.after, to: plan.file, expecting: plan.before, home: env.homeDirectory)
        } catch {
            throw Failure(message: error.message)
        }
    }

    /// The text without the section's lines, or nil when the file no longer has them at its
    /// line. One blank line stays between the parts around it, a removed last section leaves
    /// the file ending in one newline, and every other byte is kept.
    static func removed(_ section: InstructionSection, from text: String) -> String? {
        var lines = InstructionText.lines(text)
        let own = InstructionText.lines(section.text)
        let start = section.line - 1
        guard start >= 0, start + own.count <= lines.count, Array(lines[start..<(start + own.count)]) == own else { return nil }
        let isBlank: (String) -> Bool = { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        let endsFile = start + own.count == lines.count
        lines.removeSubrange(start..<(start + own.count))
        if endsFile {
            // The last section: the blank lines before it go too, and the file ends in a newline
            // (after a CRLF line that is its \r\n) unless nothing is left.
            while let last = lines.last, isBlank(last) { lines.removeLast() }
            if !lines.isEmpty { lines.append("") }
        } else if start == 0 {
            while lines.count > 1, isBlank(lines[0]) { lines.removeFirst() }
        } else if isBlank(lines[start - 1]), isBlank(lines[start]) {
            lines.remove(at: start)
        }
        return lines.joined(separator: "\n")
    }

    /// A fenced code block opens in the text and never closes.
    static func hasOpenFence(_ text: String) -> Bool {
        var open: (mark: Character, length: Int)?
        for line in InstructionText.lines(text) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let first = trimmed.first, first == "`" || first == "~" else { continue }
            let run = trimmed.prefix { $0 == first }.count
            guard run >= 3 else { continue }
            if let fence = open {
                if first == fence.mark, run >= fence.length, trimmed.dropFirst(run).allSatisfy({ $0 == " " || $0 == "\t" }) { open = nil }
            } else if !(first == "`" && trimmed.dropFirst(run).contains("`")) {
                open = (first, run)
            }
        }
        return open != nil
    }

    /// One file on disk: the same real path, or the same device and inode (a hard link).
    public static func isSameFile(_ a: URL, _ b: URL) -> Bool {
        if realPath(a) == realPath(b) { return true }
        var sa = stat(), sb = stat()
        guard stat(a.path, &sa) == 0, stat(b.path, &sb) == 0 else { return false }
        return sa.st_dev == sb.st_dev && sa.st_ino == sb.st_ino
    }

    public static func realPath(_ url: URL) -> String {
        guard let resolved = realpath(url.path, nil) else { return url.standardizedFileURL.path }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}
