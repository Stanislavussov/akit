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
    }

    /// An estimate over the cap waits for the user's answer.
    struct CapQuestion: Identifiable {
        let id = UUID()
        let estimate: Double
        let cap: Int
    }

    private(set) var runs: [Summary] = []
    private(set) var run: ReviewWorkflow.Run?
    private(set) var activity: Activity?
    var problem: String?
    var capQuestion: CapQuestion?
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
        activity = Activity(title: "Reviewing \(mr.label)")
        let env = env
        let scope = Cancellation.Scope()
        self.scope = scope
        task = Task { [weak self] in
            await Cancellation.$scope.withValue(scope) {
            do {
                let result = try await ReviewRuns.start(mr: mr, project: project, choices: choices, env: env, brain: brain,
                                                        tokens: { try ReviewTokens.store().value($0) },
                                                        progress: { line in Task { @MainActor in self?.log(line) } })
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
    func runPasses(_ id: String) {
        guard task == nil else { return }
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
        let options = ReviewPasses.Options(confirmOverCap: { [weak self] estimate, cap in
            await self?.askOverCap(estimate: estimate, cap: cap) ?? false
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
        if let id = activity?.runID, run?.id == id { open(id) }
    }

    private func askOverCap(estimate: Double, cap: Int) async -> Bool {
        await withCheckedContinuation { continuation in
            capAnswer = continuation
            capQuestion = CapQuestion(estimate: estimate, cap: cap)
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

    /// Reads the user's drafts and the threads again and plans the requests anew.
    func refreshFromGitLab() {
        guard let run else { return }
        Task {
            await attemptAsync {
                let client = try await self.client(for: run)
                try await ReviewWorkflow.plan(run.folder, gitlab: client, env: self.env)
            }
        }
    }

    /// The run's GitLab client; the Keychain is read off the main thread (it may ask first).
    private func client(for run: ReviewWorkflow.Run) async throws -> GitLabClient {
        try await Task.detached { try ReviewWorkflow.gitlab(for: run, tokens: { try ReviewTokens.store().value($0) }) }.value
    }

    /// Sends the approved requests the sheet showed (not any approved since); the report says
    /// what GitLab answered.
    func send(_ shown: [ReviewRequest]) async -> ReviewWorkflow.SendReport? {
        guard let run else { return nil }
        do {
            let client = try await client(for: run)
            let ids = Dictionary(uniqueKeysWithValues: shown.map { ($0.id, ReviewNotes.textHash($0.text)) })
            let report = try await ReviewWorkflow.send(run.folder, gitlab: client, shown: ids)
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
        let checkout = run?.id == id ? catalogProfile(for: run?.spec)?.checkout : nil
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

    // MARK: - Tokens

    func hasToken(_ kind: ReviewTokens.Kind, for name: String) -> Bool {
        !name.isEmpty && ReviewTokens.store().contains(ReviewTokens.account(kind, for: name))
    }

    func saveToken(_ kind: ReviewTokens.Kind, for name: String, value: String) throws {
        try ReviewTokens.store().save(value.trimmingCharacters(in: .whitespacesAndNewlines), for: ReviewTokens.account(kind, for: name))
    }

    func deleteToken(_ kind: ReviewTokens.Kind, for name: String) throws {
        try ReviewTokens.store().delete(ReviewTokens.account(kind, for: name))
    }
}
