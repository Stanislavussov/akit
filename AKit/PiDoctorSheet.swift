import AKitDoctor
import AKitFoundation
import AppKit
import SwiftUI

/// Overview → Pi → Check Pi…: `akit doctor pi` as a sheet. Only reads; the live part
/// (`pi mcp list`, `pi auth check`) runs only on Check Servers and Sign-In.
struct PiDoctorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var report: PiDoctor.Report?
    @State private var busy = false
    @State private var checkingLive = false
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("Pi Doctor").font(.title2.bold())
                Spacer()
                if let report { summary(report) }
            }
            Text("What is wrong in Pi's setup, like claude doctor: the install, settings, environment, MCP servers, packages, skills and instructions. Only reads.")
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
                                    LineRow(line: line)
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
                    .help("Runs pi mcp list and pi auth check --no-refresh; never reads a credential")
                if checkingLive {
                    ProgressView().controlSize(.small)
                    Text("Connecting to the servers…").font(.callout).foregroundStyle(.secondary)
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
        .task {
            await run(live: false)
            if DebugSnapshot.options?.capture == true { await run(live: true) }
        }
    }

    private func summary(_ report: PiDoctor.Report) -> some View {
        Group {
            if report.problems == 0 && report.warnings == 0 {
                Label("No problems found", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            } else {
                Label("\(report.problems) problem\(report.problems == 1 ? "" : "s"), \(report.warnings) warning\(report.warnings == 1 ? "" : "s")",
                      systemImage: report.problems > 0 ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(report.problems > 0 ? .red : .orange)
            }
        }
        .font(.callout)
    }

    private func run(live: Bool) async {
        busy = true
        checkingLive = live
        copied = false
        let env = HarnessEnvironment.current
        report = await Task.detached { await PiDoctor.check(env: env, live: live) }.value
        busy = false
        checkingLive = false
    }
}

/// One line: a colored icon by level, the text, and what to do under it.
private struct LineRow: View {
    let line: PiDoctor.Line

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: icon).foregroundStyle(color).frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(line.text).fixedSize(horizontal: false, vertical: true)
                if let fix = line.fix {
                    Text(fix).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var icon: String {
        switch line.level {
        case .ok: "checkmark.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .problem: "xmark.octagon.fill"
        }
    }

    private var color: Color {
        switch line.level {
        case .ok: .green
        case .warning: .orange
        case .problem: .red
        }
    }
}
