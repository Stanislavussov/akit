import AppKit
import MeetingsCore
import SwiftUI

/// The editor of Summary and the own tabs, given by the host app (M17): AKit passes its Crepe
/// editor, `Meetings.app` the plain one. `save(key, text)` writes a page; the page's key says
/// which meeting and tab it belongs to.
public struct MeetingsEditor {
    public typealias Make = @MainActor (_ page: MeetingsPage, _ save: @escaping @MainActor (String, String) -> Void) -> AnyView
    let make: Make

    public init(make: @escaping Make) { self.make = make }

    @MainActor public static let plain = MeetingsEditor { page, save in AnyView(PlainMarkdownEditor(page: page, save: save)) }
}

/// Work → Meetings (docs/design/meetings.md): the meetings by day on the left, the open meeting's
/// tabs on the right. Record and Stop are plain buttons here; nothing shows outside this screen
/// while it records (M4).
public struct MeetingsView: View {
    @Bindable var model: MeetingsModel
    let editor: MeetingsEditor
    /// Extra toolbar items of the host (AKit's Guide button).
    let extraToolbar: AnyView?

    public init(model: MeetingsModel, editor: MeetingsEditor = .plain, extraToolbar: AnyView? = nil) {
        self.model = model
        self.editor = editor
        self.extraToolbar = extraToolbar
    }

