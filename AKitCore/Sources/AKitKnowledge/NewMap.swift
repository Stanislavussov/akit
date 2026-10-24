import AKitFoundation
import Foundation

/// Fresh `.excalidraw` scenes in the shape Excalidraw 0.17.6 saves (`serializeAsJSON(…, "local")`,
/// as in the spike fixtures): `type`, `version: 2`, `source`, `elements`, `appState` with the
/// background colour, `files`. `scene()` is the empty map `kb new-map` writes; the builders make
/// the sample base's maps (`KnowledgeSeed`), with fixed ids and seeds so the text never changes.
public enum NewMap {
    /// What AKit's canvas writes as `source` too.
    public static let source = "akit-web://app"

    /// An empty map.
    public static func scene() -> String { scene(elements: []) }

    /// A scene with these elements, printed with sorted keys (`JSONValue.pretty`).
    static func scene(elements: [JSONValue]) -> String {
        JSONValue.object([
            "type": .string("excalidraw"),
            "version": .number("2"),
            "source": .string(source),
            "elements": .array(elements),
            "appState": .object(["gridSize": .null, "viewBackgroundColor": .string("#ffffff")]),
            "files": .object([:]),
        ]).pretty
    }

    /// A block's place on the canvas.
    struct Box {
        let id: String
        let x: Double
        let y: Double
        var width: Double = 180
        var height: Double = 80
    }

    /// A rectangle with a bound, centred label; `arrows` are the ids of the arrows bound to it.
    static func block(_ box: Box, label: String, link: String?, arrows: [String] = []) -> [JSONValue] {
        let textID = box.id + "-label"
        let rectangle = element(box.id, type: "rectangle", x: box.x, y: box.y, width: box.width, height: box.height, link: link,
                                bound: [("text", textID)] + arrows.map { ("arrow", $0) })
        return [rectangle, text(textID, label, container: box.id, centre: (box.x + box.width / 2, box.y + box.height / 2))]
    }

    /// An arrow from the right edge of `from` to the left edge of `to`, bound at both ends, with a
    /// bound label and a link.
    static func arrow(_ id: String, from: Box, to: Box, label: String?, link: String?) -> [JSONValue] {
        let start = (x: from.x + from.width + 0.5, y: from.y + from.height / 2)
        let end = (x: to.x - 0.5, y: to.y + to.height / 2)
        return arrow(id, start: start, end: end, startBinding: from.id, endBinding: to.id, label: label, link: link)
    }

    /// An arrow between two points, bound where an element id is given.
    static func arrow(_ id: String, start: (x: Double, y: Double), end: (x: Double, y: Double), startBinding: String? = nil,
                      endBinding: String? = nil, label: String? = nil, link: String? = nil) -> [JSONValue] {
        let textID = id + "-label"
        let (dx, dy) = (end.x - start.x, end.y - start.y)
        guard case .object(var fields) = element(id, type: "arrow", x: start.x, y: start.y, width: abs(dx), height: abs(dy),
                                                 link: link, bound: label == nil ? [] : [("text", textID)]) else { return [] }
        func binding(_ element: String?) -> JSONValue {
            element.map { .object(["elementId": .string($0), "focus": .number("0"), "gap": .number("1")]) } ?? .null
        }
        fields["startBinding"] = binding(startBinding)
        fields["endBinding"] = binding(endBinding)
        fields["lastCommittedPoint"] = .null
        fields["startArrowhead"] = .null
        fields["endArrowhead"] = .string("arrow")
        fields["points"] = .array([.array([.number("0"), .number("0")]), .array([number(dx), number(dy)])])
        let arrow = JSONValue.object(fields)
        guard let label else { return [arrow] }
        return [arrow, text(textID, label, container: id, centre: (start.x + dx / 2, start.y + dy / 2))]
    }

