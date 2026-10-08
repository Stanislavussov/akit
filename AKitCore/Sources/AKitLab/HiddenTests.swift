import AKitFoundation
import Foundation

/// The oracle of a task made from a commit, shared by replays and control cells: after the
/// agent, the commit's own test files are copied into the work folder, the package is built
/// once, and each fail-to-pass and pass-to-pass test runs in its own process
/// (`SwiftTests`, under the memory watchdog).
enum HiddenTests {
    /// Throws when cancelled, or when a test file can't be read from the task's repository.
    static func judge(_ task: ReplayTask, in work: URL, log: FileHandle?, env: HarnessEnvironment,
                      out: @escaping @Sendable (String) -> Void) async throws -> TestOutcome {
        out("Hidden tests: \(task.failToPass.count) fail-to-pass, \(task.passToPass.count) pass-to-pass.")
        try await IsolatedClone.copyTests(task.testFiles, from: URL(filePath: task.repo), commit: task.commit, into: work, env: env)
        let package = task.package.isEmpty ? work : work.appending(path: task.package, directoryHint: .isDirectory)
        let runner = SwiftTests(package: package, folder: work, env: env, log: log, out: out)
        guard await runner.build() else {
            guard !Cancellation.isCancelled else { throw CancellationError() }
            return TestOutcome(status: .failed, failToPass: .init(passed: 0, total: task.failToPass.count),
                               passToPass: .init(passed: 0, total: task.passToPass.count),
                               failed: (task.failToPass + task.passToPass).map(\.id),
                               note: "The tests don't build after the agent's changes (see check.log).")
        }
        let results = await runner.run(task.failToPass + task.passToPass)
        guard !Cancellation.isCancelled else { throw CancellationError() }
        return outcome(task, results)
    }

    static func outcome(_ task: ReplayTask, _ results: [TestName: SwiftTests.Outcome]) -> TestOutcome {
        func count(_ tests: [TestName]) -> TestOutcome.Count {
            TestOutcome.Count(passed: tests.filter { results[$0] == .passed }.count, total: tests.count)
        }
        let all = task.failToPass + task.passToPass
        let failed = all.filter { results[$0] != .passed }
        return TestOutcome(status: failed.isEmpty ? .passed : .failed, failToPass: count(task.failToPass),
                           passToPass: count(task.passToPass), timeouts: all.filter { results[$0] == .timedOut }.count,
                           failed: failed.map(\.id))
    }
}
