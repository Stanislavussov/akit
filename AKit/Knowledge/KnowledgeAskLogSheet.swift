import AKitFoundation
import AKitLab
import AppKit
import SwiftUI

/// Log… of Ask Pi (K34): how Pi was called for each answer (`streams/qN.call.json`) and what it
/// did (its saved json stream): the arguments, folder, model, thinking, fork and session, times,
/// exit and tokens; the system prompt and the prompt sent; each tool call in order with its
/// arguments, result and time; Pi's text and thinking. Everything is masked. Answers saved before
/// K34 show what their entry and stream hold. Copy Full Log puts it all on the clipboard.
struct KnowledgeAskLogSheet: View {
    @Environment(\.dismiss) private var dismiss
    /// nil in snapshots: the canned chat, with a made-up log.
    let chat: KnowledgeAsk.Chat?
    let entries: [KnowledgeAsk.Entry]
    /// One answer's id; nil: the whole chat.
    let focus: String?
    @State private var answers: [KnowledgeAskLog.Answer]?
    @State private var system: String?
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(focus.map { "Ask Pi Log: \($0)" } ?? "Ask Pi Log").font(.title3.weight(.semibold))
            if let chat {
                Text("\(chat.note.id) · Pi runs in \(chat.cwd)").font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let system {
                        DisclosureGroup("System prompt (appended to Pi's own)") {
                            mono(system)
                        }
                    }
                    if let answers {
                        if answers.isEmpty { Text("No answers yet.").foregroundStyle(.secondary) }
                        ForEach(answers, id: \.entry.id) { answer in AnswerLogView(answer: answer) }
                    } else {
                        ProgressView().controlSize(.small)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Button("Show in Finder") {
                    if let chat { NSWorkspace.shared.activateFileViewerSelecting([chat.folder]) }
                }
                .disabled(chat == nil)
                .help("The chat's folder: chat.jsonl, system.md, sessions/ and streams/ (each answer's stream and call record)")
                Button("Open Stream") {
                    if let stream = answers?.last?.stream, FileManager.default.fileExists(atPath: stream.path) { NSWorkspace.shared.open(stream) }
                }
                .disabled(chat == nil || answers?.last.map { !FileManager.default.fileExists(atPath: $0.stream.path) } ?? true)
                .help("Open the saved json stream of " + (focus.map { "the answer \($0)" } ?? "the last answer") + " (masked) in its app")
                Button(copied ? "Copied" : "Copy Full Log") { copyFullLog() }
                    .help("The whole log as plain text, masked and uncut: the call, the prompts, every step with its full result. It may hold work data (the note, tool results): paste it only where that may go.")
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(minWidth: 760, idealWidth: 860, minHeight: 520, idealHeight: 660)
        .task { await load() }
    }

    private func load() async {
        guard let chat else {
            let canned = Self.canned(entries.filter { focus == nil || $0.id == focus })
            (answers, system) = (canned, Self.cannedSystem)
            print("ask pi log: " + canned.map { "\($0.entry.id) \($0.steps.count) steps" + ($0.call == nil ? ", no call" : ", call") }.joined(separator: "; "))
            return
        }
        let entries = entries.filter { focus == nil || $0.id == focus }
        // Streams can be long: read them off the main thread.
        (answers, system) = await Task.detached {
            (entries.map { KnowledgeAskLog.load($0, in: chat) }, KnowledgeAskLog.systemPrompt(chat))
        }.value
    }

    private func copyFullLog() {
        let text: String
        if let chat {
            text = KnowledgeAskLog.fullLog(chat, only: focus)
        } else {
            text = (answers ?? []).map(KnowledgeAskLog.text(of:)).joined(separator: "\n\n")
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copied = true
    }

    private func mono(_ text: String) -> some View {
        Text(text).font(.caption.monospaced()).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Snapshots

    static let cannedSystem = "You answer questions in AKit about a note of the user's knowledge base.\n(The rest of the appended system prompt.)"

    /// A made-up log of the canned chat (no Pi runs).
    static func canned(_ entries: [KnowledgeAsk.Entry]) -> [KnowledgeAskLog.Answer] {
        let start = Date(timeIntervalSince1970: 1_761_900_000)
        let stream = [
            #"{"type":"message_end","message":{"role":"assistant","content":[{"type":"thinking","thinking":"Look the event up in the base first."}]}}"#,
            #"{"type":"tool_execution_start","toolName":"bash","toolCallId":"c1","args":{"command":"akit kb search \"order created\" --json"}}"#,
            #"{"type":"tool_execution_end","toolName":"bash","toolCallId":"c1","result":{"content":[{"type":"text","text":"payments/order-events ## Consumers: billing, logistics/warehouse"}]}}"#,
            #"{"type":"tool_execution_start","toolName":"read","toolCallId":"c2","args":{"path":"areas/payments/order-events.md"}}"#,
            ##"{"type":"tool_execution_end","toolName":"read","toolCallId":"c2","result":{"content":[{"type":"text","text":"# order-events\nkind: queue\n## Consumers\n- billing\n- logistics/warehouse"}]}}"##,
            #"{"type":"tool_execution_start","toolName":"mcp__gitlab__search","toolCallId":"c3","args":{"query":"order created consumer"}}"#,
            #"{"type":"tool_execution_end","toolName":"mcp__gitlab__search","toolCallId":"c3","isError":true,"result":{"content":[{"type":"text","text":"401 Unauthorized"}]}}"#,
            #"{"type":"message_end","message":{"role":"assistant","content":[{"type":"text","text":"Two services read order created: billing and warehouse."}]}}"#,
        ]
        let times = KnowledgeAskLog.ToolTimes(starts: [1, 3.5, 4.2].map(start.addingTimeInterval), ends: [2.1, 3.6, 6.0].map(start.addingTimeInterval))
        return entries.map { entry in
            let call = KnowledgeAskLog.Call(
                pi: "~/.local/bin/pi",
                arguments: ["-p", "--mode", "json", "--offline", "--session-dir", "~/.akit/local/knowledge-ask/sample/20261031-100000-ab12/sessions",
                            "--model", entry.model ?? "opencode-go/gpt-6-luna", "--thinking", entry.thinking ?? "low", "--exclude-tools", "edit,write",
                            "--append-system-prompt", "~/.akit/local/knowledge-ask/sample/20261031-100000-ab12/system.md", "--",
                            "The knowledge base \"sample\" is at ~/.akit/local/knowledge/sample.\nThe note: payments/orders-api …\n\nMy question: \(entry.question)"],
                cwd: "~/Projects/orders-api", model: entry.model ?? "", thinking: entry.thinking ?? "", fork: nil,
                session: "~/.akit/local/knowledge-ask/sample/20261031-100000-ab12/sessions/2026-10-31T10-00-00-000Z_demo-1.jsonl",
                started: start, ended: start.addingTimeInterval(40), exitStatus: 0, error: nil,
                usage: SendUsage(input: 18_400, cached: 12_000, output: 420, cost: 0.012), tools: times)
            return KnowledgeAskLog.Answer(entry: entry, call: call, steps: KnowledgeAskLog.steps(stream, times: times),
                                          stream: URL(filePath: "/nonexistent/q.jsonl"))
        }
    }
}

/// One answer in the log: the call, the prompt, the steps.
private struct AnswerLogView: View {
    let answer: KnowledgeAskLog.Answer

    var body: some View {
        let entry = answer.entry
        VStack(alignment: .leading, spacing: 8) {
            Text("\(entry.id): \(entry.question)").font(.headline).textSelection(.enabled)
            if let call = answer.call {
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 3) {
                    row("Model", (call.model.isEmpty ? "Pi's default" : call.model) + " · thinking " + (call.thinking.isEmpty ? "Pi's default" : call.thinking))
                    row("Pi", call.pi)
                    row("Folder", call.cwd)
                    row("Fork", call.fork ?? "none: the chat's first question")
                    row("Session", call.session ?? "-")
                    row("Time", call.started.formatted(date: .abbreviated, time: .standard) + " · " + KnowledgeAskLog.seconds(call.duration)
                        + (call.exitStatus.map { " · exit \($0)" } ?? ""))
                    row("Tokens", "\(call.usage.input) in, \(call.usage.cached) cached, \(call.usage.output) out"
                        + (call.usage.cost.map { String(format: " · $%.4f", $0) } ?? ""))
                    if let error = call.error { row("Error", error) }
                }
                .font(.callout)
                DisclosureGroup("Arguments") {
                    Text(call.arguments.dropLast().joined(separator: " ")).font(.caption.monospaced()).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if let prompt = call.prompt {
                    DisclosureGroup("Prompt sent") {
                        Text(prompt).font(.caption.monospaced()).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            } else {
                Text("No call record: this answer was saved before AKit kept one. Model: \(entry.model ?? "not recorded").")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Text("Steps").font(.subheadline.bold())
            if answer.steps.isEmpty {
                Text("None in the saved stream.").font(.callout).foregroundStyle(.secondary)
            }
            ForEach(answer.steps) { step in StepView(step: step) }
            if let error = entry.error {
                Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.callout).textSelection(.enabled)
            }
            if let proposals = entry.proposals {
                Label("Proposals: " + proposals.map(\.id).joined(separator: ", "), systemImage: "doc.badge.plus").font(.callout)
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder private func row(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value).textSelection(.enabled).lineLimit(2).truncationMode(.middle)
        }
    }
}

/// One step: a tool call (its arguments and result open under it), or Pi's text or thinking.
private struct StepView: View {
    let step: KnowledgeAskLog.Step
    /// Results longer than this show cut, with Show All.
    private static let preview = 2_000
    @State private var all = false

    var body: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 6) {
                if step.kind == .tool, !step.detail.isEmpty {
                    Text("Arguments").font(.caption.bold()).foregroundStyle(.secondary)
                    mono(step.detail)
                }
                if step.kind == .tool {
                    Text("Result").font(.caption.bold()).foregroundStyle(.secondary)
                    if let result = step.result {
                        mono(all || result.count <= Self.preview ? result : String(result.prefix(Self.preview)) + "…")
                        if result.count > Self.preview, !all {
                            Button("Show All (\(result.count.formatted()) characters)") { all = true }.buttonStyle(.link).font(.caption)
                        }
                    } else {
                        Text("No result: Pi was stopped before the tool answered.").font(.caption).foregroundStyle(.secondary)
                    }
                } else {
                    mono(step.detail)
                }
            }
            .padding(.leading, 4)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: icon).foregroundStyle(step.isError ? .red : .secondary)
                    .help(step.isError ? "Failed" : step.kind.rawValue)
                if step.kind == .tool { Text(step.tool).bold() }
                Text(step.summary).font(step.kind == .tool ? .callout.monospaced() : .callout).lineLimit(1).truncationMode(.tail)
                    .foregroundStyle(step.kind == .thinking ? .secondary : .primary)
                Spacer()
                if let duration = step.duration { Text(KnowledgeAskLog.seconds(duration)).font(.caption).foregroundStyle(.secondary).monospacedDigit() }
            }
        }
    }

    private var icon: String {
        switch step.kind {
        case .tool: step.isError ? "xmark.octagon" : step.result == nil ? "hourglass" : "wrench.and.screwdriver"
        case .text: "text.bubble"
        case .thinking: "brain"
        case .error: "exclamationmark.triangle"
        }
    }

    private func mono(_ text: String) -> some View {
        Text(text).font(.caption.monospaced()).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            .padding(6).background(.background.opacity(0.6), in: RoundedRectangle(cornerRadius: 4))
    }
}
