import Foundation

/// Open in Obsidian (K10): the base is a plain Obsidian vault; AKit opens a note there through
/// `obsidian://open?path=<absolute path>`, which Obsidian maps to the vault that holds the file.
/// No plugin.
public enum Obsidian {
    /// `obsidian://open?path=%2FUsers%2Fme%2F…%2Forders-api.md`: everything but letters, digits
    /// and `-._~` percent-encoded, so spaces, `&`, `#` and non-ASCII names survive.
    public static func openURL(note: URL) -> URL? {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        let path = note.standardized.path.precomposedStringWithCanonicalMapping
        guard let encoded = path.addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
        return URL(string: "obsidian://open?path=" + encoded)
    }
}
