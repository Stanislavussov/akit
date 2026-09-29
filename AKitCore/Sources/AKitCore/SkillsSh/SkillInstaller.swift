import Foundation

/// Where a skill gets installed: for every project, or inside one project.
public enum InstallScope: Hashable, Sendable {
    case global
    case project(URL)
}

/// One skills folder a new skill is copied into. Several harnesses may share it
/// (`~/.agents/skills` is read by Pi, Codex and OpenCode).
public struct InstallTarget: Hashable, Sendable, Identifiable {
    public var id: String { root.path }
    /// The skills folder, e.g. `~/.claude/skills`.
    public let root: URL
    /// The selected harnesses this copy is for.
    public let harnesses: [HarnessID]
    /// Every installed harness that will see the skill here, selected or not.
    public let seenBy: [HarnessID]

    public func folder(for name: String) -> URL { root.appending(path: name, directoryHint: .isDirectory) }
}

/// What to install and how.
public struct InstallRequest: Sendable {
    public enum Mode: Hashable, Sendable {
        /// Exactly as the author published it, linked to its skills.sh source.
        case published
        /// Your own skill, based on this one: your edited SKILL.md, possibly another name.
        case ownCopy
    }

    public let skill: FetchedSkill
    /// Folder name and `name:` in SKILL.md.
    public let name: String
    public let mode: Mode
    /// Your SKILL.md text; used for `.ownCopy` only.
    public let editedText: String

    public init(skill: FetchedSkill, name: String, mode: Mode, editedText: String? = nil) {
        self.skill = skill
        self.name = name
        self.mode = mode
        self.editedText = editedText ?? skill.skillText
    }

    /// The SKILL.md to write, with `name:` set to the chosen name.
    public var finalText: String {
        SkillText.settingName(name, in: mode == .ownCopy ? editedText : skill.skillText)
    }
    public var isModified: Bool { finalText != skill.skillText }
}

/// Installs a downloaded skill by copying its folder. Only creates new files;
/// an existing skill with the same name is moved to the Trash first, never overwritten in place.
public enum SkillInstaller {
    public enum Failure: LocalizedError {
        case invalidName(String)
        case noTarget
        case alreadyInstalled([URL])
        case tooLarge(Int)
        case notASkill([URL])
        case sourceChanged

        public var errorDescription: String? {
            switch self {
            case .invalidName(let reason): "Invalid skill name: \(reason)"
            case .noTarget: "Choose at least one harness that can take skills here."
            case .alreadyInstalled(let urls):
                "A skill with this name already exists: \(urls.map(\.path).joined(separator: ", "))"
            case .tooLarge(let bytes): "The skill is too large to install (\(bytes / 1_000_000) MB)."
            case .notASkill(let urls):
                "\(urls.map(\.path).joined(separator: ", ")) exists and is not a single skill. Choose another name."
            case .sourceChanged: "The downloaded files changed since the preview. Select the skill again."
            }
        }
    }

    static let maxBytes = 50_000_000

    /// Name problems that block installing. Harness-specific rules are warnings, see `PiNameRule`.
    public static func nameProblems(_ name: String) -> [String] {
        var problems: [String] = []
        if name.trimmingCharacters(in: .whitespaces).isEmpty { problems.append("name is empty") }
        if name.contains("/") || name.contains(":") { problems.append("name must not contain / or :") }
        if name.hasPrefix(".") { problems.append("name must not start with a dot") }
        if name.count > 64 { problems.append("name is longer than 64 characters") }
        if name != name.trimmingCharacters(in: .whitespacesAndNewlines) { problems.append("name has spaces at the ends") }
        return problems
    }

    /// Skills folders for the chosen harnesses, one entry per real folder.
    public static func targets(for harnesses: [HarnessID], scope: InstallScope,
                               adapters: [any HarnessAdapter], installed: [HarnessID],
                               in env: HarnessEnvironment) -> [InstallTarget] {
        let projects: [URL]
        if case .project(let url) = scope { projects = [url] } else { projects = [] }

        var order: [String] = []
        var roots: [String: (root: URL, harnesses: [HarnessID])] = [:]
        for harness in harnesses {
            guard let adapter = adapters.first(where: { $0.id == harness }),
                  let root = adapter.skillInstallRoot(for: scope, in: env) else { continue }
            let key = root.resolvingSymlinksInPath().path
            if roots[key] == nil {
                order.append(key)
                roots[key] = (root, [])
            }
            roots[key]?.harnesses.append(harness)
        }

        // Who reads each folder: an adapter whose skill roots include it for this scope.
        let readers = adapters.filter { installed.contains($0.id) }.map { adapter in
            (adapter.id, Set(adapter.skillRoots(in: env, projects: projects)
                .filter { $0.scope == .global || scope != .global }
                .filter { !$0.isReadOnly }
                .map { $0.url.resolvingSymlinksInPath().path }))
        }
        return order.compactMap { key in
            guard let entry = roots[key] else { return nil }
            let seenBy = readers.filter { $0.1.contains(key) }.map(\.0)
            return InstallTarget(root: entry.root, harnesses: entry.harnesses,
                                 seenBy: Array(Set(seenBy + entry.harnesses)).sorted())
        }
    }

