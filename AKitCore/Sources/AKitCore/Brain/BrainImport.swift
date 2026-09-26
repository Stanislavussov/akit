import Foundation
import Yams

/// Copies skills (global `~/.agents/skills` by default, or a project's skills folder) into
/// the brain library and lists them in a layer, `core` by default. The originals stay where
/// they are: harnesses keep reading them until the layer is rendered.
public enum BrainImport {
    public struct Candidate: Identifiable, Hashable, Sendable {
        public enum State: Hashable, Sendable {
            /// Not in the brain yet: copied.
            case new
            /// The brain has the same files: only listed in the layer.
            case same
            /// The brain has a different skill with this name: left alone.
            case different
        }

        public var id: String { name }
        public let name: String
        /// The skill folder being imported (symlinks resolved).
        public let folder: URL
        public let state: State
        /// Where it was installed from (`npx skills` or AKit lock), e.g. `mattpocock/skills`.
        public let source: String?
        /// Already listed in the layer.
        public let inLayer: Bool
        /// Files that are not copied, with the reason, e.g. `.env (may hold secrets)`.
        public let skipped: [String]

        /// Nothing to copy and nothing to list.
        public var isDone: Bool { state == .same && inLayer }
    }

    public struct Plan: Sendable {
        public let source: URL
        /// The brain the plan was made for; apply writes only there.
        public let brainRoot: URL
        public let candidates: [Candidate]
        /// The layer the skills are listed in.
        public let layer: String
        /// How they are listed: manual for core, which every project sees.
        public let mode: LayerSkill.Mode
        /// Current `layers/<layer>/layer.yaml`, empty when the file doesn't exist.
        public let layerBefore: String
    }

    public struct Failure: Error, LocalizedError {
        public let message: String
        public var errorDescription: String? { message }
    }

    public static func defaultSource(home: URL) -> URL {
        home.appending(path: ".agents/skills", directoryHint: .isDirectory)
    }

    static func layerFile(_ layer: String, in root: URL) -> URL { root.appending(path: "layers/\(layer)/layer.yaml") }

