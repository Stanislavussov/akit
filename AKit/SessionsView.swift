import AKitCore
import AppKit
import SwiftUI

/// Sessions screen: saved conversations of every installed harness, newest first.
/// Read-only: AKit never changes session files.
struct SessionsView: View {
    @Environment(AppModel.self) private var model
    @State private var selection: SessionSummary.ID?
    @State private var query = ""
    /// nil = all harnesses.
    @State private var harness: HarnessID?

    var body: some View {
        HSplitView {
            list
                .frame(minWidth: 260, idealWidth: 320, maxWidth: 480)
            Group {
                if let session = model.sessions.first(where: { $0.id == selection }) {
                    SessionDetailView(session: session)
                } else {
                    ContentUnavailableView("Select a session", systemImage: "bubble.left.and.bubble.right")
                }
            }
            .frame(minWidth: 380, maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle("Sessions")
        .navigationSubtitle(subtitle)
        .searchable(text: $query, placement: .toolbar, prompt: "Title or project")
        .toolbar {
            ToolbarItem {
                Picker("Harness", selection: $harness) {
                    Text("All harnesses").tag(HarnessID?.none)
                    ForEach(harnesses, id: \.self) { id in
                        Text(id.displayName).tag(HarnessID?.some(id))
                    }
                }
                .help("Show sessions of one harness")
            }
            ToolbarItem {
                Button("Refresh", systemImage: "arrow.clockwise") { Task { await model.refresh() } }
                    .disabled(model.isScanning)
                    .help("Rescan sessions (⌘R)")
            }
        }
        .onAppear { selection = selection ?? filtered.first?.id }
        .onChange(of: model.sessions) { if selection.flatMap({ id in model.sessions.first { $0.id == id } }) == nil { selection = filtered.first?.id } }
    }

    private var list: some View {
        List(filtered, selection: $selection) { session in
            SessionRow(session: session)
                .tag(session.id)
                .contextMenu {
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([session.file]) }
                    if let project = session.project {
                        Button("Show Project in Finder") { NSWorkspace.shared.activateFileViewerSelecting([project]) }
                    }
                }
        }
        .overlay {
            if !query.isEmpty && filtered.isEmpty {
                ContentUnavailableView.search(text: query)
            } else if model.sessions.isEmpty && !model.isScanning {
                ContentUnavailableView("No sessions found", systemImage: "bubble.left.and.bubble.right")
            }
        }
    }

    /// Harnesses that have at least one session.
    private var harnesses: [HarnessID] {
        var seen = Set<HarnessID>()
        return model.sessions.map(\.harness).filter { seen.insert($0).inserted }.sorted()
    }

    private var subtitle: String {
        filtered.count == model.sessions.count ? "\(model.sessions.count) sessions" : "\(filtered.count) of \(model.sessions.count)"
    }

    private var filtered: [SessionSummary] {
        let q = query.trimmingCharacters(in: .whitespaces)
        return model.sessions.filter { session in
            (harness == nil || session.harness == harness)
                && (q.isEmpty || session.title.localizedCaseInsensitiveContains(q)
                    || (session.project?.path.localizedCaseInsensitiveContains(q) ?? false))
        }
    }
}

private struct SessionRow: View {
    let session: SessionSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(session.title).fontWeight(.medium).lineLimit(2)
                Spacer()
                HarnessBadge(harness: session.harness)
            }
            HStack(spacing: 6) {
                if let project = session.project {
                    Label(project.lastPathComponent, systemImage: "folder")
                        .help(project.tildePath)
                }
                Spacer()
                Text(session.modified, format: .relative(presentation: .named))
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
        .padding(.vertical, 2)
    }
}

