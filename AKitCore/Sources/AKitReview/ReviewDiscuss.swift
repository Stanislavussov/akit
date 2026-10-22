import AKitFoundation
import AKitLab
import AKitSessions
import Foundation

/// Discuss in Pi… (R7): an interactive Pi that forks the verifier's session, so it has the
/// whole context while the run's own session stays as it was. What it hands back through
/// `akit_submit_findings` becomes a new version of the findings.
public enum ReviewDiscuss {
    public struct Failure: Error, LocalizedError {
        public let message: String
        public var errorDescription: String? { message }
    }

    /// What a new version changed, for the screen.
    public struct Changes: Sendable, Hashable {
        public var version: Int
        public var added: [String] = []
        /// "f2: confirmed → rejected".
        public var changed: [String] = []
        public var isEmpty: Bool { added.isEmpty && changed.isEmpty }
    }

    static let opening = """
    You are in an interactive discussion of this review with the developer. They may ask you to look again at a finding, \
    explain it, or find something that was missed. When you change the findings, call akit_submit_findings: `verdicts` to \
    change existing findings by id (confirmed, rejected, question, merged), `findings` for new ones. AKit shows the developer \
    what changed; nothing reaches GitLab without their approval.
    """

    /// Writes `<run>/discuss.command`: the environment of a pass and `pi --fork <verifier session>`.
    /// Checks the sending policy first: the discussion sends the run's context again.
    public static func script(_ folder: URL, env: HarnessEnvironment) async throws -> URL {
        let run = try ReviewWorkflow.load(folder)
        guard let log = run.passes, let session = log.verifierSessionFile ?? log.verifierSession.flatMap({
            ReviewPasses.sessionFile(id: $0, in: folder.appending(path: "sessions"))?.path
        }) ?? ReviewPasses.sessionFile(id: log.mainSession, in: folder.appending(path: "sessions"))?.path else {
            throw Failure(message: "\(run.id) has no Pi session to discuss yet; run the passes first.")
        }
        guard let pi = env.findExecutable("pi") else { throw Failure(message: "Pi (pi) is not installed.") }
        _ = try await ReviewPasses.gate(model: run.spec.verifier.value.model, env: env)
        let worktree = run.worktree
        let cwd = worktree ?? folder
        try ReviewPasses.write(ReviewPrompts.system(spec: run.spec, hasWorktree: worktree != nil) + "\n\n" + opening,
                               to: folder.appending(path: "prompts/discuss.md"))
        try ReviewPasses.write(ReviewExtension.source, to: folder.appending(path: "akit-review.ts"))
        let model = run.spec.verifier.value
        var arguments = ["--fork", session, "--session-dir", folder.appending(path: "sessions").path]
        if !model.model.isEmpty { arguments += ["--model", model.model] }
        if !model.thinking.isEmpty { arguments += ["--thinking", model.thinking] }
        arguments += ["--no-skills", "--no-context-files", "--no-prompt-templates", "--no-extensions"]
        var tools = ReviewPasses.tools
        if run.spec.access.inPasses {
            // Pi's own MCP servers, reading only, as in the passes.
            arguments += ["-e", "builtin:mcp", "-e", "builtin:codemode"]
            tools += ",codemode" + run.spec.access.toolPatterns.map { "," + $0 }.joined()
        } else {
            arguments += ["--no-mcp"]
        }
        arguments += run.spec.roles.flatMap { ["--skill", folder.appending(path: "roles/review-\($0.id)").path] }
        arguments += ["--append-system-prompt", folder.appending(path: "prompts/discuss.md").path,
                      "-e", folder.appending(path: "akit-review.ts").path, "--tools", tools]
        let variables: [(String, String)] = [
            ("AKIT_REVIEW_RUN", folder.path), ("AKIT_REVIEW_RUN_ID", run.id), ("AKIT_REVIEW_MODE", "review"), ("AKIT_REVIEW_PASS", "discuss"),
            ("AKIT_REVIEW_ROLE", "discuss"),
            ("AKIT_REVIEW_MCP", String(decoding: (try? JSONEncoder().encode(run.spec.access)) ?? Data("{}".utf8), as: UTF8.self)),
            ("AKIT_REVIEW_MAX", "50"), ("AKIT_REVIEW_ROOTS", ReviewPasses.readRoots(folder: folder, worktree: worktree)),
            ("AKIT_REVIEW_SCENARIO", run.spec.scenario.value), ("AKIT_REVIEW_HEAD", run.spec.headSHA ?? ""),
        ]
        let text = """
        #!/bin/sh
        # Discuss in Pi… for AKit review run \(run.id). Written by AKit; it writes it again each time.
        cd \(shellQuoted(cwd.path)) || exit 1
        \(variables.map { "export \($0.0)=\(shellQuoted($0.1))" }.joined(separator: "\n"))
        echo "AKit review \(run.spec.mergeRequest.label): Pi has the whole review. Ask about a finding, or ask it to look again."
        echo "Changes come back to AKit through akit_submit_findings; nothing reaches GitLab without your approval."
        exec \(shellQuoted(pi.path)) \(arguments.map(shellQuoted).joined(separator: " "))

        """
        let url = folder.appending(path: "discuss.command")
        try Data(text.utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        return url
    }

    /// Discussion submissions AKit hasn't turned into a version yet.
    public static func pending(_ folder: URL) -> [URL] {
        let applied = Set(ReviewJSON.read(ReviewFindingsFile.self, from: folder.appending(path: "findings.json"))?.appliedDiscuss ?? [])
        return FileWalk.children(of: folder.appending(path: "passes"))
            .filter { $0.lastPathComponent.hasPrefix("discuss-") && $0.pathExtension == "json" && !applied.contains($0.lastPathComponent) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// Makes a new version of the findings from the pending submissions: verdicts change
    /// findings by id, new findings are checked and fingerprinted like a role's. The old
    /// version stays as `findings-v<N>.json`; the requests are planned again.
    public static func apply(_ folder: URL, env: HarnessEnvironment) async throws -> Changes? {
        let files = pending(folder)
        guard !files.isEmpty else { return nil }
        let run = try ReviewWorkflow.load(folder)
        guard var current = run.findings else { throw Failure(message: "\(run.id) has no findings yet.") }
        try ReviewJSON.write(current, to: folder.appending(path: "findings-v\(current.version).json"))
        var changes = Changes(version: current.version + 1)
        var next = (current.findings.compactMap { Int($0.id.dropFirst()) }.max() ?? 0) + 1
        for file in files {
            guard let object = (try? Data(contentsOf: file)).flatMap({ try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }) else { continue }
            // Verdicts first: a finding the discussion rejects no longer holds its place. So a verdict
            // can only name a finding of an earlier version, not one this file adds.
            let before = current.findings
            current.findings = ReviewCandidates.apply(verdictsFile: file, to: current.findings, keepingUnmentioned: true)
            for (old, new) in zip(before, current.findings) where old.verifier != new.verifier {
                changes.changed.append("\(new.id): \(old.verifier?.verdict.rawValue ?? "unverified") → \(new.verifier?.verdict.rawValue ?? "unverified")")
            }
            for raw in object["findings"] as? [[String: Any]] ?? [] {
                // Only a role of the run: the role goes into the hidden line of a draft.
                let role = (raw["role"] as? String).flatMap { name in (run.spec.roles.map(\.id) + (run.spec.steps ?? []).map(\.id)).contains(name) ? name : nil } ?? "discuss"
                guard var finding = ReviewCandidates.finding(raw, role: role, id: "f\(next)") else { continue }
                ReviewCandidates.anchor(&finding, worktree: run.worktree)
                (finding.fingerprint, finding.previousFingerprint) = ReviewCandidates.fingerprints(finding, worktree: run.worktree)
                guard !current.findings.contains(where: { !Set($0.fingerprints).isDisjoint(with: finding.fingerprints)
                    && $0.verifier?.verdict != .rejected && $0.verifier?.verdict != .merged }) else { continue }
                // Found in the discussion, with the developer: it counts as confirmed.
                finding.verifier = ReviewFinding.Verdict(verdict: .confirmed, note: "Added in Discuss in Pi…")
                next += 1
                current.findings.append(finding)
                changes.added.append("\(finding.id): \(finding.title)")
            }
            current.appliedDiscuss = (current.appliedDiscuss ?? []) + [file.lastPathComponent]
        }
        current.version = changes.version
        current.created = .now
        current.source = "discuss"
        try ReviewJSON.write(current, to: folder.appending(path: "findings.json"))
        try logUsage(folder, run: run, env: env)
        try await ReviewWorkflow.plan(folder, env: env)
        return changes
    }

    /// The discussion's tokens go into `passes.json` and the send log once, read from the
    /// forked sessions Pi saved.
    static func logUsage(_ folder: URL, run: ReviewWorkflow.Run, env: HarnessEnvironment) throws {
        guard var log = run.passes else { return }
        let known = Set(log.passes.compactMap(\.session) + [log.mainSession])
        for file in FileWalk.children(of: folder.appending(path: "sessions")) where file.pathExtension == "jsonl" {
            guard let data = try? Data(contentsOf: file), let entries = try? JSONLines.objects(in: data),
                  let header = entries.first, header["type"] as? String == "session", let id = header["id"] as? String,
                  !known.contains(id) else { continue }
            var usage = SendUsage()
            for entry in entries {
                guard let message = entry["message"] as? [String: Any], message["role"] as? String == "assistant",
                      let recorded = message["usage"] as? [String: Any] else { continue }
                let tokens = PiLogFormat.tokens(fromPiUsage: recorded)
                usage = usage + SendUsage(input: tokens.input + tokens.cacheWrite, cached: tokens.cacheRead, output: tokens.output,
                                          cost: PiLogFormat.cost(fromPiUsage: recorded))
            }
            guard usage != SendUsage() else { continue }
            log.passes.append(ReviewPassRecord(name: "discuss", role: nil, model: run.spec.verifier.value.model, session: id, started: .now,
                                               ended: .now, usage: usage, credits: ReviewCredits.of(usage), paths: [], error: nil))
            let model = run.spec.verifier.value.model
            let entry = LabSettings.load(env: env).piAccounts.first { $0.provider.caseInsensitiveCompare(provider(model)) == .orderedSame }
            let destination = SendDestination(harness: .pi, provider: provider(model), account: entry?.account ?? "", org: entry?.org ?? "")
            _ = SendLog.appendAfterRun(SendRecord(purpose: "review-discuss", session: id, runID: run.id, destination: destination, model: model,
                                                  inputCharacters: 0, usage: usage), env: env, out: { _ in })
        }
        try ReviewJSON.write(log, to: folder.appending(path: "passes.json"))
    }

    static func provider(_ model: String) -> String {
        model.firstIndex(of: "/").map { String(model[..<$0]) } ?? ""
    }

    static func shellQuoted(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
