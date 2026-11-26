import AKitKnowledge
import AppKit
import SwiftUI

/// The board in view (K44): the task notes of a folder in the columns To Do, Doing, Review and
/// Done, and Check Fields for those the board can't place. A card is its note's frontmatter: drag
/// it to another column and the note's `status:` line is set (saved at once, committed with the
/// other edits, U2); click it and the note opens beside the board. The board has no file of its
/// own, so an edit of `status:` anywhere else (Properties, `akit kb set`, an editor) moves the
/// card here too.
struct BoardPanel: View {
    @Environment(KnowledgeModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            if let folder = model.board, let board = model.boardColumns {
                HStack(spacing: 8) {
                    Text(folder.split(separator: "/").last.map(String.init) ?? folder).font(.headline).lineLimit(1)
                        .help("The task notes (kind: task) of areas/\(folder) and its folders")
                        .layoutPriority(2)
                    Text("\(board.cards.count) task\(board.cards.count == 1 ? "" : "s")").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    if let notice = model.notice {
                        Text(notice).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Button("Show in Finder", systemImage: "folder") {
                        if let base = model.base {
                            NSWorkspace.shared.activateFileViewerSelecting([base.areasFolder.appending(path: folder, directoryHint: .isDirectory)])
                        }
                    }
                    .help("Show the folder of the task notes in Finder")
                    Button("Close Board", systemImage: "xmark") { model.closeBoard() }
                        .help("Close the board; moved cards are saved already")
                }
                .labelStyle(.titleAndIcon)
                .controlSize(.small)
                .padding(8)
                Divider()
                if board.cards.isEmpty {
                    ContentUnavailableView("No task notes", systemImage: "rectangle.split.3x1",
                                           description: Text("A note with kind: task, ado: and status: in areas/\(folder) is a card here."))
                } else {
                    // The columns share the width; below 150 points each, the board scrolls sideways.
                    GeometryReader { geometry in
                        let count = CGFloat(board.columns.count + (board.unsorted.isEmpty ? 0 : 1))
                        let width = max(150, (geometry.size.width - 20 - 10 * (count - 1)) / count)
                        ScrollView(.horizontal) {
                            HStack(alignment: .top, spacing: 10) {
                                if !board.unsorted.isEmpty {
                                    BoardColumn(title: "Check Fields", status: nil, cards: board.unsorted).frame(width: width)
                                }
                                ForEach(board.columns, id: \.status) { column in
                                    BoardColumn(title: column.title, status: column.status, cards: column.cards).frame(width: width)
                                }
                            }
                            .padding(10)
                            .frame(minHeight: geometry.size.height, alignment: .top)
                        }
                    }
                }
            }
        }
    }
}

/// One column: its cards in the order of their titles' numbers; a card dropped here gets its status.
/// Check Fields (no status) takes no drops.
private struct BoardColumn: View {
    @Environment(KnowledgeModel.self) private var model
    let title: String
    let status: KnowledgeTask.Status?
    let cards: [KnowledgeTask.Card]
    @State private var targeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title).font(.subheadline.weight(.semibold))
                Text("\(cards.count)").font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            .foregroundStyle(status == nil ? Color.orange : Color.primary)
            .help(status.map { "status: \($0.rawValue)" } ?? "Task notes whose status: is missing or not one of \(KnowledgeTask.statusList): set it in Properties, or drag the card to a column")
            ScrollView(.vertical) {
                VStack(spacing: 8) {
                    ForEach(cards) { BoardCard(card: $0) }
                }
                .frame(maxWidth: .infinity, alignment: .top)
            }
        }
        .padding(8)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(targeted ? Color.accentColor.opacity(0.12) : Color(nsColor: .controlBackgroundColor),
                    in: RoundedRectangle(cornerRadius: 8))
        .dropDestination(for: String.self) { ids, _ in
            guard let status, let id = ids.first else { return false }
            model.move(card: id, to: status)
            return true
        } isTargeted: { targeted = $0 && status != nil }
    }
}

/// A card: the note's title, its ADO ID and rules, what it waits for, and what its fields lack.
private struct BoardCard: View {
    @Environment(KnowledgeModel.self) private var model
    let card: KnowledgeTask.Card

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(card.title).font(.callout.weight(.medium)).lineLimit(3).multilineTextAlignment(.leading)
            Text(([card.ado.map { "ADO \($0)" }] + card.rule.map(Optional.some)).compactMap(\.self).joined(separator: " · "))
                .font(.caption).foregroundStyle(.secondary)
            let waits = card.depends.filter { $0.note != nil && $0.open }
            if !waits.isEmpty {
                Label("Waits for " + waits.map { [$0.number.map { "(\($0))" }, $0.ado].compactMap(\.self).joined(separator: " ") }.joined(separator: ", "),
                      systemImage: "hourglass")
                    .font(.caption).foregroundStyle(.orange)
                    .help("A task this one depends on isn't done yet")
            }
            ForEach(card.problems, id: \.self) { problem in
                Label(problem, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.red)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: model.note == card.note && model.noteBesideBoard ? .selectedContentBackgroundColor : .textBackgroundColor)
            .opacity(model.note == card.note && model.noteBesideBoard ? 0.35 : 1), in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(card.blocked ? Color.orange.opacity(0.6) : Color.secondary.opacity(0.25)))
        .contentShape(Rectangle())
        .onTapGesture { model.openCard(card.note) }
        .draggable(card.note)
        .help("areas/\(card.note).md: click to open the note; drag to another column to set its status:")
    }
}
