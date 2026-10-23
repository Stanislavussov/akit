import AKitBrain
import AKitFoundation
import AKitReview
import Foundation

extension AKitCLI {
    static let reviewUsage = """
    akit review: AI review of GitLab merge requests (docs/design/review.md). Pi reads the merge
    request and its work items through your MCP servers, AKit gathers the rest and gives Pi the
    roles, the rules and the limits, and nothing reaches GitLab until you approve it.

    Usage:
      akit review MR-URL [--wi N]… [--scenario S] [--project P] [--role +ID|-ID]…
                         [--passes-model M] [--verifier-model M] [--cap CREDITS] [--brain DIR]
                         [--note TEXT]… [--note-file PATH]… [--link URL]… [--extra-server NAME]…
                         [--gather-only] [--over-cap] [--anyway]
                                        Gather: Pi reads the merge request and its work items through
                                        its MCP servers; AKit adds the worktree at head_sha, the diff,
                                        history, commands and knowledge into a context pack. Then the
                                        passes run in Pi (brief, roles, verifier).
                                        --over-cap goes on when the estimate is over the credit cap
                                        or the change over max_changed_lines (default 1500;
                                        --max-changed-lines N sets it for this run). --anyway goes on
                                        when the merge request is a draft, its pipeline failed, or AKit
                                        already reviewed this commit
      akit review local [PATH] [--base REF] [--what all|commits|uncommitted] [--show]
                         [--scenario S] [--project P] [--role +ID|-ID]… [--passes-model M]
                         [--verifier-model M] [--cap CREDITS] [--note TEXT]… [--note-file PATH]…
                         [--link URL]… [--extra-server NAME]… [--gather-only] [--over-cap]
                                        Review a local git workspace (an Orca or herdr worktree; PATH
                                        defaults to the current folder): the commits since the base
                                        branch (origin/HEAD, main or master; or --base), the
                                        uncommitted changes, or both (--what, default: everything
                                        there is). Prints the range and the commits first; --show
                                        stops there. Pi reads a copy, never the workspace; nothing
                                        goes to GitLab. With --link, a fetch pass reads the links

    Context for a run (both forms):
      --note TEXT, --note-file PATH     Your notes: what the change is for, what to focus on, decisions
                                        made. Every pass reads them (context/notes.md)
      --link URL                        An https link (Figma, an Azure DevOps wiki page or work item,
                                        Confluence, …): the fetch pass reads it with a matching MCP
                                        server's reading tools (context/links.md; a gap when it can't)
      --extra-server NAME               A Pi MCP server added for this run as a read-only context
                                        server, on top of the profile's mcp: servers and extra_servers
      --step COMMAND                    A Pi step after the roles: /run AGENT [TASK] (a pi-subagents
                                        agent), /TEMPLATE [ARGS], /skill:NAME [REQUEST] or plain text.
                                        AKit runs it as its own pass with the review's reading tools
      --pi-flags="FLAGS"                Extra Pi flags of the brief, roles, steps and verifier (only
                                        --name, --exclude-tools, --no-approve, --verbose)
      akit review pi                    Your Pi subagents, prompt templates and skills a step can run,
                                        and the flags a pass may take (from pi --help)
      akit review passes RUN [--over-cap] [--anyway]
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
      akit review post RUN [--yes]
                                        Print the requests; --yes sends the approved ones as draft
                                        notes through Pi's GitLab MCP server, word for word (you
                                        publish them in GitLab with Submit review)
      akit review discuss RUN           Write the Discuss in Pi… script (pi --fork of the verifier's
                                        session) and print how to start it
      akit review apply RUN             Make a new version of the findings from what Pi submitted in
                                        the discussion; the requests are planned again
      akit review quality               Precision by role, scenario and model from your verdicts
      akit review runs                  Every run on this Mac, newest first
      akit review config show [--project P] [--mr MR-URL] [--scenario S] [--brain DIR]
                                        The resolved configuration with the source of each value
      akit review check [--project P] [--extra-server NAME]…
                                        Pi's MCP servers (pi mcp list) and what review may do with
                                        each tool: read, write drafts (Send Drafts only) or blocked;
                                        context servers only read

    Files: ~/.akit/local/review/projects/<slug>.yaml (project profiles), runs/<run-id>/.
    """

