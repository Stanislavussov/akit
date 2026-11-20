import AKitBrain
import AKitFlows
import AKitFoundation
import AKitLab
import SwiftUI

/// Setup → Flows (docs/design/flows.md F2, F3, F14): a flow is a column of step cards, set up by
/// clicks only. Save writes `brain/flows/<name>.yaml`; a layer includes it; Apply… renders it for Pi.
struct FlowsView: View {
    @Environment(AppModel.self) private var model
    @State private var selection: String?
    @State private var draft: Flow?
    /// The draft as it was loaded or saved; Save is on when they differ.
    @State private var saved: Flow?
    @State private var piModels: [String] = []
    @State private var project: URL?
    @State private var issues: [FlowIssue]?
    @State private var problem: String?
    @State private var saving = false
    @State private var applying: ApplyTarget?
    /// The one open card.
    @State private var expanded: String?
    @State private var choosingSkills: String?
    /// The card whose Generate… popover is open.
    @State private var generating: String?
    /// Each step's prompt before Generate… replaced it, for Undo.
    @State private var promptBefore: [String: String?] = [:]
    /// The open card shows its rarely changed settings too.
    @State private var showsMore = false
    @State private var capabilities: PiCapabilities?

    struct ApplyTarget: Identifiable {
        let id = UUID()
        let project: URL?
    }

    private var env: HarnessEnvironment { .current }
    private var brainNames: [String] { model.brain.map { BrainFlows.names(in: $0.root) } ?? [] }
    private var rendered: [FlowFile] { FlowFile.list(project: project, env: env) }
    private var skills: [String] { FlowFile.knownSkills(project: project, env: env).sorted() }
    private var commands: [String] { FlowProjectCommands.known(in: project) }
    private static let builtInTools = ["read", "bash", "edit", "write", "grep", "find", "ls"]
    private static let newTag = "\u{1}new"

