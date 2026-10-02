import AKitFoundation
import AKitLab
import Foundation

/// Validation of judges and heuristic code checks (`docs/design/error-analysis.md`,
/// "Validation"): labels split 10/30/60 into train, dev and test; iterate on dev, then one run
/// on the held-out test; valid when the Wilson lower bounds of TPR and TNR are both ≥ 80%.
public enum Validation {
    public static let lowerBound = 0.8
    public static let validatedPerClass = 30
    public static let provisionalPerClass = 20

    public enum LabelSet: String, Codable, Sendable {
        case dev, test
    }

    /// Which check a result is about: a judge (harness, model, prompt version) or a code check.
    public static func checker(judge agent: LabAgent?, modeID: String) -> String {
        if let agent { return "judge|\(agent.harness.rawValue)|\(agent.model)|\(Judges.promptVersion)" }
        return "code|\(CodeChecks.check(for: modeID)?.version ?? 0)"
    }

    /// The split of a mode's labelled sessions. A session keeps its set once it has one; new
    /// ones are placed by a hash of mode and session, 10% train, 30% dev, 60% test.
    /// `train`: sessions that must be in train (exemplars); they move there from dev or test.
    public static func split(_ labels: [ModeLabel], modeID: String, existing: ValidationStore.Split?,
                             train forced: Set<String> = []) -> ValidationStore.Split {
        var split = existing ?? ValidationStore.Split()
        split.dev.removeAll { forced.contains($0) }
        split.test.removeAll { forced.contains($0) }
        for key in forced.sorted() where labels.contains(where: { $0.sessionKey == key }) && !split.train.contains(key) {
            split.train.append(key)
        }
        let placed = Set(split.train + split.dev + split.test)
        for label in labels where !placed.contains(label.sessionKey) {
            let hash = Checksum.sha256(Data("\(modeID)|\(label.sessionKey)".utf8))
            let bucket = Int(hash.prefix(8), radix: 16).map { $0 % 100 } ?? 0
            if bucket < 10 { split.train.append(label.sessionKey) } else if bucket < 40 { split.dev.append(label.sessionKey) } else {
                split.test.append(label.sessionKey)
            }
        }
        return split
    }

    /// TPR and TNR of a check on one set of labels. Tough calls nobody reviewed are left out.
    public static func evaluate(modeID: String, modeVersion: Int, checker: String, set: LabelSet, labels: [ModeLabel], sessions: [String],
                                verdicts: [String: CheckVerdict], decided: [String: Bool]) -> ValidationResult {
        let inSet = Swift.Set(sessions)
        var onPositives: [Bool] = []
        var onNegatives: [Bool] = []
        var leftOut = 0
        var missing = 0
        for label in labels where inSet.contains(label.sessionKey) {
            guard let verdict = verdicts[label.sessionKey] else {
                missing += 1
                continue
            }
            if verdict.toughCall, decided[label.sessionKey] == nil {
                leftOut += 1
                continue
            }
            if label.positive { onPositives.append(verdict.positive) } else { onNegatives.append(verdict.positive) }
        }
        let labelsUsed = Stats.CheckLabels(onPositives: onPositives, onNegatives: onNegatives)
        let tp = onPositives.filter { $0 }.count, tn = onNegatives.filter { !$0 }.count
        return ValidationResult(modeID: modeID, modeVersion: modeVersion, checker: checker, set: set, labels: labelsUsed,
                                tprLow: onPositives.isEmpty ? nil : Stats.wilson(tp, onPositives.count).low,
                                tnrLow: onNegatives.isEmpty ? nil : Stats.wilson(tn, onNegatives.count).low,
                                toughLeftOut: leftOut, unchecked: missing, at: .now)
    }

    /// How far a mode's current check can be trusted: only a test result for the current mode
    /// version and the current checker counts (a merge, split, definition edit, model or
    /// prompt change invalidates it).
    public static func trust(modeID: String, modeVersion: Int, checker: String, results: [ValidationResult]) -> CheckTrust {
        if CodeChecks.check(for: modeID)?.kind == .mechanical, checker.hasPrefix("code") { return .exact }
        guard let result = results.last(where: { $0.set == .test && $0.modeVersion == modeVersion && $0.checker == checker }) else {
            return .none
        }
        let perClass = min(result.labels.onPositives.count, result.labels.onNegatives.count)
        if perClass >= validatedPerClass, (result.tprLow ?? 0) >= lowerBound, (result.tnrLow ?? 0) >= lowerBound {
            return CheckTrust(level: .validated, labels: result.labels)
        }
        if perClass >= provisionalPerClass { return CheckTrust(level: .provisional, labels: result.labels) }
        return .none
    }

    /// The trust of every mode, for the report: the judge when one is enabled, else the code check.
    public static func trustMap(modes: [Mode], env: HarnessEnvironment) -> [String: CheckTrust] {
        let store = ValidationStore(env: env)
        let judges = store.judges()
        let results = store.results()
        var map: [String: CheckTrust] = [:]
        for mode in modes {
            let checker = checker(judge: judges[mode.id], modeID: mode.id)
            map[mode.id] = trust(modeID: mode.id, modeVersion: mode.version, checker: checker, results: results[mode.id] ?? [])
        }
        return map
    }

