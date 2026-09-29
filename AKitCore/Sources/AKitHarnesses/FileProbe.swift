import AKitModel
import Foundation

/// Checks whether a file/folder exists and whether it is a symlink. Read-only.
enum FileProbe {
    static func location(
        _ title: String,
        _ url: URL,
        kind: ConfigLocation.Kind,
        role: ConfigLocation.Role,
        note: String? = nil
    ) -> ConfigLocation {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        // fileExists follows symlinks: a broken link counts as missing.
        let exists = fm.fileExists(atPath: url.path, isDirectory: &isDir)
            && (kind == .directory) == isDir.boolValue
        return ConfigLocation(
            title: title,
            note: note,
            role: role,
            kind: kind,
            url: url,
            exists: exists,
            symlinkDestination: symlinkDestination(of: url)
        )
    }

    static func symlinkDestination(of url: URL) -> URL? {
        guard let raw = try? FileManager.default.destinationOfSymbolicLink(atPath: url.path) else { return nil }
        let dest = raw.hasPrefix("/")
            ? URL(filePath: raw)
            : url.deletingLastPathComponent().appending(path: raw)
        return dest.standardizedFileURL
    }

    static func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }
}
