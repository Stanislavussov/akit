import AKitKnowledge
import SwiftUI

/// Work Log → Calendar (docs/design/worklog.md, W11): the week (or one day) as columns of hours.
/// Blocks (meetings, lunch) hold their own time and are drawn solid; plain entries fill the time
/// up to the next one and are drawn light behind them, so an empty stretch is time not filled.
/// Drag on an empty stretch (or click it) for a new block; drag a block to move it, its lower
/// edge to change its end; click it to edit. Each day's header shows work against the norm.
struct WorkLogCalendarView: View {
    @Environment(WorkLogModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            WorkLogCalendarBar()
            Divider()
            WorkLogWeekGrid(dates: model.calendarDates)
        }
        .sheet(item: Binding(get: { model.blockRequest }, set: { model.blockRequest = $0 })) { request in
            WorkLogBlockSheet(request: request)
        }
        .sheet(item: Binding(get: { model.importRequest.map(ImportDays.init) }, set: { model.importRequest = $0?.dates })) { days in
            WorkLogImportSheet(dates: days.dates)
        }
    }

    private struct ImportDays: Identifiable {
        var dates: [String]
        var id: String { dates.joined(separator: ",") }
    }
}

/// ‹ Today ›, the week's name, Week/Day, Weekend, the work day's norm, Import, New Block.
private struct WorkLogCalendarBar: View {
    @Environment(WorkLogModel.self) private var model

