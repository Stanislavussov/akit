import AKitFoundation
import Foundation

/// What the maps of a base say (2.1): which note each block stands for, which arrows join two
/// notes and with what label, and which blocks jump to other maps. Read from the `.excalidraw`
/// files with the one link resolver (P1), a map's links resolved from its own path.
///
/// - A block is a live element whose `link` resolves to a note. Its label is its bound text
///   (`containerId`), or, in an excalidraw-cli draft where labels are free text, the free text
///   whose centre lies inside it (the smallest such shape when several hold it).
/// - An arrow bound at both ends (`startBinding`/`endBinding.elementId`) to blocks is an edge:
///   its kind is the arrow's bound text, its flow the note its own `link` resolves to.
/// - Every other arrow (an end free, or bound to a shape that is no note) is listed apart, as
///   unbound.
/// - A live element whose `link` resolves to a map (`[[maps/x]]`, `[[area/maps/x]]`) is a jump.
public struct MapGraph: Sendable, Equatable {
    public struct Block: Encodable, Sendable, Equatable {
        public let element: String
        public let note: String
        public let label: String?
    }

    public struct Edge: Encodable, Sendable, Equatable {
        /// Note ids.
        public let from: String
        public let to: String
        /// The arrow's label ("events"); nil without one.
        public let kind: String?
        /// The note id the arrow's own link resolves to (a flow note).
        public let flow: String?
        /// The map id the edge comes from.
        public let map: String
        /// The arrow's element id.
        public let arrow: String

        private enum CodingKeys: String, CodingKey { case from, kind, to, flow, map, arrow }

        public func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(from, forKey: .from)
            try container.encode(kind, forKey: .kind) // null without a label
            try container.encode(to, forKey: .to)
            try container.encode(flow, forKey: .flow) // null without a flow link
            try container.encode(map, forKey: .map)
            try container.encode(arrow, forKey: .arrow)
        }
    }

    /// An arrow that doesn't join two blocks.
    public struct Unbound: Encodable, Sendable, Equatable {
        public let arrow: String
        public let label: String?
        /// The element ids its ends are bound to, nil for a free end.
        public let start: String?
        public let end: String?
    }

    public struct Jump: Encodable, Sendable, Equatable {
        public let element: String
        /// The map id the element links to.
        public let map: String
        public let label: String?
    }

    public struct Map: Sendable, Equatable {
        /// `payments/maps/overview`.
        public let id: String
        public let area: String
        /// Base-relative: `areas/payments/maps/overview.excalidraw`.
        public let path: String
        /// Live elements.
        public let elements: Int
        public let blocks: [Block]
        public let edges: [Edge]
        public let unbound: [Unbound]
        public let jumps: [Jump]
        /// Why the file couldn't be read; then the map is empty.
        public let error: String?
    }

    public let maps: [Map]

    public init(maps: [Map]) { self.maps = maps }

    /// The edges of every map, map by map.
    public var edges: [Edge] { maps.flatMap(\.edges) }

    /// The edges that start or end at a note, from every map.
    public func relations(of note: String) -> [Edge] { edges.filter { $0.from == note || $0.to == note } }

    /// The graph of one map file. `id` is the map id; `targets` the base's notes and maps.
    public static func map(id: String, file: Result<ExcalidrawFile, ExcalidrawFile.Failure>, targets: KnowledgeLinks) -> Map {
        let path = "areas/\(id).excalidraw"
        let area = id.split(separator: "/").first.map(String.init) ?? ""
        let scene: ExcalidrawFile
        switch file {
        case .success(let read): scene = read
        case .failure(let failure):
            return Map(id: id, area: area, path: path, elements: 0, blocks: [], edges: [], unbound: [], jumps: [], error: failure.message)
        }
        let live = scene.live
        let labels = labels(in: scene)
        var blocks: [Block] = [], jumps: [Jump] = []
        var noteOf: [String: String] = [:]
        for element in live where element.type != "text" {
            guard let link = element.link, !link.isEmpty else { continue }
            switch targets.resolve(link, from: path) {
            case .note(let note):
                if element.type == "arrow" || element.type == "line" { continue }
                blocks.append(Block(element: element.id, note: note, label: labels[element.id]))
                noteOf[element.id] = note
            case .map(let map):
                jumps.append(Jump(element: element.id, map: map, label: labels[element.id]))
            case .missing, .ambiguous:
                continue
            }
        }
        var edges: [Edge] = [], unbound: [Unbound] = []
        for arrow in live where arrow.type == "arrow" {
            let label = labels[arrow.id]
            if let start = arrow.startBinding, let end = arrow.endBinding, let from = noteOf[start], let to = noteOf[end] {
                var flow: String?
                if let link = arrow.link, case .note(let note) = targets.resolve(link, from: path) { flow = note }
                edges.append(Edge(from: from, to: to, kind: label, flow: flow, map: id, arrow: arrow.id))
            } else {
                unbound.append(Unbound(arrow: arrow.id, label: label, start: arrow.startBinding, end: arrow.endBinding))
            }
        }
        return Map(id: id, area: area, path: path, elements: live.count, blocks: blocks, edges: edges, unbound: unbound,
                   jumps: jumps, error: nil)
    }

    /// Element id → its label: the bound text first (`containerId`), else, for a shape, the free
    /// text whose centre lies inside it (each free text labels one shape, the smallest that holds
    /// it). Lines of a label are joined with spaces.
    public static func labels(in scene: ExcalidrawFile) -> [String: String] {
        let live = scene.live
        func clean(_ text: String) -> String? {
            let joined = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }.joined(separator: " ")
            return joined.isEmpty ? nil : joined
        }
        var labels: [String: String] = [:]
        for text in live where text.type == "text" {
            guard let container = text.containerId, labels[container] == nil, let label = text.text.flatMap(clean) else { continue }
            labels[container] = label
        }
        let shapes = live.filter { !["text", "arrow", "line", "freedraw"].contains($0.type) }
        let ids = Set(live.map(\.id))
        for text in live where text.type == "text" {
            // Free text, or text whose container is gone.
            if let container = text.containerId, ids.contains(container) { continue }
            guard let label = text.text.flatMap(clean) else { continue }
            let holders = shapes.filter { labels[$0.id] == nil && $0.contains(text.center) }
            if let smallest = holders.min(by: { $0.area < $1.area }) { labels[smallest.id] = label }
        }
        return labels
    }
}

extension KnowledgeBase {
    /// The maps (`.excalidraw` files under `areas/`, of one area or of all) joined into one graph,
    /// sorted by id. A map that can't be read is listed with its error and adds nothing.
    public func mapGraph(area: String? = nil) throws(Failure) -> MapGraph {
        let folder = try area.map { name throws(Failure) in try areaFolder(name) } ?? areasFolder
        let targets = linkTargets()
        let maps = Self.files(in: folder).filter { $0.pathExtension == "excalidraw" }.map { file in
            MapGraph.map(id: Self.id(of: file, areas: areasFolder), file: ExcalidrawFile.load(file), targets: targets)
        }
        return MapGraph(maps: maps.sorted { $0.id < $1.id })
    }
}
