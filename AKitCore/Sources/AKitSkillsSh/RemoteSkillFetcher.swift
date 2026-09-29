import AKitFoundation
import AKitSkills
import Foundation

/// A skill from skills.sh, downloaded and unpacked into AKit's cache. Nothing is installed yet.
public struct FetchedSkill: Sendable, Hashable {
    public let remote: RemoteSkill
    /// Skill folder inside the unpacked repository (contains SKILL.md).
    public let folder: URL
    /// Folder path inside the repository, e.g. `skills/tdd`. Empty = the repository root.
    public let pathInRepo: String
    public let skillText: String
    /// Relative paths of the skill's files.
    public let files: [String]

    public var skillFile: URL { folder.appending(path: "SKILL.md") }
    public var meta: [String: String] { Frontmatter.parse(skillText) }
    public var name: String { meta["name"].flatMap { $0.isEmpty ? nil : $0 } ?? remote.name }
    public var description: String { meta["description"] ?? "" }
}

/// Downloads a GitHub repository as a tarball (no git, no API rate limit) and finds the skill in it.
public enum RemoteSkillFetcher {
    public enum Failure: LocalizedError {
        case unsupportedSource(String)
        case download(String)
        case unpack(String)
        case skillNotFound(String, String)

        public var errorDescription: String? {
            switch self {
            case .unsupportedSource(let source):
                "“\(source)” is not a GitHub repository. Only GitHub sources can be installed for now."
            case .download(let message): "Download failed: \(message)"
            case .unpack(let message): "Couldn't unpack the repository: \(message)"
            case .skillNotFound(let skill, let source): "No SKILL.md for “\(skill)” found in \(source)."
            }
        }
    }

    /// `~/Library/Caches/dev.ussov.akit/skills-sh`.
    public static var defaultCache: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appending(path: "dev.ussov.akit/skills-sh", directoryHint: .isDirectory)
    }

    /// A downloaded repository is reused for this long.
    static let cacheLifetime: TimeInterval = 30 * 60

    public static func fetch(_ remote: RemoteSkill, cache: URL = defaultCache,
                             session: URLSession = .shared) async throws -> FetchedSkill {
        guard let repo = remote.gitHubRepo else { throw Failure.unsupportedSource(remote.source) }
        let root = try await repository(owner: repo.owner, repo: repo.repo, cache: cache, session: session)
        return try locate(remote, in: root)
    }

    /// Finds the skill in an unpacked repository and reads it.
    public static func locate(_ remote: RemoteSkill, in root: URL) throws -> FetchedSkill {
        let rootPath = root.resolvingSymlinksInPath().path
        guard let folder = SkillLocator.find(skillId: remote.skillId, name: remote.name, in: root),
              SkillLocator.isRealSkillFile(folder.appending(path: "SKILL.md"), inside: rootPath),
              let text = try? String(contentsOf: folder.appending(path: "SKILL.md"), encoding: .utf8) else {
            throw Failure.skillNotFound(remote.name, remote.source)
        }
        let folderPath = folder.resolvingSymlinksInPath().path
        let inRepo = folderPath == rootPath ? "" : String(folderPath.dropFirst(rootPath.count + 1))
        return FetchedSkill(remote: remote, folder: folder, pathInRepo: inRepo, skillText: text,
                            files: SkillCopier.files(in: folder).map(\.relative))
    }

    /// Unpacked repository root, downloaded again when older than `cacheLifetime`.
    /// Concurrent requests for one repository share a single download.
    static func repository(owner: String, repo: String, cache: URL, session: URLSession) async throws -> URL {
        try await RepositoryDownloads.shared.root(key: "\(owner)/\(repo)") {
            try await download(owner: owner, repo: repo, cache: cache, session: session)
        }
    }

    /// Every download unpacks into its own `<owner>/<repo>/<time>-<uuid>` folder, so a
    /// newer download never replaces files a preview or an install is still reading.
    /// Versions older than twice the lifetime are removed.
    private static func download(owner: String, repo: String, cache: URL, session: URLSession) async throws -> URL {
        let fm = FileManager.default
        let versions = cache.appending(path: "\(owner)/\(repo)", directoryHint: .isDirectory)
        let now = Date.now.timeIntervalSince1970
        func age(_ folder: URL) -> TimeInterval? {
            folder.lastPathComponent.split(separator: "-").first.flatMap { Double($0) }.map { now - $0 }
        }
        let existing = FileWalk.children(of: versions).filter(FileWalk.isDirectory)
        for folder in existing where (age(folder) ?? .infinity) > 2 * cacheLifetime {
            try? fm.removeItem(at: folder)
        }
        if let fresh = existing.filter({ (age($0) ?? .infinity) < cacheLifetime }).max(by: { $0.lastPathComponent < $1.lastPathComponent }),
           let unpacked = FileWalk.children(of: fresh).first(where: FileWalk.isDirectory) {
            return unpacked
        }

        let url = URL(string: "https://codeload.github.com/\(owner)/\(repo)/tar.gz/HEAD")!
        let archive: URL
        do {
            let (downloaded, response) = try await session.download(from: url)
            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                throw Failure.download(http.statusCode == 404 ? "\(owner)/\(repo) not found" : "HTTP \(http.statusCode)")
            }
            archive = downloaded
        } catch let failure as Failure {
            throw failure
        } catch {
            throw Failure.download(error.localizedDescription)
        }
        defer { try? fm.removeItem(at: archive) }

        let staging = cache.appending(path: ".staging-\(UUID().uuidString)", directoryHint: .isDirectory)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }
        try await untar(archive, into: staging)

        let target = versions.appending(path: "\(Int(now))-\(UUID().uuidString)", directoryHint: .isDirectory)
        try fm.createDirectory(at: versions, withIntermediateDirectories: true)
        try fm.moveItem(at: staging, to: target)
        guard let unpacked = FileWalk.children(of: target).first(where: FileWalk.isDirectory) else {
            throw Failure.unpack("the archive is empty")
        }
        return unpacked
    }

    /// `/usr/bin/tar` (bsdtar) refuses `..` and absolute paths by default.
    static func untar(_ archive: URL, into folder: URL) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(filePath: "/usr/bin/tar")
                process.arguments = ["-xzf", archive.path, "-C", folder.path]
                let errors = Pipe()
                process.standardError = errors
                process.standardOutput = FileHandle.nullDevice
                do {
                    try process.run()
                    let message = errors.fileHandleForReading.readDataToEndOfFile()
                    process.waitUntilExit()
                    if process.terminationStatus == 0 {
                        continuation.resume()
                    } else {
                        continuation.resume(throwing: Failure.unpack(String(decoding: message, as: UTF8.self)))
                    }
                } catch {
                    continuation.resume(throwing: Failure.unpack(error.localizedDescription))
                }
            }
        }
    }
}

