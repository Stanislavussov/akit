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

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(MarkdownBlock.parse(text).enumerated()), id: \.offset) { _, block in
                view(block)
            }
        }
        .font(font)
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder private func view(_ block: MarkdownBlock) -> some View {
        switch block {
        case .heading(let level, let text):
            Text(inline(text))
                .font(headingFont(level))
                .padding(.top, large ? (level == 1 ? 2 : 8) : 4)
                .id(headingID?(text) ?? "")
        case .paragraph(let text):
            Text(inline(text))
        case .small(let text):
            Text(inline(text)).font(.caption).foregroundStyle(.secondary)
        case .bullet(let level, let text):
            item(level == 0 ? "•" : "◦", text, level: level)
        case .numbered(let number, let level, let text):
            item(number, text, level: level)
        case .quote(let text):
            quote(text)
        case .code(let language, let text):
            if diagrams, language.lowercased() == "mermaid" {
                MarkdownMermaid(source: text)
            } else {
                code(language, text)
            }
        case .table(let header, let rows):
            table(header, rows)
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

    private func item(_ mark: String, _ text: String, level: Int) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(mark).foregroundStyle(.secondary).frame(minWidth: 14, alignment: .trailing)
            Text(inline(text))
        }
        .padding(.leading, CGFloat(level) * 18)
    }

    /// A quote; an Obsidian callout (`> [!note] Title`) gets its kind or title in bold on top.
    private func quote(_ text: String) -> some View {
        let callout = Self.callout(text)
        let body = callout?.body ?? text
        return VStack(alignment: .leading, spacing: 2) {
            if let title = callout?.title { Text(inline(title)).fontWeight(.semibold) }
            if !body.isEmpty { Text(inline(body)) }
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

    private func code(_ language: String, _ text: String) -> some View {
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

    private func table(_ header: [String], _ rows: [[String]]) -> some View {
        let columns = max(header.count, rows.map(\.count).max() ?? 0)
        return Grid(alignment: .topLeading, horizontalSpacing: 12, verticalSpacing: 6) {
            GridRow {
                ForEach(0..<columns, id: \.self) { column in
                    Text(inline(column < header.count ? header[column] : "")).fontWeight(.semibold)
                }
            }
            Divider().gridCellUnsizedAxes(.horizontal)
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                GridRow {
                    ForEach(0..<columns, id: \.self) { column in
                        Text(inline(column < row.count ? row[column] : ""))
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
