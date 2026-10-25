import AKitFoundation
import Foundation

/// One question or note of the developer in a run's conversation (`<run>/conversation.jsonl`):
/// about one finding, or about the review as a whole.
public struct ReviewConversationEntry: Codable, Sendable, Hashable, Identifiable {
    public enum Kind: String, Codable, Sendable, CaseIterable, Identifiable {
        /// A question: Pi answers; it changes a finding only when asked to.
        case question
        /// The developer's own knowledge: Pi weighs it and may change the findings.
        case note

        public var id: String { rawValue }
    }

    /// `a1`, `a2`, … in the order they were asked.
    public var id: String
    /// The finding it is about (`f3`); nil: the review as a whole.
    public var finding: String?
    public var kind: Kind
    public var text: String
    public var asked: Date
    /// Pi's answer; nil while it runs or when it failed.
    public var answer: String?
    public var error: String?
    /// The Pi session of the answer: the next question forks it, so Pi remembers the thread.
    public var session: String?
    /// The findings' version this answer made, and what it changed; nil when it changed nothing.
    public var version: Int?
    public var changes: [String]?
}

/// Ask… and Add Note… on a request or on the whole result (the user's choice 2026-10-25): a
/// one-shot Pi that forks the latest session of the conversation (at first the verifier's), so
/// it has the brief, the findings, the verifier's checks and the earlier questions. A note may
/// change the findings through `akit_submit_findings`; AKit makes a new version of them with
/// Discuss in Pi…'s rules and plans the requests again. Nothing reaches GitLab here.
public enum ReviewAsk {
    public typealias Failure = ReviewDiscuss.Failure

    static let fileName = "conversation.jsonl"

    /// The run's conversation, oldest first.
    public static func entries(_ folder: URL) -> [ReviewConversationEntry] {
        guard let data = try? Data(contentsOf: folder.appending(path: fileName)) else { return [] }
        return data.split(separator: 0x0A).compactMap { try? ReviewJSON.decoder.decode(ReviewConversationEntry.self, from: Data($0)) }
    }

    static func append(_ entry: ReviewConversationEntry, to folder: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        var line = try encoder.encode(entry)
        line.append(0x0A)
        let url = folder.appending(path: fileName)
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: line)
        } else {
            try line.write(to: url)
        }
    }

    /// A discussion submission written after `since` (ms): the extension names it
    /// `discuss-<Date.now()>.json`.
    static func submitted(_ file: URL, since: UInt64) -> Bool {
        let name = file.deletingPathExtension().lastPathComponent
        guard name.hasPrefix("discuss-"), let time = UInt64(name.dropFirst("discuss-".count)) else { return false }
        return time >= since
    }

    /// The prompt of one question or note: what it is about, the developer's text, and what Pi may do.
    static func prompt(_ kind: ReviewConversationEntry.Kind, text: String, finding: ReviewFinding?) -> String {
        let about = finding.map { finding in
            "about finding \(finding.id) (“\(finding.title)”" + (finding.file.map { ", \($0)" + (finding.line.map { ":\($0)" } ?? "") } ?? "") + ")"
        } ?? "about the review as a whole"
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch kind {
        case .question:
            return """
            The developer asks in AKit, \(about):

            \(body)

            Answer in a few sentences, in the language of the question, from the code, the context pack and this review. Change \
            no finding unless the question asks you to; then call akit_submit_findings as in the discussion.
            """
        case .note:
            return """
            The developer adds what they know, \(about):

            \(body)

            Take it as the developer's knowledge: true unless the code shows otherwise (then say so). If it changes a finding, \
            call akit_submit_findings: a verdict for it (rejected when the note shows it is no problem, question when the author \
            must answer, confirmed with a better note), or reject it and submit the corrected finding as a new one. If it shows \
            a problem the review missed, submit it as a new finding. Then say in a few sentences, in the language of the note, \
            what you changed and why, or why nothing changes.
            """
        }
    }

    /// Asks Pi and records the entry: the answer, the session, and the new version of the
    /// findings when the answer changed them. Throws when Pi can't start (no session, the
    /// sending policy); a failed answer is recorded with its error.
    @discardableResult
    public static func ask(_ folder: URL, finding id: String?, kind: ReviewConversationEntry.Kind, text: String, env: HarnessEnvironment,
                           timeout: TimeInterval = 15 * 60, progress: @escaping @Sendable (String) -> Void = { _ in }) async throws
        -> ReviewConversationEntry {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { throw Failure(message: "Write the question or the note first.") }
        let run = try ReviewWorkflow.load(folder)
        let finding = try id.map { id in
            guard let found = run.findings?.findings.first(where: { $0.id == id }) else {
                throw Failure(message: "\(run.id) has no finding \(id) (akit review show \(run.id) lists them).")
            }
            return found
        }
        let earlier = entries(folder)
        // The thread goes on from the last good answer, whatever it was about: Pi remembers the
        // whole conversation. A failed or stopped answer's session may end mid-turn: never fork it.
        var fork: String?
        if let last = earlier.last(where: { $0.session != nil && $0.error == nil }), let session = last.session {
            guard let file = ReviewPasses.sessionFile(id: session, in: folder.appending(path: "sessions")) else {
                throw Failure(message: "The Pi session of \(last.id) is gone from \(run.id)'s sessions folder, so Pi can't go on with the thread.")
            }
            fork = file.path
        }
        let setup = try await ReviewDiscuss.setup(folder, env: env, fork: fork)
        let number = earlier.count + 1
        // The saved copy is masked like the answers; Pi gets the text as written.
        var entry = ReviewConversationEntry(id: "a\(number)", finding: id, kind: kind, text: SecretFilter.masked(body), asked: .now)
        let started = UInt64(Date().timeIntervalSince1970 * 1000)
        var environment = await ReviewPasses.passEnvironment(env)
        for (key, value) in setup.variables { environment[key] = value }
        let arguments = ["-p", "--mode", "json", "--offline"] + setup.arguments + ["--", prompt(kind, text: body, finding: finding)]
        let output = await ReviewPasses.runPi(setup.pi, arguments: arguments, directory: setup.cwd, environment: environment, timeout: timeout,
                                              stream: folder.appending(path: "passes/ask-\(number).jsonl"), progress: progress)
        ReviewMask.saved(in: folder)
        entry.session = output.session
        entry.answer = output.answer.map { SecretFilter.masked($0) }
        entry.error = output.error ?? (output.answer == nil ? "Pi gave no answer." : nil)
        // Only what this answer submitted (an open Discuss in Pi… keeps its own), and only its
        // tokens. The answer is kept even when making the new version fails.
        do {
            if let changes = try await ReviewDiscuss.apply(folder, env: env, only: { Self.submitted($0, since: started) }) {
                entry.version = changes.version
                entry.changes = changes.added.map { "new: \($0)" } + changes.changed
            }
            if let session = output.session { try ReviewDiscuss.logUsage(folder, run: try ReviewWorkflow.load(folder), env: env, only: session) }
        } catch {
            entry.error = [entry.error, "The answer came, but AKit couldn't apply it: \(SecretFilter.masked(error.localizedDescription))"]
                .compactMap { $0 }.joined(separator: " ")
        }
        try append(entry, to: folder)
        return entry
    }
}
