import AKitKnowledge
import SwiftUI

/// A note's badge: its text on a tint picked from the text (`KnowledgeTag.colorIndex`), so a tag
/// has the same color everywhere.
struct TagBadge: View {
    let tag: String
    var onRemove: (() -> Void)?

    static let palette: [Color] = [.blue, .green, .orange, .pink, .purple, .teal, .red, .indigo, .brown, .mint]

    static func color(_ tag: String) -> Color { palette[KnowledgeTag.colorIndex(tag) % palette.count] }

    var body: some View {
        let tint = Self.color(tag)
        HStack(spacing: 2) {
            Text(tag).lineLimit(1)
            if let onRemove {
                Button("Remove Tag \(tag)", systemImage: "xmark", action: onRemove)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .imageScale(.small)
                    .foregroundStyle(tint)
                    .help("Take the tag \(tag) off the note")
            }
        }
        .font(.caption2.weight(.medium))
        .foregroundStyle(tint)
        .padding(.horizontal, 6)
        .padding(.vertical, 1)
        .background(tint.opacity(0.15), in: Capsule())
    }
}

/// Lays its views out in rows, starting a new row when the next one doesn't fit.
/// A note row's tags on one line: as many as fit, the rest as "+N". The list keeps a row's
/// height from before a resize, so a row whose height follows its width (tags wrapping) was drawn
/// over its neighbours; one line is always the same height.
struct TagLine: View {
    let tags: [String]

    var body: some View {
        ViewThatFits(in: .horizontal) {
            ForEach(Array(stride(from: tags.count, through: 0, by: -1)), id: \.self) { shown in
                HStack(spacing: 3) {
                    ForEach(tags.prefix(shown), id: \.self) { TagBadge(tag: $0) }
                    if shown < tags.count {
                        Text("+\(tags.count - shown)").font(.caption2).foregroundStyle(.secondary).fixedSize()
                    }
                }
                .fixedSize()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .help(tags.map { "#" + $0 }.joined(separator: " "))
    }
}

struct WrapLayout: Layout {
    var spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = rows(subviews, width: proposal.width ?? .infinity)
        let width = rows.map { $0.width }.max() ?? 0
        let height = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(rows.count - 1, 0))
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in rows(subviews, width: bounds.width) {
            var x = bounds.minX
            for index in row.items {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(width: min(size.width, bounds.width), height: size.height))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private func rows(_ subviews: Subviews, width: CGFloat) -> [(items: [Int], width: CGFloat, height: CGFloat)] {
        var rows: [(items: [Int], width: CGFloat, height: CGFloat)] = []
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            if let last = rows.last, last.width + spacing + size.width <= width {
                rows[rows.count - 1] = (last.items + [index], last.width + spacing + size.width, max(last.height, size.height))
            } else {
                rows.append(([index], min(size.width, width), size.height))
            }
        }
        return rows
    }
}

/// The note's badges in its header: each with ×, and Add Tag, which suggests the tags other
/// notes use as you type (Return adds the typed text or the first suggestion you picked).
struct NoteTagsRow: View {
    @Environment(KnowledgeModel.self) private var model
    let entry: KnowledgeBase.NoteEntry
    @State private var adding = DebugSnapshot.options?.tab == "add-tag"
    @State private var typed = DebugSnapshot.options?.tab == "add-tag" ? (DebugSnapshot.options?.query ?? "") : ""

    var body: some View {
        WrapLayout(spacing: 4) {
            ForEach(entry.tags, id: \.self) { tag in
                TagBadge(tag: tag) { model.removeTag(tag) }
            }
            Button("Add Tag", systemImage: "plus") { adding = true }
                .labelStyle(.titleAndIcon)
                .buttonStyle(.borderless)
                .font(.caption)
                .help("Put a badge on the note: any text, written as tags: in its frontmatter. Its color comes from the text; tags other notes use are suggested")
                .popover(isPresented: $adding, arrowEdge: .bottom) { addTag }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 8)
        .padding(.bottom, 6)
    }

    private var suggestions: [String] {
        Array(KnowledgeTag.suggestions(for: typed, among: model.usedTags, excluding: entry.tags).prefix(8))
    }

    private var addTag: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Tag", text: $typed, prompt: Text("on-call"))
                .textFieldStyle(.roundedBorder)
                .frame(width: 220)
                .onSubmit { if KnowledgeTag.normalize(typed) != nil { add(typed) } }
            let suggestions = suggestions
            if !suggestions.isEmpty {
                Text(typed.isEmpty ? "Used in this base" : "Already used").font(.caption).foregroundStyle(.secondary)
                WrapLayout(spacing: 4) {
                    ForEach(suggestions, id: \.self) { tag in
                        Button { add(tag) } label: { TagBadge(tag: tag) }
                            .buttonStyle(.plain)
                            .help("Add \(tag): other notes have it")
                    }
                }
                .frame(width: 220, alignment: .leading)
            }
            HStack {
                Spacer()
                Button("Add") { add(typed) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(KnowledgeTag.normalize(typed) == nil)
            }
        }
        .padding(12)
    }

    private func add(_ text: String) {
        model.addTag(text)
        typed = ""
        adding = false
    }
}
