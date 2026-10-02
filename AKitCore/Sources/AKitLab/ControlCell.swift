import AKitFoundation
import AKitSessions
import Foundation

/// The one difference a variant setup makes (`docs/design/error-analysis.md`, "Controlled
/// evals"): text appended to a file of the clone, or the file written when it is absent: a
/// CLAUDE.md or AGENTS.md rule, a skill. Applied to the isolated clone only, never to the
/// user's repository.
public struct ControlPatch: Codable, Sendable, Hashable {
    /// Relative to the repository root: `CLAUDE.md`, `AGENTS.md`, `.claude/skills/<name>/SKILL.md`.
    public var file: String
    public var text: String

    public init(file: String, text: String) {
        self.file = file
        self.text = text
    }

    /// The file in `folder`; refuses a path that could leave it or touch `.git`.
    func target(in folder: URL) throws -> URL {
        let parts = file.split(separator: "/").map(String.init)
        guard !parts.isEmpty, !file.hasPrefix("/"), !file.hasPrefix("~"), !parts.contains(".."), parts.first != ".git" else {
            throw LabWorker.Failure(message: "The patch file must be a path inside the repository, not \(file).")
        }
        return folder.appending(path: file)
    }

    /// Appends the text after a blank line, or writes the file. The change is then hidden from
    /// `git status` and `git diff` (assume-unchanged, or `.git/info/exclude` for a new file):
    /// the agent sees a clean checkout as in the baseline, and its own commits leave it out.
    func apply(in folder: URL, env: HarnessEnvironment) async throws {
        let url = try target(in: folder)
        let fm = FileManager.default
        var content = fm.fileExists(atPath: url.path) ? try String(contentsOf: url, encoding: .utf8) : ""
        if !content.isEmpty { content += content.hasSuffix("\n") ? "\n" : "\n\n" }
        content += text.hasSuffix("\n") ? text : text + "\n"
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(content.utf8).write(to: url)
        if await LabGit.run(["ls-files", "--error-unmatch", file], in: folder, env: env)?.succeeded == true {
            _ = await LabGit.run(["update-index", "--assume-unchanged", file], in: folder, env: env)
        } else {
            let exclude = folder.appending(path: ".git/info/exclude")
            let old = (try? String(contentsOf: exclude, encoding: .utf8)) ?? ""
            try? fm.createDirectory(at: exclude.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? Data((old + (old.isEmpty || old.hasSuffix("\n") ? "" : "\n") + "/\(file)\n").utf8).write(to: exclude)
        }
    }
}

/// How the agent of a control cell is started: a harness, model and effort, and at most one
/// difference from the baseline. Cells of setups that differ only in `patch` compare the fix.
public struct ControlSetup: Codable, Sendable, Hashable {
    /// `baseline`, `variant`, `read-only`: what the user calls it.
    public var name: String
    public var agent: LabAgent
    /// nil for the baseline.
    public var patch: ControlPatch?
    /// The sanity check: an agent that can only read can't do the task, so its cells must fail.
    public var readOnly: Bool

    public init(name: String, agent: LabAgent, patch: ControlPatch? = nil, readOnly: Bool = false) {
        self.name = name
        self.agent = agent
        self.patch = patch
        self.readOnly = readOnly
    }

    /// "variant · Claude Code · opus · high · + CLAUDE.md".
    public var label: String {
        var parts = [name, agent.harness.title, agent.model.isEmpty ? "default model" : agent.model, agent.effort]
        if let patch { parts.append("+ \(patch.file)") }
        if readOnly { parts.append("read-only") }
        return parts.joined(separator: " · ")
    }

