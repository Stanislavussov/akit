import AKitBrain
import AKitErrorAnalysis
import AKitFlows
import AKitFoundation
import AKitKnowledge
import AKitLab
import AKitMCP
import AKitReview
import Foundation

/// One reader per screen. Each reads the files that screen reads, without running anything:
/// no git, no agent, no model.
enum AttentionSources {
    // MARK: Lab

    /// Failed runs, finished session reviews, replays whose hidden tests failed. Control cells
    /// that failed are one item: an eval runs dozens. Analysis batches come from `analysis`.
    static func lab(env: HarnessEnvironment, since: Date) -> [AttentionItem] {
        var items: [AttentionItem] = []
        var failedCells: [LabRun] = []
        for run in LabStore.list(env: env) where run.spec.createdAt >= since {
            let date = run.state?.updatedAt ?? run.spec.createdAt
            func add(_ level: AttentionItem.Level, _ title: String, _ detail: String) {
                items.append(AttentionItem(id: "lab:\(run.id)", level: level, source: .lab, title: title, detail: detail, date: date,
                                           link: AttentionLink(screen: "lab", item: run.id),
                                           fingerprint: "\(run.status.rawValue)|\(Int(date.timeIntervalSince1970))"))
            }
            switch run.status {
            case .error:
                if run.spec.kind == .control {
                    failedCells.append(run)
                } else {
                    add(.problem, "Lab run failed: \(run.spec.title)", Attention.short(run.message ?? "It ended with an error."))
                }
            case .finished:
                if let error = run.result?.agentError {
                    add(.problem, "The agent ended with an error: \(run.spec.title)", Attention.short(error))
                } else if run.spec.kind == .review {
                    let findings = run.review?.findings ?? []
                    if run.result?.review == .invalid || run.result?.review == .missing {
                        add(.check, "The review wrote nothing usable: \(run.spec.title)",
                            "The agent finished without a valid review.json. Run the review again or read its summary.")
                    } else if let first = findings.first {
                        add(.ready, "Session review ready: \(run.spec.title)",
                            "\(Attention.plural(findings.count, "improvement")). First: \(Attention.short(first.title, limit: 140))")
                    }
                } else if run.spec.kind == .replay, let tests = run.result?.tests, tests.status == .failed {
                    add(.check, "Hidden tests failed: \(run.spec.title)",
                        "\(tests.failToPass.passed) of \(tests.failToPass.total) target tests passed"
                            + (tests.failed.isEmpty ? "." : "; failed: \(tests.failed.prefix(3).joined(separator: ", ")).")
                            + (tests.note.map { " \(Attention.short($0, limit: 120))" } ?? ""))
                }
            case .queued, .running, .cancelled:
                break
            }
        }
        if let latest = failedCells.first {
            let date = latest.state?.updatedAt ?? latest.spec.createdAt
            items.append(AttentionItem(id: "lab:control-errors", level: .problem, source: .lab,
                                       title: "\(Attention.plural(failedCells.count, "control cell")) failed",
                                       detail: "Latest: \(latest.spec.title). " + Attention.short(latest.message ?? "It ended with an error."),
                                       date: date, link: AttentionLink(screen: "lab", item: latest.id),
                                       fingerprint: failedCells.map(\.id).sorted().joined(separator: ",")))
        }
        return items
    }

    // MARK: Review

    /// Merge request reviews: failed ones, comments waiting for approval, sends that failed or
    /// may have gone through. Only the latest run of a merge request: a rerun replaces the one before.
    static func review(env: HarnessEnvironment, since: Date) -> [AttentionItem] {
        let paths = ReviewPaths(home: env.homeDirectory)
        var seen: Set<String> = []
        return ReviewRuns.list(home: env.homeDirectory).compactMap { id, spec, status in
            guard spec.created >= since, seen.insert(spec.mergeRequest.label).inserted, let status else { return nil }
            func item(_ level: AttentionItem.Level, _ title: String, _ detail: String, _ print: String) -> AttentionItem {
                AttentionItem(id: "review:\(id)", level: level, source: .review, title: title, detail: detail, date: status.updated,
                              link: AttentionLink(screen: "review", item: id),
                              fingerprint: "\(status.stage.rawValue)|\(print)")
            }
            switch status.stage {
            case .failed:
                return item(.problem, "Review failed: \(spec.name)", Attention.short(status.message ?? "It stopped with an error."), "")
            case .planned:
                guard let plan = ReviewJSON.read(ReviewPlanFile.self, from: paths.run(id).appending(path: "requests.json")) else { return nil }
                let failed = plan.requests.filter { $0.sent?.error != nil }.count
                let uncertain = plan.requests.filter(\.isUncertain).count
                let pending = plan.requests.filter { $0.decision == .pending && $0.sent == nil }.count
                let print = "\(failed)|\(uncertain)|\(pending)|\(Int(plan.created.timeIntervalSince1970))"
                if failed > 0 {
                    return item(.problem, "Comments not sent: \(spec.name)",
                                "\(Attention.plural(failed, "comment")) couldn't be added to \(spec.mergeRequest.label). Send them again.", print)
                }
                if uncertain > 0 {
                    return item(.check, "Comments may be posted twice: \(spec.name)",
                                "\(Attention.plural(uncertain, "send")) may have gone through. Look in the merge request before approving again.", print)
                }
                if pending > 0 {
                    return item(.ready, "Code review ready: \(spec.name)",
                                "\(Attention.plural(pending, "comment")) \(pending == 1 ? "waits" : "wait") for your approval · \(spec.mergeRequest.label)", print)
                }
                return nil
            case .gathering, .gathered, .estimating, .passes, .stopped:
                return nil
            }
        }
    }

