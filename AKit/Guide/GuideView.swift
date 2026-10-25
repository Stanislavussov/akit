import AKitFoundation
import SwiftUI

/// The in-app guides: `docs/guides/<name>.ru.md`, copied into the app's `guides` folder.
enum Guide: String, CaseIterable {
    case screens
    case errorAnalysis = "error-analysis"
    /// The glossary: every label of the screens. Ask AKit reads it first (`AskAKit.glossaryGuide`).
    case terms
    case review
    case knowledge
    case notebook

    var title: String {
        switch self {
        case .screens: "AKit Screens"
        case .errorAnalysis: "Error Analysis"
        case .terms: "AKit Terms"
        case .review: "AKit Review"
        case .knowledge: "Knowledge Base"
        case .notebook: "Notebook"
        }
    }

    func load() -> GuideDocument? {
        guard let url = Bundle.main.url(forResource: "\(rawValue).ru", withExtension: "md", subdirectory: "guides"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return GuideDocument.parse(text)
    }

    /// A screenshot named in a guide (`images/<name>.png`), from the bundle's guides folder.
    static func imageURL(_ path: String) -> URL? {
        guard !path.contains(".."), let folder = Bundle.main.resourceURL?.appending(path: "guides") else { return nil }
        let url = folder.appending(path: path)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    @MainActor private static let images = NSCache<NSString, NSImage>()

    /// The screenshot, read from disk once.
    @MainActor static func image(_ path: String) -> NSImage? {
        if let image = images.object(forKey: path as NSString) { return image }
        guard let url = imageURL(path), let image = NSImage(contentsOf: url) else { return nil }
        images.setObject(image, forKey: path as NSString)
        return image
    }

    /// One search over every guide and every screen of the app.
    static func searchIndex(_ documents: [Guide: GuideDocument]) -> GuideSearch {
        GuideSearch(guides: allCases.compactMap { guide in documents[guide].map { (guide.rawValue, guide.title, $0) } },
                    features: SidebarSection.allCases.map {
                        .init(id: $0.rawValue, title: $0.title, summary: $0.summary, guide: Guide.screens.rawValue, section: $0.rawValue)
                    })
    }
}

/// Which guide the Guide window shows and the section to open. One window serves every
/// screen: a Guide button sets the request and brings the window forward.
@MainActor @Observable
final class GuideNavigator {
    var guide: Guide = .errorAnalysis
    var section: String?
    /// Counts requests, so asking for the same section again scrolls back to it.
    private(set) var revision = 0
    /// Counts Help → Search Guides and Screens…: the window puts the cursor in its search field.
    private(set) var searchRequests = 0
    /// Set until the window has taken the request: the first one comes before the window exists.
    var wantsSearch = false

    /// Snapshots: `--guide <section>` opens the Error Analysis guide, `--guide screens:<section>`
    /// another one.
    init() {
        guard var id = DebugSnapshot.options?.guide else { return }
        if let colon = id.firstIndex(of: ":"), let named = Guide(rawValue: String(id[..<colon])) {
            guide = named
            id = String(id[id.index(after: colon)...])
        }
        section = id.isEmpty ? nil : id
    }

    func show(_ guide: Guide, section: String?) {
        self.guide = guide
        self.section = section
        revision += 1
    }

    func focusSearch() {
        wantsSearch = true
        searchRequests += 1
    }
}

/// A toolbar or inline button that opens a guide at a section.
struct GuideButton: View {
    @Environment(GuideNavigator.self) private var navigator
    @Environment(\.openWindow) private var openWindow
    let guide: Guide
    var section: String?
    var title = "Guide"
    var help = "How this screen works, button by button (in Russian)"

    var body: some View {
        Button(title, systemImage: "book") {
            navigator.show(guide, section: section)
            openWindow(id: GuideView.windowID)
        }
        // A word, not just an icon: this is the button for someone who doesn't know where to click.
        .labelStyle(.titleAndIcon)
        .help(help)
    }
}

/// The Help menu: one item per guide.
struct GuideMenuItems: View {
    @Environment(\.openWindow) private var openWindow
    let navigator: GuideNavigator

    var body: some View {
        ForEach(Guide.allCases, id: \.self) { guide in
            Button("\(guide.title) Guide") {
                navigator.show(guide, section: nil)
                openWindow(id: GuideView.windowID)
            }
        }
        Button("Search Guides and Screens…") {
            navigator.focusSearch()
            openWindow(id: GuideView.windowID)
        }
        .keyboardShortcut("f", modifiers: [.command, .option])
    }
}

/// A guide as collapsible sections, the requested one open and scrolled to. The search field
/// searches every guide and every screen at once and shows the places found; a click opens one.
struct GuideView: View {
    static let windowID = "guide"
    /// The main window's scene (AKitApp).
    static let mainWindowID = "main"
    @Environment(\.openWindow) private var openWindow

    @Environment(GuideNavigator.self) private var navigator
    @Environment(AppModel.self) private var model
    @State private var documents: [Guide: GuideDocument] = [:]
    @State private var index: GuideSearch?
    @State private var loaded = false
    /// Open sections of each guide: the guides share some section ids.
    @State private var openSections: [Guide: Set<String>] = [:]
    @State private var hits: [GuideSearch.Hit] = []
    /// The navigator's revision a clicked result made; any other request leaves the search.
    @State private var ownRevision = 0
    /// Snapshots: `--guide <section> --query <text>` searches.
    @State private var search = DebugSnapshot.options?.guide != nil ? DebugSnapshot.options?.query ?? "" : ""
    @State private var searching = false
    /// The search a result was opened from: its words stay marked, and one click goes back.
    @State private var opened: String?

    var body: some View {
        Group {
            if !search.isEmpty, index != nil {
                GuideSearchResults(query: search, hits: hits, open: open, showScreen: showScreen)
            } else if let document = documents[navigator.guide] {
                content(document)
            } else if loaded {
                ContentUnavailableView("No guide", systemImage: "book.closed",
                                       description: Text("\(navigator.guide.rawValue).ru.md isn't in the app bundle."))
            }
        }
        .frame(minWidth: 560, minHeight: 420)
        .navigationTitle("\(navigator.guide.title) Guide")
        .searchable(text: $search, isPresented: $searching, placement: .toolbar, prompt: "Search guides, screens and buttons")
        .toolbar {
            ToolbarItemGroup {
                Picker("Guide", selection: Binding(get: { navigator.guide }, set: { navigator.show($0, section: nil) })) {
                    ForEach(Guide.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .help("Which guide to read; the search looks in all of them")
                Button("Expand All", systemImage: "rectangle.expand.vertical") { expandAll() }
                    .help("Open every section")
                Button("Collapse All", systemImage: "rectangle.compress.vertical") { openSections[navigator.guide] = [] }
                    .help("Close every section")
            }
        }
        .task {
            for guide in Guide.allCases { documents[guide] = guide.load() }
            index = Guide.searchIndex(documents)
            loaded = true
            hits = index?.hits(for: search) ?? []
            takeSearchRequest()
        }
        .onChange(of: navigator.searchRequests) { takeSearchRequest() }
        .onChange(of: search) {
            if !search.isEmpty { opened = nil }
            hits = index?.hits(for: search) ?? []
        }
        // A Guide button, the Help menu or the picker asks for a place: show it, not the results.
        .onChange(of: navigator.revision) {
            guard navigator.revision != ownRevision else { return }
            search = ""
            searching = false
            opened = nil
        }
        // `[text](#id)` opens a section of this guide, `[text](error-analysis#id)` of another.
        .environment(\.openURL, OpenURLAction { url in
            guard url.scheme == nil, let section = url.fragment else { return .systemAction }
            navigator.show(Guide(rawValue: url.path) ?? navigator.guide, section: section)
            return .handled
        })
    }

    private var expanded: Binding<Set<String>> {
        Binding(get: { openSections[navigator.guide] ?? [] }, set: { openSections[navigator.guide] = $0 })
    }

    private func takeSearchRequest() {
        guard navigator.wantsSearch else { return }
        navigator.wantsSearch = false
        searching = true
    }

    private func content(_ document: GuideDocument) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let opened {
                        Button("Back to the Results for “\(opened)”", systemImage: "chevron.backward") { search = opened }
                            .buttonStyle(.link)
                            .help("Show the search results again")
                    }
                    Text(document.title).font(.largeTitle.bold())
                    GuideBlocks(blocks: document.intro, highlight: opened)
                    ForEach(document.sections) { section in
                        GuideSectionView(section: section, level: 0, expanded: expanded, highlight: opened)
                    }
                }
                .frame(maxWidth: 780, alignment: .leading)
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .task(id: "\(navigator.revision)|\(navigator.section ?? "")|\(document.title)") {
                await open(navigator.section, in: document, proxy: proxy)
            }
        }
        .font(.system(size: 14))
        .textSelection(.enabled)
    }

    /// A search result: its guide and section, with the query's words marked there.
    private func open(_ hit: GuideSearch.Hit) {
        let query = search
        search = ""
        searching = false
        opened = query
        navigator.show(Guide(rawValue: hit.guide) ?? navigator.guide, section: hit.section)
        ownRevision = navigator.revision
    }

    /// A screen found by the search: the main window shows it and comes forward.
    private func showScreen(_ id: String) {
        guard let section = SidebarSection(rawValue: id) else { return }
        model.section = section
        let guide = NSApp.keyWindow
        guard let window = NSApp.windows.first(where: {
            $0.canBecomeMain && $0 !== guide && $0.identifier?.rawValue.contains("Settings") != true && ($0.isVisible || $0.isMiniaturized)
        }) else {
            // The main window was closed: open it again, on the chosen screen.
            openWindow(id: Self.mainWindowID)
            return
        }
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
    }

    /// Opens the section (and its parents) and scrolls to it; without one, opens the first.
    private func open(_ id: String?, in document: GuideDocument, proxy: ScrollViewProxy) async {
        guard let id, let path = document.path(to: id) else {
            if expanded.wrappedValue.isEmpty, let first = document.sections.first { expanded.wrappedValue = [first.id] }
            return
        }
        expanded.wrappedValue.formUnion(path)
        // Let the opened sections lay out before scrolling; a newer request cancels this one.
        guard (try? await Task.sleep(for: .milliseconds(150))) != nil else { return }
        withAnimation { proxy.scrollTo(id, anchor: .top) }
    }

    private func expandAll() {
        var all = Set<String>()
        func add(_ section: GuideDocument.Section) {
            all.insert(section.id)
            section.subsections.forEach(add)
        }
        documents[navigator.guide]?.sections.forEach(add)
        openSections[navigator.guide] = all
    }
}

/// What a search found, best first: screens, section titles, buttons, screenshots, text.
private struct GuideSearchResults: View {
    let query: String
    let hits: [GuideSearch.Hit]
    let open: (GuideSearch.Hit) -> Void
    let showScreen: (String) -> Void

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 4) {
                Text(hits.isEmpty ? "Nothing mentions “\(query)”." : "\(hits.count == 80 ? "First 80" : "\(hits.count)") places for “\(query)”")
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 6)
                if hits.isEmpty {
                    Text("All the words must be found, each as the start of a word. Try fewer words or a button's name as on screen.")
                        .foregroundStyle(.secondary)
                }
                ForEach(hits) { hit in
                    row(hit)
                    Divider()
                }
            }
            .frame(maxWidth: 780, alignment: .leading)
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.system(size: 14))
    }

    private func row(_ hit: GuideSearch.Hit) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Button { open(hit) } label: {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: icon(hit.kind))
                        .foregroundStyle(hit.kind == .text ? Color.secondary : Color.accentColor)
                        .frame(width: 20)
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(marked(hit.title, query: query)).font(.headline).multilineTextAlignment(.leading)
                            Text(label(hit.kind)).font(.caption).foregroundStyle(.secondary)
                        }
                        if hit.kind != .heading {
                            Text(marked(hit.snippet, query: query))
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.leading)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Text(hit.breadcrumb.joined(separator: " › ")).font(.caption).foregroundStyle(.tertiary)
                    }
                    Spacer(minLength: 0)
                    if let path = hit.image, let image = Guide.image(path) {
                        Image(nsImage: image)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 150, height: 96)
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                            .overlay(RoundedRectangle(cornerRadius: 4).stroke(.quaternary))
                    }
                }
                .padding(.vertical, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Open this place in the guide")
            if let feature = hit.feature {
                Button("Open Screen", systemImage: "macwindow") { showScreen(feature) }
                    .padding(.top, 6)
                    .help("Show the \(hit.title) screen in the main window")
            }
        }
    }

    private func icon(_ kind: GuideSearch.Kind) -> String {
        switch kind {
        case .feature: "macwindow"
        case .heading: "book"
        case .button: "cursorarrow.click"
        case .screenshot: "photo"
        case .text: "text.alignleft"
        }
    }

    private func label(_ kind: GuideSearch.Kind) -> String {
        switch kind {
        case .feature: "Screen"
        case .heading: "Section"
        case .button: "Button"
        case .screenshot: "Screenshot"
        case .text: "Text"
        }
    }
}