    /// Skill folders that already exist under the chosen name.
    public static func conflicts(name: String, targets: [InstallTarget]) -> [URL] {
        targets.map { $0.folder(for: name) }.filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// Existing paths that are not one skill (e.g. Claude's `synced` folder or a folder that
    /// groups several skills). Those are never replaced.
    public static func blockedConflicts(name: String, targets: [InstallTarget]) -> [URL] {
        conflicts(name: name, targets: targets).filter { !SkillScanner.hasSkillFile($0) }
    }

    /// One install at a time, so two installs never lose each other's lock entries.
    private static let serial = NSLock()

    /// Copies the skill into every target and records it in `~/.akit/skills-lock.json`.
    /// `replace`: move existing same-name skills to the Trash first; otherwise they block the install.
    /// Everything is staged before anything is trashed; if a step fails, trashed skills are put back.
    /// Returns the new skill folders.
    @discardableResult
    public static func install(_ request: InstallRequest, into targets: [InstallTarget], replace: Bool,
                               in env: HarnessEnvironment,
                               trash: (URL) throws -> URL? = Trash.move) throws -> [URL] {
        serial.lock()
        defer { serial.unlock() }

        if let problem = nameProblems(request.name).first { throw Failure.invalidName(problem) }
        guard !targets.isEmpty else { throw Failure.noTarget }
        let files = SkillCopier.files(in: request.skill.folder)
        // The cached download may have been cleaned up since the preview.
        guard files.map(\.relative) == request.skill.files else { throw Failure.sourceChanged }
        let bytes = files.reduce(0) { $0 + $1.size }
        guard bytes <= maxBytes else { throw Failure.tooLarge(bytes) }

        let blocked = blockedConflicts(name: request.name, targets: targets)
        guard blocked.isEmpty else { throw Failure.notASkill(blocked) }
        let existing = conflicts(name: request.name, targets: targets)
        if !existing.isEmpty, !replace { throw Failure.alreadyInstalled(existing) }
        // Read the lock before touching anything: a broken lock stops the install.
        var lock = try InstalledSkillLock.load(in: env)

        let fm = FileManager.default
        var staged: [(staging: URL, destination: URL)] = []
        defer { for item in staged { try? fm.removeItem(at: item.staging) } }
        for target in targets {
            let staging = target.root.appending(path: ".akit-install-\(UUID().uuidString)", directoryHint: .isDirectory)
            try fm.createDirectory(at: staging, withIntermediateDirectories: true)
            staged.append((staging, target.folder(for: request.name)))
            try SkillCopier.copy(files, to: staging)
            try Data(request.finalText.utf8).write(to: staging.appending(path: "SKILL.md"), options: .atomic)
        }

        var trashed: [(original: URL, inTrash: URL)] = []
        var installed: [URL] = []
        do {
            for url in existing {
                if let moved = try trash(url) { trashed.append((url, moved)) }
            }
            for item in staged {
                try fm.moveItem(at: item.staging, to: item.destination)
                installed.append(item.destination)
            }
            let date = ISO8601DateFormatter().string(from: .now)
            for folder in installed {
                let path = folder.resolvingSymlinksInPath().path
                lock.entries.removeAll { $0.path == path }
                lock.entries.append(.init(path: path, source: request.skill.remote.source,
                                          skillId: request.skill.remote.skillId,
                                          pathInRepo: request.skill.pathInRepo,
                                          modified: request.isModified, installedAt: date,
                                          ownCopy: request.mode == .ownCopy))
            }
            try InstalledSkillLock.save(lock, in: env)
        } catch {
            // Undo (also when the lock can't be saved): remove the new copies, put the old skills back.
            for url in installed { try? fm.removeItem(at: url) }
            for item in trashed where !fm.fileExists(atPath: item.original.path) {
                try? fm.moveItem(at: item.inTrash, to: item.original)
            }
            throw error
        }

        return installed
    }
}

/// Copies a skill folder: regular files only. Symlinks (they may point outside the
/// repository), `.git` and `.DS_Store` are left out.
enum SkillCopier {
    struct File {
        let url: URL
        let relative: String
        let size: Int
    }

    static func files(in folder: URL) -> [File] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        guard let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: keys) else { return [] }
        let prefix = folder.standardizedFileURL.path + "/"
        var result: [File] = []
        for case let url as URL in walker {
            let name = url.lastPathComponent
            if name == ".git" || name == "node_modules" { walker.skipDescendants(); continue }
            guard name != ".DS_Store",
                  let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isSymbolicLink != true, values.isRegularFile == true else { continue }
            let path = url.standardizedFileURL.path
            guard path.hasPrefix(prefix) else { continue }
            result.append(File(url: url, relative: String(path.dropFirst(prefix.count)), size: values.fileSize ?? 0))
        }
        return result.sorted { $0.relative < $1.relative }
    }

    static func copy(_ files: [File], to destination: URL) throws {
        let fm = FileManager.default
        for file in files {
            let target = destination.appending(path: file.relative)
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.copyItem(at: file.url, to: target)
        }
    }
}

/// Small edits of SKILL.md text.
public enum SkillText {
    /// Sets the top-level `name:` in the frontmatter, adding a frontmatter block if there is none.
    public static func settingName(_ name: String, in text: String) -> String {
        var lines = text.components(separatedBy: "\n")
        let first = lines.first?.replacingOccurrences(of: "\u{FEFF}", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard first == "---",
              let end = lines.indices.dropFirst().first(where: { lines[$0].trimmingCharacters(in: .whitespacesAndNewlines) == "---" })
        else {
            return "---\nname: \(name)\n---\n\n" + text
        }
        if let index = (1..<end).first(where: { lines[$0].hasPrefix("name:") }) {
            let current = Frontmatter.parse(text)["name"]
            if current == name { return text }
            lines[index] = "name: \(name)"
        } else {
            lines.insert("name: \(name)", at: 1)
        }
        return lines.joined(separator: "\n")
    }
}
