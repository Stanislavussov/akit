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
            guard let text = small(dotGit), let line = text.split(whereSeparator: \.isNewline).first(where: { $0.hasPrefix("gitdir:") }) else {
                return nil
            }
            let pointer = line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
            guard !pointer.isEmpty else { return nil }
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

    /// A small text file (git's pointer files), nil when missing or larger than 64 KB.
    private static func small(_ path: String) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 65_536), data.count < 65_536 else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
