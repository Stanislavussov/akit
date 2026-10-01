import AKitSessions
import Foundation

/// Tool calls of a transcript paired with their results, the shared ground of signals and
/// code checks. Tool call items hold the call's input as JSON text.
struct TranscriptFacts {
    struct Call {
        let step: Int
        let name: String
        let input: [String: Any]
        /// The raw input text: identical calls have identical text.
        let text: String
        var result: TranscriptItem?
    }

    let items: [TranscriptItem]
    let calls: [Call]
    let phases: [Int: Phase]

    init(_ items: [TranscriptItem]) {
        self.items = items
        phases = PhaseClassifier.phases(of: items)
        var calls: [Call] = []
        // Results come in call order; with parallel calls several calls come before their
        // results, so each result takes the oldest open call of its tool.
        var open: [Int] = []
        for item in items {
            switch item.kind {
            case .toolCall(let name):
                let input = (try? JSONSerialization.jsonObject(with: Data(item.text.utf8))) as? [String: Any] ?? [:]
                calls.append(Call(step: item.id, name: name, input: input, text: item.text))
                open.append(calls.count - 1)
            case .toolResult(let name, _):
                let index = open.firstIndex { name == nil || calls[$0].name == name } ?? open.indices.first
                if let index {
                    calls[open[index]].result = item
                    open.remove(at: index)
                }
            default:
                break
            }
        }
        self.calls = calls
    }

    var userTurns: [TranscriptItem] {
        items.filter { if case .user = $0.kind { true } else { false } }
    }

    /// The last thing the agent said: its report.
    var finalReport: TranscriptItem? {
        items.last { if case .assistant = $0.kind { true } else { false } }
    }

    static func isShell(_ name: String) -> Bool { name == "Bash" || name == "bash" }

    /// The file a call reads or writes (`file_path` in Claude Code, `path` in Pi).
    static func path(_ call: Call) -> String? {
        (call.input["file_path"] as? String) ?? (call.input["path"] as? String) ?? (call.input["filePath"] as? String)
    }

    static func command(_ call: Call) -> String? { isShell(call.name) ? call.input["command"] as? String : nil }

    /// "done", "all tests pass", "готово": the agent says the work is finished.
    static func claimsDone(_ text: String) -> Bool {
        text.range(of: #"(?i)\b(done|complete[d]?|finished|all (tests|checks) pass(ed)?|works now|is fixed|fixed it|ready)\b|готово|сделано"#,
                   options: .regularExpression) != nil
    }
}