    /// What an import from `source` into `layer` would do. Only reads.
    public static func plan(from source: URL, into brainRoot: URL, layer: String = "core", mode: LayerSkill.Mode = .manual,
                            env: HarnessEnvironment) -> Plan {
        let fm = FileManager.default
        let lock = SkillLock.read(in: env)
        let before = (try? String(contentsOf: layerFile(layer, in: brainRoot), encoding: .utf8)) ?? ""
        // From the file itself, not the last scan: it may have been edited since.
        let inLayer = Set((try? LayerManifest.parse(before, folder: URL(filePath: "/\(layer)")))?.layer.skills.map(\.name) ?? [])
        let items = (try? fm.contentsOfDirectory(at: source, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? []

        let candidates = items.compactMap { item -> Candidate? in
            let name = item.lastPathComponent
            let folder = item.resolvingSymlinksInPath()
            // claude.ai skills live in `synced/` and are managed by Claude.
            guard name != "synced", Condition.isIdentifier(name),
                  fm.fileExists(atPath: folder.appending(path: "SKILL.md").path) else { return nil }
            let contents = copyable(folder)
            let existing = brainRoot.appending(path: "skills/\(name)")
            let state: Candidate.State = !fm.fileExists(atPath: existing.path) ? .new
                : sameFiles(contents.files, copyable(existing).files) ? .same : .different
            return Candidate(name: name, folder: folder, state: state, source: lock.source(forSkillFolder: folder),
                             inLayer: inLayer.contains(name), skipped: contents.skipped)
        }
        .sorted { $0.name < $1.name }
        return Plan(source: source, brainRoot: brainRoot, candidates: candidates, layer: layer, mode: mode, layerBefore: before)
    }

    /// The layer after listing these skills in the plan's mode.
    public static func layerAfter(_ plan: Plan, importing names: [String]) throws(Failure) -> String {
        let add = plan.candidates.filter { names.contains($0.name) && $0.state != .different && !$0.inLayer }.map(\.name)
        return try addSkills(add, mode: plan.mode, to: plan.layerBefore, layer: plan.layer)
    }

    /// Copies the chosen skills, updates the layer and commits both, if the brain is a git repo.
    /// Returns the names that were copied.
    @discardableResult
    public static func apply(_ plan: Plan, importing names: [String], env: HarnessEnvironment) async throws(Failure) -> [String] {
        let root = plan.brainRoot
        let chosen = plan.candidates.filter { names.contains($0.name) && $0.state != .different }
        let after = try layerAfter(plan, importing: names)
        let layerChanges = after != plan.layerBefore
        let file = layerFile(plan.layer, in: root), filePath = "layers/\(plan.layer)/layer.yaml"
        let fm = FileManager.default
        let isRepo = fm.fileExists(atPath: root.appending(path: ".git").path)

        // The layer may have changed since the plan was made.
        let current = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
        guard current == plan.layerBefore else {
            throw Failure(message: "\(filePath) changed since the preview. Open the import again.")
        }
        let toCopy = chosen.filter { $0.state == .new }
        let paths = toCopy.map { "skills/\($0.name)" } + (layerChanges ? [filePath] : [])
        // The import commit must hold only the import, not earlier edits to these paths.
        if isRepo, !paths.isEmpty {
            let status = try await git(["status", "--porcelain", "--"] + paths, in: root, env: env)
            if !status.isEmpty {
                throw Failure(message: "The brain has uncommitted changes in \(status.split(separator: "\n").map { $0.dropFirst(3) }.joined(separator: ", ")). Commit or discard them first.")
            }
        }
        for candidate in toCopy where fm.fileExists(atPath: root.appending(path: "skills/\(candidate.name)").path) {
            throw Failure(message: "skills/\(candidate.name) appeared in the brain after the preview. Open the import again.")
        }

        var copied: [String] = []
        do {
            for candidate in toCopy {
                let target = root.appending(path: "skills/\(candidate.name)")
                do {
                    try copy(candidate.folder, to: target)
                } catch {
                    try? fm.removeItem(at: target)  // only the folder this call created
                    throw error
                }
                copied.append(candidate.name)
            }
            if layerChanges {
                try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data(after.utf8).write(to: file, options: .atomic)
            }
        } catch {
            throw Failure(message: "The import stopped: \(error.localizedDescription) Copied: \(copied.isEmpty ? "nothing" : copied.joined(separator: ", ")); the \(plan.layer) layer was not changed.")
        }

        guard isRepo, !paths.isEmpty else { return copied }
        let message = "Import \(chosen.count) skill\(chosen.count == 1 ? "" : "s") into the \(plan.layer) layer"
        _ = try await git(["add", "--"] + paths, in: root, env: env)
        // Only these paths: whatever else is staged in the brain stays staged.
        _ = try await git(["commit", "--quiet", "-m", message, "--"] + paths, in: root, env: env)
        return copied
    }

    private static func git(_ arguments: [String], in root: URL, env: HarnessEnvironment) async throws(Failure) -> String {
        guard let git = env.findExecutable("git") else {
            throw Failure(message: "git was not found, so the brain can't be checked or committed.")
        }
        var environment = env.variables
        environment["PATH"] = env.pathForChildProcesses
        let result = await ProcessRunner.run(git, arguments: arguments, directory: root, environment: environment, timeout: 30)
        guard let result, result.succeeded else {
            let output = result?.output.trimmingCharacters(in: .whitespacesAndNewlines) ?? "git couldn't be started."
            throw Failure(message: "git \(arguments[0]) failed: \(output)")
        }
        return result.output.trimmingCharacters(in: .newlines)
    }

    // MARK: - What gets copied

    /// Regular files of a skill folder that go into the brain, by relative path, and what is
    /// left out: git data, files that usually hold secrets, and links pointing outside the skill.
    /// Links inside the skill are copied as the files they point to.
    static func copyable(_ folder: URL) -> (files: [String: URL], skipped: [String]) {
        let fm = FileManager.default
        let base = folder.resolvingSymlinksInPath().standardizedFileURL.path
        var files: [String: URL] = [:], skipped: [String] = []
        guard let walker = fm.enumerator(at: URL(filePath: base), includingPropertiesForKeys: [.isSymbolicLinkKey, .isDirectoryKey]) else {
            return (files, skipped)
        }
        for case let url as URL in walker {
            let path = url.standardizedFileURL.path
            guard path.hasPrefix(base + "/") else { continue }
            let relative = String(path.dropFirst(base.count + 1))
            let name = url.lastPathComponent
            if name == ".DS_Store" { continue }
            if name == ".git" {
                walker.skipDescendants()
                skipped.append("\(relative) (git data)")
                continue
            }
            let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
            var real = url
            if values?.isSymbolicLink == true {
                real = url.resolvingSymlinksInPath()
                guard real.standardizedFileURL.path.hasPrefix(base + "/") else {
                    skipped.append("\(relative) (link outside the skill)")
                    continue
                }
            }
            var isFolder: ObjCBool = false
            guard fm.fileExists(atPath: real.path, isDirectory: &isFolder) else {
                skipped.append("\(relative) (broken link)")
                continue
            }
            if isFolder.boolValue {
                // A linked folder inside the skill: its files are listed at their real path.
                continue
            }
            if SecretFilter.isSecretFile(relative) || [".pem", ".key", ".p12"].contains(where: name.hasSuffix) {
                skipped.append("\(relative) (may hold secrets)")
                continue
            }
            files[relative] = real
        }
        return (files, skipped.sorted())
    }

    private static func copy(_ folder: URL, to target: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: target, withIntermediateDirectories: true)
        for (relative, source) in copyable(folder).files {
            let destination = target.appending(path: relative)
            try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.copyItem(at: source, to: destination)
        }
    }

    /// Same relative file paths with the same bytes.
    static func sameFiles(_ left: [String: URL], _ right: [String: URL]) -> Bool {
        guard left.keys.sorted() == right.keys.sorted() else { return false }
        return left.allSatisfy { path, url in
            right[path].map { FileManager.default.contentsEqual(atPath: url.path, andPath: $0.path) } ?? false
        }
    }

    // MARK: - layer.yaml edit

    /// Adds `- name: x / mode: m` entries to the top-level `skills:` list, keeping the
    /// rest of the file (comments, order, line endings) as it is.
    static func addSkills(_ names: [String], mode: LayerSkill.Mode, to text: String, layer: String = "core") throws(Failure) -> String {
        guard !names.isEmpty else { return text }
        let newline = text.contains("\r\n") ? "\r\n" : "\n"
        var lines = text.isEmpty ? [] : text.components(separatedBy: newline)
        if lines.last == "" { lines.removeLast() }
        let entries = { (indent: String) in names.flatMap { ["\(indent)- name: \($0)", "\(indent)  mode: \(mode.rawValue)"] } }

        if let key = lines.firstIndex(where: { $0.hasPrefix("skills:") }) {
            var rest = lines[key].dropFirst("skills:".count).trimmingCharacters(in: .whitespaces)
            if let comment = rest.range(of: " #") ?? (rest.hasPrefix("#") ? rest.range(of: "#") : nil) {
                rest = rest[..<comment.lowerBound].trimmingCharacters(in: .whitespaces)
            }
            guard ["", "[]", "~", "null"].contains(rest) else {
                throw Failure(message: "The \(layer) layer's “skills:” line has “\(rest)” after it. Write skills as a block list (one “- name” per line) and try again.")
            }
            // Block list (or empty): append after its last item, with the same indent.
            var end = key + 1
            while end < lines.count, lines[end].isEmpty || lines[end].first == " " || lines[end].first == "-" { end += 1 }
            while end > key + 1, lines[end - 1].trimmingCharacters(in: .whitespaces).isEmpty { end -= 1 }
            let firstItem = lines[(key + 1)..<end].first { $0.trimmingCharacters(in: .whitespaces).hasPrefix("-") }
            let indent = firstItem.map { String($0.prefix { $0 == " " }) } ?? "  "
            if rest != "" { lines[key] = "skills:" }
            lines.insert(contentsOf: entries(indent), at: end)
        } else {
            lines += ["skills:"] + entries("  ")
        }
        let result = lines.joined(separator: newline) + newline

        // Check the edit: the old skills are all still there unchanged, the new ones were
        // added once, and nothing else in the layer moved.
        let folder = URL(filePath: "/\(layer)")
        let old = try? LayerManifest.parse(text, folder: folder).layer
        let oldSkills = old?.skills ?? []
        guard let new = try? LayerManifest.parse(result, folder: folder).layer, old != nil || text.isEmpty,
              Set(names).isDisjoint(with: oldSkills.map(\.name)), Set(names).count == names.count,
              Array(new.skills.prefix(oldSkills.count)) == oldSkills,
              new.skills.dropFirst(oldSkills.count).map(\.name) == names,
              new.fields == old?.fields ?? [], new.files == old?.files ?? [],
              new.description == old?.description ?? "", new.requires == old?.requires ?? [],
              new.conflicts == old?.conflicts ?? [] else {
            throw Failure(message: "AKit couldn't add skills to layers/\(layer)/layer.yaml safely. Add them by hand.")
        }
        return result
    }
}
