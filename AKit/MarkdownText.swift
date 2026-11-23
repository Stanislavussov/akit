import AKitFoundation
import AppKit
import SwiftUI

/// Markdown drawn for the eye (a review comment, a summary, a model's answer): headings, lists,
/// tables, code with a header, quotes; bold, italics, inline code and links inside. Never the raw
/// `**`, `###` or `|`. Links stay clickable only for http and https.
///
/// A note (`NoteReadView`) asks for more: bigger headings with scroll ids, Mermaid fences drawn as
/// diagrams, and its own inline text (wiki links, greyed links).
struct MarkdownText: View {
    let text: String
    var font: Font = .callout
    /// Headings a size up, for a page of its own (a note) rather than a box.
    var large = false
    /// ```` ```mermaid ```` fences drawn as diagrams.
    var diagrams = false
    /// The scroll id of a heading, to scroll to it.
    var headingID: ((String) -> String)?
    /// Inline text other than `inline(_:)`.
    var inlineText: ((String) -> AttributedString)?

    /// Find in a note: its matches marked, the current one brighter, with the scroll id
    /// `TextMarks.currentID` on its block.
    var marks: TextMarks?

    var body: some View {
        let blocks = MarkdownBlock.parse(text)
        let drawn = drawn(blocks)
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { index, block in
                view(block, drawn[index].texts)
                    .overlay(alignment: .topLeading) {
                        if drawn[index].current { Color.clear.frame(width: 1, height: 1).id(TextMarks.currentID) }
                    }
            }
        }
        .font(font)
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
    }

    /// How many matches of `query` the text shows, as Find counts them (not in the Markdown's marks
    /// or a link's target).
    func matches(of query: String) -> Int {
        MarkdownBlock.parse(text).reduce(0) { sum, block in
            sum + texts(block).reduce(0) { $0 + TextFind.ranges(of: query, in: $1).count }
        }
    }

    /// Each block's texts with Find's marks, and whether the current match is in it.
    private func drawn(_ blocks: [MarkdownBlock]) -> [(texts: [AttributedString], current: Bool)] {
        var ordinal = 0
        return blocks.map { block in
            let start = ordinal
            let texts = texts(block).map { text in
                guard let marks else { return text }
                var text = text
                ordinal += marks.shifted(by: ordinal).mark(&text)
                return text
            }
            let current = marks?.current.map { $0 >= start && $0 < ordinal } ?? false
            return (texts, current)
        }
    }

    /// The texts a block shows, in reading order: a callout's title and body, a table's cells row by
    /// row (the header first, short rows filled with ""). A rule and a diagram show none.
    private func texts(_ block: MarkdownBlock) -> [AttributedString] {
        switch block {
        case .heading(_, let text), .paragraph(let text), .small(let text), .bullet(_, let text), .numbered(_, _, let text):
            return [inline(text)]
        case .quote(let text):
            let callout = Self.callout(text)
            let body = callout?.body ?? text
            return (callout.map { [inline($0.title)] } ?? []) + (body.isEmpty ? [] : [inline(body)])
        case .code(let language, let text):
            return diagrams && language.lowercased() == "mermaid" ? [] : [AttributedString(text)]
        case .table(let header, let rows):
            let columns = max(header.count, rows.map(\.count).max() ?? 0)
            return ([header] + rows).flatMap { row in (0..<columns).map { inline($0 < row.count ? row[$0] : "") } }
        case .rule:
            return []
        }
    }

    @ViewBuilder private func view(_ block: MarkdownBlock, _ texts: [AttributedString]) -> some View {
        switch block {
        case .heading(let level, let text):
            Text(texts[0])
                .font(headingFont(level))
                .padding(.top, large ? (level == 1 ? 2 : 8) : 4)
                .id(headingID?(text) ?? "")
        case .paragraph:
            Text(texts[0])
        case .small:
            Text(texts[0]).font(.caption).foregroundStyle(.secondary)
        case .bullet(let level, _):
            item(level == 0 ? "•" : "◦", texts[0], level: level)
        case .numbered(let number, let level, _):
            item(number, texts[0], level: level)
        case .quote(let text):
            quote(text, texts)
        case .code(let language, let text):
            if diagrams, language.lowercased() == "mermaid" {
                MarkdownMermaid(source: text)
            } else {
                code(language, texts[0])
            }
        case .table(let header, let rows):
            table(columns: max(header.count, rows.map(\.count).max() ?? 0), rows: rows.count, texts)
        case .rule:
            Divider()
        }
    }

    private func headingFont(_ level: Int) -> Font {
        if large {
            return level <= 1 ? .title2.bold() : level == 2 ? .title3.bold() : level == 3 ? .headline : .subheadline.bold()
        }
        return level <= 1 ? .title3.weight(.semibold) : level == 2 ? .headline : .subheadline.weight(.semibold)
    }

    private func inline(_ text: String) -> AttributedString { inlineText?(text) ?? Self.inline(text) }

    private func item(_ mark: String, _ text: AttributedString, level: Int) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(mark).foregroundStyle(.secondary).frame(minWidth: 14, alignment: .trailing)
            Text(text)
        }
        .padding(.leading, CGFloat(level) * 18)
    }

    /// A quote; an Obsidian callout (`> [!note] Title`) gets its kind or title in bold on top.
    /// `texts`: the title's and the body's, as `texts(_:)` gives them.
    private func quote(_ text: String, _ texts: [AttributedString]) -> some View {
        let callout = Self.callout(text)
        return VStack(alignment: .leading, spacing: 2) {
            if callout != nil { Text(texts[0]).fontWeight(.semibold) }
            if let body = texts.dropFirst(callout == nil ? 0 : 1).first { Text(body) }
        }
        .foregroundStyle(callout == nil ? .secondary : .primary)
        .padding(.leading, 10)
        .padding(.vertical, callout == nil ? 0 : 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(callout == nil ? Color.clear : Color.accentColor.opacity(0.07))
        .overlay(alignment: .leading) { Rectangle().fill(callout == nil ? AnyShapeStyle(.tertiary) : AnyShapeStyle(Color.accentColor.opacity(0.6))).frame(width: 3) }
    }

    /// `[!warning] Mind the cache\nbody` → ("Mind the cache", "body"); no title → the kind, capitalised.
    static func callout(_ text: String) -> (title: String, body: String)? {
        guard let match = text.prefixMatch(of: /\[!([A-Za-z-]+)\][+-]?[ \t]*([^\n]*)\n?/) else { return nil }
        let title = match.output.2.trimmingCharacters(in: .whitespaces)
        return (title.isEmpty ? match.output.1.capitalized : title, String(text[match.range.upperBound...]))
    }

    private func code(_ language: String, _ text: AttributedString) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if !language.isEmpty {
                // GitLab shows a `suggestion` block as a change the author can apply.
                Text(language == "suggestion" ? "Suggested change" : language)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary.opacity(0.8))
            }
            Text(text)
                .font(.system(size: 12, design: .monospaced))
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(language == "suggestion" ? Color.green.opacity(0.08) : Color.secondary.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(.separator))
    }

    /// `texts`: the cells row by row, the header first.
    private func table(columns: Int, rows: Int, _ texts: [AttributedString]) -> some View {
        Grid(alignment: .topLeading, horizontalSpacing: 12, verticalSpacing: 6) {
            GridRow {
                ForEach(0..<columns, id: \.self) { column in
                    Text(texts[column]).fontWeight(.semibold)
                }
            }
            Divider().gridCellUnsizedAxes(.horizontal)
            ForEach(1..<(rows + 1), id: \.self) { row in
                GridRow {
                    ForEach(0..<columns, id: \.self) { column in
                        Text(texts[row * columns + column])
                    }
                }
            }
        }
        .padding(8)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 6))
    }

    /// Bold, italics, inline code and links; the line breaks the text has.
    static func inline(_ text: String) -> AttributedString {
        guard var attributed = try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))
        else { return AttributedString(text) }
        for run in attributed.runs {
            if let link = run.link, !["http", "https"].contains(link.scheme?.lowercased() ?? "") { attributed[run.range].link = nil }
            // Inline code: monospaced on a light background, as GitLab shows it.
            if run.inlinePresentationIntent?.contains(.code) == true {
                attributed[run.range].font = .system(.callout, design: .monospaced)
                attributed[run.range].backgroundColor = Color.secondary.opacity(0.12)
            }
        }
        return attributed
    }
}

