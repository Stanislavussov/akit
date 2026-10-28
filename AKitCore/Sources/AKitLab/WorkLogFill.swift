import AKitFoundation
import AKitKnowledge
import AKitModel
import AKitSessions
import Foundation

/// Auto-Fill of the work log (docs/design/worklog.md, W8): the user's prompts of one day in the
/// agent sessions of a harness become a short timeline, a model (Pi, GPT-6 Luna by default) turns
/// it into proposed entries, and the user picks the ones to add. The prompts go out through
/// `ModelCall` (sending policy, scrub, monthly limit, send log, purpose `worklog-fill`); nothing is
/// written here.
public enum WorkLogFill {
    public struct Failure: Error, LocalizedError, Sendable {
        public let message: String
        public var errorDescription: String? { message }
        public init(message: String) { self.message = message }
    }

    public static let purpose = "worklog-fill"
    /// The timeline sent to the model has at most about this many characters.
    public static let maxCharacters = 24_000
    /// One prompt is cut to this many characters.
    static let promptCharacters = 400

    /// One prompt of the day: when, in which project, harness and git branch, and its start.
    public struct Moment: Sendable, Equatable {
        public let time: String
        public let harness: String
        public let project: String
        public var branch: String?
        public let text: String
        /// The session file it came from (for the send's origins).
        public var source: String = ""

        public init(time: String, harness: String, project: String, branch: String?, text: String, source: String = "") {
            (self.time, self.harness, self.project, self.branch, self.text, self.source) = (time, harness, project, branch, text, source)
        }

        /// A ticket like `COL-123`: from the branch first, else from the prompt.
        public var ticket: String? {
            for source in [branch ?? "", text] {
                if let match = source.firstMatch(of: /[A-Z][A-Z0-9]{1,9}-\d{1,6}/) { return String(match.output) }
            }
            return nil
        }
    }

    /// The sessions of `harnesses` that may hold prompts of `day` (a local `YYYY-MM-DD`).
    public static func sessions(_ all: [SessionSummary], day: String, harnesses: Set<HarnessID>) -> [SessionSummary] {
        guard let start = KnowledgeWorkLog.date(day), let end = Calendar.current.date(byAdding: .day, value: 1, to: start) else { return [] }
        return all.filter { session in
            harnesses.contains(session.harness) && session.modified >= start && (session.started ?? session.modified) < end
        }
    }

    /// The user's prompts of `day` in these sessions, in time order, each with the branch its
    /// project's checkout was on at that moment (`branch`; default: the checkout's reflog).
    public static func moments(_ sessions: [SessionSummary], day: String,
                               read: (SessionSummary) throws -> SessionTranscript = SessionReader.transcript,
                               branch: ((URL, Date) -> String?)? = nil) -> [Moment] {
        // A fresh history per read: a branch switched since the last read counts.
        let history = GitBranchHistory()
        let branch = branch ?? { history.branch(in: $0, at: $1) }
        var moments: [(Date, Moment)] = []
        for session in sessions {
            guard let transcript = try? read(session) else { continue }
            for item in transcript.items {
                guard case .user = item.kind, let date = item.timestamp else { continue }
                let (itemDay, time) = KnowledgeWorkLog.stamp(date)
                guard itemDay == day else { continue }
                let text = item.text.replacing(/\s+/, with: " ").trimmingCharacters(in: .whitespaces)
                guard !text.isEmpty, !text.hasPrefix("<") else { continue }
                moments.append((date, Moment(time: time, harness: session.harness.rawValue,
                                             project: session.project?.lastPathComponent ?? "-",
                                             branch: session.project.flatMap { branch($0, date) },
                                             text: String(text.prefix(promptCharacters)), source: session.file.path)))
            }
        }
        return moments.sorted { $0.0 < $1.0 }.map(\.1)
    }

