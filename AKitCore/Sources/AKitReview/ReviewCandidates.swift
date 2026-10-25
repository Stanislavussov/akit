import AKitFoundation
import Foundation

/// Role findings become candidates: AKit checks each field again (the extension's check is
/// the model's side; this one is the trusted one), puts the anchor on the line the evidence
/// is really on, adds the fingerprint and folds duplicates.
public enum ReviewCandidates {
    /// Every role pass's findings, in role order, then the Pi steps', numbered `f1`, `f2`, ….
    static func collect(folder: URL, spec: ReviewRunSpec, worktree: URL?) -> [ReviewFinding] {
        var result: [ReviewFinding] = []
        let passes = spec.roles.map { ($0, "role-\($0.id)") } + (spec.steps ?? []).map { ($0.role, "step-\($0.id)") }
        for (role, pass) in passes {
            let file = folder.appending(path: "passes/\(pass).json")
            guard let object = (try? Data(contentsOf: file)).flatMap({ try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }) else { continue }
            var counted = 0
            for raw in object["findings"] as? [[String: Any]] ?? [] {
                // Matrix rows (one per acceptance criterion) don't count against the role's limit.
                if raw["kind"] as? String != "ac" {
                    guard counted < role.maxFindings else { continue }
                    counted += 1
                }
                guard var finding = finding(raw, role: role.id, id: "f\(result.count + 1)") else { continue }
                // Below the role's own floor: the role said it shouldn't comment on it.
                if finding.kind == .finding, finding.severity < role.minSeverity { continue }
                anchor(&finding, worktree: worktree)
                (finding.fingerprint, finding.previousFingerprint) = fingerprints(finding, worktree: worktree)
                if let same = result.firstIndex(where: { $0.fingerprint == finding.fingerprint && $0.kind == finding.kind }) {
                    let note = "\(finding.role):\(finding.title)"
                    if !result[same].related.contains(note) { result[same].related.append(note) }
                    let folded = finding.fingerprints.filter { !result[same].fingerprints.contains($0) }
                    if !folded.isEmpty { result[same].foldedFingerprints = (result[same].foldedFingerprints ?? []) + folded }
                    continue
                }
                result.append(finding)
            }
        }
        return result
    }

    /// A finding from the tool's JSON, nil when a required field is wrong. Model text is
    /// masked before AKit keeps it.
    static func finding(_ raw: [String: Any], role: String, id: String) -> ReviewFinding? {
        guard let title = raw["title"] as? String, !title.trimmingCharacters(in: .whitespaces).isEmpty,
              let severityText = raw["severity"] as? String, let severity = ReviewSeverity(rawValue: severityText),
              let confidence = (raw["confidence"] as? NSNumber)?.doubleValue, (0...1).contains(confidence) else { return nil }
        let kind = (raw["kind"] as? String).flatMap(ReviewFinding.Kind.init) ?? .finding
        let file = (raw["file"] as? String).map { $0.hasPrefix("./") ? String($0.dropFirst(2)) : $0 }.flatMap { $0.isEmpty ? nil : $0 }
        let line = (raw["line"] as? NSNumber).flatMap { $0.intValue >= 1 ? $0.intValue : nil }
        func text(_ key: String) -> String { ReviewNotes.defused(SecretFilter.masked(raw[key] as? String ?? "")) }
        var finding = ReviewFinding(id: id, kind: kind, role: role, file: file, side: (raw["side"] as? String) == "old" ? .old : .new,
                             line: file == nil ? nil : line, title: ReviewNotes.defused(SecretFilter.masked(title)), evidence: text("evidence"), why: text("why"),
                             severity: severity, confidence: confidence,
                             suggestion: (raw["suggestion"] as? String).map { ReviewNotes.defused(SecretFilter.masked($0)) }.flatMap { $0.isEmpty ? nil : $0 },
                             related: (raw["related"] as? [String]) ?? [])
        if raw["preExisting"] as? Bool == true { finding.preExisting = true }
        return finding
    }