/// A section's header (click to open or close), its blocks and subsections.
private struct GuideSectionView: View {
    let section: GuideDocument.Section
    let level: Int
    @Binding var expanded: Set<String>
    let highlight: String?

    private var isOpen: Bool { expanded.contains(section.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) {
                    if expanded.contains(section.id) { expanded.remove(section.id) } else { expanded.insert(section.id) }
                }
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: level == 0 ? 13 : 11, weight: .semibold))
                        .rotationEffect(.degrees(isOpen ? 90 : 0))
                        .foregroundStyle(.secondary)
                        .frame(width: 14)
                    Text(marked(section.title, query: highlight))
                        .font(level == 0 ? .title2.bold() : level == 1 ? .title3.bold() : .headline)
                        .multilineTextAlignment(.leading)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .id(section.id)
            if isOpen {
                VStack(alignment: .leading, spacing: 10) {
                    GuideBlocks(blocks: section.blocks, highlight: highlight)
                    ForEach(section.subsections) { sub in
                        GuideSectionView(section: sub, level: level + 1, expanded: $expanded, highlight: highlight)
                    }
                }
                .padding(.leading, 22)
            }
            if level == 0 { Divider().padding(.top, 4) }
        }
    }
}

/// Paragraphs, lists, callouts and code of one section (and of an Ask AKit answer).
struct GuideBlocks: View {
    let blocks: [GuideDocument.Block]
    let highlight: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case .paragraph(let text):
                    inline(text, highlight: highlight)
                case .bullet(let level, let text):
                    item(level == 0 ? "•" : "◦", text).padding(.leading, CGFloat(level) * 18)
                case .numbered(let number, let text):
                    item("\(number).", text)
                case .callout(let text):
                    GuideCallout(text: text, highlight: highlight)
                case .image(let path, let caption):
                    GuideImage(path: path, caption: caption, highlight: highlight)
                case .code(let text):
                    Text(text)
                        .font(.system(size: 12.5, design: .monospaced))
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 6))
                }
            }
        }
    }

    private func item(_ mark: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(mark).foregroundStyle(.secondary).frame(minWidth: 14, alignment: .trailing)
            inline(text, highlight: highlight)
        }
    }
}

