import MeetingsCore
import SwiftUI

/// Add Tasks to Notebook… (M25): the summary's open tasks, the user's own checked; a Notebook tab.
struct TasksToNotebookSheet: View {
    let model: MeetingsModel
    @Environment(\.dismiss) private var dismiss
    @State private var chosen: Set<String> = []
    @State private var tabs: [String] = []
    @State private var tab = ""
    @State private var problem: String?
    @State private var adding = false

    var body: some View {
        let tasks = model.selectedTasks
        VStack(alignment: .leading, spacing: 12) {
            Text("Add Tasks to Notebook").font(.title3.bold())
            Text("Each task goes under today's heading of the tab, with the meeting's title and date.")
                .foregroundStyle(.secondary)
            if tasks.isEmpty {
                Text("The summary has no open tasks (- [ ] lines).").foregroundStyle(.secondary)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(tasks) { task in
                            Toggle(isOn: Binding(get: { chosen.contains(task.id) }, set: { on in if on { chosen.insert(task.id) } else { chosen.remove(task.id) } })) {
                                Text(task.owner.isEmpty ? task.text : "\(task.owner): \(task.text)")
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 260)
            }
            Picker("Notebook tab", selection: $tab) {
                ForEach(tabs, id: \.self) { Text($0).tag($0) }
            }
            .disabled(tabs.isEmpty)
            if let problem {
                Label(problem, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).font(.callout)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Add \(chosen.count) Task\(chosen.count == 1 ? "" : "s")") {
                    adding = true
                    Task {
                        if await model.addTasks(tasks.filter { chosen.contains($0.id) }, to: tab) { dismiss() }
                        adding = false
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(chosen.isEmpty || tab.isEmpty || adding)
            }
        }
        .padding(20)
        .frame(width: 520)
        .task {
            chosen = Set(tasks.filter(model.isMine).map(\.id))
            do {
                tabs = try await model.links.notebookTabs?() ?? []
                tab = tabs.first ?? ""
            } catch {
                problem = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }
}

/// Propose to Knowledge… (M25): the facts the model found, each aimed at a note; the chosen ones
/// go to the knowledge base's Inbox as proposals.
struct FactsSheet: View {
    let model: MeetingsModel
    @Environment(\.dismiss) private var dismiss
    @State private var chosen: Set<String> = []
    @State private var sending = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Propose to Knowledge").font(.title3.bold())
            Text("The summary model reads this meeting with the names of your knowledge base's notes and picks facts about services, events, repositories and owners. The chosen facts wait in Knowledge → Inbox until you accept them.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if model.findingFacts {
                HStack { ProgressView().controlSize(.small); Text("Reading the meeting…").foregroundStyle(.secondary) }
            }
            if !model.facts.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(model.facts) { fact in
                            Toggle(isOn: Binding(get: { chosen.contains(fact.id) }, set: { on in if on { chosen.insert(fact.id) } else { chosen.remove(fact.id) } })) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("\(fact.note) · \(fact.heading)").bold()
                                    Text(fact.text).textSelection(.enabled)
                                    if !fact.reason.isEmpty { Text(fact.reason).font(.caption).foregroundStyle(.secondary) }
                                }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 340)
            }
            if let problem = model.factsProblem {
                Label(problem, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).font(.callout).textSelection(.enabled)
            }
            HStack {
                Button("Find Again") {
                    Task {
                        await model.findFacts()
                        chosen = Set(model.facts.map(\.id))
                    }
                }
                    .disabled(model.findingFacts || sending)
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Send \(chosen.count) to Inbox") {
                    sending = true
                    Task {
                        if await model.propose(model.facts.filter { chosen.contains($0.id) }) { dismiss() }
                        sending = false
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(chosen.isEmpty || sending || model.findingFacts)
            }
        }
        .padding(20)
        .frame(width: 600)
        .task {
            await model.findFacts()
            chosen = Set(model.facts.map(\.id))
        }
    }
}
