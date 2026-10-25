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

    /// Obsidian Sync is on in `vault`: `.obsidian/sync.json` exists (Sync's own settings), or the
    /// core plugin `sync` is enabled in `.obsidian/core-plugins.json` or
    /// `core-plugins-migration.json` (`{"sync": true}`, or the older list `["sync", …]`).
    public static func syncIsOn(_ vault: URL) -> Bool {
        let settings = vault.appending(path: ".obsidian")
        if FileManager.default.fileExists(atPath: settings.appending(path: "sync.json").path) { return true }
        for name in ["core-plugins.json", "core-plugins-migration.json"] {
            guard let data = try? Data(contentsOf: settings.appending(path: name)),
                  let json = try? JSONSerialization.jsonObject(with: data) else { continue }
            if let enabled = json as? [String: Any], enabled["sync"] as? Bool == true { return true }
            if let list = json as? [String], list.contains("sync") { return true }
        }
        return false
    }

    /// The nearest vault at or above `url` with Obsidian Sync on (`syncIsOn`); nil when none is.
    /// Sync uploads the whole vault, so a base in any folder of it leaves the Mac.
    public static func syncedVault(containing url: URL) -> URL? {
        var next: URL? = url
        while let folder = next, let vault = vault(containing: folder) {
            if syncIsOn(vault) { return vault }
            let parent = vault.deletingLastPathComponent()
            next = parent.standardized.path == vault.standardized.path ? nil : parent
        }
        return nil
    }

    /// The vaults Obsidian knows, from its own list `~/Library/Application Support/obsidian/
    /// obsidian.json` (`{"vaults": {id: {"path": …}}}`), read only. nil when the list can't be
    /// read (Obsidian never ran, or a format AKit doesn't know): then AKit can't tell.
    public static func knownVaults(home: URL) -> [URL]? {
        let file = home.appending(path: "Library/Application Support/obsidian/obsidian.json")
        guard let data = try? Data(contentsOf: file),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let vaults = json["vaults"] as? [String: Any] else { return nil }
        return vaults.values.compactMap { ($0 as? [String: Any])?["path"] as? String }.map { URL(filePath: $0, directoryHint: .isDirectory) }
    }

    /// Whether Obsidian can open `note`: one of `known` (its vaults) is the note's folder or a
    /// folder above it. `obsidian://open` refuses any other file ("Unable to find a vault").
    public static func canOpen(_ note: URL, known: [URL]) -> Bool {
        let path = note.standardized.resolvingSymlinksInPath().path.precomposedStringWithCanonicalMapping
        return known.contains { vault in
            let folder = vault.standardized.resolvingSymlinksInPath().path.precomposedStringWithCanonicalMapping
            return path.hasPrefix(folder.hasSuffix("/") ? folder : folder + "/")
        }
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
