import AKitFoundation
import Foundation

/// A `.excalidraw` scene, read only (2.1): the elements and the few fields the map graph needs.
/// Tolerant by design: unknown fields (newer Excalidraw writes `index`, `fontFamily: 5`, binding
/// `mode`/`fixedPoint`, `elbowed`, …) are ignored, a field of an unexpected type reads as absent,
/// and an element without an id is skipped. Only a file that isn't a JSON object with an
/// `elements` array is an error, returned as a value, never thrown. AKit never writes a scene from
/// this type: the canvas posts its own bytes (2.2b), and `NewMap` writes a fresh one.
public struct ExcalidrawFile: Sendable, Equatable {
    public struct Element: Sendable, Equatable {
        public let id: String
        /// rectangle, ellipse, diamond, text, arrow, line, …
        public let type: String
        public let isDeleted: Bool
        public let x: Double
        public let y: Double
        public let width: Double
        public let height: Double
        /// `[[note]]`, `akit:note/…`, a URL, or nil.
        public let link: String?
        /// A text element's text.
        public let text: String?
        /// For bound text: the shape or arrow it belongs to.
        public let containerId: String?
        /// For an arrow: the element its start and end are bound to.
        public let startBinding: String?
        public let endBinding: String?

        public init(id: String, type: String, isDeleted: Bool = false, x: Double = 0, y: Double = 0, width: Double = 0,
                    height: Double = 0, link: String? = nil, text: String? = nil, containerId: String? = nil,
                    startBinding: String? = nil, endBinding: String? = nil) {
            self.id = id
            self.type = type
            self.isDeleted = isDeleted
            self.x = x
            self.y = y
            self.width = width
            self.height = height
            self.link = link
            self.text = text
            self.containerId = containerId
            self.startBinding = startBinding
            self.endBinding = endBinding
        }

        /// The centre of the element's box (width and height may be negative for lines).
        var center: (x: Double, y: Double) { (x + width / 2, y + height / 2) }

        /// Whether a point lies inside the element's box.
        func contains(_ point: (x: Double, y: Double)) -> Bool {
            let (left, right) = (min(x, x + width), max(x, x + width))
            let (top, bottom) = (min(y, y + height), max(y, y + height))
            return point.x >= left && point.x <= right && point.y >= top && point.y <= bottom
        }

        var area: Double { abs(width * height) }
    }

    public struct Failure: Error, Sendable, Equatable {
        public let message: String
    }

    /// `source` as written (`akit-web://app`, `https://excalidraw.com`, the excalidraw-cli URL).
    public let source: String?
    public let version: Int?
    /// Every element in file order, deleted ones too (`isDeleted`).
    public let elements: [Element]

    public init(source: String? = nil, version: Int? = nil, elements: [Element]) {
        self.source = source
        self.version = version
        self.elements = elements
    }

    /// The elements that are not deleted.
    public var live: [Element] { elements.filter { !$0.isDeleted } }

    public static func parse(_ data: Data) -> Result<ExcalidrawFile, Failure> {
        let root: JSONValue
        do { root = try JSONValue.parse(data) } catch {
            return .failure(Failure(message: "not valid JSON: \(error.message)"))
        }
        guard case .object(let scene) = root else { return .failure(Failure(message: "not an Excalidraw scene: the file isn't a JSON object")) }
        if case .string(let type) = scene["type"], type != "excalidraw" {
            return .failure(Failure(message: "not an Excalidraw scene: its type is “\(type)”"))
        }
        guard case .array(let items) = scene["elements"] else {
            return .failure(Failure(message: "not an Excalidraw scene: it has no elements array"))
        }
        let elements: [Element] = items.compactMap { item in
            guard case .object(let fields) = item, let id = string(fields["id"]), !id.isEmpty else { return nil }
            return Element(id: id, type: string(fields["type"]) ?? "", isDeleted: fields["isDeleted"] == .bool(true),
                           x: number(fields["x"]), y: number(fields["y"]), width: number(fields["width"]), height: number(fields["height"]),
                           link: string(fields["link"]), text: string(fields["text"]), containerId: string(fields["containerId"]),
                           startBinding: binding(fields["startBinding"]), endBinding: binding(fields["endBinding"]))
        }
        var version: Int?
        if case .number(let text) = scene["version"] { version = Int(text) }
        return .success(ExcalidrawFile(source: string(scene["source"]), version: version, elements: elements))
    }

    /// Reads a file; a missing or unreadable file is a failure too.
    public static func load(_ url: URL) -> Result<ExcalidrawFile, Failure> {
        guard let data = try? Data(contentsOf: url) else { return .failure(Failure(message: "can't be read")) }
        return parse(data)
    }

    private static func string(_ value: JSONValue?) -> String? {
        if case .string(let text) = value { return text }
        return nil
    }

    private static func number(_ value: JSONValue?) -> Double {
        if case .number(let text) = value, let number = Double(text), number.isFinite { return number }
        return 0
    }

    private static func binding(_ value: JSONValue?) -> String? {
        guard case .object(let fields) = value, let id = string(fields["elementId"]), !id.isEmpty else { return nil }
        return id
    }
}