    /// Models misnumber lines. When the evidence isn't within ±3 lines of the anchor but is on
    /// exactly one line of the file, the anchor moves there; a finding whose evidence is
    /// nowhere keeps its line (the verifier sees the code and may reject it).
    static func anchor(_ finding: inout ReviewFinding, worktree: URL?) {
        guard finding.side == .new, let path = finding.file, let lines = fileLines(path, worktree: worktree) else { return }
        let needle = finding.evidence.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            .first { $0.count >= 4 }
        guard let needle else { return }
        // The model's quote went through the same masking and defusing as the file's lines. Any
        // quoted line counts, without a diff marker, a line number or `...`, spaces collapsed.
        if let hits = quoteHits(finding.evidence, in: lines) { finding.evidenceFound = !hits.isEmpty }
        if let line = finding.line, line >= 1, line <= lines.count {
            let window = lines[max(0, line - 4)..<min(lines.count, line + 3)]
            if window.contains(where: { $0.contains(needle) }) { return }
        }
        let hits = lines.indices.filter { lines[$0].contains(needle) }
        if hits.count == 1 { finding.line = hits[0] + 1 }
    }

    /// The lines (0-based) of a file, masked, that hold a piece of the quote; nil when the quote has
    /// no piece worth looking for. The quote went through the same masking and defusing as the
    /// file's lines. With a `minimum`, a shorter piece counts only when it is the whole line.
    static func quoteHits(_ quote: String, in lines: [String], minimum: Int = 0) -> [Int]? {
        let quoted = quote.split(whereSeparator: \.isNewline).flatMap { evidencePieces(String($0)) }
        guard !quoted.isEmpty else { return nil }
        let file = lines.map { collapsed(ReviewNotes.defused($0)) }
        return file.indices.filter { index in quoted.contains { pieceMatches($0, file[index], minimum: minimum) } }
    }

    /// A piece of a quote in a collapsed line: at least `minimum` characters, or the whole line.
    static func pieceMatches(_ piece: String, _ line: String, minimum: Int) -> Bool {
        line.contains(piece) && (piece.count >= minimum || line == piece)
    }

