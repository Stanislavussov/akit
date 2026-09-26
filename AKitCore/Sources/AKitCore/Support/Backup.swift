import Foundation

/// Copies of files AKit is about to change, in `~/.akit/backups/<time>/<path under home>`.
enum Backup {
    /// A new, empty backup folder; never an older one.
    static func newFolder(home: URL) throws -> URL {
        let fm = FileManager.default
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd'T'HHmmss.SSS"
        var folder = home.appending(path: ".akit/backups/\(formatter.string(from: .now))")
        var counter = 1
        while fm.fileExists(atPath: folder.path) {
            folder = home.appending(path: ".akit/backups/\(formatter.string(from: .now))-\(counter)")
            counter += 1
        }
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// Copies `file` (its content, if it is a link) into `folder`, keeping its path under home.
    @discardableResult
    static func copy(_ file: URL, into folder: URL, home: URL) throws -> URL {
        var relative = file.standardizedFileURL.path
        let homePath = home.standardizedFileURL.path
        if relative.hasPrefix(homePath + "/") { relative = String(relative.dropFirst(homePath.count + 1)) }
        let backup = folder.appending(path: relative)
        try FileManager.default.createDirectory(at: backup.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: file.resolvingSymlinksInPath(), to: backup)
        return backup
    }
}
