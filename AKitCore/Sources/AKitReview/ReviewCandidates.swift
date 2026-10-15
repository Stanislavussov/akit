import AKitFoundation
import Foundation

/// Role findings become candidates: AKit checks each field again (the extension's check is
/// the model's side; this one is the trusted one), puts the anchor on the line the evidence
/// is really on, adds the fingerprint and folds duplicates.
public enum ReviewCandidates {
    /// Every role pass's findings, in role order, numbered `f1`, `f2`, ….
    static func collect(folder: URL, spec: ReviewRunSpec, worktree: URL?) -> [ReviewFinding] {
        var result: [ReviewFinding] = []
        for role in spec.roles {
            let file = folder.appending(path: "passes/role-\(role.id).json")
            guard let object = (try? Data(contentsOf: file)).flatMap({ try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }) else { continue }
            for raw in (object["findings"] as? [[String: Any]] ?? []).prefix(role.maxFindings) {
                guard var finding = finding(raw, role: role.id, id: "f\(result.count + 1)") else { continue }
                // Below the role's own floor: the role said it shouldn't comment on it.
                if finding.kind == .finding, finding.severity < role.minSeverity { continue }
                anchor(&finding, worktree: worktree)
                finding.fingerprint = fingerprint(finding, worktree: worktree)
                if let same = result.firstIndex(where: { $0.fingerprint == finding.fingerprint && $0.kind == finding.kind }) {
                    let note = "\(finding.role):\(finding.title)"
                    if !result[same].related.contains(note) { result[same].related.append(note) }
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
        func text(_ key: String) -> String { SecretFilter.masked(raw[key] as? String ?? "") }
        return ReviewFinding(id: id, kind: kind, role: role, file: file, side: (raw["side"] as? String) == "old" ? .old : .new,
                             line: file == nil ? nil : line, title: SecretFilter.masked(title), evidence: text("evidence"), why: text("why"),
                             severity: severity, confidence: confidence,
                             suggestion: (raw["suggestion"] as? String).map(SecretFilter.masked).flatMap { $0.isEmpty ? nil : $0 },
                             related: (raw["related"] as? [String]) ?? [])
    }

    /// Models misnumber lines. When the evidence isn't within ±3 lines of the anchor but is on
    /// exactly one line of the file, the anchor moves there; a finding whose evidence is
    /// nowhere keeps its line (the verifier sees the code and may reject it).
    static func anchor(_ finding: inout ReviewFinding, worktree: URL?) {
        guard finding.side == .new, let path = finding.file, let lines = fileLines(path, worktree: worktree) else { return }
        let needle = finding.evidence.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            .first { $0.count >= 4 }
        guard let needle else { return }
        if let line = finding.line, line >= 1, line <= lines.count {
            let window = lines[max(0, line - 4)..<min(lines.count, line + 3)]
            if window.contains(where: { $0.contains(needle) }) { return }
        }
        let hits = lines.indices.filter { lines[$0].contains(needle) }
        if hits.count == 1 { finding.line = hits[0] + 1 }
    }

    static func fingerprint(_ finding: ReviewFinding, worktree: URL?) -> String {
        let path = finding.file ?? ""
        var snippet = finding.evidence
        if finding.side == .new, let line = finding.line, let lines = fileLines(path, worktree: worktree),
           let around = ReviewFingerprint.snippet(lines, line: line) {
            snippet = around
        }
        return ReviewFingerprint.make(path: path, snippet: snippet, title: finding.title)
    }

    static func fileLines(_ path: String, worktree: URL?) -> [String]? {
        guard let worktree, !path.contains(".."), !path.hasPrefix("/") else { return nil }
        guard let text = try? String(contentsOf: worktree.appending(path: path), encoding: .utf8) else { return nil }
        return text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
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
            if !finding.evidence.isEmpty { text += "- Evidence: `\(finding.evidence.replacingOccurrences(of: "`", with: "'"))`\n" }
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
            byID[id] = ReviewFinding.Verdict(verdict: value, note: SecretFilter.masked(raw["note"] as? String ?? ""), into: into,
                                             severity: (raw["severity"] as? String).flatMap(ReviewSeverity.init),
                                             confidence: (raw["confidence"] as? NSNumber).flatMap { (0...1).contains($0.doubleValue) ? $0.doubleValue : nil })
        }
        return candidates.map { finding in
            var finding = finding
            if let verdict = byID[finding.id] { finding.verifier = verdict } else if !keepingUnmentioned { finding.verifier = nil }
            if let verdict = byID[finding.id], verdict.verdict == .merged, let into = verdict.into, !finding.related.contains(into) {
                finding.related.append(into)
            }
            return finding
        }
    }
}