    public var body: some View {
        VStack(spacing: 0) {
            if let problem = model.problem {
                banner(problem, systemImage: "exclamationmark.triangle", tint: .orange) { model.problem = nil }
            } else if let notice = model.notice {
                banner(notice, systemImage: "info.circle", tint: .accentColor) { model.notice = nil }
            }
            if !model.hasKey {
                HStack {
                    Label("Add your OpenRouter key to transcribe recordings. Recording works without it.", systemImage: "key")
                    Spacer()
                    Button("Settings…") { model.showSettings = true }
                }
                .font(.callout)
                .padding(8)
                .background(.quaternary.opacity(0.5))
                .overlay(alignment: .bottom) { Divider() }
            }
            HSplitView {
                MeetingList(model: model)
                    .frame(minWidth: 220, idealWidth: 260, maxWidth: 360)
                MeetingDetail(model: model, editor: editor)
                    .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle("Meetings")
        .navigationSubtitle(model.root.path.replacingOccurrences(of: userHome.path, with: "~"))
        .toolbar {
            ToolbarItem { RecordButton(model: model) }
            ToolbarItem {
                Button("Settings…", systemImage: "gearshape") { model.showSettings = true }
                    .help("OpenRouter key, models, language, monthly limit, folder")
            }
            if let extraToolbar { ToolbarItem { extraToolbar } }
        }
        .sheet(isPresented: $model.showSettings) { MeetingsSettingsView(model: model) }
        .sheet(item: $model.tabNameRequest) { request in TabNameSheet(model: model, old: request.old) }
        .sheet(isPresented: $model.renameSpeakersRequest) { RenameSpeakersSheet(model: model) }
        .confirmationDialog("Move this meeting to the Trash?", isPresented: Binding(get: { model.trashRequest != nil }, set: { if !$0 { model.trashRequest = nil } })) {
            Button("Move to Trash", role: .destructive) { if let id = model.trashRequest { model.moveToTrash(id) } }
        } message: {
            Text("Its folder goes to the Trash: summary, transcript, own tabs and audio.")
        }
        .confirmationDialog("Move the tab \(model.removeTabRequest ?? "") to the Trash?",
                            isPresented: Binding(get: { model.removeTabRequest != nil }, set: { if !$0 { model.removeTabRequest = nil } })) {
            Button("Move to Trash", role: .destructive) { if let tab = model.removeTabRequest { model.removeTab(tab) } }
        }
        .task { await model.load() }
    }

    private func banner(_ text: String, systemImage: String, tint: Color, dismiss: @escaping () -> Void) -> some View {
        HStack {
            Label(text, systemImage: systemImage).textSelection(.enabled)
            Spacer()
            Button("Dismiss", action: dismiss)
        }
        .font(.callout)
        .padding(8)
        .background(tint.opacity(0.15))
        .overlay(alignment: .bottom) { Divider() }
    }
}

/// Record / Stop with the elapsed time. Plain on purpose: no red, no pulse (M4).
struct RecordButton: View {
    let model: MeetingsModel

    var body: some View {
        if let started = model.recordingStarted {
            HStack(spacing: 6) {
                TimelineView(.periodic(from: started, by: 0.1)) { context in
                    let levels = model.levels
                    HStack(spacing: 6) {
                        LevelWave(levels: levels.mic, systemImage: "mic", help: "Your microphone: a wave while it hears you, a flat line in silence")
                        LevelWave(levels: levels.system, systemImage: "speaker.wave.2", help: "The sound of the Mac (the call): a wave while it plays, a flat line in silence")
                        Text(timestamp(context.date.timeIntervalSince(started))).monospacedDigit().foregroundStyle(.secondary)
                    }
                }
                Button("Stop", systemImage: "stop") { Task { await model.stop() } }
                    .labelStyle(.titleAndIcon)
                    .help("Stop the recording; it is then transcribed")
            }
        } else {
            Button("Record", systemImage: "circle") { Task { await model.record() } }
                .labelStyle(.titleAndIcon)
                .disabled(model.starting)
                .keyboardShortcut("r", modifiers: [.command, .option])
                .help("Record the microphone and the sound of the Mac until Stop (⌥⌘R)")
        }
    }
}

/// A small live wave of one source: the recent loudness as a line that swings around the middle;
/// silence is a flat line. Plain colors, inside the screen only (M4).
struct LevelWave: View {
    let levels: [Float]
    let systemImage: String
    let help: String

    var body: some View {
        HStack(spacing: 2) {
            Image(systemName: systemImage).font(.caption2).foregroundStyle(.secondary)
            Canvas { context, size in
                let count = 48
                let values = Array(repeating: Float(0), count: max(0, count - levels.count)) + levels.suffix(count)
                let mid = size.height / 2
                let step = size.width / CGFloat(count - 1)
                var path = Path()
                for (i, value) in values.enumerated() {
                    // Alternate up and down, so loudness reads as a wave, not a bar chart.
                    let y = mid - CGFloat(value) * (mid - 1) * (i.isMultiple(of: 2) ? 1 : -1)
                    let point = CGPoint(x: CGFloat(i) * step, y: y)
                    if i == 0 { path.move(to: point) } else { path.addLine(to: point) }
                }
                context.stroke(path, with: .color(.secondary), lineWidth: 1.2)
            }
            .frame(width: 54, height: 16)
        }
        .help(help)
        .accessibilityLabel(levels.last ?? 0 > 0.05 ? "Sound" : "Silence")
    }
}

struct MeetingList: View {
    @Bindable var model: MeetingsModel

    var body: some View {
        List(selection: Binding(get: { model.selectedID }, set: { model.select($0) })) {
            ForEach(model.days, id: \.day) { day in
                Section(day.day.formatted(.dateTime.weekday(.wide).day().month(.wide))) {
                    ForEach(day.meetings) { meeting in
                        MeetingRow(meeting: meeting, recording: meeting.id == model.recordingID, busy: model.processing.contains(meeting.id))
                            .tag(meeting.id)
                            .contextMenu {
                                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([model.folder(meeting.id)]) }
                                Button("Move to Trash…", role: .destructive) { model.trashRequest = meeting.id }
                                    .disabled(meeting.id == model.recordingID)
                            }
                    }
                }
            }
        }
        .overlay {
            if model.meetings.isEmpty {
                ContentUnavailableView("No meetings yet", systemImage: "waveform",
                                       description: Text("Record starts a recording of the microphone and the sound of the Mac."))
            }
        }
        .safeAreaInset(edge: .bottom) {
            HStack {
                Text("This month: " + String(format: "$%.2f", model.monthCost) + " of " + String(format: "$%.0f", model.settings.monthlyLimitUSD))
                Spacer()
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(8)
        }
    }
}

struct MeetingRow: View {
    let meeting: Meeting
    let recording: Bool
    let busy: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(meeting.displayTitle).lineLimit(1)
            HStack(spacing: 6) {
                Text(meeting.started.formatted(date: .omitted, time: .shortened))
                if meeting.duration > 0 { Text(lengthText(meeting.duration)) }
                Text(stateText)
                if meeting.costUSD > 0 { Text(String(format: "$%.3f", meeting.costUSD)) }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    var stateText: String {
        if recording { return "recording" }
        if busy { return "transcribing" }
        switch meeting.state {
        case .recording: return "not stopped"
        case .waiting: return "waiting"
        case .transcribing: return "transcribing"
        case .done: return ""
        case .failed: return "failed"
        }
    }
}

struct MeetingDetail: View {
    @Bindable var model: MeetingsModel
    let editor: MeetingsEditor

    var body: some View {
        if let meeting = model.selected {
            VStack(spacing: 0) {
                header(meeting)
                Divider()
                TabBar(model: model, meeting: meeting)
                Divider()
                content(meeting)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } else {
            ContentUnavailableView("No meeting chosen", systemImage: "list.bullet.rectangle",
                                   description: Text("Choose a meeting on the left, or press Record."))
        }
    }

    private func header(_ meeting: Meeting) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(meeting.displayTitle).font(.title3.bold()).textSelection(.enabled)
                HStack(spacing: 8) {
                    Text(meeting.started.formatted(date: .abbreviated, time: .shortened))
                    if meeting.duration > 0 { Text(lengthText(meeting.duration)) }
                    if let model = meeting.model { Text(model) }
                    if meeting.costUSD > 0 { Text(String(format: "$%.3f", meeting.costUSD)) }
                    if meeting.audioTrashed { Text("audio in the Trash") }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            if meeting.state == .failed, !model.processing.contains(meeting.id) {
                Button("Try Again") { model.process(meeting.id, byUser: true) }
                    .disabled(!model.hasKey || meeting.audioTrashed)
            }
            Menu {
                Button("Rename Speakers…") { model.renameSpeakersRequest = true }
                    .disabled(meeting.speakerKeys.isEmpty)
                Button("Transcribe Again") { model.process(meeting.id, restart: true, byUser: true) }
                    .disabled(!model.hasKey || meeting.audioTrashed || model.processing.contains(meeting.id) || meeting.id == model.recordingID)
                Divider()
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([model.folder(meeting.id)]) }
                Button("Move to Trash…", role: .destructive) { model.trashRequest = meeting.id }
                    .disabled(meeting.id == model.recordingID)
            } label: {
                Label("Actions", systemImage: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private func content(_ meeting: Meeting) -> some View {
        VStack(spacing: 0) {
            if let warnings = meeting.warnings, !warnings.isEmpty {
                Label(warnings.joined(separator: " "), systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(8)
                Divider()
            }
            if model.selectedTab == MeetingsModel.transcriptTab {
                TranscriptView(meeting: meeting, status: status(meeting))
            } else if model.selectedTab == MeetingsModel.summaryTab, model.summaryLocked {
                // H5: the model writes this page after Stop; notes typed now would be replaced.
                ContentUnavailableView {
                    Label(status(meeting) ?? "Waiting", systemImage: "text.badge.checkmark")
                } description: {
                    Text("The summary, decisions and tasks appear here after the transcription. For your own notes now, add a tab with +.")
                } actions: {
                    Button("New Tab…") { model.tabNameRequest = .init(old: nil) }
                }
            } else if let page = model.page {
                editor.make(page) { key, text in model.save(key: key, text: text) }
                    .id("\(page.key)#\(page.generation)")
            }
        }
    }

    /// What the meeting waits for, when it is not done.
    private func status(_ meeting: Meeting) -> String? {
        if meeting.id == model.recordingID { return "Recording. The summary and the transcript come after Stop." }
        if model.processing.contains(meeting.id) || meeting.state == .transcribing {
            return meeting.transcribedChunks > 0 ? "Transcribing: \(meeting.transcribedChunks) part(s) of 30 min done…" : "Transcribing…"
        }
        switch meeting.state {
        case .waiting: return model.hasKey ? "Waiting to be transcribed." : "Waiting: add your OpenRouter key in Settings."
        case .failed: return "Transcription stopped: \(meeting.failure ?? "unknown reason")"
        case .recording: return "This recording was not stopped; it is mixed and transcribed on the next start."
        case .done, .transcribing: return nil
        }
    }

}

/// Summary, Transcript, then the own tabs; right-click renames or removes an own tab, + adds one.
struct TabBar: View {
    @Bindable var model: MeetingsModel
    let meeting: Meeting

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                tab(MeetingsModel.summaryTab, own: false)
                tab(MeetingsModel.transcriptTab, own: false)
                ForEach(meeting.tabs, id: \.self) { tab($0, own: true) }
                Button("New Tab…", systemImage: "plus") { model.tabNameRequest = .init(old: nil) }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .help("Add your own Markdown tab: notes, links. It is never sent to a model")
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
        }
    }

    @ViewBuilder
    private func tab(_ name: String, own: Bool) -> some View {
        let text = Text(name)
            .lineLimit(1)
            .font(.callout)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(name == model.selectedTab ? Color.accentColor.opacity(0.15) : Color.clear, in: RoundedRectangle(cornerRadius: 5))
            .contentShape(Rectangle())
            .onTapGesture { model.show(tab: name) }
        if own {
            text.contextMenu {
                Button("Rename…") { model.tabNameRequest = .init(old: name) }
                Button("Delete…", role: .destructive) { model.removeTabRequest = name }
            }
            .help("tabs/\(name).md: right-click to rename or delete it")
        } else {
            text
        }
    }
}

struct TranscriptView: View {
    let meeting: Meeting
    let status: String?

    var body: some View {
        if meeting.segments.isEmpty {
            ContentUnavailableView("No transcript yet", systemImage: "text.quote", description: Text(status ?? "Nothing was said in this recording."))
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    if let status { Text(status).font(.callout).foregroundStyle(.secondary) }
                    ForEach(Array(meeting.segments.enumerated()), id: \.offset) { _, segment in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(timestamp(segment.start)).monospacedDigit().foregroundStyle(.secondary).frame(width: 64, alignment: .trailing)
                            Text(meeting.speakerName(segment.speaker)).bold().frame(width: 110, alignment: .leading).lineLimit(1)
                            Text(segment.text).frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .textSelection(.enabled)
                    }
                }
                .padding(12)
            }
        }
    }
}

/// New Tab… (`old` nil) and Rename….
struct TabNameSheet: View {
    let model: MeetingsModel
    let old: String?
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""

    var body: some View {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let problem = model.tabNameProblem(trimmed, old: old)
        VStack(alignment: .leading, spacing: 12) {
            Text(old == nil ? "New Tab" : "Rename Tab").font(.title3.bold())
            Text("A tab is a Markdown page of this meeting, tabs/<name>.md in its folder: notes, links. It is never sent to a model.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Form {
                TextField(text: $name, prompt: Text("Notes")) {
                    HStack(spacing: 2) { Text("Name"); Text("*").foregroundStyle(.red) }
                }
            }
            if let problem {
                Label(problem, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).font(.callout)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button(old == nil ? "Add Tab" : "Rename") {
                    let done = if let old { model.renameTab(old, to: trimmed) } else { model.addTab(trimmed) }
                    if done { dismiss() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(trimmed.isEmpty || problem != nil || trimmed == old)
            }
        }
        .padding(20)
        .frame(width: 420)
        .onAppear { name = old ?? "" }
    }
}

/// Names for `Me`, `S1`, `S2` …; the transcript and the summary show them.
struct RenameSpeakersSheet: View {
    let model: MeetingsModel
    @Environment(\.dismiss) private var dismiss
    @State private var names: [String: String] = [:]

    var body: some View {
        let keys = model.selected?.speakerKeys ?? []
        VStack(alignment: .leading, spacing: 12) {
            Text("Rename Speakers").font(.title3.bold())
            Text("The transcript and the summary show these names. An empty field keeps the number.")
                .foregroundStyle(.secondary)
            Form {
                ForEach(keys, id: \.self) { key in
                    TextField(key == "Me" ? "Me" : "Speaker \(key.dropFirst())", text: Binding(get: { names[key] ?? "" }, set: { names[key] = $0 }),
                              prompt: Text(firstWords(key)))
                }
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Rename") {
                    for key in keys where (names[key] ?? "") != (model.selected?.speakers[key] ?? "") {
                        model.renameSpeaker(key, to: names[key] ?? "")
                    }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 460)
        .onAppear { names = model.selected?.speakers ?? [:] }
    }

    /// The speaker's first words, to tell the voices apart.
    private func firstWords(_ key: String) -> String {
        let text = model.selected?.segments.first { $0.speaker == key }?.text ?? ""
        return text.count > 40 ? String(text.prefix(40)) + "…" : text
    }
}

/// `Meetings.app`'s editor: the page's Markdown as text, saved 0.6 s after the last change and
/// when it goes away.
struct PlainMarkdownEditor: View {
    let page: MeetingsPage
    let save: @MainActor (String, String) -> Void
    @State private var text = ""
    @State private var saved = ""
    @State private var pending: Task<Void, Never>?

    var body: some View {
        TextEditor(text: $text)
            .font(.body.monospaced())
            .scrollContentBackground(.hidden)
            .padding(8)
            .onAppear {
                text = page.text
                saved = page.text
            }
            .onChange(of: text) { _, new in
                pending?.cancel()
                pending = Task {
                    try? await Task.sleep(for: .milliseconds(600))
                    guard !Task.isCancelled, new != saved else { return }
                    save(page.key, new)
                    saved = new
                }
            }
            .onDisappear {
                pending?.cancel()
                if text != saved { save(page.key, text) }
            }
    }
}
