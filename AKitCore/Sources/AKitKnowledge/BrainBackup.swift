import AKitBrain
import AKitFoundation
import Foundation

/// The text copy of this Mac's knowledge bases and meetings in the brain (K38, M34): at each
/// brain sync (`akit sync`, the app's Sync), before the pull and push, the allow-listed text files
/// are mirrored into `knowledge/<world>/` and `meetings/` and committed once. A one-way backup:
/// the bases keep their own local git without a remote (K11) and `~/Meetings` stays where it is.
/// Never on a work Mac (or one whose machine.json can't be read): work data must not reach the
/// brain's remote. Off with `~/.akit/local/backup.json` `{"enabled": false}`.
public enum BrainBackup {
    public struct Outcome: Equatable, Sendable {
        /// Brain paths in the commit; empty when nothing changed or nothing was committed.
        public var committed: [String] = []
        /// Lines for the sync result: what was backed up, skipped files, why nothing was.
        public var lines: [String] = []
    }

    public static let workRefusal = "Knowledge and meetings are not backed up on a work Mac."
    public static let commitMessage = "Back up knowledge and meetings"
    /// Bigger files are left out: a drawing with pasted pictures is no note.
    static let maxBytes = 5 << 20

    // MARK: - Setting

    /// `~/.akit/local/backup.json`, this Mac only.
    public static func settingsFile(home: URL) -> URL { home.appending(path: ".akit/local/backup.json") }

