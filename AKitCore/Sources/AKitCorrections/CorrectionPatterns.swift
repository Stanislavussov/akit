import AKitErrorAnalysis
import AKitFoundation
import AKitInsights
import AKitLab
import AKitSessions
import Foundation

/// Corrections (`docs/design/corrections.md`): the count by code, and Find Pattern…, the one model
/// call over short excerpts that proposes up to 3 rules for what the user corrects again and again.
public enum Corrections {
    public struct Failure: Error, LocalizedError {
        public let message: String
        public var errorDescription: String? { message }
    }

    /// The window of the card and of `akit corrections`.
    public static let defaultDays = 14
    /// The send log's purpose.
    public static let purpose = "corrections"
    /// Luna at medium: a weak model gets a short prompt, a strict schema and some thought.
    public static let defaultThinking = "medium"
    public static let maxPatterns = 3
    static let titleWords = 15
    static let ruleLines = 4

    /// The signals scan first (it reads the session files changed since the last scan), then the
    /// report. Lab's own sessions are left out (D19). When another import holds the lock, the
    /// report reads the index as it is.
    public static func report(env: HarnessEnvironment, days: Int = defaultDays, project: String? = nil,
                              bindings: BindingSet = .default, now: Date = Date()) throws -> CorrectionsReport {
        if let lock = try ImportLock.acquire(InsightsPaths(env: env).lock) {
            defer { withExtendedLifetime(lock) {} }
            try SignalScanner.refresh(env: env)
        }
        guard let database = try AnalysisIndex.open(env: env) else { return .empty(days: days, project: project) }
        return try CorrectionsReport.report(database, days: days, project: project, bindings: bindings,
                                            excluding: IndexedSessions.labKeys(env: env), now: now)
    }

    // MARK: - The call

    static let system = """
    You read short excerpts of a developer's sessions with a coding agent. Each excerpt shows the agent's last steps \
    and then a moment the user corrected the agent (an interrupt, a pushback, a refused tool call or a bad rating), \
    with the user's words verbatim after "user:".

    Find what the user corrects again and again across sessions: the same kind of mistake in the agent's way of \
    working. Leave out one-off corrections and new requirements of a task.

    Return at most 3 patterns. Each pattern:
    - title: what the agent keeps doing wrong, at most 15 words, English.
    - reactionIds: the excerpt ids (like s1.r2) of that pattern, from at least 2 different sessions (s1, s2, …).
    - rule: 1 to 4 short imperative lines for the agent, English, generic (no file names or details of one session): \
    when it applies, what to do, how to check it was done.

    When nothing repeats across sessions, return {"patterns": []}. Answer with JSON only.
    """

    static let schema = """
    {"type":"object","properties":{"patterns":{"type":"array","maxItems":3,"items":{"type":"object","properties":{\
    "title":{"type":"string"},"reactionIds":{"type":"array","items":{"type":"string"}},\
    "rule":{"type":"array","items":{"type":"string"},"minItems":1,"maxItems":4}},\
    "required":["title","reactionIds","rule"]}}},"required":["patterns"]}
    """

    /// Find Pattern…: one call over the pick, the checks, and the state saved with the new
    /// patterns (the old unapplied ones are replaced). `model` "" is the default (Luna).
    public static func find(_ pick: CorrectionPick, model: String = "", thinking: String = defaultThinking, env: HarnessEnvironment,
                            now: Date = Date()) async throws(Failure) -> [CorrectionPattern] {
        guard pick.sessions >= 2 else {
            throw Failure(message: "Corrections in fewer than 2 sessions: a pattern needs at least 2. Nothing was sent.")
        }
        var state: CorrectionsState
        do { state = try CorrectionsState.load(env: env) } catch { throw Failure(message: error.message) }
        let text: String
        do {
            let available = await LabRuns.models(for: .pi, env: env)
            let chosen = model.isEmpty ? (KnowledgeCheckModel.defaultModel(for: .pi, available: available) ?? "") : model
            let agent = try KnowledgeCheckModel.resolved(LabAgent(harness: .pi, model: chosen,
                                                                  effort: LabHarness.pi.efforts.contains(thinking) ? thinking : defaultThinking,
                                                                  mode: .call), available: available)
            let request = ModelCall.Request(agent: agent, purpose: purpose, system: system, input: pick.input, schema: schema,
                                            origins: Self.origins(pick))
            let folder = FileManager.default.temporaryDirectory.appending(path: "akit-corrections-\(UUID().uuidString)", directoryHint: .isDirectory)
            defer { try? FileManager.default.removeItem(at: folder) }
            let gate = try await SendGate.open(agent: agent, env: env)
            text = try await ModelCall.run(request, gate: gate, folder: folder, env: env).text
        } catch let error as KnowledgeCheckModel.Failure {
            throw Failure(message: error.message)
        } catch {
            throw Failure(message: error.localizedDescription)
        }
        let patterns = try checked(answer: text, pick: pick, now: now)
        let applied = Set(state.rules.map(\.id))
        state.patterns = state.patterns.filter { applied.contains($0.id) } + patterns.filter { !applied.contains($0.id) }
        do { try state.save(env: env) } catch { throw Failure(message: error.message) }
        return patterns.filter(state.shows)
    }

