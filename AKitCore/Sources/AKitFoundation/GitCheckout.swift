import Foundation

/// A git checkout read from its files, without running git: where its git folders are and
/// whether it is a linked worktree (`git worktree add`) of another checkout.
public struct GitCheckout: Sendable, Hashable {
    /// The checkout's top folder, the one holding `.git`.
    public let folder: URL
    /// This checkout's own git folder: `<folder>/.git`, or `<main>/.git/worktrees/<name>`.
    public let gitDir: URL
    /// The git folder all worktrees of the repository share (`git rev-parse --git-common-dir`).
    public let commonDir: URL

    /// A worktree made by `git worktree add` (Pi, herdr, Claude Code), not the main checkout.
    public var isLinkedWorktree: Bool { gitDir.standardizedFileURL.path != commonDir.standardizedFileURL.path }

    /// The main checkout of the repository: the folder itself, or for a linked worktree the
    /// folder holding the common `.git`; nil when that is a bare repository.
    public var mainFolder: URL? {
        guard isLinkedWorktree else { return folder }
        return commonDir.lastPathComponent == ".git" ? commonDir.deletingLastPathComponent() : nil
    }

    /// `info/exclude` in the common git folder: shared by every worktree, never committed.
    public var excludeFile: URL { commonDir.appending(path: "info/exclude") }

    /// The checkout whose top is `folder` (it holds `.git`); nil otherwise.
    public static func at(_ folder: URL) -> GitCheckout? {
        let top = folder.standardizedFileURL.path
        let dotGit = (top as NSString).appendingPathComponent(".git")
        var info = stat()
        guard lstat(dotGit, &info) == 0 else { return nil }
        let gitDir: String
        switch info.st_mode & S_IFMT {
        case S_IFDIR:
            gitDir = dotGit
        case S_IFREG:
            // "gitdir: <path>", relative to the checkout when not absolute.
            guard let pointer = small(dotGit).flatMap(gitdirPointer) else { return nil }
            gitDir = ((pointer.hasPrefix("/") ? pointer : (top as NSString).appendingPathComponent(pointer)) as NSString).standardizingPath
        default:
            return nil
        }
        var common = gitDir
        if let pointer = small((gitDir as NSString).appendingPathComponent("commondir"))?.trimmingCharacters(in: .whitespacesAndNewlines),
           !pointer.isEmpty {
            common = ((pointer.hasPrefix("/") ? pointer : (gitDir as NSString).appendingPathComponent(pointer)) as NSString).standardizingPath
        }
        return GitCheckout(folder: URL(filePath: top, directoryHint: .isDirectory), gitDir: URL(filePath: gitDir, directoryHint: .isDirectory),
                           commonDir: URL(filePath: common, directoryHint: .isDirectory))
    }

    /// The checkout `folder` is in: the nearest folder at or above it holding `.git`.
    public static func containing(_ folder: URL) -> GitCheckout? {
        var path = folder.standardizedFileURL.path
        // Bounded, on strings: every step drops one component and "/" ends the walk.
        for _ in 0..<256 {
            if let checkout = at(URL(filePath: path, directoryHint: .isDirectory)) { return checkout }
            let parent = (path as NSString).deletingLastPathComponent
            guard !parent.isEmpty, parent != path else { return nil }
            path = parent
        }
        return nil
    }

    /// Of several folders with the same project id, the one to show it by: the first that is
    /// not a linked worktree, else the first.
    public static func preferred(_ folders: [URL]) -> URL? {
        folders.first { at($0)?.isLinkedWorktree != true } ?? folders.first
    }

    /// The `url` of `[remote "origin"]` in the repository's config (the common git folder's, so
    /// a linked worktree reads its main checkout's); nil without one.
    public var originURL: String? { Self.small(commonDir.appending(path: "config").path).flatMap(Self.originURL(inConfig:)) }

    /// The `origin` URL of the checkout whose top is `repo` (a worktree's or submodule's `.git`
    /// file is followed); nil when it isn't a checkout or has no origin.
    public static func originURL(of repo: URL) -> String? { at(repo)?.originURL }

