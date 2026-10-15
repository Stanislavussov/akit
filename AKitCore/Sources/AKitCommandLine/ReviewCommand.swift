import AKitBrain
import AKitFoundation
import AKitReview
import Foundation

/// What `akit review` reaches outside the Mac, so tests can pass fakes: the Keychain of
/// review's tokens and GitLab's and Azure DevOps's REST.
public struct ReviewServices: Sendable {
    public var secrets: any SecretStore
    public var fetch: ReviewFetch

    public init(secrets: any SecretStore = ReviewTokens.store(), fetch: @escaping ReviewFetch = ReviewHTTP.network) {
        self.secrets = secrets
        self.fetch = fetch
    }
}

extension AKitCLI {
    static let reviewUsage = """
    akit review: AI review of GitLab merge requests (docs/design/review.md). AKit gathers the
    context, Pi reads it and proposes findings, and nothing reaches GitLab until you approve it.

    Usage:
      akit review MR-URL [--wi N]… [--scenario S] [--project P] [--role +ID|-ID]…
                         [--passes-model M] [--verifier-model M] [--cap CREDITS] [--brain DIR]
                         [--gather-only] [--over-cap]
                                        Gather the merge request, its work items, the worktree at
                                        head_sha, history, commands and knowledge into a context pack,
                                        then run the passes in Pi (brief, roles, verifier).
                                        --over-cap goes on when the estimate is over the credit cap
      akit review passes RUN [--over-cap]
                                        Run the passes again on a gathered run
      akit review show RUN              The run: passes, the requests with their decisions, what stays
                                        in AKit, the context gaps
      akit review approve RUN REQ…      Approve requests (r1 r2 …); --text FILE replaces one's text
      akit review reject RUN REQ --reason TAG [--comment TEXT]
                                        Reject one; TAG: false-positive, no-context, style-nit,
                                        wrong-anchor, already-handled, wrong-requirement, out-of-scope
      akit review inline RUN FINDING    Move an "only in AKit" finding inline (missed-by-filter)
      akit review missed RUN TEXT [--file F --line N]
                                        What the reviewer missed (label missed); stays in AKit
      akit review post RUN [--refresh] [--yes]
                                        Print the requests; --yes sends the approved ones as draft
                                        notes (you publish them in GitLab with Submit review).
                                        --refresh reads your drafts and the threads again first
      akit review discuss RUN           Write the Discuss in Pi… script (pi --fork of the verifier's
                                        session) and print how to start it
      akit review apply RUN             Make a new version of the findings from what Pi submitted in
                                        the discussion; the requests are planned again
      akit review quality               Precision by role, scenario and model from your verdicts
      akit review runs                  Every run on this Mac, newest first
      akit review config show [--project P] [--mr MR-URL] [--scenario S] [--brain DIR]
                                        The resolved configuration with the source of each value
      akit review token gitlab HOST     Save a GitLab token (read from stdin) in the Keychain
      akit review token azure-devops ORG
                                        Save an Azure DevOps token (Work Items: Read) in the Keychain
      akit review token … --delete      Remove it
      akit review check HOST            GitLab's version and your user, with the saved token

    Files: ~/.akit/local/review/projects/<slug>.yaml (project profiles), runs/<run-id>/.
    """