    /// The origin of each picked session's log: every one must be allowed at the destination.
    static func origins(_ pick: CorrectionPick) -> [SendOrigin] {
        var seen = Set<String>()
        return pick.excerpts.compactMap { excerpt in
            guard let file = excerpt.file, seen.insert(file).inserted else { return nil }
            return SendOrigin.of(harness: SessionKey.harness(of: excerpt.sessionKey), sessionFile: URL(filePath: file))
        }
    }

    /// The answer read leniently (a weak model's JSON), then checked by code: unknown ids dropped,
    /// patterns with reactions from fewer than 2 sessions dropped, at most 3, the words verbatim
    /// from the pick. Throws only when the answer has no JSON at all.
    static func checked(answer: String, pick: CorrectionPick, now: Date) throws(Failure) -> [CorrectionPattern] {
        let whole = try? JSONSerialization.jsonObject(with: Data(answer.trimmingCharacters(in: .whitespacesAndNewlines).utf8))
        guard let object = whole ?? ModelCall.jsonObject(in: answer).flatMap({ try? JSONSerialization.jsonObject(with: $0) }) else {
            throw Failure(message: "The model's answer has no JSON. Try again or pick another model.")
        }
        // {"patterns": […]}, a bare list, or one pattern alone.
        let dictionary = object as? [String: Any]
        let list: [Any] = (dictionary?["patterns"] as? [Any]) ?? (object as? [Any]) ?? (dictionary?["title"] != nil ? [object] : [])
        let byID = Dictionary(pick.excerpts.map { ($0.id.lowercased(), $0) }, uniquingKeysWith: { first, _ in first })
        var result: [CorrectionPattern] = []
        for case let entry as [String: Any] in list {
            guard result.count < maxPatterns else { break }
            let title = words(entry["title"] as? String ?? "", limit: titleWords)
            let ids = strings(entry["reactionIds"] ?? entry["reactions"] ?? entry["ids"])
                .flatMap { $0.split(whereSeparator: { ", ;".contains($0) }).map(String.init) }
            var seen = Set<String>()
            let reactions = ids.compactMap { byID[$0.trimmingCharacters(in: .whitespaces).lowercased()] }.filter { seen.insert($0.id).inserted }
            let rule = strings(entry["rule"] ?? entry["rules"])
                .flatMap { $0.split(separator: "\n").map(String.init) }
                .map { $0.trimmingCharacters(in: .whitespaces).trimmingPrefix(while: { "-*•".contains($0) }).trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
                .prefix(ruleLines)
            guard !title.isEmpty, !rule.isEmpty, Set(reactions.map(\.sessionKey)).count >= 2 else { continue }
            let id = CorrectionPattern.id(of: reactions)
            guard !result.contains(where: { $0.id == id }) else { continue }
            let projects = Set(reactions.map(\.project))
            result.append(CorrectionPattern(id: id, title: title, rule: Array(rule), reactions: reactions,
                                            scope: projects.count == 1 ? projects.first! : nil, found: now))
        }
        return result
    }

    /// A string, or the strings of an array.
    static func strings(_ value: Any?) -> [String] {
        if let text = value as? String { return [text] }
        return (value as? [Any])?.compactMap { $0 as? String } ?? []
    }

    static func words(_ text: String, limit: Int) -> String {
        let parts = text.split(whereSeparator: \.isWhitespace)
        return parts.prefix(limit).joined(separator: " ") + (parts.count > limit ? "…" : "")
    }
}