    /// Claude Code keeps a replay's tools; Pi's coding tools are named, since a coding agent
    /// needs them.
    var tools: [String] {
        switch agent.harness {
        case .claudeCode: readOnly ? ["--tools", "Read,Grep,Glob"] : []
        case .pi: ["--tools", readOnly ? "read,grep,find,ls" : "read,write,edit,bash,grep,find,ls"]
        }
    }
}

/// What a control cell's oracle said, and whether the cell can be trusted.
public struct ControlOutcome: Codable, Sendable, Hashable {
    /// The cell key: the done key of task, setup, base commit and repeat number. A key with a
    /// finished, unflagged result isn't queued again.
    public var key: String
    public var passed: Bool
    /// "tests passed (exit 0)", "large-file-read-whole: not present".
    public var oracle: String
    /// Fewer test markers (`@Test`, `func test`, `it(`…) after the agent than before.
    public var testsDropped: Bool
    /// Test files the agent changed or deleted.
    public var changedTestFiles: [String]
    /// Signs the agent read the exemplar session.
    public var leaks: [String]
    /// Where an assertion's mode shows.
    public var checkSteps: [Int]

    public init(key: String, passed: Bool, oracle: String, testsDropped: Bool = false, changedTestFiles: [String] = [],
                leaks: [String] = [], checkSteps: [Int] = []) {
        self.key = key
        self.passed = passed
        self.oracle = oracle
        self.testsDropped = testsDropped
        self.changedTestFiles = changedTestFiles
        self.leaks = leaks
        self.checkSteps = checkSteps
    }

    /// A guarded or leaked cell is shown, but its pass isn't trusted and comparisons leave it out.
    public var flagged: Bool { testsDropped || !changedTestFiles.isEmpty || !leaks.isEmpty }

    var lines: [String] {
        var lines = ["Control: \(passed ? "passed" : "failed") · \(oracle)"]
        if testsDropped { lines.append("  Fewer tests than before the agent: the pass isn't trusted.") }
        if !changedTestFiles.isEmpty {
            lines.append("  Test files changed: \(changedTestFiles.prefix(5).joined(separator: ", ")): the pass isn't trusted.")
        }
        return lines
    }
}

/// Lab's part of a control cell: the agent works on a task in an isolated clone of the base
/// commit with one setup, then the guard and the test command. Error analysis owns the
/// tasks, the assertion and the comparison (`AnalysisRuns`).
public enum ControlCell {
    public struct Facts: Sendable {
        /// The cell's own session, read like an indexed one; nil when the harness wrote none.
        public var transcript: SessionTranscript?
        public var metrics: SessionMetrics?
        public var agentError: String?
        public var usage: SendUsage
        /// The test command's verdict; nil without one.
        public var tests: TestCommand?
        public var testsDropped: Bool
        public var changedTestFiles: [String]

        public init(transcript: SessionTranscript?, metrics: SessionMetrics? = nil, agentError: String? = nil, usage: SendUsage = SendUsage(),
                    tests: TestCommand? = nil, testsDropped: Bool = false, changedTestFiles: [String] = []) {
            self.transcript = transcript
            self.metrics = metrics
            self.agentError = agentError
            self.usage = usage
            self.tests = tests
            self.testsDropped = testsDropped
            self.changedTestFiles = changedTestFiles
        }
    }

    public struct TestCommand: Sendable, Hashable {
        public var passed: Bool
        public var detail: String

        public init(passed: Bool, detail: String) {
            self.passed = passed
            self.detail = detail
        }
    }

