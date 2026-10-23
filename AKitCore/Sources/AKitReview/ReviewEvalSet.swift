import AKitFoundation
import Foundation

/// Merge requests with known findings, kept to check AKit Review against (`docs/design/review.md`,
/// R32): a run pinned at its head commit, with the findings a good review must report, or marked
/// clean (a good review reports nothing). **Add to Eval Set** fills it; running the set through
/// Lab is a later step. Only on this Mac: `~/.akit/local/review/eval-set.json`.
public struct ReviewEvalCase: Codable, Sendable, Hashable, Identifiable {
    public struct Expected: Codable, Sendable, Hashable {
        public var file: String?
        public var line: Int?
        public var title: String
        public var role: String
        public var severity: ReviewSeverity
        /// Every fingerprint of the finding, so a later run's finding can be matched.
        public var fingerprints: [String]
    }

    public var id: String
    public var mergeRequest: String
    public var project: String?
    public var headSHA: String
    public var baseSHA: String?
    public var scenario: String
    /// The run it came from.
    public var run: String
    public var added: Date
    /// A good review reports nothing here.
    public var clean: Bool
    public var expected: [Expected]
    public var note: String
}

public enum ReviewEvalSet {
    public struct Failure: Error, LocalizedError {
        public let message: String
        public var errorDescription: String? { message }
    }

    static func file(home: URL) -> URL { ReviewPaths(home: home).folder.appending(path: "eval-set.json") }

    public static func load(home: URL) -> [ReviewEvalCase] {
        ReviewJSON.read([ReviewEvalCase].self, from: file(home: home)) ?? []
    }

    /// Adds a run as a case. `findings`: ids of findings it must report; nil = the run's
    /// findings the user approved. `clean`: the merge request has no problem worth a comment.
    /// One case per merge request and head: named findings join the case's earlier ones; clean
    /// and expected findings never mix in one case.
    @discardableResult
    public static func add(run folder: URL, findings ids: [String]? = nil, clean: Bool = false, note: String = "", home: URL,
                           now: Date = .now) throws -> ReviewEvalCase {
        let run = try ReviewWorkflow.load(folder)
        guard run.spec.local == nil else { throw Failure(message: "A local review has no merge request to pin: add a merge request's run.") }
        guard let head = run.spec.headSHA else { throw Failure(message: "\(run.id) isn't gathered: it has no head commit to pin.") }
        let all = run.findings?.findings ?? []
        var picked: [ReviewFinding] = []
        if !clean {
            if let ids {
                for id in ids {
                    guard let finding = all.first(where: { $0.id == id }) else { throw Failure(message: "\(run.id) has no finding \(id).") }
                    picked.append(finding)
                }
            } else {
                let approved = Set((run.plan?.requests ?? []).filter { $0.decision == .approved }.compactMap(\.findingID))
                picked = all.filter { approved.contains($0.id) }
            }
            guard !picked.isEmpty else {
                throw Failure(message: "No findings to expect: approve some on the run, name them, or add it as clean.")
            }
        }
        let expected = picked.map { finding in
            ReviewEvalCase.Expected(file: finding.file, line: finding.line, title: SecretFilter.masked(finding.title), role: finding.role,
                                    severity: finding.finalSeverity, fingerprints: finding.fingerprints)
        }
        let url = run.spec.mergeRequest.url
        let id = "\(run.spec.mergeRequest.iid)-\(head.prefix(10))-" + String(Checksum.sha256(Data(url.utf8)).prefix(8))
        return try ReviewJSON.update(file(home: home), empty: [ReviewEvalCase]()) { cases in
            var item = ReviewEvalCase(id: id, mergeRequest: url, project: run.spec.project, headSHA: head, baseSHA: run.snapshot?.refs?.baseSHA,
                                      scenario: run.spec.scenario.value, run: run.id, added: now, clean: clean, expected: expected,
                                      note: String(SecretFilter.masked(note).prefix(2000)))
            if let earlier = cases.first(where: { $0.id == id }) {
                guard earlier.clean == clean else {
                    throw Failure(message: earlier.clean ? "This commit is in the eval set as clean: remove it first to expect findings."
                                  : "This commit is in the eval set with expected findings: remove it first to add it as clean.")
                }
                // The earlier expected findings stay; one already there isn't added twice.
                item.expected = earlier.expected + expected.filter { new in
                    !earlier.expected.contains { !Set($0.fingerprints).isDisjoint(with: new.fingerprints) }
                }
                item.added = earlier.added
                if item.note.isEmpty { item.note = earlier.note }
            }
            cases = cases.filter { $0.id != id } + [item]
            cases.sort { $0.added < $1.added }
            return item
        }
    }

    public static func remove(_ id: String, home: URL) throws {
        try ReviewJSON.update(file(home: home), empty: [ReviewEvalCase]()) { cases in
            guard cases.contains(where: { $0.id == id }) else { throw Failure(message: "The eval set has no case \(id).") }
            cases.removeAll { $0.id == id }
        }
    }
}
