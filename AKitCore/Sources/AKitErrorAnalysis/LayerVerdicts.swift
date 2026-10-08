import AKitFoundation
import AKitLab
import Foundation

/// The verdict of one finished layer eval (`docs/design/layer-evals.md`, "Verdict"): success
/// only, offline. Numbers, no task prompts and no repository paths.
public struct LayerVerdict: Codable, Sendable, Hashable {
    public enum Sanity: String, Codable, Sendable {
        /// Every read-only cell failed, as it must.
        case passed
        /// A read-only cell passed: the oracle can't tell work from no work.
        case failed
        /// The eval ran no read-only cell.
        case none
    }

    public var layer: String
    public var evalID: String
    public var evalCreatedAt: Date
    public var harness: LabHarness
    public var model: String
    public var effort: String
    public var brainCommit: String
    /// The layer setup's overlay hash.
    public var overlay: String?
    /// The required layers' overlay hash; nil when they write nothing.
    public var baselineOverlay: String?
    /// Tasks both setups have cells of.
    public var tasks: Int
    public var repeats: Int
    public var baselineCells: Int
    public var layerCells: Int
    /// pass@1 of each side over the shared tasks.
    public var baselineRate: Double?
    public var layerRate: Double?
    public var meanChange: Double?
    public var improvementShare: Double?
    public var worseShare: Double?
    public var verdict: ControlComparison.Verdict
    public var reason: String
    /// Cells of both setups counted as failed because they are flagged.
    public var flagged: Int
    /// Cells left out: an older akit ran them without the layer.
    public var leftOut: Int
    /// Tasks the layer couldn't be placed in.
    public var blocked: Int
    public var sanity: Sanity
    public var sanityCells: Int
    public var sanityPassed: Int
    public var harnessVersions: [String]
    public var overlap: [String]
    /// Tasks whose project has its own CLAUDE.md the layer's text is appended to; nil for an
    /// eval that didn't record it.
    public var projectOwnContext: Int?
    /// The recorded cost of the eval's cells, US dollars; nil when none recorded one.
    public var cost: Double?
    /// When the eval's last cell finished.
    public var decidedAt: Date

    public var agent: LabAgent { LabAgent(harness: harness, model: model, effort: effort) }
}

/// `~/.akit/lab/evals/verdicts/<layer>.json`: the last verdict per agent (harness, model,
/// effort), for the badge on the layer. Local only; nothing goes into the brain.
public struct LayerVerdictFile: Codable, Sendable, Hashable {
    public static let schemaVersion = 1

    public var schema = LayerVerdictFile.schemaVersion
    public var layer: String
    public var verdicts: [LayerVerdict]
}

