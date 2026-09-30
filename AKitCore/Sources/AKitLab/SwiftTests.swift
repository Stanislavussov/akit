import AKitFoundation
import Foundation

/// Hidden tests of a SwiftPM package: one build, then one `swift test` process per test
/// with a time limit, all under the memory watchdog. Output goes to `check.log`.
struct SwiftTests {
    enum Outcome: String, Codable, Sendable {
        case passed, failed, timedOut, notRun
    }

    /// The package folder (holds Package.swift) inside the work folder.
    let package: URL
    /// The folder the processes run in and the watchdog guards.
    let folder: URL
    let env: HarnessEnvironment
    let log: FileHandle?
    let out: @Sendable (String) -> Void
    var buildLimit: TimeInterval = 900
    var testLimit: TimeInterval = 30

    private var swift: URL { env.findExecutable("swift") ?? URL(filePath: "/usr/bin/swift") }
    private var variables: [String: String] {
        var variables = env.variables.merging(["PATH": env.pathForChildProcesses]) { $1 }
        for key in ["CLAUDECODE", "CLAUDE_CODE_ENTRYPOINT"] { variables[key] = nil }
        return variables
    }

    /// `swift build --build-tests`; false when it fails (the reason is in the log).
    func build() async -> Bool {
        out(package == folder ? "Building the tests…" : "Building the tests in \(package.lastPathComponent)…")
        let exit = await run(["build", "--build-tests", "--package-path", package.path], limit: buildLimit)
        guard let exit, exit.succeeded else {
            out(exit?.timedOut == true ? "The build took longer than \(MetricsText.duration(Int(buildLimit)))." : "The build failed (see check.log).")
            return false
        }
        return true
    }

    /// Each test in its own process; leftover helpers are killed after each one.
    func run(_ tests: [TestName]) async -> [TestName: Outcome] {
        var results: [TestName: Outcome] = [:]
        let helpers = Watchdog(folder: folder) { out($0) }
        for test in tests {
            guard !Cancellation.isCancelled else { break }
            let collected = Collected()
            let exit = await run(["test", "--skip-build", "--package-path", package.path, "--filter", test.filter],
                                 limit: testLimit, collect: collected)
            helpers.killHelpers()
            let outcome = Self.outcome(exit, output: collected.text)
            results[test] = outcome
            out("  \(Self.symbol(outcome)) \(test.id)")
        }
        return results
    }

    /// Runs one command with the watchdog; output into the log (and `collect`).
    private func run(_ arguments: [String], limit: TimeInterval, collect: Collected? = nil) async -> ChildProcess.Exit? {
        let log = log
        log?.write(Data("$ swift \(arguments.joined(separator: " "))\n".utf8))
        let watchdog = Watchdog(folder: folder) { out($0) }
        return await watchdog.watching {
            await ChildProcess.run(swift, arguments: arguments, directory: folder, environment: variables, timeout: limit) { line in
                log?.write(Data((line + "\n").utf8))
                collect?.append(line)
            }
        }
    }

    /// Passed only when at least one test ran and none failed.
    static func outcome(_ exit: ChildProcess.Exit?, output: String) -> Outcome {
        guard let exit else { return .failed }
        if exit.timedOut { return .timedOut }
        let ran = ranCount(output)
        if exit.succeeded { return ran > 0 ? .passed : .notRun }
        return .failed
    }

    /// Tests that ran: Swift Testing's "Test run with N tests" plus XCTest's "Executed N tests".
    static func ranCount(_ output: String) -> Int {
        var total = 0
        for match in output.matches(of: /Test run with (\d+) tests?/) { total += Int(match.1) ?? 0 }
        for match in output.matches(of: /Executed (\d+) tests?, with/) { total += Int(match.1) ?? 0 }
        return total
    }

    static func symbol(_ outcome: Outcome) -> String {
        switch outcome {
        case .passed: "✓"
        case .failed: "✗"
        case .timedOut: "⏱"
        case .notRun: "–"
        }
    }
}

/// Output of one test process, for counting what ran.
final class Collected: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    func append(_ line: String) { lock.withLock { lines.append(line) } }
    var text: String { lock.withLock { lines.joined(separator: "\n") } }
}