/// A Mermaid fence in Markdown: the diagram, with Open Larger and Copy Mermaid.
struct MarkdownMermaid: View {
    let source: String
    @State private var showLarge = false

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            HStack(spacing: 6) {
                Button("Open Larger", systemImage: "arrow.up.left.and.arrow.down.right") { showLarge = true }
                    .help("Open the diagram in a large sheet with zoom")
                Button("Copy Mermaid", systemImage: "doc.on.doc") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(source, forType: .string)
                }
                .help("Copy the diagram's Mermaid source")
            }
            .controlSize(.small)
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            MermaidView(source: source)
        }
        .sheet(isPresented: $showLarge) { MermaidLargeView(title: "Diagram", source: source) }
    }
}

/// What Find marks in a drawn text: every match of `query` on a yellow ground, the current one on
/// an orange one. `current` counts matches from this text's first; a text further down a note gets
/// it `shifted` by the matches above it.
struct TextMarks: Equatable {
    var query: String
    var current: Int?

    /// The scroll id of the block that holds the current match.
    static let currentID = "find:current"

    func shifted(by count: Int) -> TextMarks { TextMarks(query: query, current: current.map { $0 - count }) }

    /// Marks the matches in `text`; returns how many there are.
    @discardableResult
    func mark(_ text: inout AttributedString) -> Int {
        let ranges = TextFind.ranges(of: query, in: text)
        for (index, range) in ranges.enumerated() {
            text[range].backgroundColor = index == current ? Color.orange : Color.yellow.opacity(0.45)
            // Dark text on the marks in Dark Mode too, as Safari's Find shows it.
            text[range].foregroundColor = Color.black
        }
        return ranges.count
    }
}