    var body: some View {
        @Bindable var model = model
        HStack(spacing: 8) {
            ControlGroup {
                Button("Back", systemImage: "chevron.left") { model.moveCalendar(-1) }
                    .help(model.calendarDay == nil ? "The week before" : "The day before")
                Button("Today") { model.calendarToday() }
                    .help("Go to today")
                Button("On", systemImage: "chevron.right") { model.moveCalendar(1) }
                    .help(model.calendarDay == nil ? "The week after" : "The day after")
            }
            .fixedSize()
            Text(title).font(.headline).lineLimit(1).layoutPriority(1)
            Spacer()
            Picker("Show", selection: Binding(get: { model.calendarDay == nil ? 0 : 1 }, set: { mode in
                model.calendarDay = mode == 0 ? nil : model.calendarDates.contains(KnowledgeWorkLog.stamp(.now).day)
                    ? KnowledgeWorkLog.stamp(.now).day : model.calendarDates.first
            })) {
                Text("Week").tag(0)
                Text("Day").tag(1)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .help("The whole week, or one day wider")
            Toggle("Weekend", isOn: $model.showWeekend)
                .toggleStyle(.checkbox)
                .disabled(model.calendarDay != nil)
                .help("Show Saturday and Sunday too")
            WorkLogHoursField()
            Button("Import from Calendar…", systemImage: "calendar.badge.plus") { model.importRequest = model.calendarDates }
                .help("Put the meetings of these days from macOS Calendar (Outlook, Google, iCloud accounts added there) in as blocks")
            Button("New Block…", systemImage: "plus") {
                let today = KnowledgeWorkLog.stamp(.now)
                let date = model.calendarDates.contains(today.day) ? today.day : (model.calendarDates.first ?? today.day)
                let start = (KnowledgeWorkLog.minute(today.time) ?? 540) / 30 * 30
                model.blockRequest = .init(date: date, start: start, end: min(24 * 60, start + 30))
            }
            .help("A block with its own start and end: a meeting, lunch, a focus block. Or drag on the calendar")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var title: String {
        let dates = model.calendarDates.compactMap(KnowledgeWorkLog.date)
        guard let first = dates.first, let last = dates.last else { return "" }
        if dates.count == 1 { return first.formatted(.dateTime.weekday(.wide).day().month(.wide).year()) }
        let week = Calendar(identifier: .iso8601).component(.weekOfYear, from: first)
        return "Week \(week) · \(first.formatted(.dateTime.day().month(.abbreviated))) – \(last.formatted(.dateTime.day().month(.abbreviated).year()))"
    }
}

/// Work day: the norm of a work day for the base, in hours (7.5 by default).
struct WorkLogHoursField: View {
    @Environment(WorkLogModel.self) private var model
    @State private var text = ""

    var body: some View {
        HStack(spacing: 4) {
            Text("Work day")
            TextField("Hours", text: $text)
                .frame(width: 44)
                .multilineTextAlignment(.trailing)
                .onSubmit(save)
            Text("h")
        }
        .help("How many hours a work day (Monday to Friday) should have, for every day without its own norm. Return saves it")
        .onAppear { text = KnowledgeWorkLog.hoursText(model.hours) }
        .onChange(of: model.hours) { _, hours in text = KnowledgeWorkLog.hoursText(hours) }
    }

    private func save() {
        guard let hours = Double(text.replacingOccurrences(of: ",", with: ".")), (0...24).contains(hours) else {
            model.problem = "A work day has 0 to 24 hours, like 7.5."
            text = KnowledgeWorkLog.hoursText(model.hours)
            return
        }
        model.setHours(hours)
    }
}

/// The columns: a time scale and one column per day, in a vertical scroll.
private struct WorkLogWeekGrid: View {
    @Environment(WorkLogModel.self) private var model
    let dates: [String]
    static let hourHeight: CGFloat = 44

    var body: some View {
        let days = dates.map(model.dayOnCalendar)
        let hours = Self.hours(days)
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Color.clear.frame(width: 44, height: 1)
                ForEach(days, id: \.date) { day in
                    WorkLogDayColumnHeader(day: day)
                        .frame(maxWidth: .infinity)
                }
            }
            .padding(.vertical, 6)
            Divider()
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    HStack(alignment: .top, spacing: 0) {
                        WorkLogTimeScale(hours: hours)
                        ForEach(days, id: \.date) { day in
                            WorkLogDayColumn(day: day, hours: hours, wide: dates.count == 1)
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .padding(.bottom, 8)
                    .id("grid")
                }
                .onAppear { proxy.scrollTo("grid", anchor: .top) }
            }
        }
        .task { await model.tick() }
    }

    /// 7:00 to 19:00, wider when an entry is earlier or later.
    static func hours(_ days: [KnowledgeWorkLog.Day]) -> ClosedRange<Int> {
        var first = 7, last = 19
        for day in days {
            for (entry, end) in zip(day.entries, day.ends) {
                first = min(first, entry.minute / 60)
                last = max(last, ((end ?? entry.minute) + 59) / 60)
            }
        }
        return first...min(24, max(last, first + 1))
    }
}

private struct WorkLogTimeScale: View {
    let hours: ClosedRange<Int>

    var body: some View {
        VStack(alignment: .trailing, spacing: 0) {
            ForEach(Array(hours.dropLast()), id: \.self) { hour in
                Text(String(format: "%02d:00", hour))
                    .font(.caption2)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(height: WorkLogWeekGrid.hourHeight, alignment: .top)
                    .offset(y: -6)
            }
        }
        .frame(width: 44)
        .padding(.top, 6)
    }
}

/// A day's name, work against its norm and what is missing; a click shows the day alone.
private struct WorkLogDayColumnHeader: View {
    @Environment(WorkLogModel.self) private var model
    let day: KnowledgeWorkLog.Day
    @State private var editingNorm = false

