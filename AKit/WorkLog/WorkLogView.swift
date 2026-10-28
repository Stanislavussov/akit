import AKitFoundation
import AKitKnowledge
import AppKit
import SwiftUI

/// Work Log screen (docs/design/worklog.md): one line of what you did, stamped with the day and
/// time when you press Return; a kind from the presets or a `#tag`. Below, the days, newest
/// first: each entry with how long it lasted and each day's time per kind.
struct WorkLogView: View {
    @Environment(WorkLogModel.self) private var model
    @Environment(KnowledgeModel.self) private var knowledge
    @Environment(AppModel.self) private var app

    var body: some View {
        VStack(spacing: 0) {
            if let problem = model.problem {
                HStack {
                    Label(problem, systemImage: "exclamationmark.triangle").textSelection(.enabled)
                    Spacer()
                    Button("Dismiss") { model.problem = nil }
                }
                .font(.callout)
                .padding(8)
                .background(.orange.opacity(0.15))
                .overlay(alignment: .bottom) { Divider() }
            }
            if knowledge.base == nil {
                if knowledge.loaded {
                    ContentUnavailableView {
                        Label("No knowledge base", systemImage: "clock")
                    } description: {
                        Text("The work log lives in a knowledge base, in its worklog folder beside the notes. Create a base on the Knowledge screen first.")
                    } actions: {
                        Button("Open Knowledge") { app.section = .knowledge }
                    }
                } else {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                Picker("View", selection: Binding(get: { model.tab }, set: { model.tab = $0 })) {
                    ForEach(WorkLogModel.Tab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .padding(.top, 8)
                .help("Log: write and read entries. Auto-Fill: rebuild a day from your prompts to the agents")
                if model.tab == .log {
                    WorkLogEntryBar()
                    Divider()
                    WorkLogDays()
                } else {
                    Divider().padding(.top, 8)
                    WorkLogFillView()
                }
            }
        }
        .frame(maxHeight: .infinity)
        .navigationTitle("Work Log")
        .navigationSubtitle(knowledge.base.map { "\($0.name) · \($0.root.appending(path: KnowledgeWorkLog.folderName).tildePath)" } ?? "")
        .toolbar { toolbar }
        .sheet(item: Binding(get: { model.editRequest }, set: { model.editRequest = $0 })) { request in
            WorkLogEditSheet(request: request)
        }
        .confirmationDialog("Delete the entry of \(model.deleteRequest?.entry.time ?? "")?",
                            isPresented: Binding(get: { model.deleteRequest != nil }, set: { if !$0 { model.deleteRequest = nil } })) {
            Button("Delete", role: .destructive) {
                if let request = model.deleteRequest { model.delete(request) }
            }
        } message: {
            Text("The line leaves the day's file. The base's git keeps the old version.")
        }
        .task {
            (knowledge.projectsRoot, knowledge.brainRoot) = (app.projectsRoot, app.brainRoot)
            await model.load()
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        if knowledge.bases.count > 1 {
            ToolbarItem(placement: .navigation) {
                Picker("Base", selection: Binding(get: { knowledge.base }, set: { if let base = $0 { knowledge.choose(base: base) } })) {
                    ForEach(knowledge.bases, id: \.self) { Text($0.name).tag(Optional($0)) }
                }
                .fixedSize()
                .help("The knowledge base of one world (work, personal); the log is in its worklog folder")
            }
        }
        ToolbarItem {
            Button("Show in Finder", systemImage: "folder") {
                guard let worklog = model.worklog else { return }
                let today = worklog.file(KnowledgeWorkLog.stamp(.now).day)
                if FileWalk.isRegularFile(today) {
                    NSWorkspace.shared.activateFileViewerSelecting([today])
                } else {
                    NSWorkspace.shared.open(FileWalk.isDirectory(worklog.folder) ? worklog.folder : worklog.base.root)
                }
            }
            .disabled(knowledge.base == nil)
            .help("Show today's Markdown file in Finder: one file per day in the worklog folder")
        }
        ToolbarItem {
            GuideButton(guide: .worklog)
        }
    }
}

/// The kind buttons and the entry field. Return adds the entry, stamped now.
private struct WorkLogEntryBar: View {
    @Environment(WorkLogModel.self) private var model
    @FocusState private var focused: Bool

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                ForEach(Array(KnowledgeWorkLog.presets.enumerated()), id: \.element.id) { index, kind in
                    let chosen = model.kind == kind.id
                    Button {
                        model.kind = chosen ? nil : kind.id
                        focused = true
                    } label: {
                        Label(kind.title, systemImage: kind.symbol)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(chosen ? Color.accentColor.opacity(0.25) : Color.secondary.opacity(0.1), in: Capsule())
                            .overlay(Capsule().strokeBorder(chosen ? Color.accentColor : .clear))
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
                    .help("#\(kind.id) (⌘\(index + 1))" + (kind.isWork ? "" : ": a pause, not counted as work"))
                }
                Spacer(minLength: 0)
            }
            .font(.callout)
            HStack(spacing: 8) {
                TextField("What are you doing now? Return adds it with the time", text: $model.text)
                    .textFieldStyle(.roundedBorder)
                    .font(.title3)
                    .focused($focused)
                    .onSubmit { model.addFromField() }
                Button("Add") { model.addFromField() }
                    .disabled(model.text.trimmingCharacters(in: .whitespaces).isEmpty && model.kind == nil)
                    .help("Add the entry with today's date and the time now (Return)")
            }
            HStack(spacing: 6) {
                if let notice = model.notice {
                    Text(notice)
                } else {
                    Text("A kind button or #tag at the start chooses the kind. ⌘1…⌘8 choose a kind; ⌘L comes here from any screen.")
                }
                Spacer()
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(12)
        .onChange(of: model.focusRequest, initial: true) { focused = true }
    }
}

/// The days, newest first; durations refresh every minute.
private struct WorkLogDays: View {
    @Environment(WorkLogModel.self) private var model

    var body: some View {
        TimelineView(.everyMinute) { context in
            let days = model.days.map { KnowledgeWorkLog.day($0.date, text: $0.text, now: context.date) }
            let today = KnowledgeWorkLog.stamp(context.date).day
            List {
                ForEach(days, id: \.date) { day in
                    Section {
                        if day.entries.isEmpty, day.date == today {
                            Text("Nothing yet today. Write what you are doing and press Return.").foregroundStyle(.secondary)
                        }
                        ForEach(Array(zip(day.entries, day.minutes)), id: \.0) { entry, minutes in
                            WorkLogRow(date: day.date, entry: entry, minutes: minutes,
                                       running: minutes != nil && entry == day.entries.last && day.date == KnowledgeWorkLog.stamp(context.date).day)
                        }
                    } header: {
                        WorkLogDayHeader(day: day, today: KnowledgeWorkLog.stamp(context.date).day)
                    }
                }
                if model.moreDays {
                    Button("Show More Days") { model.showMore() }
                        .buttonStyle(.link)
                }
            }
            // After midnight the new day gets its section without waiting for a write.
            .onChange(of: today) { model.reload() }
        }
    }
}

private struct WorkLogDayHeader: View {
    let day: KnowledgeWorkLog.Day
    let today: String

    var body: some View {
        HStack(spacing: 10) {
            Text(title).font(.headline)
            if day.workMinutes > 0 {
                Text("work \(KnowledgeWorkLog.duration(day.workMinutes))").foregroundStyle(.secondary)
            }
            Spacer()
            ForEach(day.totals.prefix(5), id: \.kind) { total in
                let kind = KnowledgeWorkLog.kind(total.kind.isEmpty ? "other" : total.kind)
                Label("\(kind.title) \(KnowledgeWorkLog.duration(total.minutes))", systemImage: total.kind.isEmpty ? "circle" : kind.symbol)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    private var title: String {
        guard let date = KnowledgeWorkLog.date(day.date) else { return day.date }
        let name = date.formatted(.dateTime.weekday(.wide).day().month(.wide))
        return day.date == today ? "Today · \(name)" : name
    }
}

private struct WorkLogRow: View {
    @Environment(WorkLogModel.self) private var model
    let date: String
    let entry: KnowledgeWorkLog.Entry
    let minutes: Int?
    let running: Bool

    var body: some View {
        let kind = entry.kind.map(KnowledgeWorkLog.kind)
        HStack(spacing: 10) {
            Text(entry.time).monospacedDigit().foregroundStyle(.secondary)
            Label(kind?.title ?? "—", systemImage: kind?.symbol ?? "circle")
                .frame(width: 110, alignment: .leading)
                .foregroundStyle(kind?.isWork == false ? .secondary : .primary)
            Text(linked(entry.text)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            if let minutes {
                Text((running ? "now · " : "") + KnowledgeWorkLog.duration(minutes))
                    .monospacedDigit()
                    .foregroundStyle(running ? Color.accentColor : .secondary)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { model.editRequest = .init(date: date, entry: entry) }
        .contextMenu {
            Button("Again Now") { model.again(entry) }
            Button("Edit…") { model.editRequest = .init(date: date, entry: entry) }
            Button("Copy") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(entry.markdown, forType: .string)
            }
            Divider()
            Button("Delete…", role: .destructive) { model.deleteRequest = .init(date: date, entry: entry) }
        }
        .help("Double-click to edit; right-click: Again Now adds the same entry with the time now")
    }

    /// Web links in the text open with a click.
    private func linked(_ text: String) -> AttributedString {
        var result = AttributedString(text)
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return result }
        for match in detector.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let url = match.url, let range = Range(match.range, in: text),
                  let lower = AttributedString.Index(range.lowerBound, within: result),
                  let upper = AttributedString.Index(range.upperBound, within: result) else { continue }
            result[lower..<upper].link = url
        }
        return result
    }
}

/// Edit…: time, kind and text of one entry; the day stays.
private struct WorkLogEditSheet: View {
    @Environment(WorkLogModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let request: WorkLogModel.EditRequest
    @State private var time = ""
    @State private var kind = ""
    @State private var text = ""

    var body: some View {
        let validTime = KnowledgeWorkLog.minute(time) != nil
        let kinds = KnowledgeWorkLog.presets.map(\.id) + (request.entry.kind.map { KnowledgeWorkLog.presets.map(\.id).contains($0) ? [] : [$0] } ?? [])
        VStack(alignment: .leading, spacing: 12) {
            Text("Edit Entry").font(.title3.bold())
            Text("An entry of \(request.date) in \(KnowledgeWorkLog.folderName)/\(request.date).md. A new time moves it to its place.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Form {
                TextField(text: $time, prompt: Text("09:30")) { RequiredLabel("Time") }
                Picker("Kind", selection: $kind) {
                    Text("None").tag("")
                    ForEach(kinds, id: \.self) { id in
                        Label(KnowledgeWorkLog.kind(id).title, systemImage: KnowledgeWorkLog.kind(id).symbol).tag(id)
                    }
                }
                TextField("Text", text: $text, prompt: Text("What you did"))
            }
            if !validTime {
                Label("Write the time as HH:MM.", systemImage: "exclamationmark.triangle").foregroundStyle(.orange).font(.callout)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Save") {
                    if model.replace(request, with: .init(time: time, kind: kind.isEmpty ? nil : kind, text: text)) { dismiss() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!validTime || (text.trimmingCharacters(in: .whitespaces).isEmpty && kind.isEmpty))
            }
        }
        .padding(20)
        .frame(width: 440)
        .onAppear { (time, kind, text) = (request.entry.time, request.entry.kind ?? "", request.entry.text) }
    }
}
