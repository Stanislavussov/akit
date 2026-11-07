import AKitFoundation
import AKitLab
import AKitSkills
import SwiftUI

/// Port to Pi…: a Claude Code skill rewritten as a Pi skill and checked (docs/design/skill-port.md).
/// Target and model → Run → the check and the SKILL.md diff → Install… with a confirmation.
struct PortToPiSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let skill: Skill

    private enum Place: Hashable { case global, project }

    @State private var place = Place.global
    @State private var project: URL?
    @State private var useModel = true
    @State private var harness = LabHarness.claudeCode
    @State private var modelName = ""
    @State private var models: [String] = []
    @State private var running: String?
    @State private var draft: SkillPort.Draft?
    @State private var report: SkillPortCheck.Report?
    @State private var modelLabel: String?
    @State private var confirming = false
    @State private var installedAt: URL?
    @State private var error: String?
    @State private var task: Task<Void, Never>?

    private var env: HarnessEnvironment { .current }

    private var target: SkillPort.Target? {
        switch place {
        case .global: .global
        case .project: project.map { .project($0) }
        }
    }

    private var plan: SkillPort.InstallPlan? {
        guard let draft, let target else { return nil }
        return SkillPort.plan(draft, target: target, env: env)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Port “\(skill.name)” to Pi").font(.title2.bold())
            Text("Rewrites the Claude Code parts (frontmatter, /plugin:x commands, .claude and .omc paths, tool names, subagents, questions, task lists, MCP state) and checks the result. Nothing is written before Install….")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            settings
            Divider()
            result.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            buttons
        }
        .padding(16)
        .frame(width: 780, height: 640)
        .task {
            let agent = SkillPortModel.agent(settings: LabSettings.load(env: env), env: env)
            harness = agent.harness
            modelName = agent.model
            project = model.projects.first
            // Snapshots: `--tab port-report` runs the port without a model.
            if DebugSnapshot.options?.tab == "port-report" {
                useModel = false
                run()
            }
        }
        .task(id: harness) {
            models = await model.labModels(for: harness)
        }
        .confirmationDialog(confirmTitle, isPresented: $confirming, titleVisibility: .visible) {
            Button(plan?.replaces == true ? "Replace" : "Install", role: plan?.replaces == true ? .destructive : nil, action: install)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(plan?.replaces == true ? "The folder there now goes to the Trash." : "Pi loads it in new sessions (/reload in running ones).")
        }
    }

    private var confirmTitle: String {
        guard let plan else { return "Install?" }
        return "\(plan.replaces ? "Replace" : "Install") \(plan.folder.tildePath)?"
    }

    private var settings: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 8) {
            GridRow {
                Text("Install to")
                HStack {
                    Picker("Install to", selection: $place) {
                        Text("Global").tag(Place.global)
                        Text("Project").tag(Place.project)
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .fixedSize()
                    if place == .project {
                        Picker("Project", selection: $project) {
                            Text("Choose…").tag(URL?.none)
                            ForEach(model.projects, id: \.self) { Text($0.lastPathComponent).tag(Optional($0)) }
                        }
                        .labelsHidden()
                        .fixedSize()
                    }
                    Text(target.map { SkillPort.folder(for: $0, name: skill.name, env: env).tildePath } ?? "")
                        .font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
            }
            GridRow {
                Text("Model")
                HStack {
                    Toggle("Rewrite with a model", isOn: $useModel)
                        .help("Off: only the rule-based pass and the check; nothing is sent")
                    if useModel {
                        Picker("Harness", selection: $harness) {
                            ForEach(model.labHarnesses, id: \.self) { Text($0.title).tag($0) }
                        }
                        .labelsHidden()
                        .fixedSize()
                        Picker("Model", selection: $modelName) {
                            if harness == .pi { Text("Pi's default").tag("") }
                            ForEach(models, id: \.self) { Text($0).tag($0) }
                            if !modelName.isEmpty && !models.contains(modelName) { Text(modelName).tag(modelName) }
                        }
                        .labelsHidden()
                        .fixedSize()
                        .help("The model gets the skill's Markdown files under the sending policy; default: the translation model")
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var result: some View {
        if let running {
            ProgressView(running).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let installedAt {
            ContentUnavailableView("Installed", systemImage: "checkmark.circle.fill",
                                   description: Text("\(installedAt.tildePath). Pi loads it in new sessions; /reload in running ones."))
        } else if let draft, let report {
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    verdict(report)
                    if let modelLabel { Text("Model: \(modelLabel)").font(.caption).foregroundStyle(.secondary) }
                    ForEach(report.problems, id: \.self) { Label($0, systemImage: "xmark.octagon.fill").foregroundStyle(.red) }
                    ForEach(report.hits, id: \.self) { hit in
                        Label("\(hit.file):\(hit.line) [\(hit.rule)] \(hit.text)", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                    if !report.missingNumbers.isEmpty {
                        Label("Numbers of the original missing: \(report.missingNumbers.joined(separator: ", "))", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                    ForEach(report.missingHeadings, id: \.self) { Label("Heading missing: \($0)", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange) }
                    GroupBox("Changes") {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(draft.changes, id: \.self) { Text("• \($0)") }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    GroupBox(plan?.replaces == true ? "SKILL.md: the Pi skill there now → the port" : "SKILL.md: the original → the port") {
                        VStack(alignment: .leading, spacing: 0) {
                            DiffPreview(diff: plan?.replaces == true ? plan!.diff
                                        : TextDiff.lines(from: draft.originals[SkillPort.skillFile] ?? "", to: draft.skillText))
                        }
                        .font(.callout.monospaced())
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(4)
                    }
                }
                .font(.callout)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            ContentUnavailableView("Run the port", systemImage: "arrow.triangle.2.circlepath",
                                   description: Text("Run shows the check (pass, warnings or fail) and the new SKILL.md."))
        }
    }

    private func verdict(_ report: SkillPortCheck.Report) -> some View {
        switch report.verdict {
        case .pass: Label("Check passed", systemImage: "checkmark.circle.fill").foregroundStyle(.green).font(.headline)
        case .warnings: Label("Check: warnings", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.headline)
        case .fail: Label("Check failed: it can't be installed", systemImage: "xmark.octagon.fill").foregroundStyle(.red).font(.headline)
        }
    }

    private var buttons: some View {
        HStack {
            if let error { Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).lineLimit(3) }
            Spacer()
            if running != nil {
                Button("Stop") { task?.cancel() }
            }
            Button(installedAt == nil ? "Cancel" : "Done") { task?.cancel(); dismiss() }.keyboardShortcut(.cancelAction)
            Button(draft == nil ? "Run" : "Run Again", action: run)
                .disabled(running != nil)
            Button("Install…") { confirming = true }
                .keyboardShortcut(.defaultAction)
                .disabled(running != nil || report == nil || report?.verdict == .fail || target == nil || installedAt != nil)
        }
    }

    private func run() {
        error = nil
        installedAt = nil
        let folder = skill.realFolder
        let env = env
        let agent = LabAgent(harness: harness, model: modelName, effort: harness.efforts.contains("low") ? "low" : harness.efforts[0], mode: .call)
        let withModel = useModel
        running = "Porting…"
        task = Task {
            defer { running = nil }
            do {
                var made = try await Task.detached { try SkillPort.port(folder: folder, env: env) }.value
                var checked = SkillPortCheck.check(made)
                if withModel {
                    running = "Asking \(OutputTranslation.modelLabel(agent))…"
                    let gate = try await SkillPortModel.gate(agent: agent, env: env)
                    let outcome = try await SkillPortModel.run(made, agent: agent, gate: gate, env: env)
                    made = outcome.draft
                    checked = outcome.report
                    modelLabel = "\(OutputTranslation.modelLabel(agent)), \(outcome.rounds) round\(outcome.rounds == 1 ? "" : "s")"
                } else {
                    modelLabel = nil
                }
                draft = made
                report = checked
            } catch is CancellationError {
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    private func install() {
        guard let draft, let plan else { return }
        do {
            try SkillPort.install(draft, plan: plan)
            installedAt = plan.folder
            Task { await model.refresh() }
        } catch {
            self.error = error.localizedDescription
        }
    }
}
