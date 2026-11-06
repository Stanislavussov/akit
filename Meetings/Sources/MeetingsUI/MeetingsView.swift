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
                Button("Ask…", systemImage: "bubble.left.and.text.bubble.right") { model.openAsk() }
                    .help("Ask a question about your meetings: what was decided, who does what")
            }
            ToolbarItem {
                Button("Costs…", systemImage: "chart.bar") { model.showCosts = true }
                    .help("What OpenRouter charged by day, week or month, with filters and Copy CSV")
            }
            ToolbarItem {
                Button("Settings…", systemImage: "gearshape") { model.showSettings = true }
                    .help("OpenRouter key, models, language, monthly limit, folder")
            }
            if let extraToolbar { ToolbarItem { extraToolbar } }
        }
        .sheet(isPresented: $model.showSettings) { MeetingsSettingsView(model: model) }
        .sheet(isPresented: $model.showCosts) { CostsView(model: model) }
        .sheet(isPresented: $model.showAsk) { AskView(model: model) }
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
        let days = model.days
        List(selection: Binding(get: { model.selectedID }, set: { model.select($0) })) {
            ForEach(days, id: \.day) { day in
                Section(day.day.formatted(.dateTime.weekday(.wide).day().month(.wide))) {
                    ForEach(day.meetings) { meeting in
                        MeetingRow(meeting: meeting, recording: meeting.id == model.recordingID, busy: model.processing.contains(meeting.id),
                                   hit: model.hit(meeting.id))
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
            } else if days.isEmpty {
                ContentUnavailableView.search(text: model.searchText)
            }
        }
        .safeAreaInset(edge: .top) { SearchBar(model: model) }
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

/// M23: the search field over all meetings and the tag menu.
struct SearchBar: View {
    @Bindable var model: MeetingsModel

    var body: some View {
        HStack(spacing: 6) {
            HStack(spacing: 4) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search meetings", text: $model.searchText)
                    .textFieldStyle(.plain)
                if !model.searchText.isEmpty {
                    Button("Clear", systemImage: "xmark.circle.fill") { model.searchText = "" }
                        .labelStyle(.iconOnly).buttonStyle(.borderless).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 6))
            .help("Looks in titles, tags, summaries, transcripts and your tabs; #tag shows the meetings with that tag")
            let tags = model.allTags
            Menu {
                if tags.isEmpty { Text("No tags yet") }
                ForEach(tags, id: \.tag) { item in
                    Button("#\(item.tag) (\(item.count))") { model.filter(tag: item.tag) }
                }
            } label: {
                Label("Tags", systemImage: "tag")
            }
            .menuStyle(.borderlessButton)
            .labelStyle(.iconOnly)
            .fixedSize()
            .help("Show the meetings with a tag")
        }
        .padding(8)
        .background(.bar)
    }
}

struct MeetingRow: View {
    let meeting: Meeting
    let recording: Bool
    let busy: Bool
    var hit: MeetingSearch.Hit?

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
            if let snippet = hit?.snippet {
                (Text((hit?.place ?? "") + ": ").bold() + Text(snippet))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            } else if !meeting.tagList.isEmpty {
                Text(meeting.tagList.map { "#" + $0 }.joined(separator: " "))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
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
                TagLine(model: model, meeting: meeting)
            }
            Spacer()
            SimilarMenu(model: model, meeting: meeting)
            TemplateMenu(model: model, meeting: meeting)
            if meeting.state == .failed, !model.processing.contains(meeting.id) {
                Button("Try Again") { model.process(meeting.id, byUser: true) }
                    .disabled(!model.hasKey || meeting.audioTrashed)
            }
            Menu {
                Button("Ask About This Meeting…") { model.openAsk(meetingID: meeting.id) }
                    .disabled(meeting.segments.isEmpty)
                Button("Rename Speakers…") { model.renameSpeakersRequest = true }
                    .disabled(meeting.speakerKeys.isEmpty)
                Button("Summarize Again") { model.summarizeAgain(meeting.id) }
                    .disabled(!model.hasKey || meeting.segments.isEmpty || model.processing.contains(meeting.id) || meeting.id == model.recordingID)
                    .help("Write the summary again from the transcript (one text call, no audio)")
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

/// M23: the meeting's tags (a click shows the meetings with it) and Edit Tags….
struct TagLine: View {
    let model: MeetingsModel
    let meeting: Meeting
    @State private var editing = false

    var body: some View {
        HStack(spacing: 4) {
            ForEach(meeting.tagList, id: \.self) { tag in
                Button("#" + tag) { model.filter(tag: tag) }
                    .buttonStyle(.borderless)
                    .font(.caption)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(.quaternary.opacity(0.6), in: Capsule())
                    .help("Show the meetings tagged \(tag)")
            }
            Button(meeting.tagList.isEmpty ? "Add Tags…" : "Edit…") { editing = true }
                .buttonStyle(.borderless)
                .font(.caption)
                .help("Tags of this meeting, for search; the summary proposes some when it has none")
                .popover(isPresented: $editing) { TagEditor(model: model, tags: meeting.tagList) }
        }
    }
}

struct TagEditor: View {
    let model: MeetingsModel
    let tags: [String]
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Tags").font(.headline)
            TextField("release, payments", text: $text)
                .frame(width: 280)
                .onSubmit(save)
            Text("Separated by commas. An empty field removes them.").font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Save", action: save).keyboardShortcut(.defaultAction)
            }
        }
        .padding(14)
        .onAppear { text = tags.joined(separator: ", ") }
    }

    private func save() {
        model.setTags(text.split(separator: ",").map(String.init))
        dismiss()
    }
}

/// M24: the meetings most like this one, by the words of title, tags and summary (local).
struct SimilarMenu: View {
    let model: MeetingsModel
    let meeting: Meeting

    var body: some View {
        let similar = model.similar(to: meeting.id)
        Menu {
            ForEach(similar) { other in
                Button("\(other.displayTitle) — \(other.started.formatted(date: .abbreviated, time: .omitted))") { model.select(other.id) }
            }
        } label: {
            Label("Similar", systemImage: "square.on.square")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .disabled(similar.isEmpty)
        .help(similar.isEmpty ? "No meeting with a similar title, tags or summary" : "Meetings with a similar title, tags or summary")
    }
}

/// M22: the meeting's template; on a done meeting a change writes the summary again.
struct TemplateMenu: View {
    let model: MeetingsModel
    let meeting: Meeting

    var body: some View {
        let current = model.settings.template(meeting.template)
        Menu {
            Picker("Template", selection: Binding(get: { current.id }, set: { model.setTemplate($0) })) {
                ForEach(model.settings.templates) { Text($0.name).tag($0.id) }
            }
            .pickerStyle(.inline)
        } label: {
            Label(current.name, systemImage: "rectangle.grid.1x2")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .disabled(model.processing.contains(meeting.id))
        .help("What kind of meeting it is: the summary lists that kind's sections. On a done meeting a change writes the summary again (one text call, no audio)")
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
