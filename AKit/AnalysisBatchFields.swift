import AKitErrorAnalysis
import AKitFoundation
import AKitInsights
import AKitLab
import SwiftUI

/// What an error analysis batch asks for (`akit lab new analysis`): which sessions of the
/// index, how many, and who writes and matches the notes.
struct AnalysisBatchDraft {
    /// A bound project id or a folder the sessions ran in; nil = all projects.
    var project: String?
    var useFrom = false
    var from = Calendar.current.date(byAdding: .day, value: -30, to: .now) ?? .now
    var useTo = false
    var to = Date.now
    var size = 20
    /// Automatic: a reviewer of another model family than the sampled sessions', when the
    /// sending policy allows one (`Batches.defaultReviewer`).
    var automatic = true
    var harness: LabHarness = .claudeCode
    var model = ""
    var effort = "high"
    /// Empty: the notes model matches too.
    var matchingModel = ""
    var language: LabLanguage = .english

    var filter: Sampling.Filter {
        let start = Calendar.current.startOfDay(for: from)
        let end = Calendar.current.startOfDay(for: to).addingTimeInterval(86_399)
        return Sampling.Filter(project: project, from: useFrom ? start : nil, to: useTo ? end : nil)
    }

    /// nil: Automatic.
    var notesAgent: LabAgent? {
        automatic ? nil : LabAgent(harness: harness, model: model.trimmingCharacters(in: .whitespaces), effort: effort, mode: .call)
    }

    /// nil: the notes agent matches too.
    func matchingAgent(defaultAgent: LabAgent) -> LabAgent? {
        let name = matchingModel.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return notesAgent }
        var agent = notesAgent ?? defaultAgent
        agent.model = name
        agent.mode = .call
        return agent
    }

    var isValid: Bool { automatic || harness == .pi || !model.trimmingCharacters(in: .whitespaces).isEmpty }
}

/// The batch form of New Lab Run: project (from the session index), period, size, the notes
/// agent, the matching model and the language.
struct AnalysisBatchFields: View {
    struct ProjectOption: Hashable, Sendable {
        /// What the filter gets: a project id or a folder.
        var value: String
        var title: String
        var sessions: Int
    }

    @Binding var draft: AnalysisBatchDraft
    @State private var projects: [ProjectOption] = []

    var body: some View {
        Text("AKit samples sessions of the index (\(Sampling.minimumRequests)+ requests each): a random quarter, the rest stratified by cheap signals, harness and model. For each session a model writes notes, a verifier checks them and matching routes them to modes, two sessions at a time; clustering runs once at the end. Transcripts and notes go out under the sending policy.")
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        Form {
            Picker("Project", selection: $draft.project) {
                Text("All projects").tag(String?.none)
                ForEach(projects, id: \.self) { option in
                    Text("\(option.title) · \(option.sessions)").tag(String?.some(option.value))
                }
            }
            .help("A project the sessions are bound to, or a folder they ran in; the number is how many long-enough sessions it has")
            LabeledContent("Period") {
                HStack {
                    Toggle("From", isOn: $draft.useFrom)
                    DatePicker("From", selection: $draft.from, displayedComponents: .date)
                        .labelsHidden()
                        .disabled(!draft.useFrom)
                    Toggle("To", isOn: $draft.useTo)
                    DatePicker("To", selection: $draft.to, displayedComponents: .date)
                        .labelsHidden()
                        .disabled(!draft.useTo)
                }
            }
            Stepper("Sessions: \(draft.size)", value: $draft.size, in: 1...200)
            Picker("Notes by", selection: $draft.automatic) {
                Text("Automatic").tag(true)
                Text("Choose…").tag(false)
            }
            .help("Automatic: a model of another family than the one that ran most sampled sessions, when the sending policy allows it; else Claude Code with your settings")
            if !draft.automatic {
                ReviewAgentFields(harness: $draft.harness, modelName: $draft.model, effort: $draft.effort)
            }
            TextField("Matching model", text: $draft.matchingModel, prompt: Text("same as the notes"))
                .help("The model that routes notes to modes; kept while its route acceptance holds")
            Picker("Language", selection: $draft.language) {
                ForEach(LabLanguage.allCases, id: \.self) { Text($0.name).tag($0) }
            }
        }
        .formStyle(.grouped)
        .task {
            let env = HarnessEnvironment.current
            draft.language = LabSettings.load(env: env).reportLanguage
            projects = await Task.detached { Self.projects(env: env) }.value
        }
    }

    /// Bound projects first, then the folders sessions ran in, by how many sessions could be sampled.
    nonisolated static func projects(env: HarnessEnvironment) -> [ProjectOption] {
        guard let database = try? AnalysisIndex.open(env: env), let sessions = try? AnalysisIndex.sessions(database) else { return [] }
        let long = sessions.filter { $0.file != nil && $0.requests >= Sampling.minimumRequests }
        let bound = Dictionary(grouping: long.filter { $0.projectID != nil }, by: { $0.projectID ?? "" }).map { id, members in
            ProjectOption(value: id, title: "Project \(id)", sessions: members.count)
        }
        let folders = Dictionary(grouping: long.filter { $0.cwd != nil }, by: { $0.cwd ?? "" }).map { cwd, members in
            ProjectOption(value: cwd, title: URL(filePath: cwd).tildePath, sessions: members.count)
        }
        return bound.sorted { $0.sessions > $1.sessions } + folders.sorted { ($0.sessions, $1.title) > ($1.sessions, $0.title) }
    }
}