    var body: some View {
        let norm = KnowledgeWorkLog.norm(of: day, hours: model.hours)
        let work = day.workMinutes, missing = max(0, norm - work)
        let today = day.date == KnowledgeWorkLog.stamp(.now).day
        VStack(spacing: 2) {
            Text(name)
                .font(.callout.weight(today ? .bold : .semibold))
                .foregroundStyle(today ? Color.accentColor : .primary)
            Text(norm > 0 ? "\(Self.hours(work)) of \(Self.hours(norm)) h" : (work > 0 ? "\(Self.hours(work)) h" : "no norm"))
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
            if norm > 0 {
                Text(missing > 0 ? "missing \(KnowledgeWorkLog.duration(missing))" : "filled")
                    .font(.caption2)
                    .foregroundStyle(missing > 0 ? .orange : .green)
            }
        }
        .padding(.horizontal, 4)
        .contentShape(Rectangle())
        .onTapGesture { model.calendarDay = model.calendarDay == nil ? day.date : nil }
        .contextMenu {
            Button("Show This Day") { model.calendarDay = day.date }
            Button("Set Norm…") { editingNorm = true }
            if day.norm != nil { Button("Default Norm") { model.setNorm(nil, on: day.date) } }
            Button("Day Off (no norm)") { model.setNorm(0, on: day.date) }
        }
        .popover(isPresented: $editingNorm) { WorkLogNormPopover(day: day) }
        .help((day.norm != nil ? "This day has its own norm. " : "") + "Click: show this day alone (or the week again). Right-click: its norm, a day off")
    }

    private var name: String {
        KnowledgeWorkLog.date(day.date)?.formatted(.dateTime.weekday(.abbreviated).day().month(.defaultDigits)) ?? day.date
    }

    static func hours(_ minutes: Int) -> String { KnowledgeWorkLog.hoursText((Double(minutes) / 60 * 100).rounded() / 100) }
}

/// Set Norm…: one day's own hours (a half day, a day off), or back to the default.
private struct WorkLogNormPopover: View {
    @Environment(WorkLogModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let day: KnowledgeWorkLog.Day
    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Norm of \(day.date)").font(.headline)
            HStack {
                TextField("Hours", text: $text).frame(width: 60).onSubmit(save)
                Text("h")
            }
            Text("0 for a day off. Saved as “norm: 4 h” in the day's file.").font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Default (\(KnowledgeWorkLog.hoursText(model.hours)) h)") {
                    model.setNorm(nil, on: day.date)
                    dismiss()
                }
                Spacer()
                Button("Save", action: save).keyboardShortcut(.defaultAction)
            }
        }
        .padding(12)
        .frame(width: 260)
        .onAppear { text = day.norm.map { KnowledgeWorkLog.hoursText(Double($0) / 60) } ?? KnowledgeWorkLog.hoursText(model.hours) }
    }

    private func save() {
        guard let hours = Double(text.replacingOccurrences(of: ",", with: ".")), (0...24).contains(hours) else {
            model.problem = "A day has 0 to 24 hours."
            return
        }
        model.setNorm(hours, on: day.date)
        dismiss()
    }
}

/// One day's column: hour lines, plain entries light, blocks solid, the drag for a new block,
/// the line of now.
private struct WorkLogDayColumn: View {
    @Environment(WorkLogModel.self) private var model
    let day: KnowledgeWorkLog.Day
    let hours: ClosedRange<Int>
    let wide: Bool
    /// A new block being dragged: its first and current minute.
    @State private var drawing: (from: Int, to: Int)?

