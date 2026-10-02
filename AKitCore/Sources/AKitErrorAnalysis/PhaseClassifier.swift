import AKitSessions
import Foundation

/// Where in the work something happened (`docs/design/error-analysis.md`, "Transition
/// matrix"). Code derives explore, edit, verify and report; only the model labels
/// understand and plan.
public enum Phase: String, Codable, Sendable, CaseIterable {
    case understand, explore, plan, edit, verify, report

    public var title: String { rawValue.capitalized }
}

/// One session's phases by code: what the transition matrix reads.
public struct SessionPhases: Hashable, Sendable {
    /// The phase of every step.
    public var steps: [Int: Phase]
    /// The phase of the step just before each step's action: the matrix's row.
    public var before: [Int: Phase]

    public init(steps: [Int: Phase], before: [Int: Phase]) {
        self.steps = steps
        self.before = before
    }
}

/// Phases by code, from the tool each step used. Notes get their phase from their step `#n`
/// here, never from the model, so the matrix doesn't depend on the notes model.
public enum PhaseClassifier {
    /// A phase for every item id. Tool calls go by tool and command; results take their call's
    /// phase; everything else keeps the previous phase (understand before any tool), except
    /// the session's last assistant text, which is the report.
    public static func phases(of items: [TranscriptItem]) -> [Int: Phase] {
        let report = items.last { $0.kind == .assistant }?.id
        let calls = calls(of: items)
        var result: [Int: Phase] = [:]
        var previous = Phase.understand
        for item in items {
            let phase: Phase
            switch item.kind {
            case .toolCall(let name):
                phase = toolPhase(name, input: item.text) ?? previous
            case .toolResult:
                phase = calls[item.id].flatMap { result[$0] } ?? previous
            default:
                phase = item.id == report ? .report : previous
            }
            result[item.id] = phase
            previous = phase
        }
        return result
    }

    /// The phases of a session's steps, and for every step the phase of the step just before
    /// its action. A tool result is part of its call's action, so its row is the step before
    /// that call: otherwise a failing test result would always sit in the verify → verify cell.
    public static func session(_ items: [TranscriptItem]) -> SessionPhases {
        let steps = phases(of: items)
        let calls = calls(of: items)
        var before: [Int: Phase] = [:]
        var previous: Phase?
        for item in items {
            if case .toolResult = item.kind, let call = calls[item.id] {
                before[item.id] = before[call]
            } else {
                before[item.id] = previous
            }
            previous = steps[item.id]
        }
        return SessionPhases(steps: steps, before: before)
    }

    /// Each tool result's call: the oldest call still waiting for a result, of the same tool
    /// when the result names one. Parallel calls (call A, call B, result A, result B) get
    /// their own results in order. A user turn ends the calls still waiting.
    static func calls(of items: [TranscriptItem]) -> [Int: Int] {
        var waiting: [(id: Int, name: String)] = []
        var result: [Int: Int] = [:]
        for item in items {
            switch item.kind {
            case .toolCall(let name):
                waiting.append((item.id, name))
            case .toolResult(let name, _):
                guard let index = waiting.firstIndex(where: { $0.name == name }) ?? (waiting.isEmpty ? nil : 0) else { continue }
                result[item.id] = waiting.remove(at: index).id
            case .user:
                waiting.removeAll()
            default:
                break
            }
        }
        return result
    }

    /// The phases of a recorded session, read from its transcript file; nil when it can't be read.
    public static func session(sessionKey: String, transcript: String) -> SessionPhases? {
        let target = NotesPipeline.Target(harness: SessionKey.harness(of: sessionKey), file: URL(filePath: transcript))
        return (try? SessionReader.transcript(of: target.summary)).map { session($0.items) }
    }

    static let exploreTools: Set = ["Read", "Grep", "Glob", "LS", "NotebookRead", "WebFetch", "WebSearch",
                                    "read", "grep", "find", "ls"]
    static let editTools: Set = ["Edit", "Write", "MultiEdit", "NotebookEdit", "edit", "write"]
    static let browserPrefixes = ["mcp__claude-in-chrome__", "mcp__playwright", "mcp__Claude_Browser"]

    /// nil: the tool says nothing about the phase (Task, TodoWrite, Skill, unknown MCP…).
    static func toolPhase(_ name: String, input: String) -> Phase? {
        if exploreTools.contains(name) { return .explore }
        if editTools.contains(name) { return .edit }
        if browserPrefixes.contains(where: name.hasPrefix) || name.lowercased().contains("browser") { return .verify }
        guard name == "Bash" || name == "bash" else { return nil }
        let object = try? JSONSerialization.jsonObject(with: Data(input.utf8)) as? [String: Any]
        return (object?["command"] as? String).flatMap(ShellPhase.phase)
    }
}

