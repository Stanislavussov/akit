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
        await CloneHiding.hide(paths: [file], in: folder, env: env)
    }
}

/// A brain layer as a setup's difference (`docs/design/layer-evals.md`, "Format"): the
/// layer's rendered overlay, or its required layers alone as the eval's baseline. Cells of
/// one eval pair only with each other, so the eval id is part of the cell key.
public struct LayerVariant: Codable, Sendable, Hashable {
    public enum Role: String, Codable, Sendable {
        /// The baseline of X's eval: X's required layers alone (nothing when X requires none).
        case requiredOnly
        /// The required layers and X.
        case layer
    }

    /// The brain layer being evaluated (X), also on its baseline.
    public var layer: String
    public var role: Role
    /// The stored overlay (`layer-evals/<eval>/overlays/<hash>`); nil when nothing is written.
    public var overlayHash: String?
    /// The eval run: `<layer>-<yyyyMMdd-HHmm>-<4 hex>`.
    public var evalID: String
    /// The brain commit the overlay was rendered from; shown, not part of the cell key.
    public var brainCommit: String

    public init(layer: String, role: Role, overlayHash: String?, evalID: String, brainCommit: String) {
        self.layer = layer
        self.role = role
        self.overlayHash = overlayHash
        self.evalID = evalID
        self.brainCommit = brainCommit
    }

    /// "layer swiftui@a1b2c3d", "without swiftui@a1b2c3d".
    public var title: String { "\(role == .layer ? "layer" : "without") \(layer)@\(brainCommit.prefix(7))" }
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
    /// A brain layer instead of a patch (layer evals); at most one of `patch` and `layer`.
    public var layer: LayerVariant?
    /// Shell commands the agent may not run, by prefix (`make snapshot`): Claude Code gets
    /// `Bash(make snapshot:*)` in its one `--disallowedTools` flag, next to the push rule
    /// every run has. A layer eval gives the same list to both setups, so the comparison
    /// stays fair. nil: the default for the task's repository (`defaultDenied`), filled in
    /// when the cell is queued; empty: none.
    public var denied: [String]?

    /// Commands an agent must not run in a clone of AKit's own repository: its CLAUDE.md asks
    /// for `make snapshot` after a UI change, and these build, install or start AKit (or
    /// Xcode) from the clone, against the real `~/.akit` (an index migration locks out the
    /// installed app). `open` launches any app. Every Makefile target that does so is listed
    /// (a test reads the Makefile).
    public static let akitDenied = ["make snapshot", "make run", "make restart", "make install", "make install-cli",
                                    "make screenshots", "make open", "open"]

    /// The denied commands of a cell whose setup names none: `akitDenied` in AKit's own
    /// repository (it has `AKitCore/Package.swift`), else none.
    public static func defaultDenied(repo: URL) -> [String] {
        FileManager.default.fileExists(atPath: repo.appending(path: "AKitCore/Package.swift").path) ? akitDenied : []
    }

    /// Why a denied command can't be used, or nil: it is a command prefix, not a permission
    /// rule, so it may not hold `(`, `)` or `*` (nor start with `Bash(`).
    public static func deniedProblem(_ commands: [String]) -> String? {
        guard let bad = commands.first(where: { $0.contains("(") || $0.contains(")") || $0.contains("*") }) else { return nil }
        return "“\(bad)” isn't a command prefix: give the command itself (make snapshot), without Bash(…), parentheses or *."
    }

    /// Claude Code's `--disallowedTools` values for denied commands.
    public static func disallowedTools(_ commands: [String]) -> [String] { commands.map { "Bash(\($0):*)" } }

    public init(name: String, agent: LabAgent, patch: ControlPatch? = nil, readOnly: Bool = false, layer: LayerVariant? = nil,
                denied: [String]? = nil) {
        self.name = name
        self.agent = agent
        self.patch = patch
        self.readOnly = readOnly
        self.layer = layer
        self.denied = denied
    }

    /// "variant · Claude Code · opus · high · + CLAUDE.md"; a layer setup
    /// "layer swiftui@a1b2c3d · Claude Code · opus · high", its sanity setup
    /// "read-only · without swiftui@a1b2c3d · …".
    public var label: String {
        let agentParts = [agent.harness.title, agent.model.isEmpty ? "default model" : agent.model, agent.effort]
        if let layer { return ((readOnly ? ["read-only"] : []) + [layer.title] + agentParts).joined(separator: " · ") }
        var parts = [name] + agentParts
        if let patch { parts.append("+ \(patch.file)") }
        if readOnly { parts.append("read-only") }
        return parts.joined(separator: " · ")
    }

