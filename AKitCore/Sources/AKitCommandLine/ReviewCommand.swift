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
            let account = ReviewTokens.account(kind, for: name)
            if delete {
                try services.secrets.delete(account)
                out("Removed the \(kind.title) token for \(name).")
                return 0
            }
            let token = String(decoding: input(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !token.isEmpty else { throw Failure(message: "Pipe the token on stdin, for example: pbpaste | akit review token \(kind.rawValue) \(name)") }
            try services.secrets.save(token, for: account)
            out("Saved the \(kind.title) token for \(name) in the Keychain (AKit Review · \(account)).")
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
        case let text?:
            let mr = try mergeRequest(text)
            try args.finish()
            let secrets = services.secrets
            let result = try await ReviewRuns.start(mr: mr, project: project, choices: choices, env: env, brain: brain,
                                                    tokens: { try secrets.value($0) }, fetch: services.fetch, progress: { out($0) })
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