    /// The clone goes to the Trash at the end, or into the run folder as `work` with `keep`.
    /// The agent gets the run folder for its stream only, never as `AKIT_LAB_DIR`.
    public static func run(_ run: LabRun, setup: ControlSetup, repo: URL, base: String, prompt: String, testCommand: String?,
                           testLimit: TimeInterval = 15 * 60, env: HarnessEnvironment,
                           phase: @escaping @Sendable (RunState.Phase) -> Void,
                           out: @escaping @Sendable (String) -> Void) async throws -> Facts {
        let work = FileManager.default.temporaryDirectory
            .appending(path: "akit-control-\(UUID().uuidString.lowercased())", directoryHint: .isDirectory)
        defer {
            if FileManager.default.fileExists(atPath: work.path) {
                if run.spec.keep {
                    try? FileManager.default.moveItem(at: work, to: run.folder.appending(path: "work"))
                } else {
                    _ = try? Trash.move(work)
                }
            }
        }
        try await IsolatedClone.make(at: work, from: repo, commit: base, env: env)
        if let patch = setup.patch { try await patch.apply(in: work, env: env) }
        let before = TestFiles.state(of: work)
        guard !Cancellation.isCancelled else { throw CancellationError() }

        phase(.agent)
        var spec = run.spec
        spec.agent = setup.agent
        spec.setup = nil
        let agent = try await AgentRun.run(prompt: prompt, spec: spec, in: work, runFolder: run.folder, exposeRunFolder: false,
                                           extra: setup.tools, env: env, out: out)
        guard !agent.exit.cancelled else { throw CancellationError() }
        let after = TestFiles.state(of: work)

        var tests: TestCommand?
        if let testCommand {
            phase(.tests)
            tests = await runTests(testCommand, in: work, limit: testLimit, log: run.folder.appending(path: "check.log"), env: env, out: out)
            guard !Cancellation.isCancelled else { throw CancellationError() }
        }

        phase(.metrics)
        let transcript = transcript(spec, runFolder: run.folder, env: env)
        let metrics = setup.agent.harness == .claudeCode ? await LabWorker.ownMetrics(spec, project: work, env: env) : nil
        return Facts(transcript: transcript, metrics: metrics, agentError: agent.error, usage: agent.usage, tests: tests,
                     testsDropped: after.markers < before.markers,
                     changedTestFiles: before.hashes.filter { after.hashes[$0.key] != $0.value }.map(\.key).sorted())
    }

    /// The runbook's sanity check: the task's test command must pass on its reference commit
    /// (the one that later fixed it). Runs in an isolated clone that goes to the Trash.
    public static func checkReference(repo: URL, commit: String, command: String, log: URL, limit: TimeInterval = 15 * 60,
                                      env: HarnessEnvironment, trash: (URL) throws -> URL? = Trash.move,
                                      out: @escaping @Sendable (String) -> Void) async throws -> TestCommand {
        let work = FileManager.default.temporaryDirectory
            .appending(path: "akit-reference-\(UUID().uuidString.lowercased())", directoryHint: .isDirectory)
        defer { if FileManager.default.fileExists(atPath: work.path) { _ = try? trash(work) } }
        try await IsolatedClone.make(at: work, from: repo, commit: commit, env: env)
        try FileManager.default.createDirectory(at: log.deletingLastPathComponent(), withIntermediateDirectories: true)
        return await runTests(command, in: work, limit: limit, log: log, env: env, out: out)
    }

    /// Claude Code's transcript of the cell's session, or Pi's stream in `agent.jsonl`.
    static func transcript(_ spec: RunSpec, runFolder: URL, env: HarnessEnvironment) -> SessionTranscript? {
        switch AgentRun.harness(of: spec) {
        case .claudeCode:
            guard let file = LabPaths.transcript(sessionID: spec.sessionID, env: env) else { return nil }
            let info = JSONLines.fileInfo(file)
            return try? SessionReader.transcript(of: SessionSummary(harness: .claudeCode, file: file, title: spec.title, project: nil,
                                                                    started: nil, modified: info.modified, size: info.size))
        case .pi:
            guard let text = try? String(contentsOf: runFolder.appending(path: "agent.jsonl"), encoding: .utf8) else { return nil }
            return PiSessions.transcript(ofStream: text.split(whereSeparator: \.isNewline).map(String.init))
        }
    }