    /// The parts of a quoted line worth looking for: no diff marker or line number, split at
    /// `...` and `…`, spaces collapsed, at least 4 characters.
    static func evidencePieces(_ line: String) -> [String] {
        var text = line.trimmingCharacters(in: .whitespaces)
        if let marker = text.first, "+-".contains(marker), text.count > 1 { text = String(text.dropFirst()) }
        if let range = text.range(of: #"^\s*\d+\s*[:|]\s"#, options: .regularExpression) { text = String(text[range.upperBound...]) }
        return text.replacingOccurrences(of: "…", with: "...").components(separatedBy: "...").map(collapsed).filter { $0.count >= 4 }
    }

    static func collapsed(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    static func fingerprint(_ finding: ReviewFinding, worktree: URL?) -> String {
        fingerprints(finding, worktree: worktree).current
    }

    /// The fingerprint, and the one the first rule gave (with the title) when it differs.
    static func fingerprints(_ finding: ReviewFinding, worktree: URL?) -> (current: String, previous: String?) {
        let file = finding.file ?? ""
        let path = ReviewLinked.repoPath(file, worktree: worktree)
        if finding.kind != .ac, finding.side == .new, let line = finding.line, let lines = fileLines(file, worktree: worktree),
           let around = ReviewFingerprint.snippet(lines, line: line) {
            return (ReviewFingerprint.make(path: path, snippet: around, title: nil),
                    ReviewFingerprint.make(path: path, snippet: around, title: finding.title))
        }
        return (ReviewFingerprint.make(path: path, snippet: finding.evidence, title: finding.title), nil)
    }

    /// A file of the worktree, its lines masked. A merge request can add a symlink that points out
    /// of the worktree, so the real path must stay inside it; secret files are never read.
    static func fileLines(_ path: String, worktree: URL?) -> [String]? {
        guard var worktree, !path.contains(".."), !path.hasPrefix("/"), !ReviewExtension.isBlocked(path) else { return nil }
        var path = path
        // `@key/…`: a file of a linked merge request, in its worktree beside the run's.
        if let linked = ReviewLinked.split(path), linked.key.range(of: "^[a-z0-9-]+$", options: .regularExpression) != nil {
            let tree = ReviewLinked.worktree(worktree.deletingLastPathComponent(), key: linked.key)
            if FileManager.default.fileExists(atPath: tree.appending(path: ".git").path) {
                worktree = tree
                path = linked.path
            }
        }
        let root = worktree.resolvingSymlinksInPath().path
        let file = worktree.appending(path: path).resolvingSymlinksInPath()
        guard file.path.hasPrefix(root + "/"), !ReviewExtension.isBlocked(file.path),
              let text = try? String(contentsOf: file, encoding: .utf8) else { return nil }
        return text.split(separator: "\n", omittingEmptySubsequences: false).map { SecretFilter.masked(String($0)) }
    }

    /// The verifier's input: each candidate with ±5 numbered lines around its anchor.
    static func verifierInput(_ candidates: [ReviewFinding], worktree: URL?) -> String {
        var text = "## Candidates\n"
        for finding in candidates {
            let place = finding.file.map { "`\($0)`" + (finding.line.map { ":\($0)" } ?? "") + (finding.side == .old ? " (removed line)" : "") }
                ?? "the whole merge request"
            text += "\n### \(finding.id) · \(finding.role) · \(finding.kind.rawValue) · \(finding.severity.rawValue) · confidence "
                + String(format: "%.2f", finding.confidence) + "\n\n"
            text += "- Where: \(place)\n- Title: \(finding.title)\n- Why: \(finding.why)\n"
            if finding.preExisting == true { text += "- The role says: already there before this change.\n" }
            if let run = finding.carriedFrom {
                text += "- Also found by the last review (run \(run)). If the code changed since and the change fixed it, reject it with "
                    + "the note \"fixed\"; otherwise judge it as usual.\n"
            }
            if !finding.evidence.isEmpty { text += "- Evidence: `\(finding.evidence.replacingOccurrences(of: "`", with: "'"))`\n" }
            if finding.evidenceFound == false { text += "- AKit: this quote is not in the file at the reviewed commit.\n" }
            if let suggestion = finding.suggestion { text += "- Suggestion: `\(suggestion.replacingOccurrences(of: "`", with: "'"))`\n" }
            if let path = finding.file, let line = finding.line, finding.side == .new, let lines = fileLines(path, worktree: worktree) {
                let start = max(1, line - 5)
                let end = min(lines.count, line + 5)
                if start <= end {
                    text += "\n```\n" + (start...end).map { "\($0 == line ? ">" : " ")\(String(format: "%5d", $0))  \(lines[$0 - 1])" }
                        .joined(separator: "\n") + "\n```\n"
                }
            }
        }
        return text
    }

    /// The verifier's verdicts on the candidates. A candidate without a verdict stays
    /// unverified, which never goes inline.
    /// `keepingUnmentioned`: a candidate without a verdict in the file keeps the one it has (a
    /// discussion changes some findings, not all).
    static func apply(verdictsFile: URL, to candidates: [ReviewFinding], keepingUnmentioned: Bool = false) -> [ReviewFinding] {
        guard let object = (try? Data(contentsOf: verdictsFile)).flatMap({ try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }) else {
            return candidates
        }
        var byID: [String: ReviewFinding.Verdict] = [:]
        for raw in object["verdicts"] as? [[String: Any]] ?? [] {
            guard let id = raw["id"] as? String, let value = (raw["verdict"] as? String).flatMap(ReviewFinding.Verdict.Value.init) else { continue }
            let into = raw["into"] as? String
            // A merge into a finding that doesn't exist (or into itself) isn't a merge.
            if value == .merged, into == nil || into == id || !candidates.contains(where: { $0.id == into }) { continue }
            byID[id] = ReviewFinding.Verdict(verdict: value, note: ReviewNotes.defused(SecretFilter.masked(raw["note"] as? String ?? "")), into: into,
                                             severity: (raw["severity"] as? String).flatMap(ReviewSeverity.init),
                                             confidence: (raw["confidence"] as? NSNumber).flatMap { (0...1).contains($0.doubleValue) ? $0.doubleValue : nil },
                                             preExisting: raw["preExisting"] as? Bool)
        }
        return candidates.map { finding in
            var finding = finding
            if var verdict = byID[finding.id] {
                // A discussion that only changes a severity keeps the earlier say on "before this change".
                if keepingUnmentioned, verdict.preExisting == nil { verdict.preExisting = finding.verifier?.preExisting }
                finding.verifier = verdict
            } else if !keepingUnmentioned { finding.verifier = nil }
            if let verdict = byID[finding.id], verdict.verdict == .merged, let into = verdict.into, !finding.related.contains(into) {
                finding.related.append(into)
            }
            return finding
        }
    }
}
