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
    public static func removing(_ section: InstructionSection, from file: URL, rendered: Set<String>, env: HarnessEnvironment) throws(Failure) -> Plan {
        if let reason = unavailable(section, in: file, rendered: rendered) { throw Failure(message: reason) }
        let shown = FileWalk.tilde(file, home: env.homeDirectory)
        guard let before = try? Data(contentsOf: file), let text = String(data: before, encoding: .utf8) else {
            throw Failure(message: "\(shown) can't be read as text.")
        }
        guard let after = removed(section, from: text) else {
            throw Failure(message: "\(shown) changed: its line \(section.line) is no longer \(section.heading.map { "## \($0)" } ?? "that section"). Look at the screen again.")
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
    /// line. One blank line stays between the parts around it; every other byte is kept.
    static func removed(_ section: InstructionSection, from text: String) -> String? {
        var lines = InstructionText.lines(text)
        let own = InstructionText.lines(section.text)
        let start = section.line - 1
        guard start >= 0, start + own.count <= lines.count, Array(lines[start..<(start + own.count)]) == own else { return nil }
        // The section's text may end with the file's final newline (an empty last line): keep it.
        let endsFile = start + own.count == lines.count
        let count = endsFile && own.last?.isEmpty == true ? own.count - 1 : own.count
        lines.removeSubrange(start..<(start + count))
        // No two blank lines where the section was, and none left at the top.
        let isBlank: (String) -> Bool = { $0.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "\r", with: "").isEmpty }
        if start > 0, start < lines.count, isBlank(lines[start - 1]), isBlank(lines[start]), !(start == lines.count - 1 && lines[start].isEmpty) {
            lines.remove(at: start)
        } else if start == 0 {
            while lines.count > 1, isBlank(lines[0]) { lines.removeFirst() }
        }
        // A trailing blank line before the final newline, left by removing the last section.
        while lines.count >= 2, lines[lines.count - 1].isEmpty, isBlank(lines[lines.count - 2]) { lines.remove(at: lines.count - 2) }
        return lines.joined(separator: "\n")
    }

    static func realPath(_ url: URL) -> String {
        guard let resolved = realpath(url.path, nil) else { return url.standardizedFileURL.path }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}