    /// A text element centred on a point; bound to `container` when given.
    static func text(_ id: String, _ text: String, container: String?, centre: (x: Double, y: Double)) -> JSONValue {
        let width = Double(text.count) * 10, height = 25.0
        guard case .object(var fields) = element(id, type: "text", x: centre.x - width / 2, y: centre.y - height / 2,
                                                 width: width, height: height, link: nil, bound: []) else { return .null }
        fields["fontSize"] = .number("20")
        fields["fontFamily"] = .number("1")
        fields["text"] = .string(text)
        fields["originalText"] = .string(text)
        fields["textAlign"] = .string("center")
        fields["verticalAlign"] = .string("middle")
        fields["containerId"] = container.map { .string($0) } ?? .null
        fields["lineHeight"] = .number("1.25")
        fields["baseline"] = .number("19")
        return .object(fields)
    }

    /// The fields every 0.17.6 element has.
    static func element(_ id: String, type: String, x: Double, y: Double, width: Double, height: Double, link: String?,
                        bound: [(type: String, id: String)]) -> JSONValue {
        .object([
            "type": .string(type), "version": .number("1"), "versionNonce": .number(String(stableNumber(id + "/nonce"))),
            "isDeleted": .bool(false), "id": .string(id), "fillStyle": .string("solid"), "strokeWidth": .number("2"),
            "strokeStyle": .string("solid"), "roughness": .number("1"), "opacity": .number("100"), "angle": .number("0"),
            "x": number(x), "y": number(y), "strokeColor": .string("#1e1e1e"), "backgroundColor": .string("transparent"),
            "width": number(width), "height": number(height), "seed": .number(String(stableNumber(id))), "groupIds": .array([]),
            "frameId": .null, "roundness": .null,
            "boundElements": .array(bound.map { .object(["type": .string($0.type), "id": .string($0.id)]) }),
            "updated": .number("1792868740000"), "link": link.map { .string($0) } ?? .null, "locked": .bool(false),
        ])
    }

    static func number(_ value: Double) -> JSONValue {
        value == value.rounded() && abs(value) < 1e15 ? .number(String(Int(value))) : .number(String(value))
    }

    /// A positive 31-bit number from a text (FNV-1a), the same on every run.
    static func stableNumber(_ text: String) -> Int {
        var hash: UInt32 = 2_166_136_261
        for byte in text.utf8 { hash = (hash ^ UInt32(byte)) &* 16_777_619 }
        return Int(hash & 0x7FFF_FFFF)
    }
}

extension KnowledgeBase {
    /// Creates `areas/AREA/maps/NAME.excalidraw` (the area too, when new) with an empty 0.17.6
    /// scene and commits it at once: one commit, only that file (P8, U2: no queue).
    @discardableResult
    public func newMap(area: String, name: String, env: HarnessEnvironment) async throws(Failure) -> String {
        let area = Self.nfc(area.trimmingCharacters(in: .whitespaces)), name = Self.nfc(name.trimmingCharacters(in: .whitespaces))
        for (what, value) in [("An area", area), ("A map name", name)] where !Self.validName(value) {
            throw Failure(message: "“\(value)” can't be used: \(what.lowercased()) is one folder or file name, without /, and doesn't start with a dot.")
        }
        let stem = name.hasSuffix(".excalidraw") ? String(name.dropLast(".excalidraw".count)) : name
        let path = "areas/\(area)/maps/\(stem).excalidraw"
        let file = root.appending(path: path)
        if FileManager.default.fileExists(atPath: file.path) { throw Failure(message: "The map \(area)/maps/\(stem) exists already.") }
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(NewMap.scene().utf8).write(to: file, options: .withoutOverwriting)
        } catch {
            throw Failure(message: "Couldn't write \(path): \(error.localizedDescription)")
        }
        do {
            try await KnowledgeGit(base: root, env: env).commit(paths: [path], message: "Add map \(area)/maps/\(stem)")
        } catch {
            throw Failure(message: "\(path) was written, but not committed: \(error.message)")
        }
        return path
    }
}