    /// Runs a mode's check on its dev or test labels and records TPR and TNR. A judge judges the
    /// sessions of the set (sent under the sending policy); a code check reads its verdicts over
    /// the index. The test set runs once per mode version and checker.
    @discardableResult
    public static func run(mode: Mode, set: LabelSet, modes: [Mode], gate: SendGate?, workFolder: URL, env: HarnessEnvironment,
                           out: @escaping @Sendable (String) -> Void = { _ in }) async throws -> ValidationResult {
        let store = ValidationStore(env: env)
        let judge = store.judges()[mode.id]
        let checker = checker(judge: judge, modeID: mode.id)
        if set == .test, (store.results()[mode.id] ?? []).contains(where: { $0.set == .test && $0.modeVersion == mode.version && $0.checker == checker }) {
            throw Judges.Failure(message: "The test set already ran for \(mode.name) v\(mode.version) with this check. Iterate on dev; a change of the mode, model or prompt allows a new test run.")
        }
        let book = LabelBookStore(env: env).load()
        let labels = ModeLabels.labels(for: mode.id, modes: modes, bootstrap: Bootstrap.LabelStore(env: env).all(), book: book,
                                       toughCalls: book.toughCalls(of: mode.id))
        // Exemplars go into every matching and judge call: their sessions are kept in train.
        let exemplarSessions = Set(try ModeStore(env: env).exemplars(of: mode.id).map(\.sessionKey))
        var split = ValidationStore.Split()
        try store.updateSplits { splits in
            split = Validation.split(labels, modeID: mode.id, existing: splits[mode.id], train: exemplarSessions)
            splits[mode.id] = split
        }
        let sessions = set == .dev ? split.dev : split.test
        let verdicts: [String: CheckVerdict]
        if let judge {
            guard let gate else { throw Judges.Failure(message: "A judge needs a send gate.") }
            let files = transcripts(env: env)
            let targets = sessions.compactMap { key in files[key].map { (key: key, file: $0) } }
            verdicts = try await Judges.run(mode: mode, sessions: targets, agent: judge, gate: gate, runID: nil, workFolder: workFolder,
                                            env: env, out: out).verdicts
        } else {
            guard CodeChecks.check(for: mode.id) != nil else { throw Judges.Failure(message: "\(mode.name) has no judge and no code check.") }
            verdicts = CheckStore(env: env).load(mode.id)?.verdicts ?? [:]
        }
        let result = evaluate(modeID: mode.id, modeVersion: mode.version, checker: checker, set: set, labels: labels, sessions: sessions,
                              verdicts: verdicts, decided: book.toughCalls(of: mode.id))
        try store.append(result)
        return result
    }

    /// Transcript files of every session the labels can name: bootstrap sessions and the pool.
    static func transcripts(env: HarnessEnvironment) -> [String: String] {
        var files: [String: String] = [:]
        for notes in NotesStore(env: env).all() { files[notes.sessionKey] = notes.transcript }
        for entry in BootstrapReservations(env: env).all() { files[entry.sessionKey] = entry.transcript }
        return files
    }

    /// The verdicts that count for a mode: the enabled judge's, else the code check's.
    public static func verdicts(modeID: String, env: HarnessEnvironment) -> CheckResults? {
        let store = CheckStore(env: env)
        if ValidationStore(env: env).judges()[modeID] != nil { return store.load(Judges.resultsID(modeID)).map { results in
            var renamed = results
            renamed.modeID = modeID
            return renamed
        } }
        return store.load(modeID)
    }
}

/// One validation run of a check on dev or test.
public struct ValidationResult: Codable, Hashable, Sendable {
    public var modeID: String
    public var modeVersion: Int
    public var checker: String
    public var set: Validation.LabelSet
    /// The check's verdicts on positive and negative labels.
    public var labels: Stats.CheckLabels
    public var tprLow: Double?
    public var tnrLow: Double?
    /// Tough calls nobody reviewed, left out of TPR/TNR.
    public var toughLeftOut: Int
    /// Labeled sessions the check has no verdict for.
    public var unchecked: Int
    public var at: Date

    public var tpr: Double? { labels.tpr }
    public var tnr: Double? { labels.tnr }
}

/// `labels/splits.json`, `labels/validation.json`, `labels/judges.json`.
public struct ValidationStore: Sendable {
    public struct Split: Codable, Hashable, Sendable {
        public var train: [String]
        public var dev: [String]
        public var test: [String]

        public init(train: [String] = [], dev: [String] = [], test: [String] = []) {
            self.train = train
            self.dev = dev
            self.test = test
        }
    }

    let folder: URL

    public init(env: HarnessEnvironment) { folder = AnalysisPaths(env: env).labels }

    private func read<T: Decodable>(_ name: String, as type: T.Type) -> T? {
        (try? Data(contentsOf: folder.appending(path: name))).flatMap { try? AnalysisJSON.decoder.decode(T.self, from: $0) }
    }

    public func splits() -> [String: Split] { read("splits.json", as: [String: Split].self) ?? [:] }

    /// Sessions in any mode's test set: never exemplars.
    public func testSessions() -> Set<String> { Set(splits().values.flatMap(\.test)) }

    public func results() -> [String: [ValidationResult]] { read("validation.json", as: [String: [ValidationResult]].self) ?? [:] }

    public func append(_ result: ValidationResult) throws {
        try JSONFile.update(folder.appending(path: "validation.json"), empty: [String: [ValidationResult]]()) {
            $0[result.modeID, default: []].append(result)
        }
    }

    /// Modes with a judge, and who judges.
    public func judges() -> [String: LabAgent] { read("judges.json", as: [String: LabAgent].self) ?? [:] }

    public func setJudge(_ agent: LabAgent?, for modeID: String) throws {
        try JSONFile.update(folder.appending(path: "judges.json"), empty: [String: LabAgent]()) { $0[modeID] = agent }
    }

    /// Changes the splits as they are on disk now.
    public func updateSplits(_ change: (inout [String: Split]) throws -> Void) throws {
        try JSONFile.update(folder.appending(path: "splits.json"), empty: [String: Split]()) { try change(&$0) }
    }
}