public enum LayerVerdicts {
    /// The verdict of an eval from its cells (the Lab runs of its setups) and the recorded
    /// cost per run (`SendLog.runCosts`). nil while a cell of the eval is queued or running,
    /// and when no task has finished cells of both setups (none queued, or all cancelled or
    /// failed), so an empty eval never replaces a stored verdict.
    public static func verdict(of manifest: LayerEvalManifest, runs: [LabRun], costs: [String: RunCost]) -> LayerVerdict? {
        let mine = runs.filter { $0.spec.kind == .control && $0.spec.controlSetup?.layer?.evalID == manifest.id }
        guard !mine.isEmpty, !mine.contains(where: { $0.status == .queued || $0.status == .running }),
              let baseline = manifest.setups.first(where: { $0.layer?.role == .requiredOnly }),
              let variant = manifest.setups.first(where: { $0.layer?.role == .layer }) else { return nil }
        let cells = ControlComparison.Cell.of(mine)
        let comparison = ControlComparison.compare(cells)
        let before = comparison.rows.first { $0.setup == baseline }
        let after = comparison.rows.first { $0.setup == variant }
        guard let pair = comparison.paired.first(where: { $0.variant == variant && $0.baseline == baseline }), pair.tasks > 0 else { return nil }
        // pass@1 of a side over the tasks both sides have.
        let shared = Set(before?.tasks.map(\.task) ?? []).intersection(after?.tasks.map(\.task) ?? [])
        func rate(_ row: ControlComparison.Row?) -> Double? {
            let rates = (row?.tasks ?? []).filter { shared.contains($0.task) }.map(\.rate)
            return rates.isEmpty ? nil : rates.reduce(0, +) / Double(rates.count)
        }
        let sanity = cells.filter { $0.overlayRecorded && $0.setup.readOnly }
        let sanityPassed = sanity.filter(\.passed).count
        // In run order, so the same runs always give the same sum.
        let priced = mine.sorted { $0.id < $1.id }.compactMap { costs[$0.id]?.dollars }
        return LayerVerdict(
            layer: manifest.layer, evalID: manifest.id, evalCreatedAt: seconds(manifest.createdAt), harness: variant.agent.harness,
            model: variant.agent.model, effort: variant.agent.effort, brainCommit: manifest.brainCommit,
            overlay: variant.layer?.overlayHash, baselineOverlay: baseline.layer?.overlayHash,
            tasks: pair.tasks, repeats: manifest.repeats, baselineCells: pair.baselineCells, layerCells: pair.variantCells,
            baselineRate: rate(before), layerRate: rate(after), meanChange: pair.meanChange,
            improvementShare: pair.improvementShare, worseShare: pair.worseShare, verdict: pair.verdict, reason: pair.reason,
            flagged: (before?.flagged ?? 0) + (after?.flagged ?? 0), leftOut: comparison.leftOut, blocked: manifest.blocked.count,
            sanity: sanity.isEmpty ? .none : sanityPassed > 0 ? .failed : .passed, sanityCells: sanity.count, sanityPassed: sanityPassed,
            harnessVersions: Set(cells.compactMap(\.harnessVersion)).sorted(), overlap: manifest.overlap,
            projectOwnContext: manifest.ownFiles.map { files in manifest.tasks.filter { files[$0] != nil }.count },
            cost: priced.isEmpty ? nil : priced.reduce(0, +),
            decidedAt: seconds(mine.compactMap { $0.state?.updatedAt }.max() ?? manifest.createdAt))
    }

    /// Whole seconds, so a verdict read back from its file equals the one computed again.
    private static func seconds(_ date: Date) -> Date { Date(timeIntervalSince1970: date.timeIntervalSince1970.rounded(.down)) }

    /// Stores the verdict as its agent's last one. An older eval never replaces a newer one's
    /// verdict, so looking at an old eval leaves the badge alone. Returns whether it was stored.
    @discardableResult
    public static func save(_ verdict: LayerVerdict, env: HarnessEnvironment) throws -> Bool {
        let url = EvalPaths(env: env).verdict(verdict.layer)
        return try JSONFile.locked(url) {
            var file = LayerVerdictFile(layer: verdict.layer, verdicts: [])
            if let data = try? Data(contentsOf: url) {
                guard let read = decode(data) else {
                    throw JSONFile.Failure(message: problem(data, url: url))
                }
                file = read
            }
            if let index = file.verdicts.firstIndex(where: { $0.agent == verdict.agent }) {
                let stored = file.verdicts[index]
                guard stored.evalID == verdict.evalID || stored.evalCreatedAt < verdict.evalCreatedAt else { return false }
                guard stored != verdict else { return false }
                file.verdicts[index] = verdict
            } else {
                file.verdicts.append(verdict)
            }
            try AnalysisJSON.encoder.encode(file).write(to: url, options: .atomic)
            return true
        }
    }

    /// The layer's stored verdicts; nil when there are none, or the file was written by a
    /// newer AKit.
    public static func load(layer: String, env: HarnessEnvironment) -> LayerVerdictFile? {
        (try? Data(contentsOf: EvalPaths(env: env).verdict(layer))).flatMap(decode)
    }

