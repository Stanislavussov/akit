import AKitErrorAnalysis
import AKitFoundation
import AKitLab
import SwiftUI

/// One control cell in the Lab: its task and setup, the oracle's verdict and the guard flags
/// that keep a cell out of comparisons.
struct LabControlSection: View {
    @Environment(AppModel.self) private var model
    let run: LabRun

    var body: some View {
        let task = run.spec.controlTask.flatMap { model.labControlTasks[$0] }
        VStack(alignment: .leading, spacing: 6) {
            Text("Control task").font(.title3.bold())
            if let task {
                Text(task.title).fontWeight(.medium).textSelection(.enabled)
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 4) {
                    row("Repository", "\(URL(filePath: task.repo).tildePath) at \(task.base.prefix(7))")
                    row("Oracle", task.oracle.label)
                    row("Source", task.sourceTitle)
                    if let setup = run.spec.controlSetup { row("Setup", setup.label) }
                    if let index = run.spec.repeatIndex, let repeats = run.spec.repeats { row("Repeat", "\(index) of \(repeats)") }
                }
                .font(.callout)
                .textSelection(.enabled)
            } else {
                Text("The control task \(run.spec.controlTask ?? "") is gone (removed from ~/.akit/lab/evals/tasks).")
                    .foregroundStyle(.secondary)
            }
            if run.spec.keep {
                Text("The clone is kept: \(run.folder.appending(path: "work").tildePath)").font(.caption).foregroundStyle(.secondary)
            }
        }
        if let error = run.result?.agentError {
            Text("The agent stopped with an error: \(error)")
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        if let control = run.result?.control {
            outcome(control)
        }
    }

    private func outcome(_ control: ControlOutcome) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Oracle").font(.title3.bold())
            Label(control.passed ? "Passed" : "Failed", systemImage: control.passed ? "checkmark.seal" : "xmark.seal")
                .foregroundStyle(control.passed ? .green : .red)
                .font(.headline)
            Text(control.oracle).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            if !control.checkSteps.isEmpty {
                Text("The mode shows at " + control.checkSteps.map { "#\($0)" }.joined(separator: ", ")).foregroundStyle(.secondary)
            }
            if control.flagged {
                Label("Flagged: comparisons count this cell as failed.", systemImage: "flag")
                    .foregroundStyle(.orange)
                    .fontWeight(.medium)
            }
            if control.testsDropped {
                Label("Fewer tests than before the agent ran.", systemImage: "minus.circle").foregroundStyle(.orange)
            }
            if !control.changedTestFiles.isEmpty {
                Label("Test files changed: \(control.changedTestFiles.joined(separator: ", "))", systemImage: "pencil.circle")
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !control.leaks.isEmpty {
                Label("The agent's tool calls read \(control.leaks.joined(separator: " and ")).", systemImage: "eye.trianglebadge.exclamationmark")
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !control.flagged {
                Text("Guard: the test count didn't drop, no test file changed, no sign the agent read the exemplar.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let notes = control.overlay {
                ForEach(notes, id: \.self) { note in
                    Label(note, systemImage: "square.3.layers.3d").font(.caption).fixedSize(horizontal: false, vertical: true)
                }
            } else if run.spec.controlSetup?.layer != nil {
                Label("Run by an akit that ignored the layer: left out of comparisons. Install the app and akit together.",
                      systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let version = control.harnessVersion {
                Text("Claude Code \(version)").font(.caption).foregroundStyle(.secondary)
            }

        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
            Text(value).lineLimit(2).truncationMode(.middle)
        }
    }
}

extension ControlTask {
    /// "From claude:…", "Reproduction".
    var sourceTitle: String {
        switch source {
        case .session(let key): "From session \(key)"
        case .reproduction: "Reproduction"
        }
    }
}
