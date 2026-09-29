import Foundation

/// Moving things to the macOS Trash. AKit never deletes: it trashes.
public enum Trash {
    /// Moves `url` to the Trash. Returns where it ended up.
    public static func move(_ url: URL) throws -> URL? {
        var result: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &result)
        return result as URL?
    }
}
