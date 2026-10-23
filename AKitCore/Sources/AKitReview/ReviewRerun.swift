import AKitFoundation
import Foundation

/// A rerun of a merge request after the author's push (`docs/design/review.md`, R28): the roles
/// look only at the lines changed since the last reviewed head, AKit carries the earlier
/// findings on lines that didn't change, and the verifier checks the earlier findings whose
/// code changed ("fixed?"). Gather writes it into `run.json`; **Full review** turns it off.
public struct ReviewRerunInfo: Codable, Sendable, Hashable {
    /// The earlier run whose findings carry over, and the head it reviewed.
    public var previousRun: String
    public var previousHead: String
    /// Lines of the new files changed since `previousHead` (new side), by path. A file deleted
    /// or renamed away has one range over every line.
    public var changed: [String: [Range]]

    public struct Range: Codable, Sendable, Hashable {
        public var start: Int
        public var end: Int

        public init(start: Int, end: Int) {
            self.start = start
            self.end = end
        }

        public static let wholeFile = Range(start: 1, end: Int.max / 2)
    }

    public init(previousRun: String, previousHead: String, changed: [String: [Range]]) {
        self.previousRun = previousRun
        self.previousHead = previousHead
        self.changed = changed
    }

    /// Whether a line of a file changed since the last review (±2 lines: a finding names the
    /// line next to the change as often as the line itself, and the fingerprint reads ±2).
    public func touches(file: String?, line: Int?) -> Bool {
        guard let file, let ranges = changed[file] else { return false }
        guard let line else { return true }
        return ranges.contains { $0.start - 2 <= line && line <= $0.end + 2 }
    }
}

extension ReviewFinding {
    /// An earlier finding whose code changed since, which the verifier rejected as fixed on the
    /// rerun: its drafts and threads count as gone ("Looks fixed").
    public func isFixed(on rerun: ReviewRerunInfo?) -> Bool {
        guard let rerun, carriedFrom != nil, verifier?.verdict == .rejected,
              verifier?.note.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().hasPrefix("fixed") == true else { return false }
        return rerun.touches(file: file, line: line)
    }
}

public enum ReviewRerun {
    /// After this many reviewed heads of one merge request the next run asks first: talk about
    /// the approach instead of another round.
    public static let maxRounds = 3

    /// Earlier runs of the same merge request with passes done, newest first.
    static func earlier(than folder: URL, spec: ReviewRunSpec, home: URL) -> [(id: String, spec: ReviewRunSpec)] {
        guard spec.local == nil else { return [] }
        let paths = ReviewPaths(home: home)
        return ReviewRuns.list(home: home).filter { run in
            run.id != folder.lastPathComponent && run.spec.local == nil && run.spec.mergeRequest.url == spec.mergeRequest.url
                && run.spec.headSHA != nil
                && ReviewJSON.read(ReviewFindingsFile.self, from: paths.run(run.id).appending(path: "findings.json")) != nil
        }.map { ($0.id, $0.spec) }
    }

    /// The run a rerun builds on: the newest earlier run with findings, when it reviewed another
    /// head. A newest run on this same head means the user asked for this commit again (other
    /// roles, another model): a full review, nil.
    public static func previous(folder: URL, spec: ReviewRunSpec, home: URL) -> (id: String, spec: ReviewRunSpec)? {
        guard let newest = earlier(than: folder, spec: spec, home: home).first, newest.spec.headSHA != spec.headSHA else { return nil }
        return newest
    }

    /// Which round of review this run is: the distinct heads reviewed before, plus this one.
    public static func round(folder: URL, spec: ReviewRunSpec, home: URL) -> Int {
        let heads = Set(earlier(than: folder, spec: spec, home: home).compactMap(\.spec.headSHA))
        return heads.count + (heads.contains(spec.headSHA ?? "") ? 0 : 1)
    }

    /// The new-side lines changed between two commits, by path; a deleted or renamed-away file
    /// changes as a whole. nil when git can't tell (the earlier head isn't in the checkout).
    static func changedLines(from old: String, to new: String, worktree: URL, env: HarnessEnvironment) async -> (ranges: [String: [ReviewRerunInfo.Range]], patch: String)? {
        guard ReviewGather.isCommitID(old), ReviewGather.isCommitID(new), let git = env.findExecutable("git") else { return nil }
        if old == new { return ([:], "") }
        // Fixed prefixes and unquoted paths, whatever the user's git config says.
        let result = await ProcessRunner.run(git, arguments: ["-C", worktree.path, "-c", "core.quotePath=false", "diff", "--no-ext-diff",
                                                              "--no-textconv", "--no-color", "--src-prefix=a/", "--dst-prefix=b/",
                                                              "--unified=0", old, new, "--"],
                                             environment: env.gitVariables, timeout: 60)
        guard result?.succeeded == true, let output = result?.output else { return nil }
        return (parse(output), output)
    }

