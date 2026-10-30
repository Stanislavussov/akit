import AKitFoundation
import AKitReview
import AppKit
import SwiftUI

/// Debug…: find gaps in a run's process (`ReviewDebug`, `akit review debug`). AKit's checks show
/// at once, without a model; Debug with Pi lets the run's verifier model read the full log and
/// say what went wrong and what to change. Copy Full Log puts everything on the clipboard.
struct ReviewDebugSheet: View {
    @Environment(\.dismiss) private var dismiss
    let folder: URL
    @State private var checks: [ReviewDebug.Check]?
    @State private var reports: [ReviewDebug.Report] = []
    @State private var problem: String?
    @State private var running: Task<Void, Never>?
    @State private var lines: [String] = []
    /// The debug run whose progress lines show; a stopped run's late lines are dropped.
    @State private var runToken: UUID?
    @State private var copied: String?

    private var report: ReviewDebug.Report? { reports.last }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Debug the Run").font(.title3.weight(.semibold))
            Text("Gaps in the review process: data that didn't come, passes that failed or read nothing, calls AKit blocked, rules that misled a role. Not about the code under review; nothing goes to GitLab.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    checksSection
                    piSection
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let problem {
                Label(problem, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).textSelection(.enabled)
            }
            HStack {
                Button("Show in Finder") {
                    let debug = folder.appending(path: "debug")
                    NSWorkspace.shared.activateFileViewerSelecting([FileManager.default.fileExists(atPath: debug.path) ? debug : folder])
                }
                    .help("The run folder; Debug with Pi saves its reports and the full log in debug/")
                Button(copied == "log" ? "Copied" : "Copy Full Log") { copyFullLog() }
                    .help("Everything to debug the run, masked and uncut: prompts, each pass's transcript, MCP calls with arguments and whole answers, findings, plan. It holds work data (code, merge request texts): paste it only where that may go.")
                if let report {
                    Button(copied == "report" ? "Copied" : "Copy Report") { copy(report.markdown, as: "report") }
                        .help("AKit's checks and Pi's analysis as Markdown")
                }
                Spacer()
                if running != nil {
                    Button("Stop") { running?.cancel() }
                }
                Button(report == nil ? "Debug with Pi" : "Debug Again with Pi") { debug() }
                    .disabled(running != nil)
                    .help("Pi (the run's verifier model, reading tools only, no MCP) reads the full log and the run's prompts and context pack, and says where the process left gaps and what to change. Uses the sending policy, as Ask… does.")
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(minWidth: 760, idealWidth: 860, minHeight: 520, idealHeight: 640)
        .task { await load() }
        .onDisappear { running?.cancel() }
    }

    @ViewBuilder private var checksSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("AKit's checks").font(.headline)
            if let checks {
                if checks.isEmpty {
                    Label("No gap in the run's records.", systemImage: "checkmark.circle").foregroundStyle(.secondary)
                }
                ForEach(checks) { check in
                    VStack(alignment: .leading, spacing: 1) {
                        Label(check.title, systemImage: icon(check.level)).foregroundStyle(color(check.level))
                        Text(check.detail).font(.caption).foregroundStyle(.secondary).padding(.leading, 22)
                    }
                    .textSelection(.enabled)
                }
            } else {
                ProgressView().controlSize(.small)
            }
        }
    }

    @ViewBuilder private var piSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Pi's analysis").font(.headline)
            if running != nil {
                HStack(spacing: 6) { ProgressView().controlSize(.small); Text(lines.last ?? "Starting…").font(.caption).foregroundStyle(.secondary).lineLimit(1) }
            }
            if let report {
                Text("\(report.id) · \(report.model.isEmpty ? "Pi's default model" : report.model) · \(report.created.formatted(date: .abbreviated, time: .shortened))"
                     + String(format: " · %.1f credits", report.credits) + (report.usage.cost.map { " · " + ReviewRunLog.dollars($0) } ?? ""))
                    .font(.caption).foregroundStyle(.tertiary)
                if let answer = report.answer {
                    MarkdownText(text: answer)
                } else {
                    Label(report.error ?? "Pi gave no answer.", systemImage: "xmark.circle").foregroundStyle(.red).textSelection(.enabled)
                }
            } else if running == nil {
                Text("Not run yet. Debug with Pi sends the masked log of this run to the run's verifier model.").font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    private func icon(_ level: ReviewDebug.Check.Level) -> String {
        switch level {
        case .high: "xmark.octagon"
        case .medium: "exclamationmark.triangle"
        case .low: "info.circle"
        }
    }

    private func color(_ level: ReviewDebug.Check.Level) -> Color {
        switch level {
        case .high: .red
        case .medium: .orange
        case .low: .primary
        }
    }

    private func load() async {
        let folder = folder
        // Every saved MCP answer is decoded: off the main thread.
        let result = await Task.detached { Result { try ReviewDebug.checks(folder) } }.value
        switch result {
        case .success(let found): checks = found
        case .failure(let error): problem = error.localizedDescription; checks = []
        }
        reports = ReviewDebug.reports(folder)
    }

    private func copyFullLog() {
        let folder = folder
        Task {
            let result = await Task.detached { Result { try ReviewDebug.fullLog(folder, cut: nil) } }.value
            switch result {
            case .success(let text): copy(text, as: "log")
            case .failure(let error): problem = error.localizedDescription
            }
        }
    }

    private func copy(_ text: String, as what: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copied = what
    }

    private func debug() {
        problem = nil
        lines = []
        let folder = folder
        let token = UUID()
        runToken = token
        running = Task {
            do {
                _ = try await ReviewDebug.run(folder, env: HarnessEnvironment.current) { line in
                    Task { @MainActor in if runToken == token { lines.append(line) } }
                }
            } catch {
                problem = error.localizedDescription
            }
            reports = ReviewDebug.reports(folder)
            running = nil
        }
    }
}
