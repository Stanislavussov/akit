import AKitFoundation
import SwiftUI

/// Markdown drawn for the eye (a review comment, a summary, a model's answer): headings, lists,
/// tables, code with a header, quotes; bold, italics, inline code and links inside. Never the raw
/// `**`, `###` or `|`. Links stay clickable only for http and https.
struct MarkdownText: View {
    let text: String
    var font: Font = .callout

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
            Text(Self.inline(text))
                .font(level <= 1 ? .title3.weight(.semibold) : level == 2 ? .headline : .subheadline.weight(.semibold))
                .padding(.top, 4)
        case .paragraph(let text):
            Text(Self.inline(text))
        case .small(let text):
            Text(Self.inline(text)).font(.caption).foregroundStyle(.secondary)
        case .bullet(let level, let text):
            item(level == 0 ? "•" : "◦", text, level: level)
        case .numbered(let number, let level, let text):
            item(number, text, level: level)
        case .quote(let text):
            Text(Self.inline(text))
                .foregroundStyle(.secondary)
                .padding(.leading, 10)
                .overlay(alignment: .leading) { Rectangle().fill(.tertiary).frame(width: 3) }
        case .code(let language, let text):
            code(language, text)
        case .table(let header, let rows):
            table(header, rows)
        case .rule:
            Divider()
        }
    }

    private func item(_ mark: String, _ text: String, level: Int) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(mark).foregroundStyle(.secondary).frame(minWidth: 14, alignment: .trailing)
            Text(Self.inline(text))
        }
        .padding(.leading, CGFloat(level) * 18)
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
                    Text(Self.inline(column < header.count ? header[column] : "")).fontWeight(.semibold)
                }
            }
            Divider().gridCellUnsizedAxes(.horizontal)
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                GridRow {
                    ForEach(0..<columns, id: \.self) { column in
                        Text(Self.inline(column < row.count ? row[column] : ""))
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