    // MARK: Error Analysis

    /// Batches with failed sessions, paused batches, finished reports, and candidate modes that
    /// wait for a decision.
    static func analysis(env: HarnessEnvironment, since: Date) -> [AttentionItem] {
        var items: [AttentionItem] = BatchStore(env: env).all().compactMap { batch in
            guard batch.createdAt >= since else { return nil }
            let failed = batch.sessions.filter { $0.status == .error }
            let coverage = batch.coverage
            func item(_ level: AttentionItem.Level, _ title: String, _ detail: String) -> AttentionItem {
                AttentionItem(id: "analysis:batch:\(batch.runID)", level: level, source: .analysis, title: title, detail: detail,
                              date: batch.createdAt, link: AttentionLink(screen: "analysis", tab: "reports", item: batch.runID),
                              fingerprint: "\(level.rawValue)|\(coverage.done)|\(failed.count)|\(batch.paused)|\(batch.candidates.count)")
            }
            if !failed.isEmpty {
                return item(.check, "Analysis batch: \(Attention.plural(failed.count, "session")) failed",
                            "\(coverage.done) of \(coverage.total) done. " + Attention.short(failed.first?.message ?? "Resume runs them again."))
            }
            if batch.paused {
                return item(.check, "Analysis batch paused",
                            "\(coverage.done) of \(coverage.total) sessions done. " + Attention.short(batch.pauseReason ?? "Resume continues it."))
            }
            guard !batch.hasOpenSessions, !batch.unfinished else { return nil }
            return item(.ready, "Error analysis report ready",
                        "\(coverage.done) of \(coverage.total) sessions"
                            + (batch.candidates.isEmpty ? "." : "; \(Attention.plural(batch.candidates.count, "new candidate mode")) to review."))
        }
        // Candidate modes; a file that can't be read is the Error Analysis screen's to report.
        let candidates = ((try? ModeStore(env: env).storedModes()) ?? []).filter { $0.isCurrent && $0.status == .candidate }
        if !candidates.isEmpty {
            let names = candidates.prefix(3).map(\.name).joined(separator: ", ")
            items.append(AttentionItem(id: "analysis:candidates", level: .check, source: .analysis,
                                       title: "\(Attention.plural(candidates.count, "candidate failure mode")) \(candidates.count == 1 ? "waits" : "wait") for a decision",
                                       detail: Attention.short("Accept, merge or reject: \(names)\(candidates.count > 3 ? ", …" : "")."),
                                       date: candidates.map(\.createdAt).max(), link: AttentionLink(screen: "analysis", tab: "review"),
                                       fingerprint: candidates.map(\.id).sorted().joined(separator: ",")))
        }
        return items
    }

    // MARK: Evals

    /// The saved verdict of each layer eval, per agent: a sanity failure is a problem, every
    /// other verdict is ready to read.
    static func evals(env: HarnessEnvironment, layers: [String], since: Date) -> [AttentionItem] {
        layers.flatMap { layer -> [AttentionItem] in
            (LayerVerdicts.load(layer: layer, env: env)?.verdicts ?? []).compactMap { verdict in
                guard verdict.decidedAt >= since else { return nil }
                let agent = "\(verdict.harness.rawValue) · \(verdict.model) · \(verdict.effort)"
                func item(_ level: AttentionItem.Level, _ title: String, _ detail: String) -> AttentionItem {
                    AttentionItem(id: "evals:\(layer):\(agent)", level: level, source: .evals, title: title, detail: detail,
                                  date: verdict.decidedAt, link: AttentionLink(screen: "analysis", tab: "evals", item: layer),
                                  fingerprint: "\(verdict.evalID)|\(verdict.verdict.rawValue)|\(verdict.sanity.rawValue)")
                }
                if verdict.sanity == .failed {
                    return item(.problem, "Eval of \(layer) can't be trusted",
                                "\(verdict.sanityPassed) of \(verdict.sanityCells) read-only cells passed: the check can't tell work from no work (\(agent)).")
                }
                let lines = LayerVerdicts.lines(verdict)
                let success = lines.count > 1 ? lines[1] : verdict.reason
                if (verdict.setupCheckFailed ?? 0) > 0 || verdict.blocked > 0 {
                    return item(.check, "Eval of \(layer): \(verdict.verdict.title), with cells left out",
                                Attention.short(success) + " · \(agent)")
                }
                return item(.ready, "Eval of \(layer): \(verdict.verdict.title)", Attention.short(success) + " · \(agent)")
            }
        }
    }

