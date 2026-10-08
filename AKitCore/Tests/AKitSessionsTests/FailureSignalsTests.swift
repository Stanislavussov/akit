import Foundation
import Testing
@testable import AKitSessions

/// The shared rules of interrupts, rejections, tool errors and repeated calls.
struct FailureSignalsTests {
    /// A made-up transcript.
    struct Log {
        var items: [TranscriptItem] = []

        mutating func add(_ kind: TranscriptItem.Kind, _ text: String) {
            items.append(TranscriptItem(id: items.count, kind: kind, text: text, timestamp: nil))
        }

        mutating func call(_ name: String, _ input: [String: Any]) {
            add(.toolCall(name: name), FailureSignals.inputText(input))
        }
    }

    @Test func interruptIsTheStartOfUserText() {
        var log = Log()
        log.add(.user, "[Request interrupted by user]")
        log.add(.user, "  [Request interrupted by user for tool use]")
        log.add(.user, "Why did you print [Request interrupted by user] in the log?")
        // Assistant text and tool output are not the user's.
        log.add(.assistant, "[Request interrupted by user]")
        log.add(.toolResult(name: "Bash", isError: true), "[Request interrupted by user for tool use]")
        let signals = FailureSignals(log.items)
        #expect(signals.interrupts == 2)
        #expect(signals.toolErrors == 0 && signals.rejected == 0)
        #expect(!FailureSignals.isInterrupt("Stop [Request interrupted by user]"))
    }

    @Test func threeInARowIsARepeat() {
        var log = Log()
        // Two in a row: not a repeat.
        log.call("Read", ["file_path": "/a"])
        log.add(.toolResult(name: "Read", isError: false), "a")
        log.call("Read", ["file_path": "/a"])
        #expect(FailureSignals(log.items).repeatedCalls == 0)
        // The third, with results and text between: one run.
        log.add(.toolResult(name: "Read", isError: false), "a")
        log.add(.assistant, "Again")
        log.call("Read", ["file_path": "/a"])
        #expect(FailureSignals(log.items).repeatedCalls == 1)
        // A longer run still counts once.
        log.call("Read", ["file_path": "/a"])
        log.call("Read", ["file_path": "/a"])
        #expect(FailureSignals(log.items).repeatedCalls == 1)
    }

    @Test func anotherCallBreaksTheRun() {
        var log = Log()
        log.call("Bash", ["command": "swift test"])
        log.call("Bash", ["command": "swift test"])
        log.call("Read", ["file_path": "/a"])
        log.call("Bash", ["command": "swift test"])
        // Same tool, other input.
        log.call("Bash", ["command": "swift build"])
        log.call("Bash", ["command": "swift test"])
        // Same input, other tool.
        log.call("Grep", ["command": "swift test"])
        #expect(FailureSignals(log.items).repeatedCalls == 0)
        // Key order doesn't matter: the input is sorted JSON.
        var signals = FailureSignals()
        for input in [#"{"a":1,"b":2}"#, #"{"b":2,"a":1}"#, #"{"a":1,"b":2}"#] {
            let object = try! JSONSerialization.jsonObject(with: Data(input.utf8))
            signals.toolCall("Edit", input: FailureSignals.inputText(object))
        }
        #expect(signals.repeatedCalls == 1)
    }

    @Test func twoRunsCountTwice() {
        var log = Log()
        for _ in 0..<3 { log.call("Read", ["file_path": "/a"]) }
        log.call("Glob", ["pattern": "*"])
        for _ in 0..<4 { log.call("Read", ["file_path": "/a"]) }
        #expect(FailureSignals(log.items).repeatedCalls == 2)
    }

    @Test func rejectionsAreNotToolErrors() {
        var log = Log()
        log.call("Edit", ["file_path": "/a"])
        log.add(.toolResult(name: "Edit", isError: true), "The user doesn't want to proceed with this tool use. The tool use was rejected.")
        log.call("Bash", ["command": "rm -rf /"])
        log.add(.toolResult(name: "Bash", isError: true), "Permission to use Bash with command rm -rf / has been denied.")
        log.call("Bash", ["command": "swift build"])
        log.add(.toolResult(name: "Bash", isError: true), "Exit code 1\nerror: nope")
        log.call("Read", ["file_path": "/missing"])
        log.add(.toolResult(name: "Read", isError: true), "File does not exist.")
        // Pi: an extension's refusal and an aborted command.
        log.call("write", ["path": "/a"])
        log.add(.toolResult(name: "write", isError: true), "Blocked write: /a is outside the project")
        log.call("bash", ["command": "sleep 100"])
        log.add(.toolResult(name: "bash", isError: true), "Command aborted")
        // A successful call is nothing.
        log.call("Read", ["file_path": "/b"])
        log.add(.toolResult(name: "Read", isError: false), "Permission to use the file was denied, it says")
        let signals = FailureSignals(log.items)
        #expect(signals.rejected == 3 && signals.toolErrors == 2 && signals.interrupts == 0)
    }

    @Test func escAtThePromptIsAnInterruptNotARejection() {
        var log = Log()
        // Two parallel calls refused by Esc: Claude Code writes the refusal text, then the interrupt line.
        log.call("Edit", ["file_path": "/a"])
        log.call("Edit", ["file_path": "/b"])
        let refusal = "The user doesn't want to proceed with this tool use. The tool use was rejected."
        log.add(.toolResult(name: "Edit", isError: true), refusal)
        log.add(.toolResult(name: "Edit", isError: true), refusal)
        log.add(.user, "[Request interrupted by user for tool use]")
        // A refusal with a reason stays one.
        log.call("Edit", ["file_path": "/c"])
        log.add(.toolResult(name: "Edit", isError: true), refusal)
        log.add(.user, "Use the other file")
        let signals = FailureSignals(log.items)
        #expect(signals.interrupts == 1 && signals.rejected == 1 && signals.toolErrors == 0)
    }
}