    /// `/bin/sh -c command` in the clone with a time limit; passed = exit 0. Output goes to
    /// `check.log`. The watchdog guards test helpers only: the command may build first, and
    /// compilers may use more than a test may.
    static func runTests(_ command: String, in folder: URL, limit: TimeInterval, log url: URL, env: HarnessEnvironment,
                         out: @escaping @Sendable (String) -> Void) async -> TestCommand {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let log = try? FileHandle(forWritingTo: url)
        defer { try? log?.close() }
        try? log?.write(contentsOf: Data("$ \(command)\n".utf8))
        out("Oracle: \(command)")
        var variables = env.variables.merging(["PATH": env.pathForChildProcesses]) { $1 }
        for key in ["CLAUDECODE", "CLAUDE_CODE_ENTRYPOINT", "CLAUDE_CODE_SSE_PORT"] { variables[key] = nil }
        let watchdog = Watchdog(folder: folder, watchesGroups: false) { out($0) }
        let exit = await watchdog.watching {
            await ChildProcess.run(URL(filePath: "/bin/sh"), arguments: ["-c", command], directory: folder, environment: variables,
                                   timeout: limit) { line in
                try? log?.write(contentsOf: Data((line + "\n").utf8))
            }
        }
        watchdog.killHelpers()
        let result: TestCommand
        if let exit {
            if exit.timedOut {
                result = TestCommand(passed: false, detail: "tests timed out after \(MetricsText.duration(Int(limit)))")
            } else {
                result = TestCommand(passed: exit.succeeded, detail: exit.succeeded ? "tests passed (exit 0)" : "tests failed (exit \(exit.status))")
            }
        } else {
            result = TestCommand(passed: false, detail: "the test command didn't start")
        }
        out("Oracle: \(result.detail) (see check.log).")
        return result
    }
}

/// The test files of a work folder, before and after the agent: whether it weakened the
/// oracle (the seed "Weakening tests or oversight"). Content hashes tell changed files;
/// the count of test markers tells tests that disappeared. The two rules are also the
/// weakening-tests code check's (AKitErrorAnalysis), so both agree on what a test is.
public struct TestFiles: Equatable {
    /// Relative path → sha256 of the content.
    var hashes: [String: String] = [:]
    var markers = 0

    static let pathPattern = #"(^|/)(Tests?|tests?|__tests__|specs?)/|_test\.\w+$|\.test\.\w+$|\.spec\.\w+$|(^|/)test_[^/]*\.py$|Tests?\.swift$"#
    /// Tests and assertions: fewer of either weakens the oracle.
    static let markerPattern = #"@Test\b|\bfunc test\w*\s*\(|\bit\(|\btest\(|\bdef test_|assert|#expect|XCTAssert|expect\("#
    /// Build output and dependencies, never the project's own tests. Hidden folders (`.git`,
    /// `.build`, `.venv`) are skipped too.
    static let skipped: Set<String> = ["node_modules", "Pods", "DerivedData", "target", "dist", "build", "__pycache__", "venv"]

    public static func isTestFile(_ path: String) -> Bool { path.range(of: pathPattern, options: .regularExpression) != nil }

    /// Tests and assertions in a test file's text.
    public static func markers(in text: String) -> Int {
        (try? NSRegularExpression(pattern: markerPattern))?.numberOfMatches(in: text, range: NSRange(text.startIndex..., in: text)) ?? 0
    }

    static func state(of folder: URL) -> TestFiles {
        var state = TestFiles()
        guard let walker = FileManager.default.enumerator(atPath: folder.path) else { return state }
        while let path = walker.nextObject() as? String {
            let type = walker.fileAttributes?[.type] as? FileAttributeType
            let name = (path as NSString).lastPathComponent
            if type == .typeDirectory {
                if name.hasPrefix(".") || skipped.contains(name) { walker.skipDescendants() }
                continue
            }
            guard type == .typeRegular, !name.hasPrefix("."), isTestFile(path),
                  let data = try? Data(contentsOf: folder.appending(path: path)) else { continue }
            state.hashes[path] = Checksum.sha256(data)
            state.markers += markers(in: String(decoding: data, as: UTF8.self))
        }
        return state
    }
}