    /// One slot of the day (15 or 30 minutes) with its prompts.
    public struct Slot: Sendable, Equatable {
        /// `HH:MM`, the slot's start.
        public let time: String
        public let moments: [Moment]

        /// The projects, branches and tickets of the slot, as `akit · work-log · COL-1`.
        public var places: [String] {
            var seen: [String] = []
            for moment in moments {
                let place = ([moment.project, moment.branch, moment.ticket].compactMap { $0 }).joined(separator: " · ")
                if !seen.contains(place) { seen.append(place) }
            }
            return seen
        }
    }

    /// The moments in slots of `minutes`, slots without prompts left out.
    public static func slots(_ moments: [Moment], minutes: Int) -> [Slot] {
        let size = max(5, minutes)
        var order: [Int] = [], groups: [Int: [Moment]] = [:]
        for moment in moments {
            let start = (KnowledgeWorkLog.minute(moment.time) ?? 0) / size * size
            if groups[start] == nil { order.append(start) }
            groups[start, default: []].append(moment)
        }
        return order.sorted().map { Slot(time: String(format: "%02d:%02d", $0 / 60, $0 % 60), moments: groups[$0] ?? []) }
    }

    /// The model's input: the day, the entries already in the log, and the slots with their
    /// places and prompts (cut to `maxCharacters`, an even spread kept).
    public static func input(day: String, slots: [Slot], minutes: Int, existing: [KnowledgeWorkLog.Entry]) -> String {
        func block(_ slot: Slot, perSlot: Int) -> String {
            // An even spread of at most `perSlot` prompts.
            let step = max(1, Int((Double(slot.moments.count) / Double(perSlot)).rounded(.up)))
            let kept = slot.moments.enumerated().filter { $0.offset % step == 0 }.prefix(perSlot).map(\.element)
            return "## \(slot.time) (\(minutes) min) — \(slot.places.prefix(4).joined(separator: "; "))\n"
                + kept.map { "- \($0.time) \($0.harness): \($0.text)" }.joined(separator: "\n")
        }
        var perSlot = Int.max
        var blocks = slots.map { block($0, perSlot: perSlot) }
        func size() -> Int { blocks.joined(separator: "\n\n").count + existing.reduce(0) { $0 + $1.markdown.count + 1 } }
        while size() > maxCharacters, perSlot > 1 {
            perSlot = perSlot == .max ? 8 : perSlot / 2
            blocks = slots.map { block($0, perSlot: perSlot) }
        }
        // Still too long (very many slots): every other slot goes, so the whole day stays in view.
        while size() > maxCharacters, blocks.count > 1 {
            blocks = blocks.enumerated().filter { $0.offset % 2 == 0 }.map(\.element)
        }
        let have = existing.isEmpty ? "(none)" : existing.map(\.markdown).joined(separator: "\n")
        return """
        Day: \(day). Slot length: \(minutes) minutes.

        Entries already in the work log (don't repeat them):
        \(have)

        The day in slots: start, project · git branch · ticket, then the user's prompts to coding agents:

        \(blocks.joined(separator: "\n\n"))
        """
    }

    public static let system = """
    You rebuild a developer's working day as a work log from their prompts to coding agents, given \
    in time slots with the project, git branch and ticket of each slot. Make one entry per slot \
    that has prompts; join neighbouring slots only when they are clearly the same work. Each entry \
    has the slot's start time (HH:MM), a kind and a short text (at most 15 words) in the language \
    named below: start with the ticket when there is one (COL-123), then what was solved or \
    done, and the branch in parentheses when it is not the main branch. Kinds: agent (working with an agent on code), \
    task, bug, research, reply, meeting, review, break. Use break only for a gap of more than \
    45 minutes without prompts. Each entry also has a summary: 2 to 3 sentences, in the same \
    language, of what the person did in that stretch: the problem or goal, what they tried, found \
    or decided, and the result when the prompts show it. Write only what the prompts support; no \
    guesses. Leave out times the existing entries already cover. Never put secrets, tokens or \
    personal data in the text or the summary.
    """

