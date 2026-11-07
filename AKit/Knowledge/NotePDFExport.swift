import AKitKnowledge
import AppKit
import SwiftUI

/// Export PDF…: one note as an A4 PDF, drawn like the read view (fields table, then the Markdown)
/// in light colours. Mermaid diagrams stay as their source: the diagram view is a web view, which
/// a PDF render can't draw.
@MainActor
enum NotePDFExport {
    static let page = CGSize(width: 595, height: 842)
    static let margin: CGFloat = 40

    /// Asks where to save, then writes the PDF. Returns the file, nil when cancelled.
    static func export(title: String, text: String) throws -> URL? {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = fileName(title) + ".pdf"
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        try pdf(title: title, text: text).write(to: url, options: .atomic)
        return url
    }

    /// A file name without the characters Finder doesn't like.
    static func fileName(_ title: String) -> String {
        let cleaned = title.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "Note" : cleaned
    }

    /// The note cut into A4 pages.
    static func pdf(title: String, text: String) throws -> Data {
        let width = page.width - 2 * margin
        let height = page.height - 2 * margin
        let renderer = ImageRenderer(content: NotePrintView(title: title, text: text).frame(width: width))
        renderer.proposedSize = ProposedViewSize(width: width, height: nil)
        let data = NSMutableData()
        var failure: Error?
        renderer.render { size, draw in
            var box = CGRect(origin: .zero, size: page)
            guard let consumer = CGDataConsumer(data: data as CFMutableData),
                  let context = CGContext(consumer: consumer, mediaBox: &box, nil) else {
                failure = Failure(message: "AKit couldn't start a PDF.")
                return
            }
            let pages = max(1, Int((size.height / height).rounded(.up)))
            for index in 0..<pages {
                context.beginPDFPage(nil)
                context.saveGState()
                context.clip(to: CGRect(x: margin, y: margin, width: width, height: height))
                // The part of the note from index × height down, at the top of the page.
                context.translateBy(x: margin, y: margin + height - size.height + CGFloat(index) * height)
                draw(context)
                context.restoreGState()
                context.endPDFPage()
            }
            context.closePDF()
        }
        if let failure { throw failure }
        return data as Data
    }

    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }
}

/// The note as printed: title, fields, then the Markdown; no buttons, links not greyed.
private struct NotePrintView: View {
    let title: String
    let text: String

    var body: some View {
        let note = KnowledgeNote(text: text)
        VStack(alignment: .leading, spacing: 10) {
            // A note that opens with its own `# Heading` has its title already.
            if !note.body.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("# ") {
                Text(title).font(.title.bold())
            }
            let front = note.frontmatter.sorted { $0.key < $1.key }
            if !front.isEmpty {
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 3) {
                    ForEach(front, id: \.key) { key, value in
                        GridRow {
                            Text(key).foregroundStyle(.secondary)
                            Text(NoteReadView.describe(value))
                        }
                    }
                }
                .font(.callout)
                .padding(8)
                .background(Color.gray.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
            }
            ForEach(Array(NoteReadView.chunks(note).enumerated()), id: \.offset) { _, chunk in
                MarkdownText(text: chunk, font: .body, large: true, inlineText: { NoteReadView.inline($0) })
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .environment(\.colorScheme, .light)
        .foregroundStyle(.black)
    }
}
