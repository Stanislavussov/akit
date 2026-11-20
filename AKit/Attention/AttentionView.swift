import AKitAttention
import AppKit
import SwiftUI

/// Attention (docs/design/attention.md): one list of what needs the person, gathered from every
/// screen, each with a short why and Open, which shows its place. Problems first, then what needs
/// a look, then what is ready to read. Dismiss hides an item until it changes.
struct AttentionView: View {
    @Environment(AppModel.self) private var model
    @Environment(ReviewModel.self) private var review
    @Environment(KnowledgeModel.self) private var knowledge
    /// Snapshots: `--tab dismissed` shows the dismissed items too.
    @State private var showDismissed = DebugSnapshot.options?.tab == "dismissed"
    /// Only this source; nil = every screen.
    @State private var source: AttentionItem.Source?
    @State private var loading = false

    private var items: [AttentionItem] {
        (showDismissed ? model.attention : model.attentionShown).filter { source == nil || $0.source == source }
    }

    var body: some View {
        Group {
            if items.isEmpty {
                ContentUnavailableView {
                    Label(source == nil ? "Nothing Needs Attention" : "Nothing from \(source!.title)", systemImage: "checkmark.seal")
                } description: {
                    Text("Failed runs, reviews and evals ready to read, MCP servers that don't connect and inbox proposals from every screen appear here.")
                } actions: {
                    let hidden = model.attention.count - model.attentionShown.count
                    if hidden > 0, !showDismissed {
                        Button("Show \(hidden) Dismissed") { showDismissed = true }
                    }
                }
            } else {
                List {
                    ForEach(AttentionItem.Level.allCases, id: \.self) { level in
                        let group = items.filter { $0.level == level }
                        if !group.isEmpty {
                            Section {
                                ForEach(group) { item in
                                    AttentionRow(item: item, dismissed: model.attentionDismissals.hides(item),
                                                 open: { model.open(item.link, review: review, knowledge: knowledge) },
                                                 dismiss: { model.dismissAttention([item]) },
                                                 restore: { model.restoreAttention([item]) })
                                }
                            } header: {
                                Label("\(level.title) (\(group.count))", systemImage: level.icon)
                                    .foregroundStyle(level.color)
                            }
                        }
                    }
                }
            }
        }
        .askAKitScreen(.attention, facts: AttentionItem.Level.allCases.map { level in
            "\(level.title): \(model.attentionShown.filter { $0.level == level }.count)"
        })
        .navigationTitle("Attention")
        .navigationSubtitle(subtitle)
        .toolbar {
            ToolbarItem {
                Picker("Screen", selection: $source) {
                    Text("Every Screen").tag(AttentionItem.Source?.none)
                    Divider()
                    ForEach(AttentionItem.Source.allCases, id: \.self) { source in
                        Text(source.title).tag(Optional(source))
                    }
                }
                .help("Only what one screen has")
            }
            ToolbarItem {
                Toggle("Show Dismissed", systemImage: "eye", isOn: $showDismissed)
                    .help("Also the items you dismissed; they come back by themselves when they change")
            }
            ToolbarItem {
                let dismissible = items.filter { !model.attentionDismissals.hides($0) && $0.level == .ready }
                Button("Dismiss All Ready", systemImage: "tray.and.arrow.down") { model.dismissAttention(dismissible) }
                    .disabled(dismissible.isEmpty)
                    .help("Hide every Ready to Read item shown: you have read them")
            }
            ToolbarItem {
                GuideButton(guide: .screens, section: "attention")
            }
            ToolbarItem {
                if loading {
                    ProgressView().controlSize(.small)
                } else {
                    Button("Refresh", systemImage: "arrow.clockwise") { Task { await reload() } }
                        .help("Read every screen's files again (AKit also does it every 30 seconds)")
                }
            }
        }
        .task { await reload() }
    }

    private func reload() async {
        loading = true
        await model.reloadAttention()
        loading = false
    }

    private var subtitle: String {
        let shown = model.attentionShown
        let parts = AttentionItem.Level.allCases.compactMap { level -> String? in
            let n = shown.filter { $0.level == level }.count
            return n == 0 ? nil : "\(n) \(level.short)"
        }
        return parts.isEmpty ? "All clear" : parts.joined(separator: " · ")
    }
}

private struct AttentionRow: View {
    let item: AttentionItem
    let dismissed: Bool
    let open: () -> Void
    let dismiss: () -> Void
    let restore: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: item.source.section.icon)
                .foregroundStyle(item.level.color)
                .frame(width: 20)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title).fontWeight(.medium).lineLimit(2)
                if !item.detail.isEmpty {
                    Text(item.detail).font(.callout).foregroundStyle(.secondary).lineLimit(3)
                }
                HStack(spacing: 6) {
                    Text(item.source.title)
                    if let date = item.date {
                        Text("·")
                        Text(date, format: .relative(presentation: .named))
                    }
                    if dismissed {
                        Text("·")
                        Text("dismissed")
                    }
                }
                .font(.caption)
                .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 12)
            Button("Open", action: open)
                .help("Show it on the \(item.source.section.title) screen")
            if dismissed {
                Button("Restore", systemImage: "arrow.uturn.backward", action: restore)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .help("Show it again")
            } else {
                Button("Dismiss", systemImage: "xmark", action: dismiss)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .help("Hide it until it changes")
            }
        }
        .padding(.vertical, 4)
        .opacity(dismissed ? 0.55 : 1)
        .contentShape(Rectangle())
        .onTapGesture(count: 2, perform: open)
        .contextMenu {
            Button("Open", action: open)
            if dismissed { Button("Restore", action: restore) } else { Button("Dismiss", action: dismiss) }
            Divider()
            Button("Copy Link") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(item.link.url.absoluteString, forType: .string)
            }
        }
    }
}

extension AttentionItem.Level {
    var icon: String {
        switch self {
        case .problem: "xmark.octagon.fill"
        case .check: "exclamationmark.triangle.fill"
        case .ready: "checkmark.circle.fill"
        }
    }

    var color: Color {
        switch self {
        case .problem: .red
        case .check: .orange
        case .ready: .green
        }
    }

    /// For the subtitle: `2 to fix · 1 to look at · 5 to read`.
    var short: String {
        switch self {
        case .problem: "to fix"
        case .check: "to look at"
        case .ready: "to read"
        }
    }
}

extension AttentionItem.Source {
    /// The screen the item lives on.
    var section: SidebarSection {
        switch self {
        case .lab: .lab
        case .review: .review
        case .analysis, .evals: .analysis
        case .flows: .runs
        case .mcp: .mcp
        case .knowledge: .knowledge
        case .brain: .brain
        }
    }
}