    static func review(_ arguments: [String], env: HarnessEnvironment, cwd: URL, out: (String) -> Void, err: (String) -> Void,
                       input: () -> Data, services: ReviewServices) async throws -> Int32 {
        var args = Arguments(arguments)
        if args.flag("--help") || args.flag("-h") || args.isEmpty {
            out(reviewUsage)
            return 0
        }
        let brain = args.value("--brain").map { resolve($0, cwd: cwd, env: env) } ?? Brain.defaultRoot(home: env.homeDirectory)
        let project = args.value("--project")
        let scenario = args.value("--scenario")
        let wis = try args.values("--wi").map { text -> Int in
            guard let id = Int(text.trimmingCharacters(in: CharacterSet(charactersIn: "#"))), id > 0 else {
                throw Failure(message: "--wi needs a work item number, not \(text).")
            }
            return id
        }
        let roleChanges = args.values("--role")
        var settings = ReviewSettingsPatch()
        if let model = args.value("--passes-model") { settings.passes = ReviewModelChoice(model: model) }
        if let model = args.value("--verifier-model") { settings.verifier = ReviewModelChoice(model: model) }
        if let cap = try positiveNumber(args.value("--cap"), "--cap") { settings.capCredits = cap }
        let mrText = args.value("--mr")
        let gatherOnly = args.flag("--gather-only")
        let yes = args.flag("--yes")
        let refresh = args.flag("--refresh")
        let reasonText = args.value("--reason")
        let comment = args.value("--comment")
        let textFile = args.value("--text")
        let fileText = args.value("--file")
        let lineText = args.value("--line")
        let overCap = args.flag("--over-cap")
        var choices = ReviewRunChoices(scenario: scenario, settings: settings, workItems: wis)
        for change in roleChanges {
            guard let sign = change.first, sign == "+" || sign == "-", change.count > 1 else {
                throw Failure(message: "--role takes +ID (turn a role on) or -ID (turn it off), not \(change).")
            }
            if sign == "+" { choices.rolesOn.append(String(change.dropFirst())) } else { choices.rolesOff.append(String(change.dropFirst())) }
        }
        let command = args.positional()
        switch command {
        case "runs":
            try args.finish()
            let runs = ReviewRuns.list(home: env.homeDirectory)
            if runs.isEmpty { out("No review runs yet.") }
            for run in runs {
                out("\(run.id)  \(run.spec.mergeRequest.label)  \(run.spec.scenario.value)  \(run.status?.stage.rawValue ?? "?")")
            }
            return 0
        case "config":
            guard args.positional() == "show" else { throw Failure(message: "akit review config show [--project P] [--mr MR-URL].") }
            try args.finish()
            let mr = try mrText.map(mergeRequest)
            let catalog = ReviewCatalog.load(home: env.homeDirectory, brain: brain)
            for problem in catalog.problems { err("akit: \(problem)") }
            out(ReviewResolver.describe(try ReviewRuns.plan(mr: mr, project: project, choices: choices, home: env.homeDirectory, brain: brain)))
            return 0
        case "token":
            guard let kindText = args.positional(), let kind = ReviewTokens.Kind(rawValue: kindText) else {
                throw Failure(message: "akit review token gitlab HOST, or akit review token azure-devops ORG.")
            }
            guard let name = args.positional() else {
                throw Failure(message: kind == .gitlab ? "Which GitLab? akit review token gitlab https://gitlab.example.com"
                                  : "Which organization? akit review token azure-devops ORG")
            }
            let delete = args.flag("--delete")
            try args.finish()
            guard let origin = ReviewTokens.origin(kind, name) else {
                throw Failure(message: "\(name) is not an https address: AKit sends tokens only over https.")
            }
            let account = ReviewTokens.account(kind, for: name)
            if delete {
                try services.secrets.delete(account)
                out("Removed the \(kind.title) token for \(origin).")
                return 0
            }
            let token = String(decoding: input(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !token.isEmpty else { throw Failure(message: "Pipe the token on stdin, for example: pbpaste | akit review token \(kind.rawValue) \(name)") }
            try services.secrets.save(token, for: account)
            out("Saved the \(kind.title) token for \(origin) in the Keychain (AKit Review).")
            return 0
        case "check":
            guard let host = args.positional() else { throw Failure(message: "akit review check HOST.") }
            try args.finish()
            guard let token = try services.secrets.value(ReviewTokens.account(.gitlab, for: host)) else {
                throw Failure(message: "There is no GitLab token for \(host): akit review token gitlab \(host)")
            }
            let client = GitLabClient(host: host, token: token, fetch: services.fetch)
            out("GitLab \(try await client.version()) at \(client.host), signed in as \(try await client.currentUser()).")
            return 0
        case "show":
            guard let id = args.positional() else { throw Failure(message: "Which run? akit review show RUN.") }
            try args.finish()
            out(showText(try ReviewWorkflow.load(try runFolder(id, env: env))))
            return 0
        case "approve":
            guard let id = args.positional() else { throw Failure(message: "akit review approve RUN REQ….") }
            let folder = try runFolder(id, env: env)
            var requests: [String] = []
            while let request = args.positional() { requests.append(request) }
            try args.finish()
            guard !requests.isEmpty else { throw Failure(message: "Which requests? akit review approve RUN r1 r2.") }
            if textFile != nil, requests.count != 1 { throw Failure(message: "--text replaces the text of one request.") }
            let edited = try textFile.map { try String(contentsOf: resolve($0, cwd: cwd, env: env), encoding: .utf8) }
            for request in requests { try ReviewWorkflow.decide(folder, request: request, decision: .approved, edited: edited) }
            out("Approved \(requests.joined(separator: ", ")). Send them with: akit review post \(id) --yes")
            return 0
        case "reject":
            guard let id = args.positional(), let request = args.positional() else {
                throw Failure(message: "akit review reject RUN REQ --reason TAG.")
            }
            try args.finish()
            let reason = try reasonText.map { text -> ReviewRequest.Reason in
                guard let reason = ReviewRequest.Reason(rawValue: text) else {
                    throw Failure(message: "--reason is one of \(ReviewRequest.Reason.allCases.map(\.rawValue).joined(separator: ", ")).")
                }
                return reason
            }
            try ReviewWorkflow.decide(try runFolder(id, env: env), request: request, decision: .rejected, reason: reason, comment: comment)
            out("Rejected \(request).")
            return 0
        case "inline":
            guard let id = args.positional(), let finding = args.positional() else { throw Failure(message: "akit review inline RUN FINDING.") }
            try args.finish()
            try await ReviewWorkflow.moveInline(try runFolder(id, env: env), finding: finding, env: env)
            out("\(finding) goes inline now; its request waits for your approval (akit review show \(id)).")
            return 0
        case "missed":
            guard let id = args.positional(), let text = args.positional() else { throw Failure(message: "akit review missed RUN TEXT.") }
            try args.finish()
            let line = try positiveNumber(lineText, "--line")
            try ReviewWorkflow.addMissed(try runFolder(id, env: env), file: fileText, line: line, text: text)
            out("Recorded what was missed.")
            return 0
        case "post":
            guard let id = args.positional() else { throw Failure(message: "Which run? akit review post RUN.") }
            try args.finish()
            let folder = try runFolder(id, env: env)
            let secrets = services.secrets
            if refresh {
                let client = try ReviewWorkflow.gitlab(for: try ReviewWorkflow.load(folder), tokens: { try secrets.value($0) }, fetch: services.fetch)
                try await ReviewWorkflow.plan(folder, gitlab: client, env: env)
            }
            let run = try ReviewWorkflow.load(folder)
            out(requestsText(run))
            guard yes else {
                out("Nothing was sent. Approve requests (akit review approve \(id) r1 …), then: akit review post \(id) --yes")
                return 0
            }
            let approved = run.plan?.requests.filter { $0.decision == .approved && !$0.isSent } ?? []
            guard !approved.isEmpty else {
                out("No approved request is waiting to be sent.")
                return 0
            }
            let client = try ReviewWorkflow.gitlab(for: run, tokens: { try secrets.value($0) }, fetch: services.fetch)
            // Exactly what was printed above.
            let shown = Dictionary(uniqueKeysWithValues: approved.map { ($0.id, ReviewNotes.textHash($0.text)) })
            let report = try await ReviewWorkflow.send(folder, gitlab: client, shown: shown)
            out("Sent as drafts: \(report.sent.isEmpty ? "none" : report.sent.joined(separator: ", ")).")
            for failure in report.failed { err("akit: \(failure.id): \(failure.message)") }
            out("Publish them in GitLab with Submit review: \(run.spec.mergeRequest.url)")
            return report.failed.isEmpty ? 0 : 1
        case "discuss":
            guard let id = args.positional() else { throw Failure(message: "akit review discuss RUN.") }
            try args.finish()
            let script = try await ReviewDiscuss.script(try runFolder(id, env: env), env: env)
            out("Start the discussion in a terminal: \(script.path)")
            out("Then: akit review apply \(id)")
            return 0
        case "apply":
            guard let id = args.positional() else { throw Failure(message: "akit review apply RUN.") }
            try args.finish()
            guard let changes = try await ReviewDiscuss.apply(try runFolder(id, env: env), env: env) else {
                out("Pi submitted nothing new in the discussion.")
                return 0
            }
            out("Version \(changes.version) of the findings.")
            for line in changes.added { out("  new: \(line)") }
            for line in changes.changed { out("  changed: \(line)") }
            out("The requests were planned again: akit review show \(id)")
            return 0
        case "quality":
            try args.finish()
            out(qualityText(ReviewQuality.entries(home: env.homeDirectory)))
            return 0
        case let text?:
            let mr = try mergeRequest(text)
            try args.finish()
            let secrets = services.secrets
            let lines = LineBox()
            let result: ReviewGather.Result
            do {
                result = try await ReviewRuns.start(mr: mr, project: project, choices: choices, env: env, brain: brain,
                                                    tokens: { try secrets.value($0) }, fetch: services.fetch, progress: { lines.add($0) })
            } catch {
                lines.drain(out)
                throw error
            }
            lines.drain(out)
            out(gatherSummary(result))
            if gatherOnly { return 0 }
            return try await runPasses(folder: ReviewPaths(home: env.homeDirectory).run(result.spec.id), overCap: overCap, env: env, out: out)
        case "passes":
            guard let id = args.positional() else { throw Failure(message: "Which run? akit review passes RUN.") }
            try args.finish()
            return try await runPasses(folder: try runFolder(id, env: env), overCap: overCap, env: env, out: out)
        case nil:
            throw Failure(message: "Which merge request? akit review MR-URL.")
        }
    }

    static func runFolder(_ id: String, env: HarnessEnvironment) throws -> URL {
        guard !id.contains("/"), !id.hasPrefix(".") else { throw Failure(message: "\(id) is not a run id (akit review runs lists them).") }
        let folder = ReviewPaths(home: env.homeDirectory).run(id)
        guard FileManager.default.fileExists(atPath: folder.appending(path: "run.json").path) else {
            throw Failure(message: "There is no review run \(id) (akit review runs lists them).")
        }
        return folder
    }

    static func runPasses(folder: URL, overCap: Bool, env: HarnessEnvironment, out: (String) -> Void) async throws -> Int32 {
        let lines = LineBox()
        let options = ReviewPasses.Options(confirmOverCap: overCap ? { @Sendable _, _ in true } : nil, progress: { lines.add($0) })
        let findings: ReviewFindingsFile
        do {
            findings = try await ReviewPasses.run(folder: folder, env: env, options: options)
        } catch {
            lines.drain(out)
            throw Failure(message: error.localizedDescription + (error.localizedDescription.contains("over the cap") ? " Add --over-cap to go on." : ""))
        }
        lines.drain(out)
        let log = ReviewJSON.read(ReviewPassLog.self, from: folder.appending(path: "passes.json"))
        let confirmed = findings.findings.filter { $0.verifier?.verdict == .confirmed }.count
        out("Passes done: \(findings.findings.count) candidates, \(confirmed) confirmed by the verifier"
            + (log.map { String(format: ", ≈ %.1f credits", $0.credits) } ?? "") + ".")
        out("Next: akit review show \(folder.lastPathComponent)")
        return 0
    }

    static func showText(_ run: ReviewWorkflow.Run) -> String {
        var lines = ["Run \(run.id): \(run.spec.mergeRequest.url)",
                     "Scenario \(run.spec.scenario.value); roles \(run.spec.roles.map(\.id).joined(separator: ", ")); "
                     + "status \(run.status?.stage.rawValue ?? "?")" + (run.status?.message.map { " (\($0))" } ?? "")]
        if let passes = run.passes {
            lines.append(String(format: "Passes (≈ %.1f credits of %d):", passes.credits, run.spec.capCredits.value))
            lines += passes.passes.map { "  \($0.name): " + ($0.error.map { "failed: \($0)" } ?? String(format: "%.1f credits", $0.credits)) }
        }
        lines.append(requestsText(run))
        let hidden = run.plan?.placements.filter { $0.place == .onlyInAKit } ?? []
        if !hidden.isEmpty {
            lines.append("Only in AKit:")
            lines += hidden.map { placement in
                let finding = run.finding(placement.findingID)
                return "  \(placement.findingID) \(finding.map { "\($0.title) (\($0.role), \($0.finalSeverity.rawValue))" } ?? ""): \(placement.reason)"
            }
        }
        if !run.gaps.isEmpty {
            lines.append("Context gaps:")
            lines += run.gaps.map { "  \($0.id) \($0.needed): \($0.why)" }
        }
        return lines.joined(separator: "\n")
    }

    static func requestsText(_ run: ReviewWorkflow.Run) -> String {
        guard let plan = run.plan else { return "No requests yet." }
        guard !plan.requests.isEmpty else { return "No requests: GitLab already has everything AKit would write." }
        var lines = ["Requests:"]
        for request in plan.requests {
            let place = request.file.map { " \($0)" + (request.line.map { ":\($0)" } ?? "") } ?? ""
            let state = request.isSent ? "sent" : request.sent?.error.map { "failed: \($0)" } ?? request.decision.rawValue
            let edited = request.edited == nil ? "" : " (edited)"
            lines.append("  \(request.id) \(request.kind.rawValue)\(place) [\(state)]\(edited)"
                         + (request.role.map { " · \($0)" } ?? "") + (request.severity.map { " · \($0.rawValue)" } ?? ""))
            lines += request.text.split(separator: "\n", omittingEmptySubsequences: false).prefix(6).map { "      " + $0 }
        }
        return lines.joined(separator: "\n")
    }

    static func qualityText(_ entries: [ReviewQuality.Entry]) -> String {
        guard !entries.isEmpty else { return "No verdicts yet: approve or reject findings on a run first." }
        let precision = ReviewQuality.precision(entries)
        func table(_ title: String, _ rows: [ReviewQuality.Precision]) -> [String] {
            [title] + rows.map { row in
                "  \(row.key): " + (row.value.map { String(format: "%.0f%%", $0 * 100) } ?? "–") + " (\(row.approved) approved, \(row.rejected) rejected)"
            }
        }
        var lines = table("Precision by role:", precision.roles) + table("By scenario:", precision.scenarios) + table("By model:", precision.models)
        let reasons = Dictionary(grouping: entries.compactMap(\.reason), by: { $0 }).mapValues(\.count)
        if !reasons.isEmpty {
            lines.append("Rejected because: " + reasons.sorted { $0.value > $1.value }.map { "\($0.key.rawValue) ×\($0.value)" }.joined(separator: ", "))
        }
        let missed = entries.filter { $0.label == .missed }.count
        if missed > 0 { lines.append("Missed (added by you): \(missed)") }
        return lines.joined(separator: "\n")
    }

    static func mergeRequest(_ text: String) throws -> MergeRequestRef {
        guard let mr = MergeRequestRef.parse(text) else {
            throw Failure(message: "\(text) is not a merge request address (https://HOST/GROUP/PROJECT/-/merge_requests/N).")
        }
        return mr
    }

    static func gatherSummary(_ result: ReviewGather.Result) -> String {
        let spec = result.spec
        var lines = ["Run \(spec.id): \(spec.mergeRequest.label) at \(spec.headSHA?.prefix(10) ?? "?"), scenario \(spec.scenario.value), "
                     + "roles \(spec.roles.map(\.id).joined(separator: ", ")).",
                     "Context pack: \(result.snapshot.diffs.count) changed files, \(result.workItems.count) work items, "
                     + "\(result.contextCharacters / 1000)k characters."]
        if !result.scrubbed.isEmpty {
            lines.append("Masked before the agent sees it: " + result.scrubbed.sorted { $0.key < $1.key }.map { "\($0.key) ×\($0.value)" }.joined(separator: ", "))
        }
        if !result.gaps.isEmpty {
            lines.append("Context gaps:")
            lines += result.gaps.map { "  - \($0.needed): \($0.why)" }
        }
        return lines.joined(separator: "\n")
    }
}

/// Progress lines from a pass, which may come from another thread, printed in order.
final class LineBox: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    func add(_ line: String) { lock.withLock { lines.append(line) } }
    func drain(_ out: (String) -> Void) {
        for line in lock.withLock({ defer { lines = [] }; return lines }) { out(line) }
    }
}