    /// On unless the setting file says `"enabled": false`.
    public static func isEnabled(home: URL) -> Bool {
        guard let data = try? Data(contentsOf: settingsFile(home: home)),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return true }
        return object["enabled"] as? Bool ?? true
    }

    public static func setEnabled(_ enabled: Bool, home: URL) throws {
        let file = settingsFile(home: home)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{\"enabled\": \(enabled)}\n".utf8).write(to: file, options: .atomic)
    }

    // MARK: - Sources

    /// The meetings folder: `rootPath` of `~/Library/Application Support/Meetings/settings.json`
    /// (read here, AKitCore doesn't depend on the Meetings package, M1), else `~/Meetings`.
    public static func meetingsRoot(home: URL) -> URL {
        let settings = home.appending(path: "Library/Application Support/Meetings/settings.json")
        if let data = try? Data(contentsOf: settings),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let path = object["rootPath"] as? String, !path.isEmpty {
            if path.hasPrefix("~/") { return home.appending(path: String(path.dropFirst(2)), directoryHint: .isDirectory) }
            if path.hasPrefix("/") { return URL(filePath: path, directoryHint: .isDirectory) }
        }
        return home.appending(path: "Meetings", directoryHint: .isDirectory)
    }

    /// A base's text files by base-relative path: `kb.yaml`, `.spaces.json`, notes, maps and
    /// `area.yaml` under `areas/`, the Notebook's tabs, tab order and drawings, the Work Log's days. Never the index,
    /// locks, the commit queue, the miss log, `inbox/`, `.obsidian/`, `.git/`, pictures.
    static func knowledgeFiles(base root: URL) -> [String: URL] {
        var files: [String: URL] = [:]
        for name in [KnowledgeKinds.fileName, ".spaces.json"] where isFile(root.appending(path: name)) {
            files[name] = root.appending(path: name)
        }
        for (path, url) in walk(root.appending(path: "areas"), prefix: "areas")
            where ["md", "excalidraw", "yaml"].contains(url.pathExtension.lowercased()) {
            files[path] = url
        }
        let notebook = root.appending(path: "notebook")
        for child in FileWalk.children(of: notebook) where child.pathExtension.lowercased() == "md" && isFile(child) {
            files["notebook/\(child.lastPathComponent)"] = child
        }
        let order = notebook.appending(path: KnowledgeNotebook.orderName)
        if isFile(order) { files["notebook/\(KnowledgeNotebook.orderName)"] = order }
        for child in FileWalk.children(of: notebook.appending(path: "drawings"))
            where child.pathExtension.lowercased() == "excalidraw" && isFile(child) {
            files["notebook/drawings/\(child.lastPathComponent)"] = child
        }
        for (path, url) in walk(root.appending(path: "worklog"), prefix: "worklog") where url.pathExtension.lowercased() == "md" {
            files[path] = url
        }
        return files
    }

    /// A meeting folder's text files (`<day>/<time>/`): `meeting.json`, `meeting.md`,
    /// `summary.md`, `transcript.md`, own tabs `tabs/*.md`. Never `audio/` or pictures.
    static func meetingFiles(root: URL) -> [String: URL] {
        var files: [String: URL] = [:]
        for day in FileWalk.children(of: root) where visibleFolder(day) {
            for meeting in FileWalk.children(of: day) where visibleFolder(meeting) {
                let prefix = "\(day.lastPathComponent)/\(meeting.lastPathComponent)"
                for name in ["meeting.json", "meeting.md", "summary.md", "transcript.md"] where isFile(meeting.appending(path: name)) {
                    files["\(prefix)/\(name)"] = meeting.appending(path: name)
                }
                for tab in FileWalk.children(of: meeting.appending(path: "tabs"))
                    where tab.pathExtension.lowercased() == "md" && isFile(tab) && !tab.lastPathComponent.hasPrefix(".") {
                    files["\(prefix)/tabs/\(tab.lastPathComponent)"] = tab
                }
            }
        }
        return files
    }

    // MARK: - Run

    /// Mirrors and commits. Never throws: a problem is a line, so the pull and push still run.
    public static func run(env: HarnessEnvironment, brain root: URL) async -> Outcome {
        let home = env.homeDirectory, fm = FileManager.default
        guard isEnabled(home: home) else { return Outcome() }
        let profile = MachineProfile.load(home: home)
        if profile.problem != nil || profile.isWork { return Outcome(lines: [workRefusal]) }

        // Brain folder → its wanted files. A source that isn't on this Mac leaves its copy alone.
        var targets: [(folder: String, files: [String: URL])] = []
        for base in KnowledgeBase.all(home: home) where KnowledgeSeed.marker(of: base) == nil {
            guard let world = base.world else { continue }
            targets.append(("knowledge/\(world)", knowledgeFiles(base: base.root)))
        }
        let meetings = meetingsRoot(home: home)
        if FileWalk.isDirectory(meetings) { targets.append(("meetings", meetingFiles(root: meetings))) }
        guard !targets.isEmpty else { return Outcome() }

        var outcome = Outcome(), skipped: [String] = []
        do {
            for target in targets {
                let folder = root.appending(path: target.folder, directoryHint: .isDirectory)
                var keep = Set<String>()
                for (path, source) in target.files {
                    let data = try Data(contentsOf: source)
                    let label = "\(target.folder)/\(path)"
                    if data.count > maxBytes { skipped.append("\(label) (over 5 MB)"); continue }
                    if BackupSecrets.looksSecret(data) { skipped.append("\(label) (looks like it holds a secret)"); continue }
                    keep.insert(path)
                    let copy = folder.appending(path: path)
                    if (try? Data(contentsOf: copy)) == data { continue }
                    try fm.createDirectory(at: copy.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try data.write(to: copy, options: .atomic)
                }
                // Mirror: copies whose source is gone (or is no longer allowed) leave.
                for (path, url) in walk(folder, prefix: nil) where !keep.contains(path) { try fm.removeItem(at: url) }
                removeEmptyFolders(in: folder)
            }
        } catch {
            return Outcome(lines: ["Knowledge and meetings not backed up: \(error.localizedDescription)"])
        }
        if !skipped.isEmpty { outcome.lines.append("Not backed up: \(skipped.sorted().joined(separator: ", ")).") }

        guard fm.fileExists(atPath: root.appending(path: ".git").path) else { return outcome }
        do {
            let style = try await BrainGit.commitStyle(brain: root, env: env)
            let specs = targets.map(\.folder)
            let status = try await git(["-c", "core.quotePath=false", "status", "--porcelain", "-z", "--no-renames",
                                        "--untracked-files=all", "--"] + specs, in: root, style: style, env: env)
            let paths = status.split(separator: "\0").filter { $0.count > 3 && Array($0)[2] == " " }
                .map { String($0.dropFirst(3)) }.sorted()
            if !paths.isEmpty {
                try await git(["add", "--all", "--"] + specs, in: root, style: style, env: env)
                try await git(style.options + ["commit", "--quiet"] + style.commitFlags + ["-m", commitMessage, "--"] + specs,
                              in: root, style: style, env: env)
                outcome.committed = paths
                outcome.lines.insert("Backed up knowledge and meetings to the brain (\(paths.count) file\(paths.count == 1 ? "" : "s") changed).", at: 0)
            }
        } catch {
            outcome.lines.append("Knowledge and meetings copied into the brain, but not committed: \(error.localizedDescription)")
        }
        return outcome
    }

    // MARK: - Helpers

    struct GitFailure: Error, LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    @discardableResult
    private static func git(_ arguments: [String], in root: URL, style: BrainGit.CommitStyle, env: HarnessEnvironment) async throws -> String {
        guard let git = env.findExecutable("git") else { throw GitFailure(message: "git was not found") }
        let result = await ProcessRunner.run(git, arguments: arguments, directory: root, environment: style.environment, timeout: 30)
        guard let result, result.succeeded else {
            throw GitFailure(message: "git \(arguments.first { !$0.hasPrefix("-") && !$0.contains("=") } ?? "") failed: \(result.map(\.failureText) ?? "couldn't start git")")
        }
        return result.output
    }

    private static func isFile(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && !isDirectory.boolValue
    }

    private static func visibleFolder(_ url: URL) -> Bool { !url.lastPathComponent.hasPrefix(".") && FileWalk.isDirectory(url) }

    /// Every file below `folder` by relative path (`prefix/` in front), hidden ones skipped; links
    /// are not followed.
    private static func walk(_ folder: URL, prefix: String?) -> [(String, URL)] {
        var found: [(String, URL)] = []
        for child in FileWalk.children(of: folder) where !child.lastPathComponent.hasPrefix(".") {
            let path = prefix.map { "\($0)/\(child.lastPathComponent)" } ?? child.lastPathComponent
            let values = try? child.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
            if values?.isSymbolicLink == true { continue }
            if values?.isDirectory == true { found += walk(child, prefix: path) } else { found.append((path, child)) }
        }
        return found
    }

    private static func removeEmptyFolders(in folder: URL) {
        for child in FileWalk.children(of: folder) where FileWalk.isDirectory(child) {
            removeEmptyFolders(in: child)
            if (try? FileManager.default.contentsOfDirectory(atPath: child.path))?.allSatisfy({ $0 == ".DS_Store" }) == true {
                try? FileManager.default.removeItem(at: child)
            }
        }
    }
}

/// A text that looks like it holds a key or token: such a file is never copied.
enum BackupSecrets {
    static let patterns = [
        #"sk-or-v1-[A-Za-z0-9]{20,}"#, #"sk-ant-[A-Za-z0-9_\-]{20,}"#, #"sk-[A-Za-z0-9]{32,}"#,
        #"gh[pousr]_[A-Za-z0-9]{30,}"#, #"github_pat_[A-Za-z0-9_]{30,}"#, #"glpat-[A-Za-z0-9_\-]{20,}"#,
        #"xox[abposr]-[A-Za-z0-9\-]{10,}"#, #"AKIA[0-9A-Z]{16}"#, #"-----BEGIN [A-Z ]*PRIVATE KEY-----"#,
    ].compactMap { try? NSRegularExpression(pattern: $0) }

    static func looksSecret(_ data: Data) -> Bool {
        guard let text = String(data: data, encoding: .utf8) else { return false }
        let range = NSRange(text.startIndex..., in: text)
        return patterns.contains { $0.firstMatch(in: text, range: range) != nil }
    }
}
