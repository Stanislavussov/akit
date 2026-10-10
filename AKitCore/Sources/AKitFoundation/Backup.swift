import Foundation

/// Copies of files AKit is about to change, in `~/.akit/backups/<time>/<path under home>`.
public enum Backup {
    /// A new, empty backup folder; never an older one. Readable only by the user (0700, the
    /// backups folder too): backups of MCP and settings files can hold secrets.
    public static func newFolder(home: URL) throws -> URL {
        let fm = FileManager.default
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd'T'HHmmss.SSS"
        var folder = home.appending(path: ".akit/backups/\(formatter.string(from: .now))")
        var counter = 1
        while fm.fileExists(atPath: folder.path) {
            folder = home.appending(path: ".akit/backups/\(formatter.string(from: .now))-\(counter)")
            counter += 1
        }
        let privateOnly: [FileAttributeKey: Any] = [.posixPermissions: 0o700]
        let backups = folder.deletingLastPathComponent()
        try fm.createDirectory(at: backups, withIntermediateDirectories: true, attributes: privateOnly)
        try fm.setAttributes(privateOnly, ofItemAtPath: backups.path)
        try fm.createDirectory(at: folder, withIntermediateDirectories: false, attributes: privateOnly)
        return folder
    }

    /// Saves `data` (a file's bytes as AKit read them) as the backup of `file` in a new backup
    /// folder, readable only by the user (settings files may hold tokens).
    public static func save(_ data: Data, as file: URL, home: URL) throws -> URL {
        let backup = try newFolder(home: home).appending(path: relative(file, home: home))
        try FileManager.default.createDirectory(at: backup.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard FileManager.default.createFile(atPath: backup.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: backup.path])
        }
        return backup
    }

    /// Deletes all but the newest `keep` backups of `file` (and backup folders left empty).
    public static func prune(_ file: URL, home: URL, keep: Int) {
        let fm = FileManager.default
        let root = home.appending(path: ".akit/backups")
        let path = relative(file, home: home)
        let folders = ((try? fm.contentsOfDirectory(atPath: root.path)) ?? []).sorted()
        let holding = folders.filter { fm.fileExists(atPath: root.appending(path: $0).appending(path: path).path) }
        for name in holding.dropLast(keep) {
            let folder = root.appending(path: name)
            try? fm.removeItem(at: folder.appending(path: path))
            // Empty parent folders up to the backup folder go too.
            var parent = folder.appending(path: path).deletingLastPathComponent()
            while parent.path.hasPrefix(folder.path), (try? fm.contentsOfDirectory(atPath: parent.path))?.isEmpty == true {
                try? fm.removeItem(at: parent)
                if parent.standardizedFileURL == folder.standardizedFileURL { break }
                parent = parent.deletingLastPathComponent()
            }
        }
    }

    /// `file`'s path under home (its absolute path without the leading `/` otherwise).
    static func relative(_ file: URL, home: URL) -> String {
        let path = file.standardizedFileURL.path
        let homePath = home.standardizedFileURL.path
        return path.hasPrefix(homePath + "/") ? String(path.dropFirst(homePath.count + 1)) : String(path.drop { $0 == "/" })
    }

    /// Copies `file` into `folder`, keeping its path under home. `keepLink`: a link is
    /// backed up as the same link (the thing replaced), otherwise as the content it points to.
    @discardableResult
    public static func copy(_ file: URL, into folder: URL, home: URL, keepLink: Bool = false) throws -> URL {
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