    static func parse(_ diff: String) -> [String: [ReviewRerunInfo.Range]] {
        var ranges: [String: [ReviewRerunInfo.Range]] = [:]
        var oldPath: String?
        var newPath: String?
        var inHeader = false
        for line in diff.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            if line.hasPrefix("diff --git ") {
                inHeader = true
                oldPath = nil
                newPath = nil
            } else if inHeader, line.hasPrefix("--- ") {
                let name = String(line.dropFirst(4))
                oldPath = name == "/dev/null" ? nil : (name.hasPrefix("a/") ? String(name.dropFirst(2)) : name)
            } else if inHeader, line.hasPrefix("+++ ") {
                let name = String(line.dropFirst(4))
                newPath = name == "/dev/null" ? nil : (name.hasPrefix("b/") ? String(name.dropFirst(2)) : name)
                // A file gone or renamed: every earlier finding in it is checked again.
                if let oldPath, oldPath != newPath { ranges[oldPath] = [.wholeFile] }
                inHeader = false
            } else if inHeader, line.hasPrefix("rename from ") {
                // A rename without a content change has no ---/+++ lines.
                ranges[String(line.dropFirst("rename from ".count))] = [.wholeFile]
            } else if !inHeader, line.hasPrefix("@@"), let path = newPath, let header = DiffPositions.header(line) {
                // A hunk that only removes still marks where the lines were.
                let end = header.newStart + max(header.newCount, 1) - 1
                ranges[path, default: []].append(.init(start: max(header.newStart, 1), end: end))
            }
        }
        return ranges
    }

    /// What a rerun does with the earlier run's findings.
    struct Split {
        /// On lines that didn't change: carried with their verdicts.
        var carried: [ReviewFinding] = []
        /// On changed lines, or in a file gone: the verifier checks them again.
        var recheck: [ReviewFinding] = []
        /// A role found the earlier problem again: the candidate's index and the earlier
        /// finding's fingerprints, folded into it.
        var refound: [(index: Int, fingerprints: [String])] = []
        /// Every fingerprint of earlier findings not carried or rechecked (questions, merged,
        /// rejected ones) on lines the push didn't touch: their threads aren't "fixed".
        var kept: Set<String> = []
        /// The earlier id of each carried, rechecked or found-again finding, by its new fingerprint.
        var earlierIDs: [String: String] = [:]
    }

    /// The earlier run's findings on this run's code. Each earlier finding goes to one list.
    static func split(_ previous: [ReviewFinding], rerun: ReviewRerunInfo, candidates: [ReviewFinding], worktree: URL?) -> Split {
        var result = Split()
        var taken = Set(candidates.flatMap(\.fingerprints))
        for old in previous {
            let history = old.fingerprints
            let verdict = old.verifier?.verdict
            let movable = old.kind == .finding && old.role != ReviewScan.role && (verdict == .confirmed || verdict == .question)
            guard movable else {
                if !rerun.touches(file: old.file, line: old.line) { result.kept.formUnion(history) }
                continue
            }
            var finding = old
            finding.carriedFrom = rerun.previousRun
            finding.related = []
            let gone = old.file.map { ReviewCandidates.fileLines($0, worktree: worktree) == nil } ?? false
            ReviewCandidates.anchor(&finding, worktree: worktree)
            let fingerprints = ReviewCandidates.fingerprints(finding, worktree: worktree)
            finding.fingerprint = fingerprints.current
            finding.previousFingerprint = fingerprints.previous
            // Every fingerprint the finding ever had stays, so drafts and threads of any earlier run match.
            var folded: [String] = []
            for print in history + (old.foldedFingerprints ?? []) where print != fingerprints.current && print != fingerprints.previous
                && !folded.contains(print) {
                folded.append(print)
            }
            finding.foldedFingerprints = folded.isEmpty ? nil : folded
            if let index = candidates.firstIndex(where: { !Set($0.fingerprints).isDisjoint(with: finding.fingerprints) }) {
                result.refound.append((index, finding.fingerprints))
                result.earlierIDs[candidates[index].fingerprint ?? ""] = old.id
                continue
            }
            guard taken.isDisjoint(with: finding.fingerprints) else { continue }
            taken.formUnion(finding.fingerprints)
            result.earlierIDs[finding.fingerprint ?? ""] = old.id
            if gone || rerun.touches(file: finding.file, line: finding.line) || finding.evidenceFound == false {
                finding.verifier = nil
                result.recheck.append(finding)
            } else {
                result.carried.append(finding)
            }
        }
        return result
    }

    /// `context/since-last-review.md`: what changed since the last reviewed head.
    static func text(_ rerun: ReviewRerunInfo, patch: String, limit: Int = 200_000) -> String {
        var text = "# Changes since the last review\n\nAn earlier review (run \(rerun.previousRun)) covered commit "
            + "\(rerun.previousHead.prefix(10)). This rerun reviews only the lines below; AKit carries the earlier findings on the other "
            + "lines.\n\n"
        if rerun.changed.isEmpty { text += "Nothing changed since: the same commit.\n" }
        for (path, ranges) in rerun.changed.sorted(by: { $0.key < $1.key }) {
            text += "- `\(path)`: " + (ranges == [.wholeFile] ? "the whole file (deleted or renamed)"
                : "lines " + ranges.map { $0.start == $0.end ? "\($0.start)" : "\($0.start)–\($0.end)" }.joined(separator: ", ")) + "\n"
        }
        if !patch.isEmpty { text += "\n```diff\n" + String(patch.prefix(limit)) + (patch.count > limit ? "\n… (cut)" : "") + "\n```\n" }
        return text
    }
}
