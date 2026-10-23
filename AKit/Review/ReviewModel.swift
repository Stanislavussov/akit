import AKitFoundation
import AKitLab
import AKitReview
import Foundation
import SwiftUI

/// Review screen state: the runs in `~/.akit/local/review/runs`, the one on screen, and a
/// review AKit is running now (Gather and the passes run in the app, one at a time).
@MainActor @Observable
final class ReviewModel {
    struct Summary: Identifiable, Hashable {
        let id: String
        let spec: ReviewRunSpec
        let status: ReviewRunStatus?
    }

    /// The review AKit is running now.
    struct Activity {
        var runID: String?
        var title: String
        var lines: [String] = []
        /// Lines dropped from the front: a line's number stays its id in the live log.
        var dropped = 0
    }

    /// Reasons not to review now (a draft, a failed pipeline, this commit already reviewed) wait
    /// for the user's answer. Limits (credits, changed lines) never ask: see `alerts`.
    struct CapQuestion: Identifiable {
        let id = UUID()
        var concerns: [String]

        var title: String { "Review it now?" }
        var message: String { concerns.joined(separator: "\n") + "\n\nReview it anyway, or stop and come back later." }
    }

    private(set) var runs: [Summary] = []
    private(set) var run: ReviewWorkflow.Run?
    private(set) var activity: Activity?
    var problem: String?
    /// The running review went over a limit (the credit cap, `max_changed_lines`); it goes on.
    var alerts: [String] = []
    /// Review Settings…: the last `pi mcp list`, or why it failed.
    private(set) var mcpReport: ReviewMCPCheck.Report?
    private(set) var mcpProblem: String?
    private(set) var checkingMCP = false
    var capQuestion: CapQuestion?
    /// What the last Add to Eval Set did, under the run's actions.
    var evalNotice: String?
    private var capAnswer: CheckedContinuation<Bool, Never>?
    private var task: Task<Void, Never>?
    /// Stop ends this review's Pi process, nothing else (Ask AKit has its own scope).
    private var scope = Cancellation.Scope()

    var env: HarnessEnvironment { HarnessEnvironment.current }
    var home: URL { env.homeDirectory }

    func reload(select id: String? = nil) {
        runs = ReviewRuns.list(home: home).map { Summary(id: $0.id, spec: $0.spec, status: $0.status) }
        let wanted = id ?? run?.id
        if let wanted, runs.contains(where: { $0.id == wanted }) { open(wanted) } else if run == nil, let first = runs.first { open(first.id) }
    }

    func open(_ id: String?) {
        if id != run?.id { evalNotice = nil }
        guard let id else {
            run = nil
            return
        }
        do {
            run = try ReviewWorkflow.load(ReviewPaths(home: home).run(id))
        } catch {
            problem = error.localizedDescription
        }
    }

    var isBusy: Bool { activity != nil }

    // MARK: - Running

    /// Gather, then the passes, in the background of the app.
    func start(mr: MergeRequestRef, project: String?, choices: ReviewRunChoices, brain: URL) {
        guard task == nil else { return }
        alerts = []
        activity = Activity(title: "Reviewing \(mr.label)")
        let env = env
        let scope = Cancellation.Scope()
        self.scope = scope
        task = Task { [weak self] in
            await Cancellation.$scope.withValue(scope) {
            do {
                let options = ReviewPasses.Options(progress: { line in Task { @MainActor in self?.log(line) } })
                let result = try await ReviewRuns.start(mr: mr, project: project, choices: choices, env: env, brain: brain, options: options)
                self?.activity?.runID = result.spec.id
                self?.reload(select: result.spec.id)
                try await self?.passes(ReviewPaths(home: env.homeDirectory).run(result.spec.id))
            } catch {
                self?.problem = error.localizedDescription
            }
            }
            self?.finish()
        }
    }

