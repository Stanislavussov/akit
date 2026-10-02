import AKitFoundation
import SwiftUI

/// The in-app guides: `docs/guides/<name>.ru.md`, copied into the app's `guides` folder.
enum Guide: String, CaseIterable {
    case screens
    case errorAnalysis = "error-analysis"

    var title: String {
        switch self {
        case .screens: "AKit Screens"
        case .errorAnalysis: "Error Analysis"
        }
    }

    func load() -> GuideDocument? {
        guard let url = Bundle.main.url(forResource: "\(rawValue).ru", withExtension: "md", subdirectory: "guides"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return GuideDocument.parse(text)
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
    }
}

/// A guide as collapsible sections: the requested one open and scrolled to, a search
/// field that keeps only the sections that mention the text.
struct GuideView: View {
    static let windowID = "guide"

    @Environment(GuideNavigator.self) private var navigator
    @State private var document: GuideDocument?
    @State private var expanded: Set<String> = []
    /// Snapshots: `--guide <section> --query <text>` searches.
    @State private var search = DebugSnapshot.options?.guide != nil ? DebugSnapshot.options?.query ?? "" : ""

    var body: some View {
        Group {
            if let document {
                content(document)
            } else {
                ContentUnavailableView("No guide", systemImage: "book.closed",
                                       description: Text("\(navigator.guide.rawValue).ru.md isn't in the app bundle."))
            }
        }
        .frame(minWidth: 560, minHeight: 420)
        .navigationTitle("\(navigator.guide.title) Guide")
        .searchable(text: $search, placement: .toolbar, prompt: "Search the guide")
        .toolbar {
            ToolbarItemGroup {
                Button("Expand All", systemImage: "rectangle.expand.vertical") { expandAll() }
                    .help("Open every section")
                Button("Collapse All", systemImage: "rectangle.compress.vertical") { expanded = [] }
                    .help("Close every section")
            }
        }
        .task(id: navigator.guide) { document = navigator.guide.load() }
    }

    private func content(_ document: GuideDocument) -> some View {
        let sections = search.isEmpty ? document.sections : document.sections.filter { $0.contains(search) }
        return ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if search.isEmpty {
                        Text(document.title).font(.largeTitle.bold())
                        GuideBlocks(blocks: document.intro)
                    } else if sections.isEmpty {
                        Text("Nothing mentions “\(search)”.").foregroundStyle(.secondary)
                    }
                    ForEach(sections) { section in
                        GuideSectionView(section: section, level: 0, expanded: $expanded, search: search)
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

    /// Opens the section (and its parent) and scrolls to it; without one, opens the first.
    private func open(_ id: String?, in document: GuideDocument, proxy: ScrollViewProxy) async {
        guard let id, let path = document.path(to: id) else {
            if expanded.isEmpty, let first = document.sections.first { expanded = [first.id] }
            return
        }
        // A Guide button asks for a section: show it even if a search would hide it.
        if navigator.revision > 0 { search = "" }
        expanded.formUnion(path)
        // Let the opened sections lay out before scrolling.
        try? await Task.sleep(for: .milliseconds(150))
        withAnimation { proxy.scrollTo(id, anchor: .top) }
    }

    private func expandAll() {
        guard let document else { return }
        for section in document.sections {
            expanded.insert(section.id)
            expanded.formUnion(section.subsections.map(\.id))
        }
    }
}

/// A section's header (click to open or close), its blocks and subsections.
private struct GuideSectionView: View {
    let section: GuideDocument.Section
    let level: Int
    @Binding var expanded: Set<String>
    let search: String

    private var isOpen: Bool { !search.isEmpty || expanded.contains(section.id) }

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
                    Text(section.title)
                        .font(level == 0 ? .title2.bold() : .headline)
                        .multilineTextAlignment(.leading)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .id(section.id)
            if isOpen {
                VStack(alignment: .leading, spacing: 10) {
                    GuideBlocks(blocks: section.blocks)
                    ForEach(section.subsections.filter { search.isEmpty || $0.contains(search) }) { sub in
                        GuideSectionView(section: sub, level: level + 1, expanded: $expanded, search: search)
                    }
                }
                .padding(.leading, 22)
            }
            if level == 0 { Divider().padding(.top, 4) }
        }
    }
}

/// Paragraphs, lists, callouts and code of one section.
private struct GuideBlocks: View {
    let blocks: [GuideDocument.Block]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case .paragraph(let text):
                    inline(text)
                case .bullet(let level, let text):
                    item(level == 0 ? "•" : "◦", text).padding(.leading, CGFloat(level) * 18)
                case .numbered(let number, let text):
                    item("\(number).", text)
                case .callout(let text):
                    GuideCallout(text: text)
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
            inline(text)
        }
    }
}

/// A `> ` block: a tip, a warning or a reason, by its first bold word.
private struct GuideCallout: View {
    let text: String

    var body: some View {
        let (icon, tint): (String, Color) =
            if text.hasPrefix("**Важно") { ("exclamationmark.triangle.fill", .orange) }
            else if text.hasPrefix("**Почему") { ("questionmark.circle.fill", .purple) }
            else { ("lightbulb.fill", .blue) }
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: icon).foregroundStyle(tint)
            inline(text)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
        .overlay(alignment: .leading) { Rectangle().fill(tint).frame(width: 3) }
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

/// Inline Markdown (bold, italic, code); the raw text if it doesn't parse.
private func inline(_ text: String) -> some View {
    var attributed = (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
        ?? AttributedString(text)
    // Commands, file names and button names in backticks: monospaced and tinted.
    for run in attributed.runs where run.inlinePresentationIntent?.contains(.code) == true {
        attributed[run.range].font = .system(size: 13, design: .monospaced)
        attributed[run.range].foregroundColor = .accentColor
    }
    return Text(attributed)
        .lineSpacing(3)
        .fixedSize(horizontal: false, vertical: true)
}
