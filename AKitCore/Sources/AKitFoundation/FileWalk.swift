import Foundation

/// Small file-system helpers that follow symlinks, shared by every folder reader.
public enum FileWalk {
    /// Visible entries of a folder, sorted by name. Empty when the folder can't be read.
    public static func children(of dir: URL) -> [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return names.filter { !$0.hasPrefix(".") }.sorted().map { dir.appending(path: $0) }
    }

    public static func isDirectory(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }

    /// Files with this extension in a folder and in its direct subfolders: the folder's own
    /// first, then each subfolder's, each list sorted by name.
    public static func files(withExtension ext: String, inAndBelow folder: URL) -> [URL] {
        let entries = children(of: folder)
        return entries.filter { $0.pathExtension == ext }
            + entries.filter(isDirectory).flatMap { dir in children(of: dir).filter { $0.pathExtension == ext } }
    }

    /// realpath(3): every link resolved, `/var` stays `/private/var`. nil when the path doesn't exist.
    public static func realPath(_ url: URL) -> String? {
        guard let resolved = realpath(url.path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// A regular file once links are resolved: not a folder, FIFO, socket or device.
    public static func isRegularFile(_ url: URL) -> Bool {
        var info = stat()
        return stat(url.path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFREG
    }

    /// Whether `url`, links resolved, is `folder` or lies inside it (links in `folder` resolved too).
    public static func isInside(_ url: URL, _ folder: URL) -> Bool {
        guard let path = realPath(url), let base = realPath(folder) else { return false }
        return path == base || path.hasPrefix(base == "/" ? "/" : base + "/")
    }

    /// At most `limit` bytes from the start of a regular file; nil for anything else
    /// (a FIFO or device would block or never end).
    public static func head(of url: URL, limit: Int) -> Data? {
        guard isRegularFile(url), let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        return (try? handle.read(upToCount: limit)) ?? Data()
    }

    /// A JSON object from a regular file of at most `limit` bytes.
    public static func jsonObject(_ url: URL, limit: Int = 1 << 20) -> [String: Any]? {
        guard let data = head(of: url, limit: limit + 1), data.count <= limit else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    /// `/Users/me/x` → `~/x`, for messages.
    public static func tilde(_ url: URL, home: URL) -> String {
        let homePath = home.path
        return url.path.hasPrefix(homePath + "/") ? "~" + url.path.dropFirst(homePath.count) : url.path
    }
}