    /// The system prompt with the entries' language (Czech by default, the user's choice).
    public static func system(_ language: LabLanguage) -> String {
        system + " Write every entry's text in \(language.name), whatever the language of the prompts; keep ticket ids, branch names and code as they are."
    }

    public static let schema = """
    {"type":"object","properties":{"entries":{"type":"array","items":{"type":"object","properties":\
    {"time":{"type":"string"},"kind":{"type":"string"},"text":{"type":"string"},"summary":{"type":"string"}},\
    "required":["time","kind","text","summary"]}}},"required":["entries"]}
    """

    /// The proposed entries of the model's answer, checked: a valid time, a kind that can be a tag
    /// (else none), one line of text; in time order. Throws when the answer is no such JSON.
    public static func entries(fromAnswer answer: String) throws(Failure) -> [KnowledgeWorkLog.Entry] {
        guard let data = ModelCall.jsonObject(in: answer),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = object["entries"] as? [[String: Any]] else {
            throw Failure(message: "The model's answer isn't the JSON asked for ({\"entries\": [...]}); try again or pick another model.")
        }
        let entries = items.compactMap { item -> KnowledgeWorkLog.Entry? in
            guard let time = item["time"] as? String, let minute = KnowledgeWorkLog.minute(time) else { return nil }
            let kind = (try? KnowledgeWorkLog.checkedKind(item["kind"] as? String)) ?? nil
            let text = ((item["text"] as? String) ?? "").replacing(/\s+/, with: " ").trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty || kind != nil else { return nil }
            let summary = ((item["summary"] as? String) ?? "").replacing(/\s+/, with: " ").trimmingCharacters(in: .whitespaces)
            return KnowledgeWorkLog.Entry(time: String(format: "%02d:%02d", minute / 60, minute % 60), kind: kind, text: String(text.prefix(300)),
                                          summary: summary.isEmpty ? nil : String(summary.prefix(KnowledgeWorkLog.maxSummary)))
        }
        return entries.sorted { $0.minute < $1.minute }
    }

    // MARK: - Model

    /// The model by default: the first GPT-6 Luna Pi lists (GitHub Copilot on the work Mac,
    /// OpenCode Go at home), else Pi's first model.
    public static func defaultModel(available: [String]) -> String? {
        KnowledgeCheckModel.defaultModel(for: .pi, available: available)
    }

    /// Pi's thinking level when none is chosen: summaries read better with some thought than with none.
    public static let defaultThinking = "low"

    /// The models the picker offers: GitHub Copilot's when Pi lists any, else all of Pi's.
    public static func offered(_ available: [String]) -> [String] {
        let copilot = available.filter { $0.hasPrefix("github-copilot/") }
        return copilot.isEmpty ? available : copilot
    }