    var body: some View {
        let height = CGFloat(hours.count - 1) * WorkLogWeekGrid.hourHeight
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                // Hour and half-hour lines; a click or drag here draws a new block.
                VStack(spacing: 0) {
                    ForEach(Array(hours.dropLast()), id: \.self) { _ in
                        VStack(spacing: 0) {
                            Divider()
                            Spacer()
                            Divider().opacity(0.35)
                            Spacer()
                        }
                        .frame(height: WorkLogWeekGrid.hourHeight)
                    }
                }
                .contentShape(Rectangle())
                .gesture(newBlock)
                ForEach(Array(day.entries.enumerated()), id: \.offset) { index, entry in
                    if let end = day.ends[index] {
                        WorkLogCalendarItem(date: day.date, entry: entry, minutes: day.minutes[index] ?? 0, end: end,
                                            hours: hours, wide: wide, width: geometry.size.width)
                    }
                }
                if let drawing {
                    let (from, to) = (min(drawing.from, drawing.to), max(drawing.from, drawing.to) + 15)
                    RoundedRectangle(cornerRadius: 5)
                        .fill(Color.accentColor.opacity(0.3))
                        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color.accentColor, style: .init(lineWidth: 1, dash: [4])))
                        .overlay(alignment: .topLeading) {
                            Text("\(KnowledgeWorkLog.time(from))–\(WorkLogModel.endText(to))").font(.caption2).padding(3)
                        }
                        .frame(width: geometry.size.width - 6, height: Self.y(to, hours) - Self.y(from, hours))
                        .offset(x: 3, y: Self.y(from, hours))
                        .allowsHitTesting(false)
                }
                if day.date == KnowledgeWorkLog.stamp(model.now).day, let now = KnowledgeWorkLog.minute(KnowledgeWorkLog.stamp(model.now).time),
                   hours.contains(now / 60) {
                    Rectangle().fill(.red).frame(height: 1.5).offset(y: Self.y(now, hours)).allowsHitTesting(false)
                }
            }
        }
        .frame(height: height)
        .padding(.top, 6)
        .overlay(alignment: .leading) { Divider() }
    }

    /// A press and drag over empty time: the stretch, in 15 minutes, becomes a new block (a click
    /// alone gives 30 minutes).
    private var newBlock: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let from = Self.minute(at: value.startLocation.y, hours)
                drawing = (from, Self.minute(at: value.location.y, hours))
            }
            .onEnded { value in
                let from = Self.minute(at: value.startLocation.y, hours), to = Self.minute(at: value.location.y, hours)
                drawing = nil
                let start = min(from, to)
                let end = abs(value.translation.height) < 4 ? start + 30 : max(from, to) + 15
                model.blockRequest = .init(date: day.date, start: start, end: min(24 * 60, end))
            }
    }

    static func y(_ minute: Int, _ hours: ClosedRange<Int>) -> CGFloat {
        CGFloat(minute - hours.lowerBound * 60) / 60 * WorkLogWeekGrid.hourHeight
    }

    /// The 15-minute step under a point.
    static func minute(at y: CGFloat, _ hours: ClosedRange<Int>) -> Int {
        let minute = Int((y / WorkLogWeekGrid.hourHeight * 60).rounded(.down)) + hours.lowerBound * 60
        return max(hours.lowerBound * 60, min(hours.upperBound * 60 - 15, minute / 15 * 15))
    }
}

/// A block or a plain entry in a column. A block moves with a drag and ends where its lower edge
/// is dragged; both open Edit… with a click.
private struct WorkLogCalendarItem: View {
    @Environment(WorkLogModel.self) private var model
    let date: String
    let entry: KnowledgeWorkLog.Entry
    let minutes: Int
    let end: Int
    let hours: ClosedRange<Int>
    let wide: Bool
    let width: CGFloat
    @State private var move: Int = 0
    @State private var stretch: Int = 0