    var body: some View {
        HStack(spacing: 0) {
            list.frame(width: 230)
            Divider()
            if let draft {
                editor(draft)
            } else {
                ContentUnavailableView("No Flow Open", systemImage: "arrow.triangle.branch",
                                       description: Text("Pick a flow on the left, or New from Template → Feature."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task {
            let found = await LabRuns.models(for: .pi, env: env)
            // The made-up home's Pi has no credentials: its demo models stay.
            if !found.isEmpty || DebugSnapshot.options?.demo != true { piModels = found }
        }
        .onAppear {
            capabilities = FlowFile.capabilities(env: env)
            snapshotSetup()
        }
        .sheet(item: $applying) { ProjectSetupSheet(initialProject: $0.project, forHome: $0.project == nil) }
    }

    // MARK: - List

    private var list: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Project", selection: $project) {
                Text("None").tag(URL?.none)
                ForEach(model.projects, id: \.self) { Text($0.lastPathComponent).tag(URL?.some($0)) }
            }
            .help("The project whose commands the checks offer, whose rendered flows are listed below and that Apply… renders into")
            Menu("New from Template", systemImage: "plus") {
                ForEach(FlowTemplates.all) { template in
                    Button(template.like.map { "\(template.name.capitalized)  (like OMC \($0))" } ?? template.name.capitalized) {
                        newFromTemplate(template)
                    }
                    .help(template.summary)
                }
            }
            .help("Copy a built-in flow into a new draft; Save writes it into the brain")
            .disabled(model.brain == nil)
            List(selection: Binding(get: { selection }, set: { open($0) })) {
                Section("Brain") {
                    if draft != nil, saved == nil { Text("\(draft?.name ?? "") (new)").italic().tag(Self.newTag) }
                    ForEach(brainNames, id: \.self) { name in
                        Label(name, systemImage: "arrow.triangle.branch").tag(name)
                    }
                }
                Section(project.map { "Rendered for Pi (\($0.lastPathComponent))" } ?? "Rendered for Pi (home)") {
                    if rendered.isEmpty { Text("None yet: include a flow in a layer, then Apply…").foregroundStyle(.secondary).font(.caption) }
                    ForEach(rendered, id: \.url) { file in
                        Label("\(file.name) · \(file.scope.rawValue)", systemImage: file.flow == nil ? "exclamationmark.triangle" : "doc.text")
                            .help(file.flow == nil ? "Can't be read: \(String(describing: file.result))" : file.url.path)
                            .selectionDisabled()
                    }
                }
            }
            .listStyle(.sidebar)
        }
        .padding(10)
    }

    private func open(_ name: String?) {
        guard let name, name != Self.newTag, let brain = model.brain,
              let text = try? String(contentsOf: BrainFlows.url(of: name, in: brain.root), encoding: .utf8) else { return }
        selection = name
        issues = nil
        problem = nil
        do {
            let flow = try Flow.decode(yaml: text)
            draft = flow
            saved = flow
        } catch {
            draft = nil
            problem = "flows/\(name).yaml can't be read: \(error.message)"
        }
    }

    private func newFromTemplate(_ template: FlowTemplates.Template) {
        var name = template.name
        var number = 2
        while brainNames.contains(name) {
            name = "\(template.name)-\(number)"
            number += 1
        }
        var flow = template.make(piModels.first ?? "", piModels.dropFirst().first ?? "",
                                 commands.filter { $0.contains("test") })
        flow = FlowTemplates.withDefaultModels(flow, doer: piModels.first { $0.hasSuffix("/gpt-6-luna") },
                                               thinker: piModels.first { $0.hasSuffix("/gpt-6.1-terra") })
        flow.name = name
        draft = flow
        saved = nil
        selection = Self.newTag
        issues = nil
    }

    // MARK: - Editor

    private func editor(_ flow: Flow) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header(flow)
                if let problem { Label(problem, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange) }
                if let issues { checkResult(issues, flow: flow) }
                column(flow)
                addStepMenu
                DisclosureGroup("Tools of the flow") { toolsBox(flow) }
                    .help("Every step's tools are a subset of these (F13)")
            }
            .padding(16)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func header(_ flow: Flow) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                if saved == nil {
                    TextField(text: binding(\.name), prompt: Text("feature")) { RequiredLabel("Name") }
                        .frame(maxWidth: 260)
                        .help("The flow's file name: brain/flows/NAME.yaml, and /flow NAME in Pi")
                } else {
                    Text(flow.name).font(.title2.bold())
                }
                Spacer()
                Button("Check", systemImage: "checkmark.seal") { check(flow) }
                    .help("Runs the flow check (akit flow check): routes, tools, models, skills, check commands, Pi features")
                Button("Save", systemImage: "square.and.arrow.down") { Task { await save(flow) } }
                    .keyboardShortcut("s")
                    .disabled(saving || flow == saved || !ProjectBundle.isFlowName(flow.name) || flow.steps.contains { $0.model.isEmpty })
                    .help("Writes brain/flows/\(flow.name).yaml and commits it")
                layersMenu(flow)
                Button("Apply…", systemImage: "arrow.down.doc") { applying = ApplyTarget(project: project) }
                    .disabled(saved == nil)
                    .help(project.map { "Set Up Project… for \($0.lastPathComponent): the preview shows each file with its diff and backs up what it replaces" }
                          ?? "Update the home folder: the core layer's flows go to ~/.pi/agent/flows")
                GuideButton(guide: .flows)
            }
            Text("\(flow.steps.count) step\(flow.steps.count == 1 ? "" : "s") · run it in Pi with /flow \(flow.name) <task>")
                .font(.caption).foregroundStyle(.secondary)
                .help("Needs Pi \(flow.minPi) or newer")
            if piNeedsAttention { piVersionLine.font(.caption) }
            if saved != nil, let brain = model.brain, BrainFlows.layers(including: flow.name, in: brain).isEmpty {
                Label("In no layer: Apply… doesn't write it, so Pi has no /flow. Include it with Layers (core for the home folder), then Apply….",
                      systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange).font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func layersMenu(_ flow: Flow) -> some View {
        let layers = model.brain?.layers ?? []
        let included = model.brain.map { BrainFlows.layers(including: flow.name, in: $0) } ?? []
        return Menu("Layers", systemImage: "square.3.layers.3d") {
            ForEach(layers, id: \.name) { layer in
                Toggle(layer.name, isOn: Binding(get: { included.contains(layer.name) }, set: { on in
                    Task { await include(on, flow: flow.name, layer: layer.name) }
                }))
            }
        }
        .disabled(saved == nil)
        .help(included.isEmpty ? "Include the flow in a layer; Apply renders the layer's flows for Pi" : "In: \(included.joined(separator: ", "))")
    }

    private func checkResult(_ issues: [FlowIssue], flow: Flow) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 4) {
                let errors = issues.filter { $0.severity == .error }
                Label(errors.isEmpty ? "No errors" : "\(errors.count) error\(errors.count == 1 ? "" : "s")",
                      systemImage: errors.isEmpty ? "checkmark.circle.fill" : "xmark.octagon.fill")
                    .foregroundStyle(errors.isEmpty ? .green : .red).font(.headline)
                Text(modelEquality(flow)).font(.callout)
                ForEach(Array(issues.enumerated()), id: \.offset) { _, issue in
                    Label(issue.message, systemImage: issue.severity == .error ? "xmark.circle" : "exclamationmark.triangle")
                        .foregroundStyle(issue.severity == .error ? .red : .orange).font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: { Text("Check") }
    }

    /// F6: the reviewer's model next to the implementer's.
    private func modelEquality(_ flow: Flow) -> String {
        let implementers = Array(Set(flow.steps.filter { FlowTemplates.makers.contains($0.agent) }.map(\.model))).sorted()
        let reviewers = Array(Set(flow.steps.filter { FlowTemplates.judges.contains($0.agent) }.map(\.model))).sorted()
        guard !implementers.isEmpty, !reviewers.isEmpty else { return "Models: no maker and reviewer pair to compare." }
        let same = !Set(implementers).isDisjoint(with: reviewers)
        return "Makers \(implementers.joined(separator: ", ")) · reviewers \(reviewers.joined(separator: ", ")): \(same ? "the same model, pick another for the review" : "different models")"
    }

    private func toolsBox(_ flow: Flow) -> some View {
        checkboxes(Array(Set(Self.builtInTools + flow.tools)).sorted(), selected: flow.tools) { tool, on in
            update { $0.tools = on ? $0.tools + [tool] : $0.tools.filter { $0 != tool } }
        }
        .padding(.top, 4)
    }

    // MARK: - Column of cards

    private func column(_ flow: Flow) -> some View {
        FlowColumn(flow: flow) { index, step in
            card(step, index: index, flow: flow)
                .dropDestination(for: String.self) { ids, _ in
                    guard let moved = ids.first else { return false }
                    move(moved, before: step.id)
                    return true
                }
        }
    }

    /// A card is one line; a click opens it, one card at a time.
    private func card(_ step: FlowStep, index: Int, flow: Flow) -> some View {
        let open = expanded == step.id
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "line.3.horizontal").foregroundStyle(.secondary)
                    .help("Drag onto another card to move this step before it")
                Image(systemName: open ? "chevron.down" : "chevron.right").foregroundStyle(.secondary).frame(width: 10)
                FlowStepLine(step: step, index: index, flow: flow)
            }
            .contentShape(Rectangle())
            .onTapGesture { expanded = open ? nil : step.id }
            .draggable(step.id)
            .help(open ? "Click to close the card" : "Click to open the card")
            if open { details(step, index: index, flow: flow) }
        }
        .padding(8)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(open ? Color.accentColor : .secondary.opacity(0.25)))
    }

    /// The open card: what is set for most steps (agent, model, reasoning, prompt, skills, gate,
    /// checks), and the rest under More Settings.
    private func details(_ step: FlowStep, index: Int, flow: Flow) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Divider()
            HStack(spacing: 16) {
                Picker(selection: stepBinding(index, \.agent)) {
                    ForEach(Array(Set(FlowTemplates.agents + [step.agent])).sorted(), id: \.self) { Text($0).tag($0) }
                } label: { RequiredLabel("Agent") }
                    .fixedSize()
                    .help("The role of the step; implementer and reviewer must use different models (F6)")
                if step.isClaudeCode {
                    Picker(selection: stepBinding(index, \.model)) {
                        ForEach(Array(Set(FlowStep.claudeModels + [step.model])).filter { !$0.isEmpty }.sorted(), id: \.self) { Text($0).tag($0) }
                    } label: { RequiredLabel("Model") }
                        .fixedSize()
                        .help("Claude Code's model (claude --model)")
                } else {
                    PiModelPicker(selection: stepBinding(index, \.model), models: piModels, empty: "Choose a model",
                                  help: "Models Pi has credentials for (pi --list-models)", allowsOther: false) {
                        RequiredLabel("Model")
                    }
                }
            }
            HStack(spacing: 16) {
                reasoningPicker(step, index: index)
                Picker("Runs on", selection: Binding(get: { step.isClaudeCode }, set: { claude in
                    updateStep(index) { step in
                        guard claude != step.isClaudeCode else { return }
                        step.harness = claude ? FlowStep.claudeCode : nil
                        if claude {
                            // Read-only on Claude Code (F21): its tools lose edit and write; skills stay.
                            let tools = (step.tools.isEmpty ? flow.tools : step.tools).filter { FlowStep.claudeTools.contains($0) }
                            step.tools = tools.isEmpty ? ["read", "grep", "find", "ls"] : tools
                            step.model = FlowStep.claudeModels[0]
                        } else {
                            step.model = piModels.first ?? ""
                        }
                    }
                })) {
                    Text("Pi").tag(false)
                    Text("Claude Code").tag(true)
                }
                .pickerStyle(.segmented)
                .fixedSize()
                .help("Claude Code: the runner starts claude -p for this step, read only, and its answer is the handoff. Good for a judge on another model family")
            }
            promptEditor(step, index: index, flow: flow)
            skillsRow(step, index: index)
            if step.agent == "checker" || !step.checks.isEmpty { checksPicker(step, index: index) }
            HStack(spacing: 18) {
                Toggle("Gate", isOn: stepBinding(index, \.gate)).toggleStyle(.switch)
                    .disabled(missing(.uiConfirm) != nil && !step.gate)
                    .help(missing(.uiConfirm).map { "Can't: \($0)" } ?? "After the step Pi stops and asks: Approve, or Send Back with a note")
                Spacer()
                Button("Move Up", systemImage: "chevron.up") { swap(index, index - 1) }.labelStyle(.iconOnly).disabled(index == 0)
                Button("Move Down", systemImage: "chevron.down") { swap(index, index + 1) }.labelStyle(.iconOnly).disabled(index == flow.steps.count - 1)
                Button("Remove Step", systemImage: "trash") { remove(step.id) }.labelStyle(.iconOnly)
            }
            DisclosureGroup("More Settings", isExpanded: $showsMore) {
                moreSettings(step, index: index, flow: flow).padding(.top, 6)
            }
            .help("Tools, where the run goes after the step, and its loop limit")
        }
    }

    /// How much the model reasons in the step: Pi's --thinking, Claude Code's --effort (F21).
    private func reasoningPicker(_ step: FlowStep, index: Int) -> some View {
        Picker("Reasoning", selection: stepBinding(index, \.thinking)) {
            Text("Model default").tag(String?.none)
            ForEach(FlowTemplates.thinkingLevels, id: \.self) { Text($0).tag(String?.some($0)) }
            if let other = step.thinking, !FlowTemplates.thinkingLevels.contains(other) { Text(other).tag(String?.some(other)) }
        }
        .fixedSize()
        .disabled(!step.isClaudeCode && missing(.thinking) != nil && step.thinking == nil)
        .help(step.isClaudeCode
              ? "How much Claude reasons in this step (claude --effort: off and minimal are low); Model default leaves it to Claude Code"
              : missing(.thinking).map { "Can't: \($0)" } ?? "How much the model reasons in this step (pi --thinking); Model default leaves it to Pi")
    }

    /// The prompt, always in sight, with Generate… (Pi writes it) and Undo after a generation.
    private func promptEditor(_ step: FlowStep, index: Int, flow: Flow) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Instructions")
                    .help("What this step's agent is told to do: sent to it as is, after the task and the plan")
                Spacer()
                if let before = promptBefore[step.id] {
                    Button("Undo", systemImage: "arrow.uturn.backward") {
                        updateStep(index) { $0.prompt = before }
                        promptBefore[step.id] = nil
                    }
                    .help("Bring back the instructions from before Generate…")
                }
                Button("Generate…", systemImage: "sparkles") { generating = step.id }
                    .disabled(piModels.isEmpty)
                    .help(piModels.isEmpty ? "Pi has no models with credentials on this Mac" : "Pi writes or changes these instructions from your request")
                    .popover(isPresented: Binding(get: { generating == step.id }, set: { if !$0 { generating = nil } })) {
                        FlowPromptGenerator(flow: flow, step: step.id, models: piModels) { text in
                            if promptBefore[step.id] == nil { promptBefore[step.id] = .some(step.prompt) }
                            updateStep(index) { $0.prompt = text }
                            generating = nil
                        }
                    }
            }
            TextEditor(text: Binding(get: { step.prompt ?? "" }, set: { text in
                updateStep(index) { $0.prompt = text.isEmpty ? nil : text }
            }))
            .font(.callout)
            .frame(minHeight: 90, maxHeight: 200)
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(.secondary.opacity(0.3)))
            .help("What the step does, in the model's words; the runner puts it after the task and the plan")
        }
    }

    private func checksPicker(_ step: FlowStep, index: Int) -> some View {
        LabeledContent("Checks") {
            let offered = Array(Set(commands + step.checks)).sorted()
            if offered.isEmpty {
                Text(project == nil ? "Pick a project for its commands" : "No test or lint commands found").foregroundStyle(.secondary)
            } else {
                checkboxes(offered, selected: step.checks) { command, on in
                    updateStep(index) { $0.checks = on ? $0.checks + [command] : $0.checks.filter { $0 != command } }
                }
            }
        }
        .help("Commands the runner runs at the step's end, without a shell; red turns done into failed. A checker step with checks starts no model")
    }

    private func moreSettings(_ step: FlowStep, index: Int, flow: Flow) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            LabeledContent("Tools") {
                checkboxes(step.isClaudeCode ? flow.tools.filter { FlowStep.claudeTools.contains($0) } : flow.tools, selected: step.tools) { tool, on in
                    updateStep(index) { $0.tools = on ? $0.tools + [tool] : $0.tools.filter { $0 != tool } }
                }
            }
            .help("The step's tool allow-list; the guard blocks every other tool. None checked: the flow's tools")
            // One row when it fits, else one picker per row: the card never grows past the window.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) { routePickers(index: index, flow: flow) }
                VStack(alignment: .leading, spacing: 6) { routePickers(index: index, flow: flow) }
            }
            Stepper("Max loops: \(step.maxLoops)", value: stepBinding(index, \.maxLoops), in: 1...9)
                .fixedSize()
                .help("How often the run may come back to this step before it stops")
        }
    }

    private func skillsRow(_ step: FlowStep, index: Int) -> some View {
        LabeledContent("Skills") {
            HStack {
                Text("\(step.skills.count) chosen").foregroundStyle(.secondary)
                Button("Choose…") { choosingSkills = step.id }
                    .disabled(skills.isEmpty && step.skills.isEmpty)
                    .popover(isPresented: Binding(get: { choosingSkills == step.id }, set: { if !$0 { choosingSkills = nil } })) {
                        SkillChooser(all: Array(Set(skills + step.skills)), selected: step.skills) { skill, on in
                            updateStep(index) { $0.skills = on ? $0.skills + [skill] : $0.skills.filter { $0 != skill } }
                        }
                    }
                if skills.isEmpty && step.skills.isEmpty { Text("No Pi skills found").foregroundStyle(.secondary) }
                if let reason = missing(.skill), !step.skills.isEmpty {
                    Label(reason, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).font(.caption)
                }
            }
        }
        .help("Only these skills reach the step (Pi: -ns --skill; Claude Code: listed in its system prompt, folders readable)")
    }

    /// This Mac's Pi (from `akit doctor`) next to the newest Pi the runner was tested on (F20).
    private var piVersionLine: some View {
        let installed = capabilities?.version
        let newer = installed.map { FlowCheck.compare($0, Flow.testedPi) == .orderedDescending } ?? false
        let older = installed.map { FlowCheck.compare($0, Flow.defaultMinPi) == .orderedAscending } ?? false
        return Label(installed.map { "This Mac's Pi \($0) · tested on Pi \(Flow.testedPi)" + (newer ? ": newer than tested, flows run with a warning" : older ? ": too old, flows refuse to run" : "") }
                     ?? "This Mac's Pi: not checked yet (akit doctor writes it) · tested on Pi \(Flow.testedPi)",
                     systemImage: newer || older ? "exclamationmark.triangle" : "info.circle")
            .foregroundStyle(older ? .red : newer ? .orange : .secondary)
            .help("akit doctor stores this Mac's Pi features in ~/.akit/local/pi-capabilities.json; options it lacks are grey")
    }

    /// The Pi line shows only when this Mac's Pi is unknown, too old or newer than tested.
    private var piNeedsAttention: Bool {
        guard let installed = capabilities?.version else { return true }
        return FlowCheck.compare(installed, Flow.testedPi) == .orderedDescending || FlowCheck.compare(installed, Flow.defaultMinPi) == .orderedAscending
    }

    /// Why this Mac's Pi can't do `feature` (from `pi-capabilities.json`), or nil when it can or nothing is known.
    private func missing(_ feature: FlowPiFeature) -> String? {
        guard let pi = capabilities, !pi.features.contains(feature.rawValue) else { return nil }
        return "this Mac's Pi \(pi.version ?? "") has no \(feature.rawValue) (akit doctor)"
    }

    @ViewBuilder
    private func routePickers(index: Int, flow: Flow) -> some View {
        routePicker("On done", outcome: "done", index: index, flow: flow)
        routePicker("On failed", outcome: "failed", index: index, flow: flow)
        routePicker("On blocked", outcome: "blocked", index: index, flow: flow)
    }

    /// The three route pickers (F2): next step by default on done, stop on failed or blocked.
    private func routePicker(_ title: String, outcome: String, index: Int, flow: Flow) -> some View {
        let key = "\(outcome):*"
        let targets = outcome == "done" ? flow.steps.map(\.id) : flow.steps.prefix(index + 1).map(\.id)
        return Picker(title, selection: Binding(get: { flow.steps[index].routes[key] ?? "" }, set: { value in
            updateStep(index) { $0.routes[key] = value.isEmpty ? nil : value }
        })) {
            Text(outcome == "done" ? "Next step" : "Stop and ask").tag("")
            ForEach(targets, id: \.self) { Text($0).tag($0) }
            Text("End").tag(FlowRouting.end)
        }
        .fixedSize()
        .help(outcome == "done" ? "Where the run goes when the step ends done" : "Where the run goes back to; only this or an earlier step")
    }

    private var addStepMenu: some View {
        Menu("Add Step", systemImage: "plus.rectangle") {
            ForEach(FlowTemplates.agents, id: \.self) { agent in
                Button(agent) { addStep(agent) }
            }
        }
        .fixedSize()
        .help("Adds a card at the end with this agent and its default prompt")
    }

    private func checkboxes(_ items: [String], selected: [String], set: @escaping (String, Bool) -> Void) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), alignment: .leading)], alignment: .leading, spacing: 4) {
            ForEach(items, id: \.self) { item in
                Toggle(item, isOn: Binding(get: { selected.contains(item) }, set: { set(item, $0) }))
                    .toggleStyle(.checkbox)
            }
        }
    }

    // MARK: - Edits

    private func binding<T>(_ path: WritableKeyPath<Flow, T>) -> Binding<T> {
        Binding(get: { draft![keyPath: path] }, set: { value in update { $0[keyPath: path] = value } })
    }

    private func stepBinding<T>(_ index: Int, _ path: WritableKeyPath<FlowStep, T>) -> Binding<T> {
        Binding(get: { draft!.steps[index][keyPath: path] }, set: { value in updateStep(index) { $0[keyPath: path] = value } })
    }

    private func update(_ change: (inout Flow) -> Void) {
        guard var flow = draft else { return }
        change(&flow)
        draft = flow
        issues = nil
    }

    private func updateStep(_ index: Int, _ change: (inout FlowStep) -> Void) {
        update { flow in
            guard flow.steps.indices.contains(index) else { return }
            change(&flow.steps[index])
        }
    }

    private func addStep(_ agent: String) {
        update { flow in
            let id = FlowTemplates.stepID(for: agent, taken: Set(flow.steps.map(\.id)))
            flow.steps.append(FlowStep(id: id, agent: agent, model: flow.steps.last?.model ?? piModels.first ?? "",
                                       prompt: FlowTemplates.prompt(for: agent)))
        }
    }

    private func remove(_ id: String) {
        update { flow in
            flow.steps.removeAll { $0.id == id }
            for index in flow.steps.indices { flow.steps[index].routes = flow.steps[index].routes.filter { $0.value != id } }
        }
    }

    private func swap(_ a: Int, _ b: Int) {
        update { flow in
            guard flow.steps.indices.contains(a), flow.steps.indices.contains(b) else { return }
            flow.steps.swapAt(a, b)
        }
    }

    private func move(_ id: String, before target: String) {
        update { flow in
            guard id != target, let from = flow.index(of: id) else { return }
            let step = flow.steps.remove(at: from)
            flow.steps.insert(step, at: flow.index(of: target) ?? flow.steps.endIndex)
        }
    }

    // MARK: - Check, Save, Layers

    private func check(_ flow: Flow) {
        issues = FlowCheck.check(flow, knownModels: piModels.isEmpty ? nil : Set(piModels),
                                 knownSkills: FlowFile.knownSkills(project: project, env: env), pi: FlowFile.capabilities(env: env))
    }

    private func save(_ flow: Flow) async {
        guard let brain = model.brain else { return }
        saving = true
        defer { saving = false }
        do {
            try await BrainFlows.save(flow.name, text: flow.yaml(), in: brain, env: env)
            saved = flow
            selection = flow.name
            problem = nil
            await model.refresh()
        } catch let error as BrainFlows.Failure {
            problem = error.message
        } catch {
            problem = "Couldn't write the flow: \(error.localizedDescription)"
        }
    }

    private func include(_ on: Bool, flow: String, layer: String) async {
        guard let brain = model.brain else { return }
        do {
            try await BrainFlows.setIncluded(on, flow: flow, inLayer: layer, in: brain, env: env)
            await model.refresh()
        } catch {
            problem = error.message
        }
    }

    /// Snapshots: `--tab feature` opens a Feature draft, `--select <name>` a brain flow,
    /// `--tab check` runs Check on it, `--project <folder name>` picks the project.
    private func snapshotSetup() {
        guard let options = DebugSnapshot.options else { return }
        if options.demo, piModels.isEmpty { piModels = ["demo/coder-large", "demo/reviewer-pro"] }
        if let name = options.project { project = model.projects.first { $0.lastPathComponent == name } }
        if let name = options.select { open(name) }
        if options.tab == "feature" || options.tab == "check", draft == nil { newFromTemplate(FlowTemplates.all[0]) }
        if options.tab == "check", let draft { check(draft) }
        // `--query <step id>` opens that card; `--add` opens More Settings and its skill chooser.
        if let step = options.query, draft?.step(step) != nil {
            expanded = step
            if options.add {
                showsMore = true
                choosingSkills = step
            }
        }
    }
}

/// The searchable skill list of a card: chosen skills first, then the rest by name.
private struct SkillChooser: View {
    let all: [String]
    let selected: [String]
    let set: (String, Bool) -> Void
    @State private var search = ""

    var body: some View {
        let shown = all.filter { search.isEmpty || $0.localizedCaseInsensitiveContains(search) }
            .sorted { (selected.contains($0) ? 0 : 1, $0) < (selected.contains($1) ? 0 : 1, $1) }
        VStack(alignment: .leading, spacing: 6) {
            TextField("Search skills", text: $search).textFieldStyle(.roundedBorder)
            Text("\(selected.count) chosen of \(all.count)").font(.caption).foregroundStyle(.secondary)
            List(shown, id: \.self) { skill in
                Toggle(skill, isOn: Binding(get: { selected.contains(skill) }, set: { set(skill, $0) })).toggleStyle(.checkbox)
            }
            .listStyle(.plain)
        }
        .padding(10)
        .frame(width: 300, height: 380)
    }
}