    /// The result lines (success only):
    /// ```
    /// swiftui · Claude Code · opus · high · 8 tasks × 3 · eval 2026-10-12 · brain a1b2c3d
    /// success: 71% → 75%, didn't show it helped (81% of the bootstrap mass on improvement, 12% on worse; needs 95%)
    /// read-only sanity: 0 of 3 passed · 1 flagged cell · Claude Code 2.1.290
    /// home overlap: none · 8 tasks with the project's own CLAUDE.md (…) · $48.20
    /// ```
    public static func lines(_ verdict: LayerVerdict, calendar: Calendar = .current) -> [String] {
        func percent(_ value: Double?) -> String { value.map { String(format: "%.0f%%", 100 * $0) } ?? "–" }
        func count(_ n: Int, _ noun: String) -> String { "\(n) \(noun)\(n == 1 ? "" : "s")" }
        let day = calendar.dateComponents([.year, .month, .day], from: verdict.evalCreatedAt)
        let date = String(format: "%04d-%02d-%02d", day.year ?? 0, day.month ?? 0, day.day ?? 0)
        var success = "success: \(percent(verdict.baselineRate)) → \(percent(verdict.layerRate)), \(verdict.verdict.title)"
        if verdict.verdict == .noConclusion {
            success += ": \(verdict.reason)"
        } else {
            success += " (\(percent(verdict.improvementShare)) of the bootstrap mass on improvement, \(percent(verdict.worseShare)) on worse; "
                + "needs \(Int(ControlComparison.helpedShare * 100))%)"
        }
        var checks = [verdict.sanity == .none ? "read-only sanity: not run"
                      : "read-only sanity: \(verdict.sanityPassed) of \(verdict.sanityCells) passed"]
        if verdict.flagged > 0 { checks.append(count(verdict.flagged, "flagged cell")) }
        if verdict.blocked > 0 { checks.append(count(verdict.blocked, "blocked task")) }
        if verdict.leftOut > 0 { checks.append("\(count(verdict.leftOut, "cell")) run by an older akit, left out") }
        if !verdict.harnessVersions.isEmpty {
            checks.append("\(verdict.harness.title) \(verdict.harnessVersions.joined(separator: ", "))"
                          + (verdict.harnessVersions.count > 1 ? " (mixed versions)" : ""))
        }
        var context = ["home overlap: " + (verdict.overlap.isEmpty ? "none" : verdict.overlap.joined(separator: " "))]
        if let own = verdict.projectOwnContext, own > 0 {
            context.append("\(count(own, "task")) with the project's own CLAUDE.md (the project gets the layer's text only by accepting the suggestion)")
        }
        if let cost = verdict.cost { context.append(String(format: "$%.2f", cost)) }
        return [
            "\(verdict.layer) · \(verdict.harness.title) · \(verdict.model) · \(verdict.effort) · \(verdict.tasks) tasks × \(verdict.repeats)"
                + " · eval \(date) · brain \(verdict.brainCommit.prefix(7))",
            success,
            checks.joined(separator: " · "),
            context.joined(separator: " · "),
        ]
    }

    /// A file of this or an older schema; a newer AKit's file is skipped rather than misread.
    private static func decode(_ data: Data) -> LayerVerdictFile? {
        struct Header: Decodable { let schema: Int? }
        if let header = try? JSONDecoder().decode(Header.self, from: data), (header.schema ?? 1) > LayerVerdictFile.schemaVersion { return nil }
        return try? AnalysisJSON.decoder.decode(LayerVerdictFile.self, from: data)
    }

    private static func problem(_ data: Data, url: URL) -> String {
        struct Header: Decodable { let schema: Int? }
        if let header = try? JSONDecoder().decode(Header.self, from: data), (header.schema ?? 1) > LayerVerdictFile.schemaVersion {
            return "\(url.path) was written by a newer AKit; install the app and akit together."
        }
        return "\(url.path) can't be read; fix or move it before AKit changes it."
    }
}
