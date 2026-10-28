import AKitFoundation
import AKitKnowledge
import AKitLab
import SwiftUI

/// Work Log → Auto-Fill (docs/design/worklog.md, W8): a day's prompts to the agents in 15- or
/// 30-minute slots, each with its project, git branch and ticket, read on this Mac; Propose
/// Entries sends them to a Pi model (GPT-6 Luna by default) under the sending policy, and the
/// ticked proposals go into that day's log.
struct WorkLogFillView: View {
    @Environment(WorkLogModel.self) private var model
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var model = model
        HSplitView {
            Form {
                Section {
                    DatePicker("Day", selection: $model.fillDay, in: ...Date.now, displayedComponents: .date)
                    Picker("Sessions", selection: $model.fillSource) {
                        ForEach(WorkLogModel.FillSource.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    .help("Whose saved sessions to read: Claude Code's, Pi's or both")
                    Picker("Slot", selection: $model.fillSlot) {
                        Text("15 min").tag(15)
                        Text("30 min").tag(30)
                    }
                    .pickerStyle(.segmented)
                    .help("The day is cut into slots of this length; the model writes about one entry per slot")
                    Picker("Language", selection: $model.fillLanguage) {
                        ForEach(LabLanguage.allCases, id: \.self) { Text($0.name).tag($0) }
                    }
                    .help("The language the model writes the entries in; Czech unless you choose another")
                    PiModelPicker(selection: $model.fillModel, models: model.fillModels,
                                  empty: "Default (\(model.defaultModel ?? (model.fillModels.isEmpty ? "reading the list…" : "none")))",
                                  help: "Pi's models (pi --list-models); GitHub Copilot's when Pi has them", allowsOther: false) {
                        Text("Model")
                    }
                } footer: {
                    Text(summary).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Section {
                    HStack {
                        Button("Propose Entries") { Task { await model.propose() } }
                            .keyboardShortcut(.defaultAction)
                            .disabled(model.fillSlots.isEmpty || model.fillRunning || model.fillReading)
                            .help("Send the slots to the model; nothing is added until you press Add Selected")
                        if model.fillRunning { ProgressView().controlSize(.small) }
                    }
                }
            }
            .formStyle(.grouped)
            .frame(minWidth: 300, idealWidth: 340, maxWidth: 420)

            VStack(spacing: 0) {
                if model.proposals.isEmpty {
                    WorkLogSlotList(slots: model.fillSlots, reading: model.fillReading)
                } else {
                    proposals
                }
            }
            .frame(minWidth: 380, maxWidth: .infinity, maxHeight: .infinity)
        }
        .task { await model.loadModels() }
        // New sessions refresh the slots but keep the proposals; a new day, source or slot drops them.
        .task(id: "\(model.fillKey) \(app.sessions.count)") { await model.readDay(app.sessions) }
        .onChange(of: model.fillKey) { model.clearProposals() }
    }

    private var summary: String {
        if model.fillReading { return "Reading the day's sessions…" }
        let prompts = model.fillSlots.reduce(0) { $0 + $1.moments.count }
        if prompts == 0 { return "No prompts on \(model.fillDayString) in these sessions." }
        let target = model.fillModel.isEmpty ? (model.defaultModel ?? "Pi's default model") : model.fillModel
        let count = { (n: Int, noun: String) in "\(n) \(noun)\(n == 1 ? "" : "s")" }
        return "\(count(prompts, "prompt")) in \(count(model.fillSessions.count, "session")), \(count(model.fillSlots.count, "slot")). Propose Entries sends the start of each prompt (at most 240 characters) with its project, branch and ticket to \(target) through Pi, under the sending policy and the send log (worklog-fill)."
    }

    @ViewBuilder
    private var proposals: some View {
        @Bindable var model = model
        HStack {
            Text(model.proposalNote ?? "").font(.callout).foregroundStyle(.secondary)
            Spacer()
            Button("Discard") { model.clearProposals() }
            Button("Add Selected (\(model.chosen.count))") { model.addProposals() }
                .disabled(model.chosen.isEmpty)
                .help("Add the ticked entries to the day's log with their times; you can edit them there")
        }
        .padding(10)
        Divider()
        List {
            ForEach(Array(model.proposals.enumerated()), id: \.offset) { index, entry in
                let kind = entry.kind.map(KnowledgeWorkLog.kind)
                Toggle(isOn: Binding(get: { model.chosen.contains(index) },
                                     set: { if $0 { model.chosen.insert(index) } else { model.chosen.remove(index) } })) {
                    HStack(spacing: 10) {
                        Text(entry.time).monospacedDigit().foregroundStyle(.secondary)
                        Label(kind?.title ?? "—", systemImage: kind?.symbol ?? "circle").frame(width: 110, alignment: .leading)
                        Text(entry.text).textSelection(.enabled)
                    }
                }
            }
        }
    }
}

/// What the day holds before anything is sent: each slot with its places and prompts.
private struct WorkLogSlotList: View {
    let slots: [WorkLogFill.Slot]
    let reading: Bool

    var body: some View {
        if reading {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if slots.isEmpty {
            ContentUnavailableView("No prompts that day", systemImage: "clock",
                                   description: Text("Choose another day or harness. Auto-Fill reads the prompts you gave Claude Code and Pi in their saved sessions."))
        } else {
            List {
                ForEach(slots, id: \.time) { slot in
                    Section {
                        ForEach(Array(slot.moments.enumerated()), id: \.offset) { _, moment in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text(moment.time).monospacedDigit().foregroundStyle(.secondary)
                                Text(moment.text).lineLimit(2)
                            }
                            .font(.callout)
                        }
                    } header: {
                        HStack {
                            Text(slot.time).font(.headline).monospacedDigit()
                            Text(slot.places.joined(separator: "; ")).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                }
            }
        }
    }
}
