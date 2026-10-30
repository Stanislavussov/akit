import AKitReview
import SwiftUI

/// One line of a review's log: a short title and the details under it (a call's arguments, a
/// tool's answer, the model's thinking and text, the findings with their severity).
struct ReviewLogLine: Hashable {
    var title: String
    var detail: String?

    init(_ raw: String) {
        let parts = ReviewLive.split(raw)
        title = parts.title
        detail = parts.detail
    }

    init(title: String, detail: String?) {
        self.title = title
        self.detail = detail
    }

    var isFailure: Bool { title.hasSuffix(" failed") || title.contains(" failed:") || title.contains("model error:") }
}

/// The lines of a review's log, each one with a chevron that opens its details. With
/// `expandAll`, every line's details stay open.
struct ReviewLogList: View {
    let lines: [ReviewLogLine]
    /// Lines dropped from the front: a line's number stays its id while the log grows.
    var dropped = 0
    var expandAll: Bool
    /// Keeps the newest line in view (the live log).
    var follow = false
    @State private var open: Set<Int> = []
    /// Lines whose long details the user opened in full.
    @State private var whole: Set<Int> = []
    /// Characters of a detail shown before Show All: long rows make the list slow.
    static let shownLimit = 2000

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    // A line's number (dropped + its place) is its id: it stays when lines drop from the front.
                    ForEach(lines.indices, id: \.self) { offset in
                        row(lines[offset], index: dropped + offset).id(dropped + offset)
                    }
                }
                .textSelection(.enabled)
                .padding(.vertical, 2)
            }
            .onChange(of: dropped + lines.count) { if follow { proxy.scrollTo(dropped + lines.count - 1, anchor: .bottom) } }
            .onAppear { if follow { proxy.scrollTo(dropped + lines.count - 1, anchor: .bottom) } }
        }
    }

    @ViewBuilder private func row(_ line: ReviewLogLine, index: Int) -> some View {
        let isOpen = expandAll || open.contains(index)
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                if line.detail != nil {
                    Button {
                        if open.contains(index) { open.remove(index) } else { open.insert(index) }
                    } label: {
                        Image(systemName: isOpen ? "chevron.down" : "chevron.right").font(.caption2.weight(.semibold)).frame(width: 12)
                    }
                    .buttonStyle(.plain)
                    .disabled(expandAll)
                    .help(isOpen ? "Hide the details" : "Show the details: arguments, the answer, the model's thinking and text")
                } else {
                    Color.clear.frame(width: 12, height: 1)
                }
                Text(line.title)
                    .foregroundStyle(line.isFailure ? Color.red : line.title.hasPrefix("  ") ? Color.secondary : Color.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .font(.caption.monospaced())
            if isOpen, let detail = line.detail {
                let long = detail.count > Self.shownLimit && !whole.contains(index)
                Text(long ? String(detail.prefix(Self.shownLimit)) + "\n…" : detail)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(6)
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 4))
                    .padding(.leading, 16)
                if long {
                    Button("Show All \(detail.count) Characters") { whole.insert(index) }
                        .buttonStyle(.link).font(.caption).padding(.leading, 22)
                }
            }
        }
    }
}

/// The running review's log in a large window: the same lines, more room.
struct ReviewLiveLogSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(ReviewModel.self) private var model
    @AppStorage("review.log.expandAll") private var expandAll = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(model.activity?.title ?? "The review has finished").font(.title3.weight(.semibold))
                Spacer()
                Toggle("Expand All", isOn: $expandAll).toggleStyle(.switch).controlSize(.small)
                    .help("Keep every line's details open")
            }
            if let activity = model.activity {
                ReviewLogList(lines: activity.lines, dropped: activity.dropped, expandAll: expandAll, follow: true)
            } else {
                Text("Its steps stay in the run: open Log… there.").foregroundStyle(.secondary)
                Spacer()
            }
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(minWidth: 900, idealWidth: 1100, minHeight: 560, idealHeight: 760)
    }
}
