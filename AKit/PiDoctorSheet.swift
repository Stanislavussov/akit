import AKitDoctor
import AKitFoundation
import AKitMCP
import AKitModel
import AppKit
import SwiftUI

/// Overview → Pi → Check Pi…: `akit doctor pi` as a sheet. Only reads; the live part
/// (`pi mcp list`, `pi auth check`) runs only on Check Servers and Sign-In. A suggestion's
/// button opens the screen whose action does the same as its `akit` command; nothing is
/// written from here.
struct PiDoctorSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var report: PiDoctor.Report?
    @State private var busy = false
    @State private var checkingLive = false
    @State private var copied = false
    /// A `pi` command waiting for the user's yes, and how the last one ended.
    @State private var pending: PiCommands.Action?
    @State private var running = false
    @State private var outcome: PiCommands.Outcome?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("Pi Doctor").font(.title2.bold())
                Spacer()
                if let report { summary(report) }
            }
            Text("What is wrong in Pi's setup, like claude doctor: the install, settings, environment, MCP servers, packages, skills and instructions, and what recent Pi sessions say is extra in the context. Only reads.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Divider()
            if let report {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(report.sections) { section in
                            VStack(alignment: .leading, spacing: 6) {
                                Text(section.title).font(.headline)
                                ForEach(Array(section.lines.enumerated()), id: \.offset) { _, line in
                                    LineRow(line: line, busy: running) { screen in
                                        model.section = screen
                                        dismiss()
                                    } run: { action in
                                        pending = action
                                    } signIn: { name in
                                        Task { await signIn(name) }
                                    }
                                }
                            }
                        }
                        if !report.live {
                            Text("Servers and sign-in are not checked yet: Check Servers and Sign-In connects to every MCP server (pi mcp list) and checks the default provider's sign-in (pi auth check).")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                }
            } else {
                ProgressView("Checking Pi…").frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            HStack {
                Button("Check Servers and Sign-In") { Task { await run(live: true) } }
                    .disabled(busy)
                    .help("The MCP Servers screen's connection check for Pi's servers, and pi auth check --no-refresh; never reads a credential")
                if checkingLive || running {
                    ProgressView().controlSize(.small)
                    Text(running ? "Pi is working…" : "Connecting to the servers…").font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button(copied ? "Copied" : "Copy Report") {
                    guard let report else { return }
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(report.text, forType: .string)
                    copied = true
                }
                .disabled(report == nil)
                Button("Refresh") { Task { await run(live: report?.live ?? false) } }
                    .disabled(busy)
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 680, height: 600)
        .confirmationDialog(pending?.title.replacingOccurrences(of: "…", with: "") ?? "", isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }),
                            titleVisibility: .visible, presenting: pending) { action in
            Button("Run") { Task { await runPi(action) } }
        } message: { action in
            Text("AKit runs: \(action.shown(home: HarnessEnvironment.current.homeDirectory))\n\nThe same as \(action.akitCommand) --yes. Pi does the work and keeps its own files and credentials.")
        }
        .alert(outcome?.succeeded == true ? "Done" : "Pi reported a failure", isPresented: Binding(get: { outcome != nil }, set: { if !$0 { outcome = nil } })) {
            Button("OK") {}
        } message: {
            Text(String((outcome?.output ?? "").suffix(1500)))
        }
        .task {
            await run(live: false)
            if DebugSnapshot.options?.capture == true { await run(live: true) }
        }
    }

    private func summary(_ report: PiDoctor.Report) -> some View {
        Group {
            if report.problems == 0 && report.warnings == 0 {
                Label(report.suggestions == 0 ? "No problems found" : "No problems, \(report.suggestions) suggestion\(report.suggestions == 1 ? "" : "s")",
                      systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            } else {
                Label("\(report.problems) problem\(report.problems == 1 ? "" : "s"), \(report.warnings) warning\(report.warnings == 1 ? "" : "s")",
                      systemImage: report.problems > 0 ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(report.problems > 0 ? .red : .orange)
            }
        }
        .font(.callout)
    }

    /// Sign In… of MCP Servers → Connection (`AppModel.signInMCP`: the harness's own `mcp login`,
    /// then a new check of that server), then this check again.
    private func signIn(_ name: String) async {
        let env = HarnessEnvironment.current
        // The doctor saved its check with the screen's; the screen's Sign In… needs that result.
        model.mcpChecks = MCPCheckStore.load(home: env.homeDirectory)
        let id = MCPCheckResult.key(harness: HarnessID.pi.rawValue, name: name, folder: env.homeDirectory.standardizedFileURL.path)
        guard let server = model.mcpServers.first(where: { $0.name == name && $0.usedBy.contains(.pi) && $0.scope == .global }) else { return }
        running = true
        await model.signInMCP(server, harness: .pi, id: id)
        running = false
        if let failure = model.mcpFixErrors[id] { outcome = PiCommands.Outcome(succeeded: false, output: failure) }
        await run(live: true)
    }

    /// Runs the fix's `pi` command (the user said yes), then checks again.
    private func runPi(_ action: PiCommands.Action) async {
        running = true
        let env = HarnessEnvironment.current
        let result = await Task.detached { await PiCommands.run(action, env: env) }.value
        running = false
        outcome = result
        await run(live: report?.live ?? false)
        await model.refresh()
    }

    private func run(live: Bool) async {
        busy = true
        checkingLive = live
        copied = false
        let env = HarnessEnvironment.current
        let root = model.projectRoots.first.map(env.expand)
        report = await Task.detached { await PiDoctor.check(env: env, live: live, projectsRoot: root) }.value
        // The live check saved its MCP results where MCP Servers → Connection reads them.
        if live { model.mcpChecks = MCPCheckStore.load(home: env.homeDirectory) }
        busy = false
        checkingLive = false
    }
}

/// One line: a colored icon by level, the text, and what to do under it; a suggestion also
/// shows its `akit` command, Copy Command and a button to the screen with the same action.
private struct LineRow: View {
    let line: PiDoctor.Line
    let busy: Bool
    let open: (SidebarSection) -> Void
    let run: (PiCommands.Action) -> Void
    let signIn: (String) -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: icon).foregroundStyle(color).frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(line.text).fixedSize(horizontal: false, vertical: true)
                if let fix = line.fix {
                    Text(fix).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                if let command = line.command {
                    Text(command).font(.callout.monospaced()).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                if line.command != nil || line.screen != nil {
                    HStack(spacing: 8) {
                        if let name = line.signIn {
                            Button("Sign In…") { signIn(name) }
                                .disabled(busy)
                                .help("The same as Sign In… on MCP Servers → Connection: Pi opens the browser and keeps the credentials")
                        }
                        if let action = line.action {
                            Button(action.title) { run(action) }
                                .disabled(busy)
                                .help("Shows the pi command AKit will run, then runs it (the same as \(action.akitCommand) --yes)")
                        }
                        if let screen = line.screen.flatMap(SidebarSection.init(rawValue:)) {
                            Button("Open \(screen.title)") { open(screen) }
                                .help("The \(screen.title) screen has the same action; it shows the change before it writes")
                        }
                        if let command = line.command {
                            Button("Copy Command") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(command, forType: .string)
                            }
                            .help("The akit command shows the change; add --yes to write it")
                        }
                    }
                    .controlSize(.small)
                }
            }
        }
    }

    private var icon: String {
        switch line.level {
        case .ok: "checkmark.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .problem: "xmark.octagon.fill"
        case .suggestion: "lightbulb.fill"
        }
    }

    private var color: Color {
        switch line.level {
        case .ok: .green
        case .warning: .orange
        case .problem: .red
        case .suggestion: .blue
        }
    }
}