/// The phase of a shell command: verify when it runs tests, a build or a linter, edit when it
/// writes files, explore when it only reads. Chained commands (`&&`, `;`, `|`) take the
/// strongest: verify over edit over explore. nil when nothing is recognised.
enum ShellPhase {
    static func phase(of command: String) -> Phase? {
        let script = stripQuotes(stripHeredocBodies(command))
        var strongest: Phase?
        for segment in segments(markingRedirects(script)) {
            var words = segment.split(whereSeparator: \.isWhitespace).map(String.init)
            let writes = words.contains(writeMarker)
            words.removeAll { $0 == writeMarker }
            var phase = wordsPhase(words, raw: command)
            if writes, phase != .verify { phase = .edit }
            strongest = stronger(strongest, phase)
        }
        return strongest
    }

    private static func rank(_ phase: Phase?) -> Int {
        switch phase {
        case .verify: 3
        case .edit: 2
        case .explore: 1
        default: 0
        }
    }

    private static func stronger(_ a: Phase?, _ b: Phase?) -> Phase? { rank(b) > rank(a) ? b : a }

    // MARK: Words

    static let verifyTools: Set = ["xcodebuild", "pytest", "tsc", "eslint", "vitest", "jest", "mocha", "ruff", "mypy",
                                   "pyright", "flake8", "pylint", "swiftlint", "rspec", "golangci-lint", "shellcheck",
                                   "tox", "ctest", "phpunit"]
    /// Tools that verify with these subcommands only (`swift test`, not `swift package init`).
    static let verifySubcommands: [String: Set<String>] = [
        "swift": ["test", "build"], "go": ["test", "build", "vet"],
        "cargo": ["test", "build", "check", "clippy", "nextest"],
        "dotnet": ["test", "build"], "bazel": ["test", "build"], "xcrun": ["xctest", "xcodebuild"],
    ]
    static let scriptWords: Set = ["test", "t", "build", "lint", "check", "typecheck", "tsc", "vitest", "jest", "e2e"]
    static let packageManagers: Set = ["npm", "pnpm", "yarn", "bun"]
    static let gradleTasks: Set = ["test", "build", "check", "verify", "lint", "assemble", "package"]
    static let exploreCommands: Set = ["cat", "head", "tail", "less", "more", "grep", "egrep", "fgrep", "rg", "ag",
                                       "ls", "wc", "file", "stat", "which", "pwd", "echo", "printf", "jq", "tree",
                                       "du", "df", "diff", "cmp", "sort", "uniq", "cut", "tr", "nl", "column", "awk",
                                       "basename", "dirname", "realpath", "readlink", "whoami", "date", "type", "yq"]
    static let editCommands: Set = ["tee", "mv", "cp", "rm", "rmdir", "mkdir", "touch", "chmod", "chown", "ln",
                                    "patch", "apply_patch", "applypatch", "truncate"]
    static let gitExplore: Set = ["status", "log", "diff", "show", "branch", "blame", "rev-parse", "ls-files", "grep",
                                  "describe", "shortlog", "reflog", "cat-file", "ls-tree", "remote", "fetch"]
    static let gitEdit: Set = ["add", "commit", "checkout", "switch", "merge", "rebase", "reset", "stash", "restore",
                               "rm", "mv", "apply", "cherry-pick", "revert", "pull", "am", "clean"]
    /// Words that run the rest of the line as a command.
    static let wrappers: Set = ["sudo", "time", "env", "nohup", "nice", "xargs", "command", "exec", "timeout",
                                "npx", "bunx", "pnpx"]
    static let interpreters: Set = ["python", "python3", "node", "ruby", "perl", "deno"]

    static func wordsPhase(_ words: [String], raw: String) -> Phase? {
        var index = 0
        // Wrappers, their flags, environment assignments and `timeout`'s duration.
        while index < words.count {
            let word = words[index]
            let name = tool(word)
            if word.contains("="), !word.hasPrefix("-"), name == word { index += 1; continue }
            if wrappers.contains(name) {
                index += 1
                while index < words.count, words[index].hasPrefix("-") || (name == "timeout" && Double(words[index].trimmingCharacters(in: .letters)) != nil) {
                    index += 1
                }
                continue
            }
            // `uv run pytest`, `poetry run`, `bundle exec`, `python -m pytest`, `pnpm exec`.
            if index + 1 < words.count,
               ["uv run", "poetry run", "pipenv run", "bundle exec", "pnpm exec", "pnpm dlx", "yarn dlx", "yarn exec"]
                .contains("\(name) \(words[index + 1])") {
                index += 2
                continue
            }
            if interpreters.contains(name), index + 2 < words.count, words[index + 1] == "-m" {
                index += 2
                continue
            }
            break
        }
        guard index < words.count else { return nil }
        let name = tool(words[index])
        let args = Array(words[(index + 1)...])
        let firstArg = args.first { !$0.hasPrefix("-") }

        if verifyTools.contains(name) { return name == "ruff" && firstArg == "format" ? .edit : .verify }
        if let subcommands = verifySubcommands[name] {
            return firstArg.map(subcommands.contains) == true ? .verify : nil
        }
        if packageManagers.contains(name) {
            let rest = args.filter { !$0.hasPrefix("-") }
            var script = rest.first
            if script == "run" || script == "run-script" { script = rest.dropFirst().first }
            let base = script.map { String($0.split(separator: ":").first ?? "") }
            return base.map(scriptWords.contains) == true ? .verify : nil
        }
        if name == "make" {
            let targets = args.filter { !$0.hasPrefix("-") && !$0.contains("=") }
            // Without a target, make runs its default target, which usually builds.
            return targets.isEmpty || targets.contains(where: { target in
                ["build", "test", "check", "lint"].contains(where: target.hasPrefix)
            }) ? .verify : nil
        }
        if ["gradle", "gradlew", "mvn", "mvnw"].contains(name) {
            let tasks = args.map { String($0.split(separator: ":").last ?? "") }
            return tasks.contains(where: gradleTasks.contains) ? .verify : nil
        }
        if name == "git" { return gitPhase(args) }
        if name == "sed" { return args.contains { $0.hasPrefix("-i") || $0 == "--in-place" } ? .edit : .explore }
        if name == "perl", args.contains(where: { $0.hasPrefix("-") && !$0.hasPrefix("--") && $0.contains("i") }) { return .edit }
        if name == "find" { return args.contains("-delete") ? .edit : .explore }
        if exploreCommands.contains(name) { return .explore }
        if editCommands.contains(name) { return .edit }
        // A script that writes; anything else it does is unknown.
        if interpreters.contains(name) { return writesFromScript(raw) ? .edit : nil }
        return nil
    }

