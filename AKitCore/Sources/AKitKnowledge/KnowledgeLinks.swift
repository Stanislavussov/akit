import Foundation

/// The one link resolver of a base (P1): what a `[[link]]` or an `akit:` link in a note or on a
/// map points to. Ids are the path under `areas/` without the extension, NFC
/// (`payments/orders-api`, `payments/maps/overview`). Matching ignores case, as Obsidian does.
///
/// | Link | Means |
/// |---|---|
/// | `[[orders-api]]` | the one note `orders-api.md` (shortest unique path) |
/// | `[[orders-api]]`, two matches | the one in the linking file's area, else `.ambiguous` |
/// | `[[payments/orders-api]]` | a path suffix; unique, or the linking file's area |
/// | `[[maps/overview]]` | a map of the linking file's area |
/// | `[[logistics/maps/routes]]` | a map of another area |
/// | `[[note#Heading]]`, `[[note\|alias]]` | resolved by the note part |
/// | `akit:note/<id>`, `akit:map/<id>` | exactly that id |
public struct KnowledgeLinks: Sendable, Equatable {
    public enum Resolution: Sendable, Equatable {
        case note(String)
        case map(String)
        case missing
        case ambiguous([String])
    }

    public let notes: [String]
    public let maps: [String]

    public init(notes: [String], maps: [String]) {
        self.notes = notes.map(Self.nfc).sorted()
        self.maps = maps.map(Self.nfc).sorted()
    }

    /// `link` as written (`[[…]]`, its inside, or `akit:…`); `path` is the base-relative path (or id)
    /// of the note or map that holds it, which gives its area.
    public func resolve(_ link: String, from path: String) -> Resolution {
        var target = Self.nfc(link.trimmingCharacters(in: .whitespacesAndNewlines))
        if target.hasPrefix("[["), target.hasSuffix("]]") { target = String(target.dropFirst(2).dropLast(2)) }
        for (prefix, pool, make) in [("akit:note/", notes, Resolution.note), ("akit:map/", maps, Resolution.map)] where target.hasPrefix(prefix) {
            let id = Self.withoutExtension(String(target.dropFirst(prefix.count)).removingPercentEncoding ?? "")
            return pool.first { $0 == id }.map(make) ?? .missing
        }
        // `[[note\|alias]]` (escaped in a table) and `[[note|alias]]`, then `#Heading` or `#^block`.
        target = target.replacingOccurrences(of: "\\|", with: "|")
        if let bar = target.firstIndex(of: "|") { target = String(target[..<bar]) }
        if let hash = target.firstIndex(of: "#") { target = String(target[..<hash]) }
        target = target.trimmingCharacters(in: .whitespaces)
        if target.hasPrefix("/") { target.removeFirst() }
        if target.lowercased().hasPrefix("areas/") { target = String(target.dropFirst("areas/".count)) }
        let isMap = target.lowercased().hasSuffix(".excalidraw") || target.lowercased().split(separator: "/").dropLast().contains("maps")
        target = Self.withoutExtension(target)
        guard !target.isEmpty else { return .missing }

        let pool = isMap ? maps : notes
        let make = isMap ? Resolution.map : Resolution.note
        let wanted = target.lowercased()
        let matches = pool.filter { $0.lowercased() == wanted || $0.lowercased().hasSuffix("/" + wanted) }
        if matches.count == 1 { return make(matches[0]) }
        if matches.isEmpty { return .missing }
        let area = Self.area(of: path)
        let local = matches.filter { Self.area(of: $0) == area }
        if local.count == 1 { return make(local[0]) }
        // The same name in two cases (orders-api, Orders-API): the one written exactly.
        let exact = (local.isEmpty ? matches : local).filter { $0 == target || $0.hasSuffix("/" + target) }
        if exact.count == 1 { return make(exact[0]) }
        return .ambiguous(matches)
    }

    /// `areas/payments/x.md`, `payments/x` → `payments`.
    static func area(of path: String) -> String {
        var parts = nfc(path).split(separator: "/").map(String.init)
        if parts.first == "areas" { parts.removeFirst() }
        return parts.count > 1 ? parts[0].lowercased() : ""
    }

    static func withoutExtension(_ target: String) -> String {
        for ext in [".md", ".excalidraw"] where target.lowercased().hasSuffix(ext) { return String(target.dropLast(ext.count)) }
        return target
    }

    static func nfc(_ text: String) -> String { text.precomposedStringWithCanonicalMapping }
}