/// Finds a skill folder inside a repository, the way skills.sh names skills.
enum SkillLocator {
    static let skipped: Set<String> = [".git", "node_modules"]

    /// Match order: slug of the SKILL.md name, then the folder name, then the exact name.
    /// A repository holding a single skill matches that skill. Shallower folders win.
    public static func find(skillId: String, name: String, in root: URL, maxDepth: Int = 6) -> URL? {
        var candidates: [(folder: URL, depth: Int, name: String?)] = []
        collect(root, depth: 0, maxDepth: maxDepth, into: &candidates)
        candidates.sort { $0.depth < $1.depth }

        let id = slug(skillId)
        let tests: [((folder: URL, depth: Int, name: String?)) -> Bool] = [
            { $0.name.map(slug) == id },
            { slug($0.folder.lastPathComponent) == id },
            { $0.name == name },
        ]
        for test in tests {
            if let hit = candidates.first(where: test) { return hit.folder }
        }
        return candidates.count == 1 ? candidates[0].folder : nil
    }

    private static func collect(_ dir: URL, depth: Int, maxDepth: Int,
                                into result: inout [(folder: URL, depth: Int, name: String?)]) {
        guard depth <= maxDepth else { return }
        // A symlinked SKILL.md could point at any file on this Mac (e.g. a token): never read it.
        if SkillScanner.hasSkillFile(dir), isRealSkillFile(dir.appending(path: "SKILL.md"), inside: nil) {
            let text = try? String(contentsOf: dir.appending(path: "SKILL.md"), encoding: .utf8)
            result.append((dir, depth, text.flatMap { Frontmatter.parse($0)["name"] }))
        }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        for name in names.sorted() where !skipped.contains(name) {
            let child = dir.appending(path: name, directoryHint: .isDirectory)
            // Real folders only: a symlink could point outside the repository.
            let values = try? child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values?.isDirectory == true, values?.isSymbolicLink != true else { continue }
            collect(child, depth: depth + 1, maxDepth: maxDepth, into: &result)
        }
    }

    /// A regular file, not a symlink, and (when `root` is given) really inside that folder.
    static func isRealSkillFile(_ file: URL, inside root: String?) -> Bool {
        let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values?.isSymbolicLink == false, values?.isRegularFile == true else { return false }
        guard let root else { return true }
        return file.resolvingSymlinksInPath().path.hasPrefix(root + "/")
    }

    /// skills.sh ids: lower case, spaces become hyphens, other symbols are dropped
    /// (`Test-Driven Development (TDD)` → `test-driven-development-tdd`, `tdd:fix` → `tddfix`).
    public static func slug(_ text: String) -> String {
        var result = ""
        for char in text.lowercased() {
            if char.isWhitespace || char == "-" {
                if !result.isEmpty, result.last != "-" { result.append("-") }
            } else if char.isASCII, char.isLetter || char.isNumber {
                result.append(char)
            }
        }
        while result.last == "-" { result.removeLast() }
        return result
    }
}

/// One download per repository at a time; later callers wait for the running one.
private actor RepositoryDownloads {
    static let shared = RepositoryDownloads()
    private var running: [String: Task<URL, Error>] = [:]

    func root(key: String, download: @escaping @Sendable () async throws -> URL) async throws -> URL {
        if let task = running[key] { return try await task.value }
        let task = Task { try await download() }
        running[key] = task
        defer { running[key] = nil }
        return try await task.value
    }
}