    /// Claude Code keeps a replay's tools; Pi's coding tools are named, since a coding agent
    /// needs them. Denied commands go into the one `--disallowedTools` flag (`AgentRun`).
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
    /// finished result isn't queued again.
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
    /// A layer cell's overlay notes ("appended to the project's own CLAUDE.md"); `[]` when
    /// nothing needed one. Always present for a layer cell, nil for others: a layer cell
    /// without it was run by an akit that ignored the layer.
    public var overlay: [String]?
    /// The Claude Code version the cell ran with (`claude_code_version` of the stream's init).
    public var harnessVersion: String?

    public init(key: String, passed: Bool, oracle: String, testsDropped: Bool = false, changedTestFiles: [String] = [],
                leaks: [String] = [], checkSteps: [Int] = [], overlay: [String]? = nil, harnessVersion: String? = nil) {
        self.key = key
        self.passed = passed
        self.oracle = oracle
        self.testsDropped = testsDropped
        self.changedTestFiles = changedTestFiles
        self.leaks = leaks
        self.checkSteps = checkSteps
        self.overlay = overlay
        self.harnessVersion = harnessVersion
    }

    /// A guarded or leaked cell is shown, but its pass isn't trusted: comparisons count it as failed.
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

/// What judges a control cell after its agent: the project's test command, a commit's hidden
/// tests, or nothing here (an assertion on the transcript, which error analysis checks).
public enum CellOracle: Sendable {
    /// `/bin/sh -c` in the clone; exit 0 passes.
    case command(String)
    /// The commit's own tests, copied in after the agent, as in a replay.
    case hidden(ReplayTask)
    case none
}

/// Lab's part of a control cell: the agent works on a task in an isolated clone of the base
/// commit with one setup, then the guard and the oracle. Error analysis owns the tasks, the
/// assertion and the comparison (`AnalysisRuns`).
public enum ControlCell {
    public struct Facts: Sendable {
        /// The cell's own session, read like an indexed one; nil when the harness wrote none.
        public var transcript: SessionTranscript?
        public var metrics: SessionMetrics?
        public var agentError: String?
        public var usage: SendUsage
        /// The test command's verdict; nil without one.
        public var tests: TestCommand?
        /// The hidden tests' verdict (a commit task); nil for other oracles.
        public var hiddenTests: TestOutcome?
        /// Signs in the transcript that a commit task's agent looked for the answer: the
        /// commit's hash, AKit's Lab folder.
        public var hiddenLeaks: [String]
        public var testsDropped: Bool
        public var changedTestFiles: [String]
        /// The overlay's notes; nil when the cell had no overlay.
        public var overlayNotes: [String]?
        /// Claude Code's transcript file of the cell, when it wrote one.
        public var transcriptFile: URL?
        /// The harness version the stream reported.
        public var harnessVersion: String?