    /// `/usr/bin/git`, `./gradlew` → `git`, `gradlew`.
    private static func tool(_ word: String) -> String {
        word.split(separator: "/").last.map(String.init) ?? word
    }

    private static func gitPhase(_ args: [String]) -> Phase? {
        var index = 0
        // Global options before the subcommand; `-C <path>` and `-c <key=value>` take a value.
        while index < args.count, args[index].hasPrefix("-") {
            index += args[index] == "-C" || args[index] == "-c" ? 2 : 1
        }
        guard index < args.count else { return nil }
        if gitExplore.contains(args[index]) { return .explore }
        if gitEdit.contains(args[index]) { return .edit }
        return nil
    }

    static let scriptWrite = try! NSRegularExpression(
        pattern: #"open\([^)]*['"][wax]b?\+?['"]|\.write_text\(|\.write_bytes\(|writeFileSync|writeFile\(|File\.write|shutil\.(copy|move)|os\.(remove|rename)"#)

    private static func writesFromScript(_ raw: String) -> Bool {
        scriptWrite.firstMatch(in: raw, range: NSRange(raw.startIndex..., in: raw)) != nil
    }

    // MARK: Splitting

    /// Lines of a heredoc's body are data, not commands: `cat > f <<'EOF'` keeps its first line.
    static func stripHeredocBodies(_ command: String) -> String {
        let start = try! NSRegularExpression(pattern: #"<<-?\s*['"]?([A-Za-z_][A-Za-z0-9_]*)['"]?"#)
        var kept: [Substring] = []
        var delimiter: String?
        for line in command.split(separator: "\n", omittingEmptySubsequences: false) {
            if let open = delimiter {
                if line.trimmingCharacters(in: .whitespaces) == open { delimiter = nil }
                continue
            }
            kept.append(line)
            let text = String(line)
            if !text.contains("<<<"), let match = start.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
               let range = Range(match.range(at: 1), in: text) {
                delimiter = String(text[range])
            }
        }
        return kept.joined(separator: "\n")
    }

    /// Quoted text becomes `''`: a `>` or `;` inside quotes is not shell syntax.
    static func stripQuotes(_ script: String) -> String {
        var result = ""
        var quote: Character?
        var escaped = false
        for char in script {
            if let open = quote {
                if escaped { escaped = false } else if char == "\\" && open == "\"" { escaped = true } else if char == open {
                    quote = nil
                    result += "''"
                }
                continue
            }
            if char == "'" || char == "\"" { quote = char } else { result.append(char) }
        }
        if quote != nil { result += "''" }
        return result
    }

    static let writeMarker = "\u{1}write"
    /// `>`, `>>`, `2>`, `&>`, `>|` and their target. `2>&1` and `/dev/null` write no file.
    static let redirect = try! NSRegularExpression(pattern: #"(?:\d|&)?>>?\|?\s*(&[0-9-]|[^\s;&|<>()]+)?"#)

    /// Redirects become the write marker (when they write a file) or a space, before `&`
    /// can be read as a separator.
    static func markingRedirects(_ script: String) -> String {
        var result = script
        let ns = script as NSString
        for match in redirect.matches(in: script, range: NSRange(location: 0, length: ns.length)).reversed() {
            let target = match.range(at: 1).location == NSNotFound ? "" : ns.substring(with: match.range(at: 1))
            let writes = !target.isEmpty && !target.hasPrefix("&") && !target.hasPrefix("/dev/")
            guard let range = Range(match.range, in: result) else { continue }
            result.replaceSubrange(range, with: writes ? " \(writeMarker) " : " ")
        }
        return result
    }

    static func segments(_ script: String) -> [Substring] {
        script.split { "\n;|&()`{}".contains($0) }
    }
}