    // MARK: Flows

    /// Flow runs that stopped or halted, finished with deviations, or whose record can't be read.
    static func flows(env: HarnessEnvironment, projects: [URL], since: Date) -> [AttentionItem] {
        FlowRunSummary.all(projects: projects, env: env).compactMap { summary in
            let run = summary.run
            let date = summary.attempts.compactMap { $0.ended ?? $0.started }.max()
                ?? (try? run.folder.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            guard let date, date >= since else { return nil }
            let name = [run.flow, run.task.map { Attention.short($0, limit: 60) }].compactMap { $0 }.joined(separator: ": ")
            let title = name.isEmpty ? run.id : name
            let failed = summary.attempts.last { $0.state == .failed || $0.state == .blocked || $0.state == .halted }
            func item(_ level: AttentionItem.Level, _ heading: String, _ detail: String) -> AttentionItem {
                AttentionItem(id: "flows:\(run.folder.path)", level: level, source: .flows, title: "\(heading): \(title)", detail: detail,
                              date: date, link: AttentionLink(screen: "runs", item: run.id, folder: run.project),
                              fingerprint: "\(summary.status.rawValue)|\(summary.attempts.count)|\(summary.deviationCount)")
            }
            let project = run.project.map { URL(filePath: $0).lastPathComponent } ?? ""
            let reason = summary.stopReason ?? failed.flatMap { attempt in attempt.reason.map { "\(attempt.step): \($0)" } }
            switch summary.status {
            case .stopped where summary.stopRequested:
                return item(.check, "Flow run stopped by you", "\(project). " + Attention.short(reason ?? "Stopped before its next step."))
            case .stopped, .halted:
                return item(.problem, "Flow run \(summary.status == .halted ? "halted" : "stopped")",
                            "\(project). " + Attention.short(reason ?? "It ended before the last step."))
            case .done where summary.deviationCount > 0:
                return item(.check, "Flow run finished with deviations",
                            "\(project). \(Attention.plural(summary.deviationCount, "deviation")) from the flow: read them before trusting the result.")
            case .unknown where !run.problems.isEmpty:
                return item(.check, "Flow run record can't be read fully", "\(project). " + Attention.short(run.problems[0]))
            default:
                return nil
            }
        }
    }

    // MARK: MCP

    /// The last check of each MCP server that didn't connect. Errors are stored masked.
    static func mcp(env: HarnessEnvironment, since: Date) -> [AttentionItem] {
        MCPCheckStore.load(home: env.homeDirectory).values.compactMap { result in
            guard result.state.isProblem, result.checkedAt >= since else { return nil }
            let level: AttentionItem.Level = switch result.state {
            case .failed, .timedOut, .notFound: .problem
            default: .check
            }
            let place = "\(result.harnessID.displayName) in \(FileWalk.tilde(URL(filePath: result.folder), home: env.homeDirectory))"
            let why = switch result.state {
            case .needsSignIn: "Sign in from MCP Servers."
            case .pendingApproval: "Approve it for the project."
            case .untrustedProject: "The harness doesn't trust this folder yet."
            case .missingVariables: "Set " + result.missingVariables.prefix(3).joined(separator: ", ") + "."
            default: result.detail.map { Attention.short($0, limit: 160) } ?? "Check it again after fixing."
            }
            return AttentionItem(id: "mcp:\(result.id)", level: level, source: .mcp,
                                 title: "MCP server \(result.name): \(result.state.title)", detail: "\(place). \(why)",
                                 date: result.checkedAt, link: AttentionLink(screen: "mcp", item: result.id),
                                 fingerprint: "\(result.state.rawValue)|\(Int(result.checkedAt.timeIntervalSince1970))")
        }
    }

    // MARK: Knowledge

    /// Proposals agents left in a knowledge base's inbox.
    static func knowledge(env: HarnessEnvironment) -> [AttentionItem] {
        KnowledgeBase.all(home: env.homeDirectory).compactMap { base in
            let ids = base.proposalIDs()
            guard !ids.isEmpty else { return nil }
            return AttentionItem(id: "knowledge:\(base.root.path)", level: .ready, source: .knowledge,
                                 title: "\(Attention.plural(ids.count, "proposal")) in the Knowledge Inbox",
                                 detail: "Base \(base.name): agents proposed notes or map changes. Accept or reject each.",
                                 date: nil, link: AttentionLink(screen: "knowledge", tab: "inbox", folder: base.root.path),
                                 fingerprint: ids.sorted().joined(separator: ","))
        }
    }

    // MARK: Brain

    /// What reading the brain found wrong: a layer that can't be read is skipped by Apply.
    static func brain(_ brain: Brain?) -> [AttentionItem] {
        (brain?.problems ?? []).map { problem in
            AttentionItem(id: "brain:\(problem.layer ?? "")|\(problem.message)", level: .problem, source: .brain,
                          title: problem.layer.map { "Layer \($0) has a problem" } ?? "The brain has a problem",
                          detail: Attention.short(problem.message), date: nil,
                          link: AttentionLink(screen: "brain", item: problem.layer), fingerprint: problem.message)
        }
    }
}
