import Foundation
import Testing
import AKitFoundation
import AKitSessions
@testable import AKitErrorAnalysis

struct PhaseClassifierTests {
    func bash(_ command: String) -> String { JSONLines.pretty(["command": command, "description": "Run it"]) }

    func phase(_ command: String) -> Phase? { ShellPhase.phase(of: command) }

    @Test func sessionGetsAPhaseForEveryItem() {
        let items: [(TranscriptItem.Kind, String)] = [
            (.user, "Fix the parser"),
            (.assistant, "Let me look."),
            (.thinking, "hmm"),
            (.toolCall(name: "Read"), #"{"file_path": "/x/Parser.swift"}"#),
            (.toolResult(name: "Read", isError: false), "struct Parser {}"),
            (.toolCall(name: "TodoWrite"), "{}"),
            (.toolResult(name: "TodoWrite", isError: false), "ok"),
            (.toolCall(name: "Edit"), #"{"file_path": "/x/Parser.swift"}"#),
            (.toolResult(name: "Edit", isError: false), "updated"),
            (.toolCall(name: "Bash"), bash("cd AKitCore && swift test 2>&1 | tail -20")),
            (.toolResult(name: "Bash", isError: true), "Exit code 1"),
            (.event("Compacted"), "summary"),
            (.toolCall(name: "mcp__claude-in-chrome__navigate"), "{}"),
            (.toolCall(name: "Task"), "{}"),
            (.toolResult(name: nil, isError: false), "done"),
            (.assistant, "Fixed."),
            (.user, "thanks"),
        ]
        let transcript = items.enumerated().map { TranscriptItem(id: $0.offset, kind: $0.element.0, text: $0.element.1, timestamp: nil) }
        let phases = PhaseClassifier.phases(of: transcript)
        #expect(phases.count == items.count)
        #expect((0..<17).map { phases[$0] } == [
            .understand, .understand, .understand, .explore, .explore, .explore, .explore, .edit, .edit,
            .verify, .verify, .verify, .verify, .verify, .verify, .report, .report,
        ])
    }

    @Test func piToolNames() {
        let items = [
            TranscriptItem(id: 0, kind: .toolCall(name: "ls"), text: "{}", timestamp: nil),
            TranscriptItem(id: 1, kind: .toolCall(name: "write"), text: "{}", timestamp: nil),
            TranscriptItem(id: 2, kind: .toolCall(name: "bash"), text: bash("go test ./..."), timestamp: nil),
            TranscriptItem(id: 3, kind: .toolCall(name: "find"), text: "{}", timestamp: nil),
        ]
        #expect(PhaseClassifier.phases(of: items) == [0: .explore, 1: .edit, 2: .verify, 3: .explore])
    }

    @Test func browserToolsVerify() {
        for name in ["mcp__playwright__browser_click", "mcp__Claude_Browser__navigate", "mcp__remote-devices__Claude_Browser__read"] {
            #expect(PhaseClassifier.toolPhase(name, input: "{}") == .verify)
        }
        #expect(PhaseClassifier.toolPhase("mcp__linear__list_issues", input: "{}") == nil)
        #expect(PhaseClassifier.toolPhase("Bash", input: "not json") == nil)
    }

    @Test func verifyCommands() {
        for command in ["swift test --filter Foo", "swift build", "xcodebuild -scheme AKit test", "make test", "make build",
                        "make", "npm test", "npm run test:unit", "pnpm lint", "yarn build", "bun test", "npx tsc --noEmit",
                        "npx vitest run", "pytest -x tests/", "python -m pytest", "uv run pytest", "go vet ./...",
                        "cargo clippy", "./gradlew :app:test", "mvn -q test", "ruff check .", "mypy src", "tsc -p .",
                        "eslint src", "swiftlint", "bundle exec rspec", "timeout 60 swift test", "FOO=1 make check",
                        "/usr/bin/xcrun xcodebuild build"] {
            #expect(phase(command) == .verify, "\(command)")
        }
    }

    @Test func exploreCommands() {
        for command in ["cat README.md", "sed -n '1,40p' x.swift", "head -50 log", "tail -f log", "grep -rn foo .",
                        "rg 'a > b' src", "ls -la", "find . -name '*.swift'", "wc -l x", "git status", "git log --oneline -5",
                        "git -C repo diff HEAD~1", "git show HEAD", "git blame x", "which swift", "pwd", "echo $PATH",
                        "jq .name package.json", "cat x | grep y | head", "ls 2>/dev/null", "cat x 2>&1"] {
            #expect(phase(command) == .explore, "\(command)")
        }
    }

    @Test func editCommands() {
        for command in ["echo hi > notes.txt", "cat >> log.txt", "printf x | tee out.txt", "sed -i '' 's/a/b/' x",
                        "mv a b", "cp a b", "rm -rf build", "mkdir -p x/y", "touch x", "chmod +x run.sh",
                        "git add . && git commit -m 'msg > other'", "git checkout -b feature", "git stash",
                        "patch -p1 < fix.diff", "find . -name '*.orig' -delete", "ls > files.txt",
                        "cat > Sources/A.swift <<'EOF'\nimport Foundation\nswift test\nEOF",
                        "python3 - <<'EOF'\nopen('x.txt', 'w').write('y')\nEOF",
                        "node -e \"require('fs').writeFileSync('a', 'b')\""] {
            #expect(phase(command) == .edit, "\(command)")
        }
    }

    @Test func unknownCommandsHaveNoPhase() {
        for command in ["cd AKitCore", "python3 script.py", "git push", "open AKit.app", "swift package resolve",
                        "npm install", "export FOO=1", "make snapshot OUT=x.png", "echo 'a > b'"] {
            #expect(phase(command) == (command.hasPrefix("echo") ? .explore : nil), "\(command)")
        }
    }

    @Test func chainsTakeTheStrongestPhase() {
        #expect(phase("cat x && rm y") == .edit)
        #expect(phase("mkdir -p out && swift build 2>&1 | tail -5") == .verify)
        #expect(phase("git status; git diff") == .explore)
        #expect(phase("swift test > out.txt") == .verify)
        #expect(phase("cd x && (make test)") == .verify)
    }

    @Test func toolResultTakesItsCallsPhaseAndUnknownToolsKeepThePrevious() {
        let items = [
            TranscriptItem(id: 0, kind: .toolCall(name: "Bash"), text: bash("swift test"), timestamp: nil),
            TranscriptItem(id: 1, kind: .toolCall(name: "Skill"), text: "{}", timestamp: nil),
            TranscriptItem(id: 2, kind: .toolResult(name: "Bash", isError: false), text: "ok", timestamp: nil),
            TranscriptItem(id: 3, kind: .toolCall(name: "Bash"), text: bash("cd x"), timestamp: nil),
            TranscriptItem(id: 4, kind: .assistant, text: "Done", timestamp: nil),
            TranscriptItem(id: 5, kind: .toolCall(name: "Grep"), text: "{}", timestamp: nil),
        ]
        #expect(PhaseClassifier.phases(of: items) == [0: .verify, 1: .verify, 2: .verify, 3: .verify, 4: .report, 5: .explore])
    }

    @Test func phaseTitles() {
        #expect(Phase.allCases.map(\.title) == ["Understand", "Explore", "Plan", "Edit", "Verify", "Report"])
    }
}
