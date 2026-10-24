import Foundation

/// Open in Obsidian (K10, K25): the base is a plain Obsidian vault or a folder inside one. AKit
/// opens a note through `obsidian://open?vault=<name>&file=<path in the vault>` when a folder above
/// the note holds `.obsidian/` (the vault Obsidian knows), else `obsidian://open?path=<absolute
/// path>`, which Obsidian maps to the vault that holds the file. No plugin.
public enum Obsidian {
    /// Everything but letters, digits and `-._~` is percent-encoded, so spaces, `&`, `#`, `/` and
    /// non-ASCII names survive.
    static let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")

    /// A folder with `.obsidian/` in it.
    public static func isVault(_ folder: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: folder.appending(path: ".obsidian").path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    /// The nearest folder at or above `url` that is a vault. Walks the path's own components, so it
    /// always ends at `/`.
    public static func vault(containing url: URL) -> URL? {
        let parts = url.standardized.path.split(separator: "/").map(String.init)
        for count in stride(from: parts.count, through: 1, by: -1) {
            let folder = URL(filePath: "/" + parts.prefix(count).joined(separator: "/"), directoryHint: .isDirectory)
            if isVault(folder) { return folder }
        }
        return nil
    }

    /// `obsidian://open?vault=Notes&file=kb%2Fareas%2Fpayments%2Forders-api.md` inside a vault,
    /// else `obsidian://open?path=%2FUsers%2Fme%2F…%2Forders-api.md`.
    public static func openURL(note: URL) -> URL? {
        let path = note.standardized.path.precomposedStringWithCanonicalMapping
        func encoded(_ text: String) -> String? { text.addingPercentEncoding(withAllowedCharacters: allowed) }
        if let vault = vault(containing: note.deletingLastPathComponent()) {
            let prefix = vault.standardized.path.precomposedStringWithCanonicalMapping
            let folder = prefix.hasSuffix("/") ? prefix : prefix + "/"
            if path.hasPrefix(folder), let name = encoded(vault.lastPathComponent.precomposedStringWithCanonicalMapping),
               let file = encoded(String(path.dropFirst(folder.count))) {
                return URL(string: "obsidian://open?vault=\(name)&file=\(file)")
            }
        }
        guard let whole = encoded(path) else { return nil }
        return URL(string: "obsidian://open?path=" + whole)
    }
}