        public init(transcript: SessionTranscript?, metrics: SessionMetrics? = nil, agentError: String? = nil, usage: SendUsage = SendUsage(),
                    tests: TestCommand? = nil, hiddenTests: TestOutcome? = nil, hiddenLeaks: [String] = [], testsDropped: Bool = false,
                    changedTestFiles: [String] = [], overlayNotes: [String]? = nil, transcriptFile: URL? = nil, harnessVersion: String? = nil) {
            self.transcript = transcript
            self.metrics = metrics
            self.agentError = agentError
            self.usage = usage
            self.tests = tests
            self.hiddenTests = hiddenTests
            self.hiddenLeaks = hiddenLeaks
            self.testsDropped = testsDropped
            self.changedTestFiles = changedTestFiles
            self.overlayNotes = overlayNotes
            self.transcriptFile = transcriptFile
            self.harnessVersion = harnessVersion
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
    /// The agent gets the run folder for its stream only, never as `AKIT_LAB_DIR`. `overlay`:
    /// a layer setup's stored overlay, placed after the clone; a placement that is blocked
    /// here (the task should have been refused when it was queued) stops the cell. The agent
    /// runs under the memory watchdog: its own `swift test` in a large clone must not grow
    /// without limit. The guard leaves out the test files hidden tests copy in afterwards: the
    /// agent may add tests to them, and they are replaced anyway.
    public static func run(_ run: LabRun, setup: ControlSetup, repo: URL, base: String, prompt: String, oracle: CellOracle,
                           overlay: ControlOverlay? = nil, testLimit: TimeInterval = 15 * 60, env: HarnessEnvironment,
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
        var overlayNotes: [String]?
        if let overlay {
            switch ControlOverlay.place(overlay, in: CloneFiles.fromFolder(work)) {
            case .blocked(let reason):
                throw LabWorker.Failure(message: "The layer can't be placed in this clone: \(reason)")
            case .writes(let writes, let notes):
                try await ControlOverlay.apply(writes, in: work, env: env)
                overlayNotes = notes
                notes.forEach { out("Layer: \($0)") }
            }
        }
        var hiddenFiles: Set<String> = []
        if case .hidden(let task) = oracle { hiddenFiles = Set(task.testFiles) }
        let before = TestFiles.state(of: work, ignoring: hiddenFiles)
        guard !Cancellation.isCancelled else { throw CancellationError() }

        phase(.agent)
        var spec = run.spec
        spec.agent = setup.agent
        spec.setup = nil
        let agent: AgentRun.Outcome
        do {
            let watchdog = Watchdog(folder: work, watchesGroups: false) { out($0) }
            // Leftover test helpers of the agent's own `swift test`, also when the agent throws.
            defer { watchdog.killHelpers() }
            agent = try await watchdog.watching {
                try await AgentRun.run(prompt: prompt, spec: spec, in: work, runFolder: run.folder, exposeRunFolder: false,
                                       extra: setup.tools, denied: ControlSetup.disallowedTools(setup.denied ?? []), env: env, out: out)
            }
        }
        guard !agent.exit.cancelled else { throw CancellationError() }
        let after = TestFiles.state(of: work, ignoring: hiddenFiles)

        var tests: TestCommand?
        var hidden: TestOutcome?
        switch oracle {
        case .command(let command):
            phase(.tests)
            tests = await runTests(command, in: work, limit: testLimit, log: run.folder.appending(path: "check.log"), env: env, out: out)
            guard !Cancellation.isCancelled else { throw CancellationError() }
        case .hidden(let task):
            phase(.tests)
            let url = run.folder.appending(path: "check.log")
            FileManager.default.createFile(atPath: url.path, contents: nil)
            let log = try? FileHandle(forWritingTo: url)
            defer { try? log?.close() }
            hidden = try await HiddenTests.judge(task, in: work, log: log, env: env, out: out)
        case .none:
            break
        }

        phase(.metrics)
        let transcript = transcript(spec, runFolder: run.folder, env: env)
        let metrics = setup.agent.harness == .claudeCode ? await LabWorker.ownMetrics(spec, project: work, env: env) : nil
        let transcriptFile = setup.agent.harness == .claudeCode ? LabPaths.transcript(sessionID: spec.sessionID, env: env) : nil
        var hiddenLeaks: [String] = []
        if case .hidden(let task) = oracle, let transcriptFile { hiddenLeaks = LeakCheck.commitSigns(in: transcriptFile, task: task, env: env) }
        return Facts(transcript: transcript, metrics: metrics, agentError: agent.error, usage: agent.usage, tests: tests,
                     hiddenTests: hidden, hiddenLeaks: hiddenLeaks, testsDropped: after.markers < before.markers,
                     changedTestFiles: before.hashes.filter { after.hashes[$0.key] != $0.value }.map(\.key).sorted(),
                     overlayNotes: overlayNotes, transcriptFile: transcriptFile, harnessVersion: agent.harnessVersion)
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

    /// `ignoring`: paths relative to `folder` left out (a commit task's hidden test files).
    static func state(of folder: URL, ignoring: Set<String> = []) -> TestFiles {
        var state = TestFiles()
        guard let walker = FileManager.default.enumerator(atPath: folder.path) else { return state }
        while let path = walker.nextObject() as? String {
            let type = walker.fileAttributes?[.type] as? FileAttributeType
            let name = (path as NSString).lastPathComponent
            if type == .typeDirectory {
                if name.hasPrefix(".") || skipped.contains(name) { walker.skipDescendants() }
                continue
            }
            guard type == .typeRegular, !name.hasPrefix("."), isTestFile(path), !ignoring.contains(path),
                  let data = try? Data(contentsOf: folder.appending(path: path)) else { continue }
            state.hashes[path] = Checksum.sha256(data)
            state.markers += markers(in: String(decoding: data, as: UTF8.self))
        }
        return state
    }
}