    var body: some View {
        let start = entry.minute + move, last = max(start + 15, end + move + stretch)
        let top = WorkLogDayColumn.y(start, hours), height = max(8, WorkLogDayColumn.y(last, hours) - top)
        let color = Self.color(entry.kind)
        let kind = entry.kind.map(KnowledgeWorkLog.kind)
        RoundedRectangle(cornerRadius: 5)
            .fill(color.opacity(entry.isBlock ? 0.32 : 0.12))
            .overlay(alignment: .leading) { Rectangle().fill(color).frame(width: 3) }
            .overlay(alignment: .topLeading) {
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 3) {
                        if let kind { Image(systemName: kind.symbol) }
                        Text(entry.isBlock ? "\(KnowledgeWorkLog.time(start))–\(WorkLogModel.endText(last))" : entry.time).monospacedDigit()
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    if height > 22 {
                        Text(entry.text.isEmpty ? (kind?.title ?? "") : entry.text)
                            .font(wide ? .callout : .caption)
                            .lineLimit(max(1, Int(height / 15) - 1))
                    }
                }
                .padding(.leading, 6)
                .padding(.top, 2)
                .padding(.trailing, 2)
            }
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .overlay(alignment: .bottom) {
                if entry.isBlock {
                    // The lower edge: drag it to change the end.
                    Color.clear.frame(height: 6).contentShape(Rectangle())
                        .onHover { inside in if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() } }
                        .gesture(DragGesture(minimumDistance: 2)
                            .onChanged { stretch = Self.steps($0.translation.height) }
                            .onEnded { value in
                                let new = max(entry.minute + 15, end + Self.steps(value.translation.height))
                                stretch = 0
                                model.moveBlock(entry, on: date, start: entry.minute, end: min(24 * 60, new))
                            })
                }
            }
            // Plain entries sit narrower on the left, blocks over them on the right.
            .frame(width: entry.isBlock ? width - 6 : width * 0.45, height: height)
            .offset(x: 3, y: top)
            .zIndex(entry.isBlock ? 1 : 0)
            .gesture(entry.isBlock ? DragGesture(minimumDistance: 3)
                .onChanged { move = Self.steps($0.translation.height) }
                .onEnded { value in
                    let shift = Self.steps(value.translation.height)
                    move = 0
                    let length = end - entry.minute
                    let start = max(0, min(24 * 60 - length, entry.minute + shift))
                    model.moveBlock(entry, on: date, start: start, end: start + length)
                } : nil)
            .onTapGesture { model.editRequest = .init(date: date, entry: entry) }
            .contextMenu {
                Button("Edit…") { model.editRequest = .init(date: date, entry: entry) }
                Divider()
                Button("Delete…", role: .destructive) { model.deleteRequest = .init(date: date, entry: entry) }
            }
            .help(help)
    }

    private var help: String {
        let what = "\(entry.kind.map { "#\($0) " } ?? "")\(entry.text)"
        return entry.isBlock
            ? "\(what): a block, \(KnowledgeWorkLog.duration(minutes)). Click to edit, drag to move, drag the lower edge to change the end"
            : "\(what): from \(entry.time) until the next entry, \(KnowledgeWorkLog.duration(minutes)) without the blocks in it. Click to edit"
    }

    /// A drag in 15-minute steps.
    static func steps(_ height: CGFloat) -> Int { Int((height / WorkLogWeekGrid.hourHeight * 4).rounded()) * 15 }

    static func color(_ kind: String?) -> Color {
        switch kind {
        case "meeting": .blue
        case "break": .gray
        case "bug": .red
        case "review": .orange
        case "agent": .teal
        case "task": .green
        case "research": .indigo
        case "reply": .yellow
        default: .brown
        }
    }
}

/// New Block: the day and times from the drag, a kind (Meeting by default) and a text.
private struct WorkLogBlockSheet: View {
    @Environment(WorkLogModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let request: WorkLogModel.BlockRequest
    @State private var date = Date.now
    @State private var start = ""
    @State private var end = ""
    @State private var kind = "meeting"
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        let startMinute = KnowledgeWorkLog.minute(start)
        let endMinute = end.wholeMatch(of: /0?24:00/) != nil ? 24 * 60 : KnowledgeWorkLog.minute(end)
        let valid = startMinute != nil && endMinute != nil && (endMinute ?? 0) > (startMinute ?? 0)
        VStack(alignment: .leading, spacing: 12) {
            Text("New Block").font(.title3.bold())
            Text("A block holds its own time: a meeting, lunch, a focus block. Entries around it don't count its minutes.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Form {
                DatePicker("Day", selection: $date, displayedComponents: .date)
                TextField(text: $start, prompt: Text("09:00")) { RequiredLabel("Start") }
                TextField(text: $end, prompt: Text("09:30")) { RequiredLabel("End") }
                Picker("Kind", selection: $kind) {
                    ForEach(KnowledgeWorkLog.presets) { preset in
                        Label(preset.title, systemImage: preset.symbol).tag(preset.id)
                    }
                }
                TextField("Text", text: $text, prompt: Text("Standup, Lunch, COL-123 planning"))
                    .focused($focused)
                    .onSubmit(add)
            }
            if !valid {
                Label("Write the times as HH:MM; the end comes after the start.", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange).font(.callout)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Add", action: add).keyboardShortcut(.defaultAction).disabled(!valid)
            }
        }
        .padding(20)
        .frame(width: 440)
        .onAppear {
            date = KnowledgeWorkLog.date(request.date) ?? .now
            start = KnowledgeWorkLog.time(request.start)
            end = WorkLogModel.endText(request.end)
            focused = true
        }
    }