    /// A local workspace: the range is made first (a snapshot of the uncommitted changes when
    /// the mode takes them), then Gather and the passes, as for a merge request.
    func startLocal(_ inspection: ReviewLocal.Inspection, mode: ReviewLocalTarget.Mode, project: String?, choices: ReviewRunChoices, brain: URL) {
        guard task == nil else { return }
        alerts = []
        activity = Activity(title: "Reviewing \(inspection.repository) (local)")
        let env = env
        let scope = Cancellation.Scope()
        self.scope = scope
        task = Task { [weak self] in
            await Cancellation.$scope.withValue(scope) {
            do {
                let target = try await ReviewLocal.target(inspection, mode: mode, env: env)
                let options = ReviewPasses.Options(progress: { line in Task { @MainActor in self?.log(line) } })
                let result = try await ReviewRuns.startLocal(target, project: project, choices: choices, env: env, brain: brain, options: options)
                self?.activity?.runID = result.spec.id
                self?.reload(select: result.spec.id)
                try await self?.passes(ReviewPaths(home: env.homeDirectory).run(result.spec.id))
            } catch {
                self?.problem = error.localizedDescription
            }
            }
            self?.finish()
        }
    }

    /// The passes of a gathered run (again).
    /// Add to Eval Set (R32): the run pinned at its head, with findings it must report or as clean.
    func addToEvalSet(findings: [String]? = nil, clean: Bool = false) {
        guard let run else { return }
        evalNotice = nil
        do {
            let item = try ReviewEvalSet.add(run: run.folder, findings: findings, clean: clean, home: home)
            log(clean ? "Added \(item.id) to the eval set as clean." : "Added \(item.id) to the eval set with \(item.expected.count) finding(s).")
            evalNotice = clean ? "Added to the eval set as clean." : "Added to the eval set with \(item.expected.count) expected finding(s)."
        } catch {
            problem = error.localizedDescription
        }
    }

    /// Sync Outcomes (R31): one small pass reads the threads again.
    func syncOutcomes(_ id: String) {
        guard task == nil else { return }
        activity = Activity(runID: id, title: "Reading the outcomes of the comments")
        let scope = Cancellation.Scope()
        self.scope = scope
        let folder = ReviewPaths(home: home).run(id)
        let env = env
        task = Task { [weak self] in
            await Cancellation.$scope.withValue(scope) {
                do {
                    let options = ReviewPasses.Options(progress: { line in Task { @MainActor in self?.log(line) } })
                    let outcomes = try await ReviewOutcomes.sync(folder: folder, env: env, options: options)
                    self?.log("Outcomes: " + ReviewOutcome.Kind.allCases.map { kind in "\(outcomes.filter { $0.kind == kind }.count) \(kind.rawValue)" }
                        .joined(separator: ", "))
                } catch {
                    self?.problem = error.localizedDescription
                }
            }
            self?.finish()
        }
    }

    func runPasses(_ id: String) {
        guard task == nil else { return }
        alerts = []
        activity = Activity(runID: id, title: "Running the passes")
        let scope = Cancellation.Scope()
        self.scope = scope
        let folder = ReviewPaths(home: home).run(id)
        task = Task { [weak self] in
            await Cancellation.$scope.withValue(scope) {
                do {
                    try await self?.passes(folder)
                } catch {
                    self?.problem = error.localizedDescription
                }
            }
            self?.finish()
        }
    }

    private func passes(_ folder: URL) async throws {
        let options = ReviewPasses.Options(alert: { [weak self] message in
            Task { @MainActor in self?.alerts.append(message) }
        }, confirmConcerns: { [weak self] concerns in
            await self?.ask(CapQuestion(concerns: concerns)) ?? false
        }, progress: { [weak self] line in Task { @MainActor in self?.log(line) } })
        try await ReviewPasses.run(folder: folder, env: env, options: options)
    }

    func stop() {
        scope.cancel()
        task?.cancel()
    }

    private func finish() {
        task = nil
        let id = activity?.runID
        activity = nil
        reload(select: id)
    }

    private func log(_ line: String) {
        activity?.lines.append(line)
        if let count = activity?.lines.count, count > 3000 {
            activity?.lines.removeFirst(count - 3000)
            activity?.dropped += count - 3000
        }
        // A pass's own events (indented) come often: the run reloads only on the steps between them.
        if !line.hasPrefix("  "), let id = activity?.runID, run?.id == id { open(id) }
    }

    private func ask(_ question: CapQuestion) async -> Bool {
        await withCheckedContinuation { continuation in
            capAnswer = continuation
            capQuestion = question
        }
    }

    func answerCap(_ goOn: Bool) {
        capQuestion = nil
        capAnswer?.resume(returning: goOn)
        capAnswer = nil
    }

    // MARK: - Requests

    private var folder: URL? { run.map(\.folder) }

