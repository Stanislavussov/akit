import AKitFoundation
import Foundation

/// What AKit itself checks in the diff, without a model (`docs/design/review.md`, "Checks
/// without a model"): the size of the change and the secrets its added lines carry.
/// Gather writes it to `<run>/scan.json`; only masked lines are kept, never a secret's value.
public struct ReviewScan: Codable, Sendable, Hashable {
    public struct Secret: Codable, Sendable, Hashable {
        public var file: String
        /// nil: the whole file (one that usually holds secrets, left out of the review).
        public var line: Int?
        /// The added line with the secret masked, cut around the mask.
        public var evidence: String
        /// A token, a key or a value named like a secret. false: only a password rule matched,
        /// which a test fixture's password does too.
        public var strong: Bool

        public init(file: String, line: Int?, evidence: String, strong: Bool = true) {
            self.file = file
            self.line = line
            self.evidence = evidence
            self.strong = strong
        }
    }

    /// Added and removed lines of the files the review reads (not ignored).
    public var changedLines: Int
    public var secrets: [Secret]

    public init(changedLines: Int = 0, secrets: [Secret] = []) {
        self.changedLines = changedLines
        self.secrets = secrets
    }

    static let maxSecrets = 20
    static let role = "secret-scan"

    /// Counts the changed lines and looks for secrets in every added line, ignored files too
    /// (a secret in a generated file is still in the history). `secretFiles`: files that
    /// usually hold secrets, already left out of the diff; each is one secret, by path only.
    public static func make(diffs: [GitLabFileDiff], secretFiles: [String] = [], isIgnored: (String) -> Bool) -> ReviewScan {
        var scan = ReviewScan()
        for path in secretFiles.prefix(maxSecrets) {
            scan.secrets.append(Secret(file: path, line: nil, evidence: "A file that usually holds secrets (\((path as NSString).lastPathComponent)) is in the change."))
        }
        // A diff over GitLab's limits still has text when git made it: scan and count it too.
        for diff in diffs where !diff.diff.isEmpty && !diff.deletedFile {
            var new = 0
            for raw in diff.diff.split(separator: "\n", omittingEmptySubsequences: false) {
                let line = String(raw)
                if line.hasPrefix("@@") {
                    new = DiffPositions.header(line)?.newStart ?? new
                    continue
                }
                if line.hasPrefix("+") {
                    if !isIgnored(diff.newPath) { scan.changedLines += 1 }
                    let text = String(line.dropFirst())
                    let masked = SecretFilter.masked(text)
                    if masked != text, scan.secrets.count < maxSecrets {
                        let strong = SecretFilter.maskedTokens(text) != text
                        // A password in a test fixture is no leak.
                        if strong || !isTestPath(diff.newPath) {
                            scan.secrets.append(Secret(file: diff.newPath, line: new, evidence: around(masked), strong: strong))
                        }
                    }
                    new += 1
                } else if line.hasPrefix("-") {
                    if !isIgnored(diff.newPath) { scan.changedLines += 1 }
                } else if !line.hasPrefix("\\") {
                    new += 1
                }
            }
        }
        for diff in diffs where diff.deletedFile && !isIgnored(diff.newPath) {
            scan.changedLines += diff.diff.split(separator: "\n").filter { $0.hasPrefix("-") }.count
        }
        return scan
    }

    /// At most 80 characters each side of the first mask: a minified line can be huge.
    static func around(_ masked: String) -> String {
        let text = masked.trimmingCharacters(in: .whitespaces)
        guard text.count > 200, let range = text.range(of: SecretFilter.mask) else { return String(text.prefix(200)) }
        let start = text.index(range.lowerBound, offsetBy: -80, limitedBy: text.startIndex) ?? text.startIndex
        let end = text.index(range.upperBound, offsetBy: 80, limitedBy: text.endIndex) ?? text.endIndex
        return (start > text.startIndex ? "…" : "") + text[start..<end] + (end < text.endIndex ? "…" : "")
    }

    static func isTestPath(_ path: String) -> Bool {
        let lower = path.lowercased()
        return ["test", "spec", "fixture", "mock", "sample", "example"].contains { lower.contains($0) }
    }

    /// The scan's secrets as findings, confirmed by AKit: a secret needs no model to be real. A
    /// role's finding on the same lines is merged into the scan's, so the secret keeps its own
    /// title and text whatever the role said.
    static func addSecrets(_ scan: ReviewScan, to findings: [ReviewFinding], worktree: URL?) -> [ReviewFinding] {
        var result = findings
        for secret in scan.secrets {
            let severity: ReviewSeverity = secret.strong ? .critical : .high
            var finding = ReviewFinding(
                id: "f\(result.count + 1)", role: role, file: secret.file, line: secret.line,
                title: secret.line == nil ? "A secrets file in the change" : secret.strong ? "A secret in the change" : "A password in the change",
                evidence: secret.evidence,
                why: secret.line == nil
                    ? "This file usually holds tokens, keys or passwords, so AKit didn't read it. Once pushed it stays in the history: keep it out of the repository (.gitignore), and rotate what it held."
                    : "This added line holds what looks like a \(secret.strong ? "token, key or password" : "password"). Once pushed it stays in the "
                        + "history: rotate it, and read it from the environment or a secret store instead.",
                severity: severity, confidence: secret.strong ? 1 : 0.9,
                verifier: .init(verdict: .confirmed, note: "Found by AKit's secret scan of the change."))
            let current = ReviewCandidates.fingerprints(finding, worktree: worktree)
            // Without the file's lines, two masked lines of one file look alike: the line tells them apart.
            finding.fingerprint = ReviewCandidates.fileLines(secret.file, worktree: worktree) == nil
                ? ReviewFingerprint.make(path: ReviewLinked.repoPath(secret.file, worktree: worktree), snippet: "\(secret.line ?? 0): \(secret.evidence)", title: nil) : current.current
            finding.previousFingerprint = nil
            for index in result.indices where result[index].kind == .finding && result[index].role != role
                && !Set(result[index].fingerprints).isDisjoint(with: [finding.fingerprint].compactMap { $0 }) {
                result[index].verifier = .init(verdict: .merged, note: "The secret scan reports this line.", into: finding.id)
                finding.related.append("\(result[index].role):\(result[index].title)")
                finding.foldedFingerprints = (finding.foldedFingerprints ?? []) + result[index].fingerprints
            }
            result.append(finding)
        }
        return result
    }
}