private struct SessionDetailView: View {
    @Environment(AppModel.self) private var model
    let session: SessionSummary
    @State private var transcript: SessionTranscript?
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(20)
            Divider()
            content
        }
        // Reload on selection change and after every rescan (⌘R).
        .task(id: "\(session.id)|\(session.modified.timeIntervalSince1970)") {
            transcript = nil
            error = nil
            do {
                let loaded = try await model.transcript(of: session)
                guard !Task.isCancelled else { return }
                transcript = loaded
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(session.title).font(.title2.bold()).textSelection(.enabled).lineLimit(3)
                Spacer()
                HarnessBadge(harness: session.harness)
                if ExternalEditor.appURL != nil {
                    Button("Open in \(ExternalEditor.name)", systemImage: "square.and.pencil") {
                        ExternalEditor.open(session.file)
                    }
                    .labelStyle(.iconOnly)
                    .help("Open the raw session file in \(ExternalEditor.name)")
                }
                Button("Show in Finder", systemImage: "folder") {
                    NSWorkspace.shared.activateFileViewerSelecting([session.file])
                }
                .labelStyle(.iconOnly)
                .help("Show the session file in Finder")
            }
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 4) {
                if let project = session.project {
                    row("Project", project.tildePath, monospaced: true)
                }
                if let started = session.started {
                    row("Started", started.formatted(date: .abbreviated, time: .shortened))
                }
                row("Last change", session.modified.formatted(date: .abbreviated, time: .shortened))
                if let models = transcript?.models, !models.isEmpty {
                    row("Model", models.joined(separator: ", "))
                }
                row("File", "\(session.file.tildePath) · \(session.size.formatted(.byteCount(style: .file)))", monospaced: true)
                if let version = session.harnessVersion {
                    row("Version", version)
                }
            }
            .font(.callout)
            .textSelection(.enabled)
        }
    }

    private func row(_ label: String, _ value: String, monospaced: Bool = false) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
            Text(value).monospaced(monospaced).lineLimit(2).truncationMode(.middle)
        }
    }

    @ViewBuilder private var content: some View {
        if let error {
            ContentUnavailableView("Couldn't read the session", systemImage: "exclamationmark.triangle",
                                   description: Text(error))
        } else if let transcript {
            if transcript.items.isEmpty {
                ContentUnavailableView("No messages", systemImage: "bubble.left")
            } else {
                TranscriptView(items: transcript.items)
            }
        } else {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// The conversation, top to bottom. Thinking, tool calls and results start collapsed.
struct TranscriptView: View {
    let items: [TranscriptItem]

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                ForEach(items) { item in
                    TranscriptRow(item: item)
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct TranscriptRow: View {
    let item: TranscriptItem

    var body: some View {
        switch item.kind {
        case .user:
            LongText(text: item.text)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
        case .assistant:
            LongText(text: item.text)
                .padding(.horizontal, 10)
        case .thinking:
            Collapsible(title: "Thinking", icon: "brain", tint: .secondary, text: item.text, monospaced: false)
        case .toolCall(let name):
            Collapsible(title: name, icon: "wrench.and.screwdriver", tint: .teal, text: item.text, monospaced: true)
        case .toolResult(let name, let isError):
            Collapsible(title: isError ? "\(name ?? "Tool") failed" : "\(name ?? "Tool") result",
                        icon: isError ? "xmark.octagon" : "arrow.turn.down.right",
                        tint: isError ? .red : .secondary, text: item.text, monospaced: true)
        case .event(let title):
            Collapsible(title: title, icon: "info.circle", tint: .orange, text: item.text, monospaced: false,
                        startsExpanded: item.text.count < 200)
        }
    }
}

/// A collapsed block with a one-line preview.
private struct Collapsible: View {
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
                    Text(JSONLinePreview.line(text))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            .font(.callout)
        }
    }
}

private enum JSONLinePreview {
    static func line(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline).lazy
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty && $0 != "{" } ?? ""
    }
}

/// Selectable text; very long texts show their start and a button for the rest.
private struct LongText: View {
    let text: String
    var monospaced = false
    @State private var showAll = false
    private static let limit = 4_000

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(showAll || text.count <= Self.limit ? text : String(text.prefix(Self.limit)) + "…")
                .font(monospaced ? .system(.callout, design: .monospaced) : .body)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            if text.count > Self.limit {
                Button(showAll ? "Show less" : "Show all (\(text.count.formatted()) characters)") { showAll.toggle() }
                    .buttonStyle(.link)
                    .font(.caption)
            }
        }
    }
}