    /// `gitdir: <path>` of a worktree's or submodule's `.git` file, as written (maybe relative).
    public static func gitdirPointer(_ text: String) -> String? {
        text.split(whereSeparator: \.isNewline)
            .first { $0.hasPrefix("gitdir:") }
            .map { $0.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces) }
            .flatMap { $0.isEmpty ? nil : $0 }
    }

    /// `url` of `[remote "origin"]` in the text of a git config file (a quoted value unquoted).
    public static func originURL(inConfig config: String) -> String? {
        var inOrigin = false
        for raw in config.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") {
                inOrigin = line.filter { !$0.isWhitespace }.hasPrefix("[remote\"origin\"]")
                continue
            }
            guard inOrigin, let equals = line.firstIndex(of: "=") else { continue }
            guard line[..<equals].trimmingCharacters(in: .whitespaces).lowercased() == "url" else { continue }
            var value = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") { value = String(value.dropFirst().dropLast()) }
            return value.isEmpty ? nil : value
        }
        return nil
    }

    /// The remote names of a git config file's text (`[remote "NAME"]` sections), in file order.
    /// nil when the file includes others (`[include]`, `[includeIf …]`): those may add remotes,
    /// so the caller asks git instead.
    public static func remoteNames(inConfig config: String) -> [String]? {
        var names: [String] = []
        for raw in config.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("[") else { continue }
            let header = line.dropFirst().prefix { $0 != "]" }.trimmingCharacters(in: .whitespaces)
            let lower = header.lowercased()
            if lower == "include" || lower.hasPrefix("includeif") { return nil }
            guard lower.hasPrefix("remote"), let open = header.firstIndex(of: "\""), let close = header.lastIndex(of: "\""), open < close
            else { continue }
            let name = String(header[header.index(after: open)..<close])
            if !name.isEmpty, !names.contains(name) { names.append(name) }
        }
        return names
    }

    /// The git folder and the common git folder of the repository `path` lies in, found as session
    /// capture has always found them (`RecordSession`): the nearest `.git` at or above `path` with
    /// links followed (a linked `.git` counts), a `.git` file's `gitdir:` pointer, then the git
    /// folder's `commondir`. Only reads files; nil outside git or for a relative path.
    public static func repositoryFolders(containing path: String) -> (gitDir: String, commonDir: String)? {
        guard path.hasPrefix("/") else { return nil }
        var folder = (path as NSString).standardizingPath
        // Bounded: every step drops one path component, and "/" ends the walk.
        for _ in 0..<512 {
            let dotGit = (folder as NSString).appendingPathComponent(".git")
            var info = stat()
            if stat(dotGit, &info) == 0 {
                switch info.st_mode & S_IFMT {
                case S_IFDIR:
                    return (dotGit, commonDir(ofGitDir: dotGit))
                case S_IFREG:
                    if let target = metadata(dotGit).flatMap(gitdirPointer) {
                        let gitDir = ((target.hasPrefix("/") ? target : (folder as NSString).appendingPathComponent(target)) as NSString).standardizingPath
                        return (gitDir, commonDir(ofGitDir: gitDir))
                    }
                default:
                    break
                }
            }
            let parent = (folder as NSString).deletingLastPathComponent
            guard !parent.isEmpty, parent != folder else { return nil }
            folder = parent
        }
        return nil
    }

    /// The common git folder a git folder's `commondir` names; the git folder itself without one.
    static func commonDir(ofGitDir gitDir: String) -> String {
        guard let pointer = metadata(gitDir + "/commondir")?.trimmingCharacters(in: .whitespacesAndNewlines), !pointer.isEmpty else { return gitDir }
        return ((pointer.hasPrefix("/") ? pointer : gitDir + "/" + pointer) as NSString).standardizingPath
    }

    /// The text of a git metadata file (a config, a pointer file), at most `limit` bytes: a
    /// longer file is cut there. nil when it can't be opened.
    public static func metadata(_ path: String, limit: Int = 256 << 10) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        return (try? handle.read(upToCount: limit)).map { String(decoding: $0, as: UTF8.self) }
    }

    /// A small text file (git's pointer files), nil when missing or larger than 64 KB.
    private static func small(_ path: String) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 65_536), data.count < 65_536 else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
