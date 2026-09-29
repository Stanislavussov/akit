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

    /// `/Users/me/x` → `~/x`, for messages.
    public static func tilde(_ url: URL, home: URL) -> String {
        let homePath = home.path
        return url.path.hasPrefix(homePath + "/") ? "~" + url.path.dropFirst(homePath.count) : url.path
    }
}