/// A `> ` block: a tip, a warning or a reason, by its first bold word.
private struct GuideCallout: View {
    let text: String
    let highlight: String?

    var body: some View {
        let (icon, tint): (String, Color) =
            if text.hasPrefix("**Важно") { ("exclamationmark.triangle.fill", .orange) }
            else if text.hasPrefix("**Почему") { ("questionmark.circle.fill", .purple) }
            else { ("lightbulb.fill", .blue) }
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: icon).foregroundStyle(tint)
            inline(text, highlight: highlight)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
        .overlay(alignment: .leading) { Rectangle().fill(tint).frame(width: 3) }
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

/// A screenshot with its caption; a click opens it full size.
private struct GuideImage: View {
    let path: String
    let caption: String
    let highlight: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            if let url = Guide.imageURL(path), let image = Guide.image(path) {
                Button { NSWorkspace.shared.open(url) } label: {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: min(width(image), 720))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
                        .shadow(color: .black.opacity(0.12), radius: 5, y: 2)
                }
                .buttonStyle(.plain)
                .help("Open the screenshot full size")
            } else {
                Label("No screenshot \(path)", systemImage: "photo").foregroundStyle(.secondary)
            }
            if !caption.isEmpty {
                inline(caption, highlight: highlight).font(.system(size: 12.5)).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    /// Screenshots are saved at one pixel per point of the window they show.
    private func width(_ image: NSImage) -> CGFloat {
        CGFloat(image.representations.first?.pixelsWide ?? Int(image.size.width))
    }
}

/// `text` with the words of a search marked.
private func marked(_ text: String, query: String?) -> AttributedString {
    var attributed = AttributedString(text)
    mark(&attributed, query: query)
    return attributed
}

private func mark(_ attributed: inout AttributedString, query: String?) {
    guard let query, !query.isEmpty else { return }
    let plain = String(attributed.characters)
    for range in GuideSearch.matches(of: query, in: plain) {
        let from = attributed.index(attributed.startIndex, offsetByCharacters: plain.distance(from: plain.startIndex, to: range.lowerBound))
        let to = attributed.index(from, offsetByCharacters: plain.distance(from: range.lowerBound, to: range.upperBound))
        attributed[from..<to].backgroundColor = .yellow.opacity(0.45)
    }
}

/// Inline Markdown (bold, italic, code, links); the raw text if it doesn't parse.
private func inline(_ text: String, highlight: String? = nil) -> some View {
    var attributed = (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
        ?? AttributedString(text)
    // Commands, file names and button names in backticks: monospaced and tinted.
    for run in attributed.runs where run.inlinePresentationIntent?.contains(.code) == true {
        attributed[run.range].font = .system(size: 13, design: .monospaced)
        attributed[run.range].foregroundColor = .accentColor
    }
    mark(&attributed, query: highlight)
    return Text(attributed)
        .lineSpacing(3)
        .fixedSize(horizontal: false, vertical: true)
}