    private func add() {
        let endMinute = end.wholeMatch(of: /0?24:00/) != nil ? 24 * 60 : KnowledgeWorkLog.minute(end)
        guard let first = KnowledgeWorkLog.minute(start), let last = endMinute, last > first else { return }
        let block = WorkLogModel.BlockRequest(date: KnowledgeWorkLog.stamp(date).day, start: first, end: last)
        if model.addBlock(block, kind: kind, text: text) { dismiss() }
    }
}

/// Import from Calendar: the meetings of the days on screen, ticked unless they are in the log
/// already; Add Selected puts them in as blocks of the chosen kind.
private struct WorkLogImportSheet: View {
    @Environment(WorkLogModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let dates: [String]
    @State private var events: [CalendarEvents.Event] = []
    @State private var chosen: Set<String> = []
    @State private var present: Set<String> = []
    @State private var problem: String?
    @State private var loading = true
    @State private var kind = "meeting"

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Import from Calendar").font(.title3.bold())
            Text("The meetings of \(dates.first ?? "")\(dates.count > 1 ? " – \(dates.last ?? "")" : "") in macOS Calendar: the accounts added in Calendar (Outlook, Google, iCloud). AKit only reads them. All-day events and declined invitations are left out.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if loading {
                ProgressView().frame(maxWidth: .infinity, minHeight: 120)
            } else if let problem {
                Label(problem, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                Button("Open Privacy Settings") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars")!)
                }
            } else if events.isEmpty {
                Text("No meetings on these days.").foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 80)
            } else {
                List {
                    ForEach(dates, id: \.self) { date in
                        let ofDay = events.filter { $0.date == date }
                        if !ofDay.isEmpty {
                            Section(KnowledgeWorkLog.date(date)?.formatted(.dateTime.weekday(.wide).day().month(.wide)) ?? date) {
                                ForEach(ofDay) { event in
                                    Toggle(isOn: Binding(get: { chosen.contains(event.id) },
                                                         set: { if $0 { chosen.insert(event.id) } else { chosen.remove(event.id) } })) {
                                        HStack {
                                            Text("\(KnowledgeWorkLog.time(event.start))–\(WorkLogModel.endText(event.end))").monospacedDigit()
                                            Text(event.title)
                                            Spacer()
                                            if present.contains(event.id) { Text("in the log").font(.caption).foregroundStyle(.secondary) }
                                            Text(event.calendar).font(.caption).foregroundStyle(.secondary)
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
                .frame(minHeight: 260)
                Picker("Kind", selection: $kind) {
                    ForEach(KnowledgeWorkLog.presets) { preset in
                        Label(preset.title, systemImage: preset.symbol).tag(preset.id)
                    }
                }
                .fixedSize()
            }
            HStack {
                if !events.isEmpty {
                    Button("All") { chosen = Set(events.map(\.id)).subtracting(present) }
                    Button("None") { chosen = [] }
                }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Add \(chosen.count) Selected") {
                    model.addEvents(events.filter { chosen.contains($0.id) }, kind: kind)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(chosen.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 560)
        .task { await load() }
    }

    private func load() async {
        defer { loading = false }
        switch await CalendarEvents.requestAccess() {
        case .denied(let message):
            problem = message
        case .granted:
            events = CalendarEvents.events(on: dates)
            present = Set(events.filter { event in
                model.dayOnCalendar(event.date).entries.contains { $0.minute == event.start && $0.endMinute == event.end && $0.text == event.title }
            }.map(\.id))
            chosen = Set(events.map(\.id)).subtracting(present)
        }
    }
}
