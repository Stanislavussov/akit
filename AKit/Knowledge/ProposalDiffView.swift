import AKitFoundation
import AKitKnowledge
import SwiftUI

/// What Accept of a note proposal changes, as the diff window shows it: the note's text now and
/// the text Accept writes. Codable, so Open Diff Window can pass it to its own window.
struct ProposalDiff: Codable, Hashable {
    let title: String
    let path: String
    let old: String
    let new: String

    init(title: String, plan: KnowledgeInbox.Plan) {
        self.title = title
        path = plan.original == nil ? "\(plan.notePath) (new" + (plan.newArea ? ", in a new area" : "") + ")" : plan.notePath
        old = plan.original.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        new = plan.planned
    }

    var lines: [TextDiff.Line] { TextDiff.lines(from: old, to: new) }
}

/// A diff coloured like git: added lines green with +, removed lines red with −, unchanged ones
/// plain, each with its line number before and after. Changes only: 3 unchanged lines around each
/// change, the rest folded into "⋯ N unchanged lines"; whole: every line of the note.
struct ColoredDiffView: View {
    let lines: [TextDiff.Line]
    var whole = false
    var font: Font = .callout.monospaced()

    enum Row: Hashable {
        case line(TextDiff.Line, old: Int?, new: Int?)
        case gap(Int)
    }

    var body: some View {
        let rows = Self.rows(lines, whole: whole)
        let digits = String(max(lines.count, 1)).count
        LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                switch row {
                case .line(let line, let old, let new):
                    DiffLineRow(line: line, old: old, new: new, digits: digits)
                case .gap(let count):
                    Text("⋯ \(count) unchanged line\(count == 1 ? "" : "s")")
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 2)
                        .padding(.leading, 6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.blue.opacity(0.08))
                }
            }
        }
        .font(font)
    }

    /// The rows to show, with line numbers counted over the whole diff.
    static func rows(_ lines: [TextDiff.Line], whole: Bool) -> [Row] {
        var numbered: [Row] = []
        var old = 0, new = 0
        for line in lines {
            switch line {
            case .same: old += 1; new += 1; numbered.append(.line(line, old: old, new: new))
            case .removed: old += 1; numbered.append(.line(line, old: old, new: nil))
            case .added: new += 1; numbered.append(.line(line, old: nil, new: new))
            }
        }
        if whole { return numbered }
        let changed = lines.indices.filter { if case .same = lines[$0] { false } else { true } }
        var shown = Set<Int>()
        for index in changed { shown.formUnion(max(0, index - 3)...min(lines.count - 1, index + 3)) }
        var rows: [Row] = []
        var hidden = 0
        for index in lines.indices {
            if shown.contains(index) {
                if hidden > 0 { rows.append(.gap(hidden)); hidden = 0 }
                rows.append(numbered[index])
            } else {
                hidden += 1
            }
        }
        if hidden > 0, !rows.isEmpty { rows.append(.gap(hidden)) }
        return rows
    }

    /// Added and removed line counts, for "+3 −1".
    static func counts(_ lines: [TextDiff.Line]) -> (added: Int, removed: Int) {
        lines.reduce(into: (0, 0)) { counts, line in
            switch line {
            case .added: counts.0 += 1
            case .removed: counts.1 += 1
            case .same: break
            }
        }
    }
}

private struct DiffLineRow: View {
    let line: TextDiff.Line
    let old: Int?
    let new: Int?
    let digits: Int

    var body: some View {
        let (sign, text, tint): (String, String, Color?) = switch line {
        case .same(let text): (" ", text, nil)
        case .added(let text): ("+", text, .green)
        case .removed(let text): ("−", text, .red)
        }
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            Text(number(old)).foregroundStyle(.tertiary)
            Text(number(new)).foregroundStyle(.tertiary).padding(.leading, 6)
            Text(sign).foregroundStyle(tint ?? .secondary).bold().padding(.horizontal, 6)
            // An empty line keeps its height.
            Text(text.isEmpty ? " " : text)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 1)
        .padding(.leading, 4)
        .background(tint.map { $0.opacity(0.16) } ?? .clear)
    }

    private func number(_ value: Int?) -> String {
        let text = value.map(String.init) ?? ""
        return String(repeating: " ", count: max(0, digits - text.count)) + text
    }
}

/// "+3 −1": the added lines in green, the removed ones in red.
struct DiffCounts: View {
    let lines: [TextDiff.Line]

    var body: some View {
        let counts = ColoredDiffView.counts(lines)
        HStack(spacing: 6) {
            Text("+\(counts.added)").foregroundStyle(.green)
            Text("−\(counts.removed)").foregroundStyle(.red)
        }
        .font(.callout.monospaced().bold())
        .help("\(counts.added) line\(counts.added == 1 ? "" : "s") added, \(counts.removed) removed")
    }
}

/// Open Diff Window: the proposal's diff in its own window, big enough to read; Changes or
/// Whole Note, and a larger or smaller text.
struct ProposalDiffWindow: View {
    static let id = "proposal-diff"
    let diff: ProposalDiff
    @AppStorage("proposalDiffWhole") private var whole = false
    @AppStorage("proposalDiffSize") private var size = 14.0

    var body: some View {
        let lines = diff.lines
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(diff.title).font(.headline).lineLimit(1)
                    Text(diff.path).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                }
                Spacer()
                DiffCounts(lines: lines)
                Picker("Show", selection: $whole) {
                    Text("Changes").tag(false)
                    Text("Whole Note").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .help("Changes: the changed lines with 3 lines around them. Whole Note: every line of the note, the changes marked")
                ControlGroup {
                    Button("Smaller Text", systemImage: "textformat.size.smaller") { size = max(10, size - 1) }
                        .keyboardShortcut("-")
                    Button("Larger Text", systemImage: "textformat.size.larger") { size = min(28, size + 1) }
                        .keyboardShortcut("=")
                }
                .fixedSize()
                .help("Smaller (⌘−) or larger (⌘=) text")
            }
            .padding(10)
            Divider()
            ScrollView {
                ColoredDiffView(lines: lines, whole: whole, font: .system(size: size, design: .monospaced))
                    .padding(8)
            }
        }
        .frame(minWidth: 600, minHeight: 400)
        .navigationTitle(diff.title)
    }
}

/// A note proposal's diff in a panel: the note's path, "+3 −1", Open Diff Window, and the
/// coloured changes.
struct ProposalDiffBox: View {
    @Environment(\.openWindow) private var openWindow
    let diff: ProposalDiff
    var font: Font = .callout.monospaced()

    init(title: String, plan: KnowledgeInbox.Plan, font: Font = .callout.monospaced()) {
        diff = ProposalDiff(title: title, plan: plan)
        self.font = font
    }

    var body: some View {
        let lines = diff.lines
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(diff.path).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                Spacer()
                DiffCounts(lines: lines)
                Button("Open Diff Window", systemImage: "arrow.up.left.and.arrow.down.right") {
                    openWindow(id: ProposalDiffWindow.id, value: diff)
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .help("Open the diff in its own window, to read it on a large screen")
            }
            ColoredDiffView(lines: lines, font: font)
        }
    }
}