    static func review(_ arguments: [String], env: HarnessEnvironment, cwd: URL, out: (String) -> Void, err: (String) -> Void,
                       input: () -> Data) async throws -> Int32 {
        // `--pi-flags=…` carries flags, so it can't be a value Arguments reads.
        let piFlags = arguments.filter { $0.hasPrefix("--pi-flags=") }.flatMap { ReviewPiFlags.split(String($0.dropFirst("--pi-flags=".count))) }
        var args = Arguments(arguments.filter { !$0.hasPrefix("--pi-flags=") })
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
        if let lines = try positiveNumber(args.value("--max-changed-lines"), "--max-changed-lines") { settings.maxChangedLines = lines }
        let mrText = args.value("--mr")
        let gatherOnly = args.flag("--gather-only")
        let yes = args.flag("--yes")
        let reasonText = args.value("--reason")
        let comment = args.value("--comment")
        let textFile = args.value("--text")
        let fileText = args.value("--file")
        let lineText = args.value("--line")
        let overCap = args.flag("--over-cap")
        let anyway = args.flag("--anyway")
        let baseRef = args.value("--base")
        let whatText = args.value("--what")
        let showOnly = args.flag("--show")
        var choices = ReviewRunChoices(scenario: scenario, settings: settings, workItems: wis)
        // The developer's context for this run: notes, links, context servers.
        var notes = args.values("--note")
        for path in args.values("--note-file") {
            let url = resolve(path, cwd: cwd, env: env)
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { throw Failure(message: "Can't read the notes file \(path).") }
            notes.append(text)
        }
        choices.notes = notes.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }.joined(separator: "\n\n")
        do {
            choices.links = try ReviewContext.links(args.values("--link"))
        } catch {
            throw Failure(message: error.localizedDescription)
        }
        choices.pi = ReviewPiExtras(flags: piFlags, steps: args.values("--step").map { ReviewStepConfig(command: $0) })
        if let problem = ReviewPiFlags.problem(piFlags) { throw Failure(message: "--pi-flags: \(problem)") }
        choices.extraServers = args.values("--extra-server").flatMap { $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } }
            .filter { !$0.isEmpty }
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
            out(ReviewResolver.describe(try ReviewRuns.plan(mr: mr, project: project, choices: choices, env: env, brain: brain)))
            return 0
        case "check":
            try args.finish()
            let catalog = ReviewCatalog.load(home: env.homeDirectory, brain: brain)
            let profile = try project.map { name -> ReviewProfile in
                guard let profile = catalog.profiles.first(where: { $0.slug == name }) else { throw Failure(message: "There is no project profile \(name).") }
                return profile
            }
            let access = (profile?.mcp ?? ReviewMCPAccess()).adding(extraServers: choices.extraServers)
            let report = try await ReviewMCPCheck.run(env: env, access: access)
            out(mcpCheckText(report, access: access, project: profile?.slug))
            let connected = report.servers.filter { $0.enabled && $0.state == "connected" }
            return connected.contains(where: { $0.count(.read) > 0 && access.isBase(server: $0.name) }) ? 0 : 1
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
            let run = try ReviewWorkflow.load(folder)
            out(requestsText(run))
            if run.spec.local != nil {
                out("A local review stays in AKit: nothing goes to GitLab. Approve or reject requests to keep your verdicts.")
                return 0
            }
            guard yes else {
                out("Nothing was sent. Approve requests (akit review approve \(id) r1 …), then: akit review post \(id) --yes")
                return 0
            }
            let approved = run.plan?.requests.filter { $0.decision == .approved && !$0.isSent } ?? []
            guard !approved.isEmpty else {
                out("No approved request is waiting to be sent.")
                return 0
            }
            // Exactly what was printed above.
            let shown = Dictionary(uniqueKeysWithValues: approved.map { ($0.id, ReviewNotes.textHash($0.text)) })
            let lines = LineBox()
            let report = try await ReviewWorkflow.send(folder, env: env, shown: shown, options: ReviewPasses.Options(progress: { lines.add($0) }))
            lines.drain(out)
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
        case "local":
            let path = args.positional().map { resolve($0, cwd: cwd, env: env) } ?? cwd
            try args.finish()
            let mode = try whatText.map { text -> ReviewLocalTarget.Mode in
                guard let mode = ReviewLocalTarget.Mode(rawValue: text) else { throw Failure(message: "--what is all, commits or uncommitted, not \(text).") }
                return mode
            }
            let inspection = try await ReviewLocal.inspect(path: path, baseRef: baseRef, env: env)
            out(localText(inspection))
            guard let chosen = mode ?? inspection.suggestedMode else { return 0 }
            guard inspection.has(chosen) else { throw Failure(message: "Nothing to review with --what \(chosen.rawValue). " + inspection.summary) }
            out("To review: \(chosen.title.lowercased()).")
            if showOnly { return 0 }
            let catalog = ReviewCatalog.load(home: env.homeDirectory, brain: brain)
            let slug = project ?? ReviewLocal.profile(for: inspection, in: catalog, env: env)?.slug
            let target = try await ReviewLocal.target(inspection, mode: chosen, env: env)
            let lines = LineBox()
            let result: ReviewGather.Result
            do {
                result = try await ReviewRuns.startLocal(target, project: slug, choices: choices, env: env, brain: brain,
                                                         options: ReviewPasses.Options(progress: { lines.add($0) }))
            } catch {
                lines.drain(out)
                throw error
            }
            lines.drain(out)
            out(gatherSummary(result))
            if gatherOnly { return 0 }
            return try await runPasses(folder: ReviewPaths(home: env.homeDirectory).run(result.spec.id), overCap: overCap, anyway: anyway, env: env, out: out)
        case "pi":
            try args.finish()
            let library = ReviewPiLibrary.load(env: env)
            for (kind, title) in [(ReviewPiLibrary.Item.Kind.agent, "Subagents (pi-subagents)"), (.template, "Prompt templates"), (.skill, "Skills")] {
                let items = library.items.filter { $0.kind == kind }
                out("\(title):" + (items.isEmpty ? " none" : ""))
                for item in items {
                    out("  \(item.command)\(item.argumentHint.map { " " + $0 } ?? "")  [\(item.origin)]  \(item.description.prefix(100))")
                }
            }
            if let pi = env.findExecutable("pi"), let help = await ReviewPiCommands.help(pi: pi, env: env) {
                out("Flags a pass may take (--pi-flags=…):")
                for suggestion in ReviewPiFlags.suggestions(help: help) { out("  \(suggestion.flag)  \(suggestion.help)") }
            }
            for problem in library.problems { err(problem) }
            return 0
        case "passes":
            guard let id = args.positional() else { throw Failure(message: "Which run? akit review passes RUN.") }
            try args.finish()
            return try await runPasses(folder: try runFolder(id, env: env), overCap: overCap, anyway: anyway, env: env, out: out)
        case let text?:
            let mr = try mergeRequest(text)
            try args.finish()
            let lines = LineBox()
            let result: ReviewGather.Result
            do {
                result = try await ReviewRuns.start(mr: mr, project: project, choices: choices, env: env, brain: brain,
                                                    options: ReviewPasses.Options(progress: { lines.add($0) }))
            } catch {
                lines.drain(out)
                throw error
            }
            lines.drain(out)
            out(gatherSummary(result))
            if gatherOnly { return 0 }
            return try await runPasses(folder: ReviewPaths(home: env.homeDirectory).run(result.spec.id), overCap: overCap, anyway: anyway, env: env, out: out)
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

    static func runPasses(folder: URL, overCap: Bool, anyway: Bool = false, env: HarnessEnvironment, out: (String) -> Void) async throws -> Int32 {
        let lines = LineBox()
        let options = ReviewPasses.Options(confirmOverCap: overCap ? { @Sendable _, _ in true } : nil,
                                           confirmLarge: overCap ? { @Sendable _, _ in true } : nil,
                                           confirmConcerns: anyway ? { @Sendable _ in true } : nil, progress: { lines.add($0) })
        let findings: ReviewFindingsFile
        do {
            findings = try await ReviewPasses.run(folder: folder, env: env, options: options)
        } catch {
            lines.drain(out)
            let text = error.localizedDescription
            let hint = text.contains("over the cap") || text.contains("over the limit of") ? " Add --over-cap to go on."
                : text.contains("is a draft") || text.contains("Its pipeline") || text.contains("already reviewed this commit") ? " Add --anyway to go on." : ""
            throw Failure(message: text + hint)
        }
        lines.drain(out)
        let log = ReviewJSON.read(ReviewPassLog.self, from: folder.appending(path: "passes.json"))
        let confirmed = findings.findings.filter { $0.verifier?.verdict == .confirmed }.count
        out("Passes done: \(findings.findings.count) candidates, \(confirmed) confirmed by the verifier"
            + (log.map { String(format: ", ≈ %.1f credits", $0.credits) } ?? "") + ".")
        out("Next: akit review show \(folder.lastPathComponent)")
        return 0
    }

    /// The workspace before a local review: branch, base, the commits of the range, the
    /// uncommitted files.
    static func localText(_ inspection: ReviewLocal.Inspection) -> String {
        var lines = ["Workspace \(inspection.path) on \(inspection.branch) at \(inspection.head.prefix(10))",
                     "Base: " + (inspection.baseRef.map { "\($0), merge base \(inspection.mergeBase?.prefix(10) ?? "none")" }
                        ?? "none found (give one with --base)"),
                     inspection.summary]
        if !inspection.commits.isEmpty {
            lines.append("Commits (newest first):")
            lines += inspection.commits.prefix(30).map { "  \($0.sha.prefix(10)) \($0.date) \($0.author): \($0.subject)" }
            if inspection.commits.count > 30 { lines.append("  … and \(inspection.commits.count - 30) more") }
        }
        if !inspection.uncommitted.isEmpty {
            lines.append("Uncommitted:")
            lines += inspection.uncommitted.prefix(20).map { "  \($0)" }
            if inspection.uncommitted.count > 20 { lines.append("  … and \(inspection.uncommitted.count - 20) more") }
        }
        return lines.joined(separator: "\n")
    }

    static func mcpCheckText(_ report: ReviewMCPCheck.Report, access: ReviewMCPAccess, project: String?) -> String {
        var lines = ["Pi's MCP servers" + (project.map { " for project \($0)" } ?? "") + " (pi mcp list):"]
        if report.servers.isEmpty { lines.append("  none. Add your GitLab and tracker servers to Pi: pi mcp add …") }
        for server in report.servers {
            let used = access.allows(server: server.name, inPasses: access.inPasses)
            let role = access.isExtra(server: server.name) ? " · context server, read only"
                : access.isBase(server: server.name) ? ""
                : used ? " · read only, in the brief, roles and verifier (all_servers)"
                : ReviewMCPAccess.isRisky(server: server.name) && access.allServers ? " · not used: name it as a context server to use it"
                : " · not used by this project"
            lines.append("  \(server.name): \(server.enabled ? server.state : "disabled")" + role
                         + " · \(server.tools.count) tools: \(server.count(.read)) read, \(server.count(.write)) write drafts, \(server.count(.blocked)) blocked")
            if let warning = ReviewMCPAccess.warning(forServer: server.name), !access.isBase(server: server.name) {
                lines.append("    ! \(warning)")
            }
            for kind in [ReviewMCPPolicy.Kind.read, .write] {
                let names = server.tools.filter { $0.kind == kind }.map(\.name)
                if !names.isEmpty, used { lines.append("    \(kind == .read ? "read" : "write"): \(names.joined(separator: ", "))") }
            }
        }
        for server in access.extrasTakenAsBase {
            lines.append("  ! extra server \(server) is one of the run's own servers (GitLab or the tracker): it keeps that role, "
                         + "and Send Drafts may write with it.")
        }
        for error in report.errors { lines.append("  error: \(error)") }
        if !report.servers.contains(where: { $0.enabled && $0.state == "connected" && $0.count(.read) > 0 && access.isBase(server: $0.name) }) {
            lines.append("No connected GitLab or tracker server has a tool review may read with: a review can't start.")
        }
        lines.append("A tool its server marks read-only also reads in a run, whatever its name.")
        return lines.joined(separator: "\n")
    }

    static func showText(_ run: ReviewWorkflow.Run) -> String {
        var lines = ["Run \(run.id): " + (run.spec.local.map { "\($0.path) (\($0.summary))" } ?? run.spec.mergeRequest.url),
                     "Scenario \(run.spec.scenario.value); roles \(run.spec.roles.map(\.id).joined(separator: ", ")); "
                     + "status \(run.status?.stage.rawValue ?? "?")" + (run.status?.message.map { " (\($0))" } ?? "")]
        if let passes = run.passes {
            lines.append(String(format: "Passes (≈ %.1f credits of %d):", passes.credits, run.spec.capCredits.value))
            lines += passes.passes.map { "  \($0.name): " + ($0.error.map { "failed: \($0)" } ?? String(format: "%.1f credits", $0.credits)) }
        }
        lines.append(requestsText(run))
        for (place, title) in [(ReviewPlacement.Place.onlyInAKit, "Only in AKit:"), (.preExisting, "Before this MR (never posted):")] {
            let hidden = run.plan?.placements.filter { $0.place == place } ?? []
            guard !hidden.isEmpty else { continue }
            lines.append(title)
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
        if spec.notes != nil { lines.append("Your notes: context/notes.md.") }
        if let links = spec.links, !links.isEmpty {
            let unread = spec.linksUnread?.count ?? 0
            lines.append("Links: \(links.count - unread) of \(links.count) read (context/links.md).")
        }
        let extra = (spec.mcpServers ?? []).filter(\.readOnly).map { "\($0.name) [\($0.source.rawValue)]" }
        if !extra.isEmpty { lines.append("Context servers (read only): " + extra.joined(separator: ", ") + ".") }
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
