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

    /// Copies `file` into `folder`, keeping its path under home. `keepLink`: a link is
    /// backed up as the same link (the thing replaced), otherwise as the content it points to.
    @discardableResult
    static func copy(_ file: URL, into folder: URL, home: URL, keepLink: Bool = false) throws -> URL {
        let fm = FileManager.default
        var relative = file.standardizedFileURL.path
        let homePath = home.standardizedFileURL.path
        if relative.hasPrefix(homePath + "/") { relative = String(relative.dropFirst(homePath.count + 1)) }
        let backup = folder.appending(path: relative)
        try fm.createDirectory(at: backup.deletingLastPathComponent(), withIntermediateDirectories: true)
        if keepLink, let destination = try? fm.destinationOfSymbolicLink(atPath: file.path) {
            try fm.createSymbolicLink(atPath: backup.path, withDestinationPath: destination)
        } else {
            try fm.copyItem(at: file.resolvingSymlinksInPath(), to: backup)
        }
        return backup
    }
}