    func decide(_ request: ReviewRequest, _ decision: ReviewRequest.Decision, edited: String? = nil, reason: ReviewRequest.Reason? = nil,
                comment: String? = nil) {
        guard let folder else { return }
        attempt {
            try ReviewWorkflow.decide(folder, request: request.id, decision: decision, edited: edited, reason: reason, comment: comment)
        }
    }

    func moveInline(_ finding: ReviewFinding) {
        guard let folder else { return }
        Task {
            await attemptAsync { try await ReviewWorkflow.moveInline(folder, finding: finding.id, env: self.env) }
        }
    }

    func addMissed(file: String, line: Int?, text: String) {
        guard let folder else { return }
        attempt { try ReviewWorkflow.addMissed(folder, file: file, line: line, text: text) }
    }

    /// Sends the approved requests the sheet showed (not any approved since) through a Pi send
    /// pass and the user's GitLab MCP server; the report says what GitLab answered.
    func send(_ shown: [ReviewRequest]) async -> ReviewWorkflow.SendReport? {
        guard let run else { return nil }
        do {
            let ids = Dictionary(uniqueKeysWithValues: shown.map { ($0.id, ReviewNotes.textHash($0.text)) })
            let options = ReviewPasses.Options(progress: { [weak self] line in Task { @MainActor in self?.log(line) } })
            let report = try await ReviewWorkflow.send(run.folder, env: env, shown: ids, options: options)
            open(run.id)
            return report
        } catch {
            problem = error.localizedDescription
            return nil
        }
    }

    /// Moves a run to the Trash, after removing its worktree from the checkout.
    func delete(_ id: String) {
        let folder = ReviewPaths(home: home).run(id)
        // The worktree leaves the clone it came from: the local workspace, or the profile's checkout.
        let spec = ReviewJSON.read(ReviewRunSpec.self, from: folder.appending(path: "run.json"))
        let checkout = spec?.local?.path ?? catalogProfile(for: spec)?.checkout
        Task {
            await ReviewGather.removeWorktree(run: folder, checkout: checkout, env: env)
            attempt { _ = try Trash.move(folder) }
            if run?.id == id { run = nil }
            reload()
        }
    }

    func catalog(brain: URL) -> ReviewCatalog { ReviewCatalog.load(home: home, brain: brain) }

    private func catalogProfile(for spec: ReviewRunSpec?) -> ReviewProfile? {
        guard let slug = spec?.project else { return nil }
        return ReviewCatalog.load(home: home, brain: nil).profiles.first { $0.slug == slug }
    }

    private func attempt(_ body: () throws -> Void) {
        do {
            try body()
            if let id = run?.id { open(id) }
        } catch {
            problem = error.localizedDescription
        }
    }

    private func attemptAsync(_ body: @escaping () async throws -> Void) async {
        do {
            try await body()
            if let id = run?.id { open(id) }
        } catch {
            problem = error.localizedDescription
        }
    }

    // MARK: - Discuss in Pi…

    /// Submissions from Discuss in Pi… that aren't a version yet.
    private(set) var pendingDiscuss = 0
    /// What the last new version changed.
    var discussChanges: ReviewDiscuss.Changes?

    func discuss() {
        guard let run else { return }
        Task {
            await attemptAsync {
                let script = try await ReviewDiscuss.script(run.folder, env: self.env)
                let place = try await Launcher.openInteractive(script: script, folder: run.worktree ?? run.folder,
                                                               title: "Review: \(run.spec.mergeRequest.label)", env: self.env)
                self.problem = nil
                self.discussOpenedIn = place
            }
        }
    }

    var discussOpenedIn: String?

    func checkDiscuss() {
        guard let folder else { return }
        pendingDiscuss = ReviewDiscuss.pending(folder).count
    }

    func applyDiscuss() {
        guard let folder else { return }
        Task {
            await attemptAsync {
                self.discussChanges = try await ReviewDiscuss.apply(folder, env: self.env)
                self.checkDiscuss()
            }
        }
    }

    // MARK: - MCP

    /// Review Settings…: Pi's MCP servers (`pi mcp list`) sorted by a profile's rules.
    func checkMCP(access: ReviewMCPAccess) {
        guard !checkingMCP else { return }
        checkingMCP = true
        mcpProblem = nil
        let env = env
        Task {
            do {
                mcpReport = try await ReviewMCPCheck.run(env: env, access: access)
            } catch {
                mcpReport = nil
                mcpProblem = error.localizedDescription
            }
            checkingMCP = false
        }
    }
}
