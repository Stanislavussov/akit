import AKitReview
import AppKit
import SwiftUI

extension ReviewSeverity {
    /// The dot of a finding's severity on the map and in its inspector.
    var color: Color {
        switch self {
        case .critical, .high: .red
        case .medium: .orange
        case .low: .yellow
        case .nit: .secondary
        }
    }
}

/// The Map tab of a run (R40, "The map on the Review screen"): three lanes left to right, This
/// change (modules with their files, faded files that import them), Boundaries and Other
/// repositories, with lines between them. A fixed layout; hovering a node lights up its lines,
/// clicking it opens the inspector on the right. For the user only, never posted.
struct ReviewMapView: View {
    let map: ReviewMap
    let run: ReviewWorkflow.Run
    /// Show Request: the requests tab at this finding's request.
    let showFinding: (String) -> Void
    /// Snapshots: `--tab map --query <node id>` selects a node.
    @State private var selected: String? = DebugSnapshot.options?.tab == "map" ? DebugSnapshot.options?.query : nil
    @State private var hovered: String?
    /// Modules and projects folded to one node; those over 8 files start folded.
    @State private var folded: Set<String>
    @State private var dependentsOpen = false
    /// The width of the lanes' scroll view beside the inspector: each lane gets its share of it.
    /// Measured on the scroll view, which takes the width it is offered, never the lanes' own:
    /// the lanes can't widen what they are measured by, and the map never widens its pane.
    @State private var lanesWidth: CGFloat = 0

    /// Over this many files a module (or a project) starts folded.
    static let foldOver = 8
    static let dependentsShown = 8

    /// The map's nodes by id (the first of a repeated id) and its dependents, worked out once.
    private let byID: [String: ReviewMap.Node]
    private let dependents: [ReviewMap.Node]
    /// The dependents shown while Show All is off.
    private let firstDependents: Set<String>