    /// Reads the day's prompts, asks the model, returns the proposals (nothing is written).
    /// `model` "" is the default. Throws when there are no prompts, the gate refuses or the call fails.
    public static func propose(day: String, sessions: [SessionSummary], existing: [KnowledgeWorkLog.Entry], model: String,
                               slotMinutes: Int = 30, language: LabLanguage = .czech, thinking: String = defaultThinking,
                               env: HarnessEnvironment) async throws(Failure)
        -> (entries: [KnowledgeWorkLog.Entry], prompts: Int, model: String) {
        let moments = moments(sessions, day: day)
        guard !moments.isEmpty else {
            throw Failure(message: "No prompts on \(day) in the chosen harness's sessions, so there is nothing to fill from.")
        }
        do {
            let available = await LabRuns.models(for: .pi, env: env)
            let agent = try KnowledgeCheckModel.resolved(LabAgent(harness: .pi, model: model.isEmpty ? (defaultModel(available: available) ?? "") : model,
                                                                  effort: LabHarness.pi.efforts.contains(thinking) ? thinking : defaultThinking,
                                                                  mode: .call), available: available)
            // Only sessions that gave prompts; the log's own entries are knowledge base text.
            let used = Set(moments.map(\.source))
            var origins: [SendOrigin] = sessions.filter { used.contains($0.file.path) }
                .map { SendOrigin.of(harness: $0.harness, sessionFile: $0.file) }
            if !existing.isEmpty { origins.append(.knowledgeBase) }
            let request = ModelCall.Request(agent: agent, purpose: purpose, system: system(language),
                                            input: input(day: day, slots: slots(moments, minutes: slotMinutes), minutes: slotMinutes, existing: existing), schema: schema,
                                            origins: Array(Set(origins)))
            let folder = FileManager.default.temporaryDirectory.appending(path: "akit-worklog-fill-\(UUID().uuidString)", directoryHint: .isDirectory)
            defer { try? FileManager.default.removeItem(at: folder) }
            let gate = try await SendGate.open(agent: agent, env: env)
            let answer = try await ModelCall.run(request, gate: gate, folder: folder, env: env)
            return (try entries(fromAnswer: answer.text), moments.count, agent.model)
        } catch let failure as Failure {
            throw failure
        } catch let error as KnowledgeCheckModel.Failure {
            throw Failure(message: error.message)
        } catch {
            throw Failure(message: error.localizedDescription)
        }
    }
}

/// Which branch a checkout was on at a moment, from its reflog (`checkout: moving from A to B`),
/// read once per folder. A moment before the first checkout gets that checkout's "from"; a
/// checkout without reflog its current branch. Read only; git never takes a lock here.
public final class GitBranchHistory: @unchecked Sendable {
    private let lock = NSLock()
    private var cache: [String: [(Date, String, String)]] = [:]
    private var current: [String: String] = [:]

    public init() {}

    public func branch(in folder: URL, at date: Date) -> String? {
        let (moves, now) = history(folder)
        if let last = moves.last(where: { $0.0 <= date }) { return last.2 }
        if let first = moves.first { return first.1 }
        return now
    }

    func history(_ folder: URL) -> ([(Date, String, String)], String?) {
        lock.lock()
        defer { lock.unlock() }
        if let moves = cache[folder.path] { return (moves, current[folder.path]) }
        let git = URL(filePath: "/usr/bin/git")
        let env = ["GIT_OPTIONAL_LOCKS": "0", "PATH": "/usr/bin:/bin", "HOME": NSHomeDirectory()]
        // No signatures or fsmonitor from the user's config: a plain, quick read.
        let quiet = ["-c", "log.showSignature=false", "-c", "core.fsmonitor=false"]
        let output = ProcessRunner.runAndWait(git, arguments: quiet + ["-C", folder.path, "reflog", "show", "HEAD", "--date=unix", "--format=%gd%x09%gs", "-n", "2000"],
                                              environment: env, timeout: 10)
        var moves: [(Date, String, String)] = []
        for line in (output?.succeeded == true ? output!.output : "").split(separator: "\n") {
            let parts = line.split(separator: "\t", maxSplits: 1)
            guard parts.count == 2, let stamp = parts[0].firstMatch(of: /\{(\d+)\}/), let seconds = TimeInterval(stamp.output.1),
                  let move = parts[1].firstMatch(of: /^checkout: moving from (\S+) to (\S+)$/) else { continue }
            moves.append((Date(timeIntervalSince1970: seconds), String(move.output.1), String(move.output.2)))
        }
        moves.sort { $0.0 < $1.0 }
        let head = ProcessRunner.runAndWait(git, arguments: quiet + ["-C", folder.path, "branch", "--show-current"], environment: env, timeout: 10)
        let now = head?.succeeded == true ? head!.output.trimmingCharacters(in: .whitespacesAndNewlines) : ""
        cache[folder.path] = moves
        current[folder.path] = now.isEmpty ? nil : now
        return (moves, current[folder.path])
    }
}
