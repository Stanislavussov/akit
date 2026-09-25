import SwiftUI

/// A collapsed block with a one-line preview.
struct Collapsible: View {
    let title: String
    let icon: String
    let tint: Color
    let text: String
    let monospaced: Bool
    var startsExpanded = false
    @State private var expanded: Bool?

    var body: some View {
        DisclosureGroup(isExpanded: Binding(get: { expanded ?? startsExpanded }, set: { expanded = $0 })) {
            LongText(text: text, monospaced: monospaced)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
        } label: {
            HStack(spacing: 6) {
                Label(title, systemImage: icon).foregroundStyle(tint).fontWeight(.medium)
                if !(expanded ?? startsExpanded) {
                    Text(PreviewLine.line(text))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            .font(.callout)
        }
    }
}

enum PreviewLine {
    static func line(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline).lazy
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty && $0 != "{" } ?? ""
    }
}

/// Selectable text; very long texts show their start and a button for the rest.
struct LongText: View {
    let text: String
    var monospaced = false
    var limit = 4_000
    @State private var showAll = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(showAll || text.count <= limit ? text : String(text.prefix(limit)) + "…")
                .font(monospaced ? .system(.callout, design: .monospaced) : .body)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            if text.count > limit {
                Button(showAll ? "Show less" : "Show all (\(text.count.formatted()) characters)") { showAll.toggle() }
                    .buttonStyle(.link)
                    .font(.caption)
            }
        }
    }
}