    init(map: ReviewMap, run: ReviewWorkflow.Run, showFinding: @escaping (String) -> Void) {
        self.map = map
        self.run = run
        self.showFinding = showFinding
        byID = Dictionary(map.nodes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        dependents = map.nodes.filter { $0.kind == .dependent }
        firstDependents = Set(dependents.prefix(Self.dependentsShown).map(\.id))
        _folded = State(initialValue: Self.startFolded(map))
    }

    /// Modules and projects with over `foldOver` files.
    static func startFolded(_ map: ReviewMap) -> Set<String> {
        Set(map.nodes.filter { node in (node.kind == .module || node.kind == .project)
            && map.nodes.count(where: { $0.parent == node.id }) > foldOver }.map(\.id))
    }

    /// The node a line ends at: a file of a folded module ends at the module, a hidden dependent at
    /// the dependents' row.
    private func shown(_ id: String) -> String? {
        guard let node = byID[id] else { return nil }
        if node.kind == .dependent {
            return dependentsOpen || firstDependents.contains(id) ? id : "dependents"
        }
        if let parent = node.parent, folded.contains(parent) { return parent }
        return id
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("What the change touches, its boundaries and the other repositories that use them.")
                    .font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button("Copy as Mermaid", systemImage: "doc.on.doc") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(map.mermaid, forType: .string)
                }
                .controlSize(.small)
                .help("Copy the map as a Mermaid flowchart (akit review map RUN --mermaid prints the same)")
            }
            ForEach(Array(map.notes.enumerated()), id: \.offset) { Text($1).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
            HStack(alignment: .top, spacing: 12) {
                lanes
                if let id = selected, let node = byID[id] {
                    ReviewMapInspector(node: node, map: map, run: run, showFinding: showFinding) { selected = nil }
                        .frame(width: 260)
                }
            }
        }
        .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { width in
            if DebugSnapshot.options != nil { print("map: \(Int(width)) wide") }
        }
        // Another map in the same view (another run): its own folds, nothing selected.
        .onChange(of: map) { _, map in
            folded = Self.startFolded(map)
            selected = nil
            hovered = nil
            dependentsOpen = false
        }
    }

    private static let laneSpacing: CGFloat = 36

    /// The lanes in a sideways scroll view: under their least widths they scroll inside it, and the
    /// inspector beside them stays in view.
    private var lanes: some View {
        ScrollView(.horizontal) {
            HStack(alignment: .top, spacing: Self.laneSpacing) {
                lane("This change", systemImage: "doc.text", width: laneWidth(0.38, least: 150)) { changeLane }
                lane("Boundaries", systemImage: "square.dashed", width: laneWidth(0.30, least: 120)) { boundariesLane }
                lane("Other repositories", systemImage: "shippingbox", width: laneWidth(0.32, least: 130)) { othersLane }
            }
            .backgroundPreferenceValue(MapAnchors.self) { anchors in
                GeometryReader { proxy in
                    Canvas { context, _ in draw(in: &context, anchors: anchors, proxy: proxy) }
                }
                .allowsHitTesting(false)
            }
            .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { width in
                if DebugSnapshot.options != nil { print("map: lanes \(Int(width)) wide in \(Int(lanesWidth))") }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { lanesWidth = $0 }
    }

    /// A lane's share of the scroll view's width, at least `least`.
    private func laneWidth(_ share: CGFloat, least: CGFloat) -> CGFloat {
        max(least, ((lanesWidth - 2 * Self.laneSpacing) * share).rounded(.down))
    }

    private func lane(_ title: String, systemImage: String, width: CGFloat, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: systemImage).font(.subheadline.weight(.medium)).foregroundStyle(.secondary)
            content()
        }
        .frame(width: width, alignment: .topLeading)
    }

    // MARK: - Lanes

    @ViewBuilder private var changeLane: some View {
        ForEach(Array(map.nodes.filter { $0.kind == .module }.enumerated()), id: \.offset) { _, module in
            let files = map.nodes.filter { $0.parent == module.id }
            VStack(alignment: .leading, spacing: 3) {
                node(module, fold: files.count > 1 ? module.id : nil)
                if !folded.contains(module.id) {
                    ForEach(Array(files.enumerated()), id: \.offset) { node($1).padding(.leading, 14) }
                }
            }
        }
        if !dependents.isEmpty {
            Text("Import the change, unchanged").font(.caption).foregroundStyle(.tertiary).padding(.top, 6)
            ForEach(Array((dependentsOpen ? dependents : Array(dependents.prefix(Self.dependentsShown))).enumerated()), id: \.offset) { node($1) }
            if dependents.count > Self.dependentsShown {
                Button(dependentsOpen ? "Show Fewer" : "Show All \(dependents.count)") { dependentsOpen.toggle() }
                    .buttonStyle(.link).font(.caption)
                    .anchorPreference(key: MapAnchors.self, value: .bounds) { ["dependents": $0] }
            }
        }
        if map.nodes(in: .change).isEmpty { empty("No changed files.") }
    }

    @ViewBuilder private var boundariesLane: some View {
        let boundaries = map.nodes(in: .boundaries)
        if boundaries.isEmpty {
            empty("None found: the change stays inside this repository, or the brief named none.")
        }
        ForEach(Array(boundaries.enumerated()), id: \.offset) { node($1) }
    }

    @ViewBuilder private var othersLane: some View {
        let projects = map.nodes.filter { $0.kind == .project }
        if projects.isEmpty {
            empty(map.nodes(in: .boundaries).isEmpty ? "Nothing to look for." : "No uses found in other repositories.")
        }
        ForEach(Array(projects.enumerated()), id: \.offset) { _, project in
            let files = map.nodes.filter { $0.parent == project.id }
            VStack(alignment: .leading, spacing: 3) {
                node(project, fold: files.isEmpty ? nil : project.id)
                if !folded.contains(project.id) {
                    ForEach(Array(files.enumerated()), id: \.offset) { node($1).padding(.leading, 14) }
                }
            }
        }
    }

    private func empty(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - A node

    private func node(_ node: ReviewMap.Node, fold: String? = nil) -> some View {
        let lit = selected == node.id || hovered == node.id
        return HStack(spacing: 5) {
            if let fold {
                Button {
                    if folded.contains(fold) { folded.remove(fold) } else { folded.insert(fold) }
                } label: {
                    Image(systemName: folded.contains(fold) ? "chevron.right" : "chevron.down").font(.caption2).frame(width: 10)
                }
                .buttonStyle(.plain)
                .help(folded.contains(fold) ? "Show its files" : "Fold its files into one node")
            }
            if let symbol = symbol(node) {
                Image(systemName: symbol).font(.caption).foregroundStyle(.secondary).frame(width: 14)
            }
            title(node)
            if node.boundary?.isRemoved == true {
                Text("removed").font(.caption2.weight(.semibold)).foregroundStyle(.red)
            }
            Spacer(minLength: 4)
            if let added = node.added, node.kind != .dependent {
                Text("+\(added)").font(.caption.monospacedDigit()).foregroundStyle(.green)
                Text("−\(node.removed ?? 0)").font(.caption.monospacedDigit()).foregroundStyle(.red)
            }
            if node.kind == .project, let uses = node.consumers {
                Text("\(uses.count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    .help("\(uses.count) use\(uses.count == 1 ? "" : "s") of the change's boundaries")
            }
            if node.breaks == true {
                Image(systemName: "bolt.horizontal.fill").font(.caption).foregroundStyle(.red).help("This change breaks it")
            }
            if let severity = node.severity {
                Circle().fill(severity.color).frame(width: 8, height: 8).help("Worst finding: \(severity.rawValue)")
            }
        }
        .padding(.horizontal, 7).padding(.vertical, 4)
        .background(background(node), in: RoundedRectangle(cornerRadius: 6))
        .overlay {
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(lit ? Color.accentColor : Color.secondary.opacity(node.kind == .dependent ? 0.25 : 0.35),
                              style: StrokeStyle(lineWidth: lit ? 1.5 : 1, dash: node.kind == .dependent ? [3, 3] : []))
        }
        .opacity(node.kind == .dependent ? 0.6 : 1)
        .contentShape(Rectangle())
        .onTapGesture { toggleSelection(node.id) }
        .onHover { inside in hovered = inside ? node.id : (hovered == node.id ? nil : hovered) }
        .anchorPreference(key: MapAnchors.self, value: .bounds) { [node.id: $0] }
        .help(node.boundary.map { "\($0.name)\n\($0.file)" } ?? node.path ?? node.label)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { toggleSelection(node.id) }
    }

    /// A click on a node opens its inspector; a second one closes it.
    private func toggleSelection(_ id: String) { selected = selected == id ? nil : id }

    /// Over this many characters a file's path shows its name on the first line and its folder below.
    static let longPath = 24

    /// A file's path (under a module, relative to it): a long one as its name in full and its folder
    /// in secondary text. Modules, boundaries and projects wrap to three lines.
    @ViewBuilder private func title(_ node: ReviewMap.Node) -> some View {
        let label = node.boundary?.name ?? node.label
        let slash = label.lastIndex(of: "/")
        if [.file, .dependent, .consumer].contains(node.kind), label.count > Self.longPath, let slash, slash != label.startIndex {
            VStack(alignment: .leading, spacing: 1) {
                Text(label[label.index(after: slash)...]).font(.callout).lineLimit(1).truncationMode(.middle)
                Text(label[..<slash]).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
            }
        } else {
            Text(label)
                .font(node.kind == .module || node.kind == .project ? .callout.weight(.medium) : .callout)
                .strikethrough(node.boundary?.isRemoved == true)
                .lineLimit(3)
                .truncationMode(.middle)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func background(_ node: ReviewMap.Node) -> Color {
        switch node.kind {
        case .module, .project: Color.secondary.opacity(0.1)
        case .boundary: Color.accentColor.opacity(0.08)
        default: Color(nsColor: .controlBackgroundColor)
        }
    }

    private func symbol(_ node: ReviewMap.Node) -> String? {
        switch node.kind {
        case .module: return "folder"
        case .project: return "shippingbox"
        case .file, .dependent, .consumer: return nil
        case .boundary:
            guard let boundary = node.boundary else { return "square.dashed" }
            switch boundary.kind {
            case .httpAPI: return "arrow.left.arrow.right"
            case .graphql: return "point.3.connected.trianglepath.dotted"
            case .mfe: return "square.grid.2x2"
            case .sharedLib: return "books.vertical"
            case .event: return "dot.radiowaves.right"
            case .dbSchema: return "cylinder"
            case .infra: return "server.rack"
            case .ci: return "gearshape.2"
            case .config: return "slider.horizontal.3"
            }
        }
    }

    // MARK: - Lines

    private func draw(in context: inout GraphicsContext, anchors: [String: Anchor<CGRect>], proxy: GeometryProxy) {
        let focus = hovered ?? selected
        var drawn = Set<String>()
        for edge in map.edges {
            guard let from = shown(edge.from), let to = shown(edge.to), from != to, let a = anchors[from], let b = anchors[to] else { continue }
            let key = "\(from)→\(to)"
            guard drawn.insert(key).inserted else { continue }
            let start = proxy[a]
            let end = proxy[b]
            let lit = focus != nil && (focus == from || focus == to || focus == edge.from || focus == edge.to)
            var path = Path()
            if edge.kind == .imports {
                // Inside the first lane: an arc on its left side.
                let p = CGPoint(x: start.minX, y: start.midY)
                let q = CGPoint(x: end.minX, y: end.midY)
                let bulge = min(40, 8 + abs(q.y - p.y) / 6)
                path.move(to: p)
                path.addCurve(to: q, control1: CGPoint(x: p.x - bulge, y: p.y), control2: CGPoint(x: q.x - bulge, y: q.y))
            } else {
                let p = CGPoint(x: start.maxX, y: start.midY)
                let q = CGPoint(x: end.minX, y: end.midY)
                let mid = (p.x + q.x) / 2
                path.move(to: p)
                path.addCurve(to: q, control1: CGPoint(x: mid, y: p.y), control2: CGPoint(x: mid, y: q.y))
            }
            let color: Color = edge.breaks == true ? .red : lit ? .accentColor : .secondary
            let faded = focus != nil && !lit
            context.stroke(path, with: .color(color.opacity(faded ? 0.15 : lit ? 0.95 : 0.45)),
                           style: StrokeStyle(lineWidth: lit ? 2 : 1.2, dash: edge.kind == .imports ? [3, 3] : []))
        }
    }
}

/// Where each node is drawn, for the lines.
private struct MapAnchors: PreferenceKey {
    static let defaultValue: [String: Anchor<CGRect>] = [:]
    static func reduce(value: inout [String: Anchor<CGRect>], nextValue: () -> [String: Anchor<CGRect>]) {
        value.merge(nextValue()) { $1 }
    }
}

/// The selected node: its files and changed lines, the findings on them, a boundary's quote, a
/// use's quote, why it breaks, and its GitLab link.
private struct ReviewMapInspector: View {
    let node: ReviewMap.Node
    let map: ReviewMap
    let run: ReviewWorkflow.Run
    let showFinding: (String) -> Void
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                Button("Close", systemImage: "xmark") { close() }
                    .labelStyle(.iconOnly).buttonStyle(.borderless)
                    .help("Close this panel")
            }
            Text(node.boundary?.name ?? node.path ?? node.label).font(.callout.weight(.medium)).textSelection(.enabled)
            content
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.3)))
    }

    private var title: String {
        switch node.kind {
        case .module: "MODULE"
        case .file: "CHANGED FILE"
        case .dependent: "IMPORTS THE CHANGE"
        case .boundary: "BOUNDARY"
        case .project: "OTHER REPOSITORY"
        case .consumer: "A FILE THAT USES IT"
        }
    }

    @ViewBuilder private var content: some View {
        switch node.kind {
        case .module:
            counts(node)
            ForEach(Array(map.nodes.filter { $0.parent == node.id }.enumerated()), id: \.offset) { _, file in
                HStack {
                    Text(file.label).font(.caption.monospaced()).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    if let severity = file.severity { Circle().fill(severity.color).frame(width: 7, height: 7) }
                    Text("+\(file.added ?? 0) −\(file.removed ?? 0)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            findings
        case .file:
            HStack {
                counts(node)
                if let status = node.status, status != "modified" { Text(status).font(.caption).foregroundStyle(.secondary) }
            }
            findings
            changedLines
        case .dependent:
            Text("Unchanged, imports:").font(.caption).foregroundStyle(.secondary)
            ForEach(Array(map.edges.filter { $0.from == node.id }.map(\.to).enumerated()), id: \.offset) { _, target in
                Text(target.replacingOccurrences(of: "file:", with: "")).font(.caption.monospaced())
            }
        case .boundary:
            if let boundary = node.boundary { boundaryDetails(boundary) }
        case .project, .consumer:
            ForEach(Array((node.consumers ?? []).enumerated()), id: \.offset) { _, use in useDetails(use) }
        }
    }

    private func counts(_ node: ReviewMap.Node) -> some View {
        HStack(spacing: 6) {
            Text("+\(node.added ?? 0)").foregroundStyle(.green)
            Text("−\(node.removed ?? 0)").foregroundStyle(.red)
            Text("lines").foregroundStyle(.secondary)
        }
        .font(.caption.monospacedDigit())
    }

    @ViewBuilder private var findings: some View {
        let found = (node.findings ?? []).compactMap { run.finding($0) }
        if !found.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("Findings").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                ForEach(Array(found.enumerated()), id: \.offset) { _, finding in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 5) {
                            Circle().fill(finding.finalSeverity.color).frame(width: 7, height: 7)
                            Text(finding.title).font(.caption).lineLimit(3)
                        }
                        HStack {
                            Text("\(finding.role) · \(finding.finalSeverity.rawValue)" + (finding.line.map { " · line \($0)" } ?? ""))
                                .font(.caption2).foregroundStyle(.secondary)
                            Spacer()
                            let request = run.plan?.requests.first { $0.findingID == finding.id }
                            Button("Show Request") { showFinding(finding.id) }
                                .buttonStyle(.link).font(.caption2)
                                .disabled(request == nil)
                                .help(request == nil ? "No request goes to GitLab for it (Only in AKit, a question or a matrix row)" : "Go to its request")
                        }
                    }
                }
            }
        }
    }

    /// The file's diff from the gathered snapshot, at most 120 lines.
    @ViewBuilder private var changedLines: some View {
        if let diff = run.snapshot?.diffs.first(where: { $0.newPath == node.path })?.diff, !diff.isEmpty {
            let lines = diff.split(separator: "\n", omittingEmptySubsequences: false).prefix(120)
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    Text(String(line)).font(.caption2.monospaced())
                        .foregroundStyle(line.hasPrefix("+") ? .green : line.hasPrefix("-") ? .red : line.hasPrefix("@@") ? .blue : .secondary)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .textSelection(.enabled)
            .padding(6)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
        }
    }

    @ViewBuilder private func boundaryDetails(_ boundary: ReviewBoundary) -> some View {
        Text("\(boundary.direction == .provides ? "Provides" : "Uses") · \(boundary.kind.rawValue)"
             + (boundary.isRemoved ? " · removed by this change: its users break" : ""))
            .font(.caption).foregroundStyle(boundary.isRemoved ? .red : .secondary)
        Text(boundary.file + (boundary.line.map { ":\($0)" } ?? "")).font(.caption.monospaced()).textSelection(.enabled)
        quote(boundary.quote)
        if !boundary.note.isEmpty { Text(boundary.note).font(.caption).textSelection(.enabled) }
        let uses = map.edges.filter { $0.from == node.id && $0.kind == .usedBy }
        Text(uses.isEmpty ? "No uses found in other repositories." : "\(uses.count) file\(uses.count == 1 ? "" : "s") in other repositories use it.")
            .font(.caption).foregroundStyle(.secondary)
    }

    @ViewBuilder private func useDetails(_ use: ReviewConsumer) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(use.file + (use.line.map { ":\($0)" } ?? "") + (use.ref.map { " @ \($0)" } ?? ""))
                .font(.caption.monospaced()).textSelection(.enabled)
            if let boundary = map.nodes.first(where: { $0.id == "boundary:\(use.boundary)" })?.boundary {
                Text("Uses \(boundary.name)").font(.caption).foregroundStyle(.secondary)
            }
            if !use.usage.isEmpty { Text(use.usage).font(.caption).textSelection(.enabled) }
            if use.breaks {
                Label("Breaks" + (use.why.isEmpty ? "" : ": \(use.why)"), systemImage: "bolt.horizontal.fill")
                    .font(.caption).foregroundStyle(.red).textSelection(.enabled)
            } else if !use.why.isEmpty {
                Text(use.why).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
            quote(use.quote)
            if let url = gitLabLink(use.url) {
                Link("Open in GitLab", destination: url).font(.caption)
            }
        }
        .padding(.bottom, 4)
    }

    /// A use's link, only http/https on the run's own GitLab (its merge request's host and port).
    private func gitLabLink(_ link: String?) -> URL? {
        guard let link, let url = URL(string: link), ["http", "https"].contains(url.scheme?.lowercased()),
              let own = URL(string: run.spec.mergeRequest.host), let host = url.host()?.lowercased(), !host.isEmpty,
              host == own.host()?.lowercased(), url.port == own.port else { return nil }
        return url
    }

    private func quote(_ text: String) -> some View {
        Text(text).font(.caption.monospaced()).textSelection(.enabled)
            .padding(6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
    }
}
