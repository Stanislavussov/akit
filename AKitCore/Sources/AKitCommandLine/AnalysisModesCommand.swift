import AKitErrorAnalysis
import AKitFoundation
import AKitLab
import Foundation

/// `akit analysis modes|mode|route|cluster|retro|queue|bootstrap …`: the list of modes, the
/// router, clustering and the user's side of error analysis.
extension AKitCLI {
    static let analysisModesUsage = """

        Modes (~/.akit/lab/analysis/modes, a local git repository with one commit per change):
          akit analysis modes [--all] [--json]
                                          Current modes: status, kind, seen in k notes, code check rate
                                          (--all: merged and rejected too)
          akit analysis mode show ID      Definition, criteria, exemplars, notes routed to it
          akit analysis mode rename ID NAME
          akit analysis mode edit ID [--definition TEXT] [--include A;B] [--exclude A;B] [--kind failure|success|efficiency]
                                          A changed definition or criteria bumps the version and
                                          invalidates the mode's test metrics
          akit analysis mode merge ID… --into ID
          akit analysis mode split ID --into "NAME: DEFINITION" --into "NAME: DEFINITION" …
          akit analysis mode reject ID REASON  /  restore ID  /  confirm ID
          akit analysis mode scope ID general|project:ID
          akit analysis mode exemplar ID SESSION#NOTE
          akit analysis mode history      The commits of the modes repository

        The model side (each sends notes to a model: sending policy, cost estimate first):
          akit analysis route SESSION     Match a reviewed session's accepted notes to modes
          akit analysis cluster [--rebuild] [--yes]
                                          Group the notes no mode fits into candidate modes; --rebuild
                                          groups all notes from scratch to compare with the list
          akit analysis retro MODE [--yes]
                                          Route the whole note pool against one mode
          Options: --harness claude-code|pi, --model M, --effort E (default: Claude Code's settings)

        Batches (each is a Lab run; queue one with akit lab new analysis):
          akit analysis batch list [--json]
          akit analysis batch show ID [--json]
                                          Sample, per-session status, progress per step, coverage
          akit analysis batch pause ID    Stop after the current calls
          akit analysis batch resume ID [--retry-errors] [--env …]
                                          Continue from the same place (and rerun failed sessions)

        The user's side:
          akit analysis queue [--json]    What waits for you: candidates, low-confidence routes, tough
                                          calls, spot checks, seeds that may be umbrellas
          akit analysis accept SESSION#NOTE
          akit analysis reject SESSION#NOTE [--move MODE|none]
                                          Accept or reject a route; route acceptance comes from these
          akit analysis spot SESSION#NOTE agree|disagree
          akit analysis unclear SESSION#NOTE [--remove]
                                          A note you can't place: kept as a source of future modes

        Bootstrap labeling (your own notes on 30+ sessions, before you see the model's):
          akit analysis bootstrap pick [N] Reserve N (30) sessions: cluster representatives and random
          akit analysis bootstrap list [--json]
          akit analysis bootstrap label SESSION --note "STEP|QUOTE|DESCRIPTION" … [--outcome achieved|partly|no|unclear]
                              [--decisive STEP] [--observed STEP] [--done]
          akit analysis bootstrap pair SESSION [--yes]
                                          The model proposes pairs of your notes and its own
          akit analysis bootstrap confirm SESSION --pairs h1=n1,h2=n3 --agree n1,n3
          akit analysis bootstrap metrics [--json]
                                          Recall, precision, phase and step agreement, outcome agreement
                                          per notes model and prompt version
          akit analysis bootstrap first-modes [--yes]
                                          Cluster the labeled sessions' notes (yours and the model's)
                                          into the first candidate modes
          akit analysis bootstrap notes [--harness …] [--model …] [--env …]
                                          Queue the model's notes on the labeled sessions (a batch)
          akit analysis bootstrap map SESSION#hN MODE|unclear
          akit analysis bootstrap similar MODE [--yes]
                                          Find cases like your mapped notes in the pool
          akit analysis bootstrap find SESSION#NOTE MODE accept|reject
        """

    struct AnalysisOptions {
        var json: Bool
        var yes: Bool
        var harness: String?
        var model: String?
        var effort: String?

        func agent(env: HarnessEnvironment) throws -> LabAgent {
            guard let harness = LabHarness(rawValue: harness ?? "claude-code") else { throw Failure(message: "--harness is claude-code or pi.") }
            var agent = LabRuns.defaultAgent(harness, env: env)
            agent.mode = .call
            if let model { agent.model = model }
            if let effort { agent.effort = effort }
            guard harness.efforts.contains(agent.effort) else {
                throw Failure(message: "--effort for \(harness.title) is one of \(harness.efforts.joined(separator: ", ")).")
            }
            return agent
        }
    }

    /// Returns nil for a command it doesn't know.
    static func analysisModes(_ command: String, _ args: inout Arguments, options: AnalysisOptions, env: HarnessEnvironment, cwd: URL,
                              out: (String) -> Void) async throws -> Int32? {
        let store = ModeStore(env: env)
        let notesStore = NotesStore(env: env)
        func fail<T>(_ work: () async throws -> T) async throws -> T {
            do { return try await work() } catch let failure as Failure { throw failure } catch {
                throw Failure(message: error.localizedDescription)
            }
        }
        func ref(_ text: String?) throws -> NoteRef {
            guard let text, let ref = NoteRef(parsing: text) else { throw Failure(message: "Give a note as SESSION#NOTE, e.g. claude:abc#n2.") }
            return ref
        }
        switch command {
        case "modes":
            let all = args.flag("--all")
            try args.finish()
            let modes = try await fail { try await store.list() }.filter { all || $0.isCurrent }
            if options.json { out(try labJSON(modes)); return 0 }
            let seen = Matching.seen(notesStore.all(), modes: modes).byMode
            let checks = CheckStore(env: env)
            for mode in modes {
                var line = "\(mode.id)  [\(mode.status.title)] \(mode.kind.rawValue) v\(mode.version)  \(mode.name)"
                line += "  · seen in \(seen[mode.id]?.count ?? 0) notes"
                if let results = checks.load(mode.id), let check = CodeChecks.check(for: mode.id) {
                    let rate = results.rate()
                    if rate.total > 0 {
                        line += String(format: "  · %@ check %d/%d", check.kind.rawValue, rate.positive, rate.total)
                    }
                }
                if let merged = mode.mergedInto { line += "  → merged into \(merged)" }
                out(line)
            }
            return 0
        case "mode":
            return try await fail { try await modeCommand(&args, store: store, options: options, env: env, out: out) }
        case "route":
            guard let session = args.positional() else { throw Failure(message: "Which session? akit analysis route SESSION.") }
            try args.finish()
            let key = try sessionKey(session, cwd: cwd, env: env)
            guard let notes = notesStore.load(key) else { throw Failure(message: "No notes for \(session); review it first.") }
            let agent = try options.agent(env: env)
            return try await fail {
                let gate = try await SendGate.open(agent: agent, env: env)
                let modes = try await store.list()
                var exemplars: [String: [Exemplar]] = [:]
                for mode in Matching.routable(modes) { exemplars[mode.id] = try store.exemplars(of: mode.id) }
                let routed = try await Matching.route(notes, modes: modes, exemplars: exemplars, agent: agent, gate: gate, origin: notes.origin,
                                                      runID: nil, workFolder: analysisWork(env), env: env)
                for (id, route) in Matching.currentRoutes(routed).sorted(by: { $0.key < $1.key }) {
                    out("\(id) → \(route.modeID ?? "none fits") (\(String(format: "%.2f", route.confidence)))\(route.confidence < Matching.lowConfidence ? " · waits for you" : "")")
                }
                return 0
            }
        case "cluster":
            let rebuild = args.flag("--rebuild")
            try args.finish()
            let agent = try options.agent(env: env)
            return try await fail {
                let modes = try await store.list()
                let pool = notesStore.all()
                let items = rebuild ? Clustering.items(pool) : Clustering.unmatchedItems(pool, modes: modes)
                guard !items.isEmpty else { out("No notes to cluster."); return 0 }
                guard try confirmCost(characters: items.map { $0.description.count + $0.quote.count + 60 }.reduce(0, +), agent: agent,
                                      what: "Clustering \(items.count) notes", options: options, env: env, out: out) else { return 0 }
                let gate = try await SendGate.open(agent: agent, env: env)
                let candidates = try await Clustering.cluster(items, existing: modes, rejected: try await store.rejectedNames(),
                                                              rebuild: rebuild, agent: agent, gate: gate, runID: nil,
                                                              workFolder: analysisWork(env), env: env)
                if rebuild {
                    for candidate in candidates { out("\(candidate.name): \(candidate.notes.count) notes — \(candidate.definition)") }
                    let umbrellas = Clustering.umbrellas(candidates, pool: pool, modes: modes)
                    if !umbrellas.isEmpty { out("Umbrella seeds (their notes fall into several clusters): \(umbrellas.joined(separator: ", ")).") }
                    out("A rebuild only compares; nothing was saved.")
                    return 0
                }
                let created = try await Clustering.apply(candidates, store: store, env: env)
                for mode in created { out("\(mode.id) [\(mode.status.title)] \(mode.name)") }
                if created.isEmpty { out("No new candidates.") }
                return 0
            }
        case "retro":
            guard let id = args.positional() else { throw Failure(message: "Which mode? akit analysis retro MODE.") }
            try args.finish()
            let agent = try options.agent(env: env)
            return try await fail {
                guard let mode = try await store.mode(id) else { throw Failure(message: "No mode \(id).") }
                let pool = notesStore.all()
                let origins = Dictionary(pool.map { ($0.sessionKey, $0.origin) }, uniquingKeysWith: { first, _ in first })
                let parts = Matching.retroInput(mode: mode, pool: pool, origins: origins)
                guard try confirmCost(characters: parts.map(\.text.count).reduce(0, +), agent: agent,
                                      what: "Retro-matching \(parts.flatMap(\.refs).count) notes against \(mode.name)",
                                      options: options, env: env, out: out) else { return 0 }
                let gate = try await SendGate.open(agent: agent, env: env)
                let fits = try await Matching.retroMatch(mode: mode, pool: pool, origins: origins, agent: agent, gate: gate,
                                                         workFolder: analysisWork(env), env: env)
                out("\(fits.count) notes fit \(mode.name).")
                return 0
            }
        case "queue":
            try args.finish()
            return try await fail {
                let modes = try await store.list()
                let checks = modes.compactMap { CheckStore(env: env).load($0.id) }
                let queue = ReviewQueue.build(modes: modes, pool: notesStore.all(), checks: checks, book: LabelBookStore(env: env).load(),
                                              spotCheck: BatchStore(env: env).latest()?.spotCheck ?? [])
                if options.json {
                    struct QueueJSON: Encodable {
                        let candidates: [String]
                        let routes: [String]
                        let toughCalls: [String]
                        let spotChecks: [String]
                        let umbrellas: [String]
                    }
                    out(try labJSON(QueueJSON(candidates: queue.candidates.map(\.id),
                                              routes: queue.routes.map { "\($0.ref) → \($0.route.modeID ?? "none")" },
                                              toughCalls: queue.toughCalls.map { "\($0.modeID)|\($0.sessionKey)" },
                                              spotChecks: queue.spotChecks.map(\.description),
                                              umbrellas: queue.umbrellas.map(\.modeID))))
                    return 0
                }
                if queue.isEmpty { out("Nothing waits for you."); return 0 }
                for mode in queue.candidates { out("Candidate  \(mode.id): \(mode.name) — confirm, rename, merge or reject") }
                for item in queue.routes {
                    out("Route      \(item.ref) → \(item.route.modeID ?? "none fits") (\(String(format: "%.2f", item.route.confidence)))")
                }
                for call in queue.toughCalls { out("Tough call \(call.modeID) in \(call.sessionKey)") }
                for note in queue.spotChecks { out("Spot check \(note)") }
                for umbrella in queue.umbrellas {
                    out(String(format: "Umbrella?  %@ takes %.0f%% of routed notes (%d): narrow or split it", umbrella.modeID, umbrella.share * 100, umbrella.notes))
                }
                return 0
            }
        case "accept", "reject":
            let note = try ref(args.positional())
            let move = args.value("--move")
            try args.finish()
            // --move none: no mode fits; --move MODE: that mode; no --move: just rejected.
            let target: String?? = move.map { text -> String? in text == "none" ? nil : text }
            try Matching.review(note, accept: command == "accept", moveTo: target, env: env)
            let acceptance = Matching.acceptance(notesStore.all())
            out("\(command == "accept" ? "Accepted" : "Rejected") the route of \(note). Route acceptance: \(acceptance.accepted) of \(acceptance.reviewed).")
            return 0
        case "spot":
            let note = try ref(args.positional())
            guard let verdict = args.positional(), ["agree", "disagree"].contains(verdict) else { throw Failure(message: "agree or disagree?") }
            try args.finish()
            _ = try LabelBookStore(env: env).update { $0.spotChecks[note.description] = verdict == "agree" }
            out("Noted.")
            return 0
        case "unclear":
            let note = try ref(args.positional())
            let remove = args.flag("--remove")
            try args.finish()
            let unclear = UnclearNotes(env: env)
            if remove {
                _ = try unclear.remove(sessionKey: note.sessionKey, noteID: note.noteID)
            } else {
                let text = notesStore.load(note.sessionKey)?.notes.first { $0.id == note.noteID }?.description
                    ?? Bootstrap.LabelStore(env: env).load(note.sessionKey)?.notes.first { $0.id == note.noteID }?.description ?? ""
                _ = try unclear.add(UnclearNotes.Entry(sessionKey: note.sessionKey, noteID: note.noteID, text: text))
            }
            out("\(unclear.all().count) notes in the unclear bucket.")
            return 0
        case "bootstrap":
            return try await fail { try await bootstrapCommand(&args, options: options, env: env, cwd: cwd, out: out) }
        case "batch":
            return try await fail { try await batchCommand(&args, options: options, env: env, out: out) }
        default:
            return nil
        }
    }

    static func analysisWork(_ env: HarnessEnvironment) -> URL {
        AnalysisPaths(env: env).folder.appending(path: "work", directoryHint: .isDirectory)
    }

    /// Prints the "≈" cost of a call; true when it may go ahead (`--yes`).
    static func confirmCost(characters: Int, agent: LabAgent, what: String, options: AnalysisOptions, env: HarnessEnvironment,
                            out: (String) -> Void) throws -> Bool {
        let estimate = SendLog.estimate(characters: characters, harness: agent.harness, model: agent.model, records: SendLog.records(env: env))
        let cost = estimate.map { String(format: "≈ $%.2f", $0) } ?? "no estimate yet (no recorded calls of this model)"
        out("\(what): about \(characters / 1000)K characters to \(agent.label), \(cost).")
        if !options.yes { out("Run it again with --yes to send.") }
        return options.yes
    }

    private static func modeCommand(_ args: inout Arguments, store: ModeStore, options: AnalysisOptions, env: HarnessEnvironment,
                                     out: (String) -> Void) async throws -> Int32 {
        let action = args.positional()
        if action == "history" {
            try args.finish()
            for entry in try await store.history() {
                out("\(entry.date.formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false)))  \(entry.message)")
            }
            return 0
        }
        guard let id = args.positional() else { throw Failure(message: "Which mode? akit analysis modes lists them.") }
        func split(_ text: String?) -> [String]? {
            text.map { $0.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }
        }
        switch action {
        case "show":
            try args.finish()
            guard let mode = try await store.mode(id) else { throw Failure(message: "No mode \(id).") }
            if options.json { out(try labJSON(mode)); return 0 }
            var lines = ["\(mode.name) (\(mode.id), v\(mode.version))", "\(mode.status.title) · \(mode.kind.rawValue) · \(mode.origin.rawValue) · \(mode.scope)",
                         mode.definition]
            lines += mode.include.map { "  + \($0)" } + mode.exclude.map { "  − \($0)" }
            if let fix = mode.fix { lines.append("Fix: \(fix.title)") }
            lines += try store.exemplars(of: mode.id).map { "  e.g. \($0.sessionKey) #\($0.step): “\($0.quote)”" }
            let seen = Matching.seen(NotesStore(env: env).all(), modes: try await store.list()).byMode[mode.id] ?? []
            lines.append("Seen in \(seen.count) notes" + (seen.isEmpty ? "" : ": " + seen.prefix(10).map(\.description).joined(separator: ", ")))
            out(lines.joined(separator: "\n"))
        case "rename":
            guard let name = args.positional() else { throw Failure(message: "Give the new name.") }
            try args.finish()
            out("Renamed to \(try await store.rename(id, to: name).name).")
        case "edit":
            let definition = args.value("--definition")
            let include = split(args.value("--include"))
            let exclude = split(args.value("--exclude"))
            let kind = try args.value("--kind").map { text in
                guard let kind = Mode.Kind(rawValue: text) else { throw Failure(message: "--kind is failure, success or efficiency.") }
                return kind
            }
            try args.finish()
            let change = try await store.edit(id, definition: definition, include: include, exclude: exclude, kind: kind)
            for invalidation in change.invalidations { out("\(invalidation.modeID) is now v\(invalidation.version): \(invalidation.reason)") }
            if change.invalidations.isEmpty { out("Saved.") }
        case "merge":
            var ids = [id]
            let target = args.value("--into")
            while let more = args.positional() { ids.append(more) }
            try args.finish()
            guard let target else { throw Failure(message: "Merge into which mode? --into ID.") }
            _ = try await store.merge(ids, into: target)
            out("Merged \(ids.joined(separator: ", ")) into \(target).")
        case "split":
            let parts = args.values("--into")
            try args.finish()
            var taken = Set(try await store.list().map(\.id))
            let modes = try parts.map { text -> Mode in
                guard let colon = text.firstIndex(of: ":") else { throw Failure(message: "--into takes \"NAME: DEFINITION\".") }
                let name = text[..<colon].trimmingCharacters(in: .whitespaces)
                let definition = text[text.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                let slug = Clustering.slug(name, taken: taken)
                taken.insert(slug)
                return Mode(id: slug, name: name, definition: definition)
            }
            let change = try await store.split(id, into: modes)
            out("Split \(id) into \(change.modes.filter { $0.id != id }.map(\.id).joined(separator: ", ")).")
        case "reject":
            var words: [String] = []
            while let word = args.positional() { words.append(word) }
            try args.finish()
            guard !words.isEmpty else { throw Failure(message: "Why? Give a reason: it keeps the model from proposing it again.") }
            _ = try await store.reject(id, reason: words.joined(separator: " "))
            out("Rejected \(id).")
        case "restore":
            try args.finish()
            out("\(id) is \(try await store.restore(id).status.title) again.")
        case "confirm":
            try args.finish()
            let mode = try await store.confirm(id)
            out("\(mode.name) is active.")
            // A confirmed mode with a code check is checked over every indexed session at once.
            if let check = CodeChecks.check(for: mode.id) {
                let results = try CheckRunner.run([check], modeVersions: [mode.id: mode.version], env: env)
                if let rate = results.first?.rate(), rate.total > 0 { out("Its code check: \(rate.positive) of \(rate.total) indexed sessions.") }
            }
            out("Retro-matching the note pool: akit analysis retro \(mode.id)")
        case "scope":
            guard let text = args.positional() else { throw Failure(message: "general or project:ID?") }
            try args.finish()
            out("Scope: \(try await store.setScope(id, try Mode.Scope(parsing: text)).scope).")
        case "exemplar":
            let note = args.positional().flatMap(NoteRef.init(parsing:))
            try args.finish()
            guard let note, let found = NotesStore(env: env).load(note.sessionKey)?.notes.first(where: { $0.id == note.noteID }) else {
                throw Failure(message: "Give a note of a reviewed session as SESSION#NOTE.")
            }
            let exemplars = try await store.addExemplar(Exemplar(modeID: id, sessionKey: note.sessionKey, step: found.step, quote: found.quote,
                                                                 noteID: found.id),
                                                        testSessions: ValidationStore(env: env).testSessions())
            out("\(exemplars.count) exemplars.")
        default:
            throw Failure(message: "Unknown “akit analysis mode \(action ?? "")”. Run akit analysis --help.")
        }
        return 0
    }

    private static func batchCommand(_ args: inout Arguments, options: AnalysisOptions, env: HarnessEnvironment,
                                     out: (String) -> Void) async throws -> Int32 {
        let store = BatchStore(env: env)
        switch args.positional() {
        case "list":
            try args.finish()
            let batches = store.all()
            if options.json { out(try labJSON(batches)); return 0 }
            if batches.isEmpty { out("No batches. Queue one: akit lab new analysis.") }
            for batch in batches {
                let coverage = batch.coverage
                let failed = batch.sessions.filter { $0.status == .error }.count
                out("\(batch.runID)  \(coverage.done)/\(coverage.total) done\(failed > 0 ? ", \(failed) failed" : "")\(batch.paused ? ", paused" : "")"
                    + "\(batch.clustered ? ", clustered" : "")  \(batch.filter.project ?? "all projects")")
            }
        case "show":
            guard let id = args.positional(), let batch = store.load(id) else { throw Failure(message: "Which batch? akit analysis batch list.") }
            try args.finish()
            if options.json { out(try labJSON(batch)); return 0 }
            let total = batch.sessions.count
            out("Batch \(batch.runID) · \(batch.fixed ? "fixed sessions" : "sample of \(total), seed \(batch.seed)") · notes by \(batch.notesAgent.label)")
            out("Progress: notes \(batch.progress(of: "notes"))/\(total), verifier \(batch.progress(of: "verifier"))/\(total), "
                + "matching \(batch.progress(of: "matching"))/\(total), clustering \(batch.clustered ? "done" : "not yet")")
            for session in batch.sessions {
                out("  \(session.status.rawValue.padding(toLength: 8, withPad: " ", startingAt: 0)) \(session.pick.sessionKey)  π=\(String(format: "%.2f", session.pick.inclusion)) \(session.pick.sampling)"
                    + (session.message.map { "  — \($0)" } ?? ""))
            }
            if !batch.candidates.isEmpty { out("Candidates: \(batch.candidates.joined(separator: ", "))") }
        case "pause":
            guard let id = args.positional() else { throw Failure(message: "Which batch?") }
            try args.finish()
            try Batches.pause(id, env: env)
            out("Batch \(id) stops after its current calls.")
        case "resume":
            guard let id = args.positional() else { throw Failure(message: "Which batch?") }
            let retry = args.flag("--retry-errors")
            let environment = try labEnvironment(args.value("--env"), env: env)
            try args.finish()
            let run = try await Batches.resume(id, retryErrors: retry, environment: environment, akit: ownExecutable, env: env)
            out("Queued \(run.id): \(run.spec.title).")
            _ = try? await LabQueue.startNext(env: env)
        case let other:
            throw Failure(message: "Unknown “akit analysis batch \(other ?? "")”. Run akit analysis --help.")
        }
        return 0
    }

    private static func bootstrapCommand(_ args: inout Arguments, options: AnalysisOptions, env: HarnessEnvironment, cwd: URL,
                                         out: (String) -> Void) async throws -> Int32 {
        let labels = Bootstrap.LabelStore(env: env)
        let reservations = BootstrapReservations(env: env)
        switch args.positional() {
        case "pick":
            let count = try positiveNumber(args.positional(), "N") ?? Bootstrap.minimumSessions
            try args.finish()
            let entries = try Bootstrap.pick(count: count, env: env)
            out("Reserved \(entries.count) sessions for labeling. They stay out of reviews and batches until you label them.")
        case "list":
            try args.finish()
            let entries = reservations.all()
            if options.json { out(try labJSON(entries)); return 0 }
            for entry in entries {
                let label = labels.load(entry.sessionKey)
                let state = entry.labeledAt != nil ? "labeled" : (label == nil ? "to label" : "draft")
                out("\(entry.sessionKey)  \(state)  \(label?.notes.count ?? 0) notes")
            }
            let done = entries.filter { $0.labeledAt != nil }.count
            out("\(done) of \(entries.count) labeled (at least \(Bootstrap.minimumSessions) are needed).")
        case "label":
            guard let session = args.positional() else { throw Failure(message: "Which session?") }
            let notes = args.values("--note")
            let outcome = try args.value("--outcome").map { text in
                guard let outcome = Outcome(rawValue: text) else { throw Failure(message: "--outcome is achieved, partly, no or unclear.") }
                return outcome
            }
            let decisive = try args.value("--decisive").map { try positiveNumber($0, "--decisive") ?? 0 }
            let observed = try args.value("--observed").map { try positiveNumber($0, "--observed") ?? 0 }
            let done = args.flag("--done")
            try args.finish()
            let key = try sessionKey(session, cwd: cwd, env: env)
            guard let entry = reservations.all().first(where: { $0.sessionKey == key }) else {
                throw Failure(message: "\(key) isn't reserved for the bootstrap (akit analysis bootstrap list).")
            }
            var label = labels.load(key) ?? Bootstrap.Label(sessionKey: key, transcript: entry.transcript)
            for text in notes {
                let parts = text.split(separator: "|", maxSplits: 2).map(String.init)
                guard parts.count == 3, let step = Int(parts[0]) else { throw Failure(message: "--note is \"STEP|QUOTE|DESCRIPTION\".") }
                label.notes.append(Note(id: "", source: .human, description: parts[2], step: step, quote: parts[1]))
            }
            if let outcome { label.outcome = outcome }
            if let decisive { label.deviation.decisiveStep = decisive }
            if let observed { label.deviation.observedStep = observed }
            if done { label.labeledAt = .now }
            try labels.save(label, items: try? Bootstrap.items(transcript: entry.transcript, sessionKey: key, env: env))
            out("\(key): \(label.notes.count) notes\(done ? ", finished" : ", draft").")
        case "pair":
            guard let session = args.positional() else { throw Failure(message: "Which session?") }
            try args.finish()
            let key = try sessionKey(session, cwd: cwd, env: env)
            guard let label = labels.load(key), label.labeledAt != nil else { throw Failure(message: "Finish labeling \(key) first.") }
            guard let notes = NotesStore(env: env).load(key) else {
                throw Failure(message: "The model hasn't reviewed \(key) yet: akit lab new review \(key) (it's allowed once you've labeled it).")
            }
            let agent = try options.agent(env: env)
            guard try confirmCost(characters: (label.notes + notes.notes).map { $0.description.count + $0.quote.count + 40 }.reduce(0, +),
                                  agent: agent, what: "Pairing \(label.notes.count) of your notes with \(notes.notes.count) of the model's",
                                  options: options, env: env, out: out) else { return 0 }
            let gate = try await SendGate.open(agent: agent, env: env)
            let pairing = try await Bootstrap.proposePairs(label: label, notes: notes, agent: agent, gate: gate, origin: notes.origin,
                                                           workFolder: analysisWork(env), env: env)
            for pair in pairing.proposed { out("\(pair.human) ↔ \(pair.model)") }
            out("Confirm with: akit analysis bootstrap confirm \(key) --pairs \(pairing.proposed.map { "\($0.human)=\($0.model)" }.joined(separator: ",")) --agree …")
        case "confirm":
            guard let session = args.positional() else { throw Failure(message: "Which session?") }
            let pairsText = args.value("--pairs") ?? ""
            let agreeText = args.value("--agree") ?? ""
            try args.finish()
            let key = try sessionKey(session, cwd: cwd, env: env)
            let pairingStore = Bootstrap.PairingStore(env: env)
            guard var pairing = pairingStore.load(key) else { throw Failure(message: "No proposed pairs for \(key): akit analysis bootstrap pair \(key).") }
            pairing.confirmed = try pairsText.split(separator: ",").map { text in
                let parts = text.split(separator: "=").map(String.init)
                guard parts.count == 2 else { throw Failure(message: "--pairs is h1=n1,h2=n3.") }
                return Bootstrap.Pairing.Pair(human: parts[0], model: parts[1])
            }
            pairing.agreed = agreeText.split(separator: ",").map(String.init)
            try pairingStore.save(pairing)
            out("Confirmed \(pairing.confirmed?.count ?? 0) pairs.")
        case "metrics":
            try args.finish()
            let all = labels.all()
            let metrics = Bootstrap.metrics(labels: all, notes: NotesStore(env: env).all(), pairings: Bootstrap.PairingStore(env: env).all(),
                                            phases: Bootstrap.phases(of: all))
            if options.json { out(try labJSON(metrics)); return 0 }
            if metrics.isEmpty { out("No confirmed pairings yet.") }
            func pct(_ value: Double?) -> String { value.map { String(format: "%.0f%%", $0 * 100) } ?? "—" }
            for m in metrics {
                out("\(m.notesVersion) (\(m.sessions) sessions): recall \(pct(m.recall)) (\(m.recallCounts[0])/\(m.recallCounts[1])), "
                    + "precision \(pct(m.precision)) (\(m.precisionCounts[0])/\(m.precisionCounts[1])), "
                    + "decisive step: phase \(pct(m.phaseAgreement)), ±3 steps \(pct(m.stepAgreement)), outcome \(pct(m.outcomeAgreement))")
            }
            let store = ModeStore(env: env)
            let since = Bootstrap.sessionsSinceLastModeChange(all, lastChange: try await store.history(limit: 1).first?.date)
            out("\(since) labeled sessions since the list of modes last changed (stop after \(Bootstrap.stopAfter)).")
        case "first-modes":
            try args.finish()
            let agent = try options.agent(env: env)
            let all = labels.all().filter { $0.labeledAt != nil }
            guard !all.isEmpty else { throw Failure(message: "Label some sessions first.") }
            let store = ModeStore(env: env)
            let pool = NotesStore(env: env).all()
            guard try confirmCost(characters: all.flatMap(\.notes).map { $0.description.count + $0.quote.count + 60 }.reduce(0, +) * 2,
                                  agent: agent, what: "Clustering the notes of \(all.count) labeled sessions", options: options, env: env,
                                  out: out) else { return 0 }
            let gate = try await SendGate.open(agent: agent, env: env)
            let candidates = try await Bootstrap.firstModes(labels: all, pool: pool, existing: try await store.list(),
                                                            rejected: try await store.rejectedNames(), agent: agent, gate: gate,
                                                            workFolder: analysisWork(env), env: env)
            let created = try await Clustering.apply(candidates, store: store, env: env)
            for mode in created { out("\(mode.id) [\(mode.status.title)] \(mode.name)") }
            out("Confirm or edit them, then map your notes: akit analysis bootstrap map SESSION#hN MODE.")
        case "notes":
            let environment = try labEnvironment(args.value("--env"), env: env)
            try args.finish()
            let done = reservations.all().filter { $0.labeledAt != nil }
            guard !done.isEmpty else { throw Failure(message: "Finish labeling some sessions first.") }
            var agent = try options.agent(env: env)
            agent.mode = .call
            let run = try await Batches.newFixed(sessions: done.map { ($0.sessionKey, $0.transcript) },
                                                 title: "Bootstrap: model notes on \(done.count) labeled sessions", notesAgent: agent,
                                                 environment: environment, akit: ownExecutable, env: env)
            out("Queued \(run.id) (\(run.spec.environment.title)). Then pair them: akit analysis bootstrap pair SESSION.")
            _ = try? await LabQueue.startNext(env: env)
        case "map":
            let note = args.positional().flatMap(NoteRef.init(parsing:))
            let mode = args.positional()
            try args.finish()
            guard let note, let mode else { throw Failure(message: "akit analysis bootstrap map SESSION#hN MODE|unclear.") }
            if mode != LabelBook.unclear, try await ModeStore(env: env).mode(mode) == nil { throw Failure(message: "No mode \(mode).") }
            _ = try LabelBookStore(env: env).update { $0.mapping[note.description] = mode }
            out("Mapped \(note) to \(mode).")
        case "similar":
            guard let id = args.positional() else { throw Failure(message: "Which mode?") }
            try args.finish()
            let agent = try options.agent(env: env)
            guard let mode = try await ModeStore(env: env).mode(id) else { throw Failure(message: "No mode \(id).") }
            let pool = NotesStore(env: env).all()
            guard try confirmCost(characters: Clustering.items(pool).map { $0.description.count + $0.quote.count + 60 }.reduce(0, +),
                                  agent: agent, what: "Searching the pool for cases of \(mode.name)", options: options, env: env,
                                  out: out) else { return 0 }
            let gate = try await SendGate.open(agent: agent, env: env)
            let finds = try await Bootstrap.findSimilar(mode: mode, labels: labels.all(), pool: pool, book: LabelBookStore(env: env).load(),
                                                        agent: agent, gate: gate, workFolder: analysisWork(env), env: env)
            for find in finds { out("\(find.ref)  — akit analysis bootstrap find \(find.ref) \(id) accept|reject") }
            if finds.isEmpty { out("No similar cases found.") }
        case "find":
            let note = args.positional().flatMap(NoteRef.init(parsing:))
            let mode = args.positional()
            let verdict = args.positional()
            try args.finish()
            guard let note, let mode, let verdict, ["accept", "reject"].contains(verdict) else {
                throw Failure(message: "akit analysis bootstrap find SESSION#NOTE MODE accept|reject.")
            }
            _ = try LabelBookStore(env: env).update { book in
                guard let index = book.finds.firstIndex(where: { $0.ref == note && $0.modeID == mode }) else {
                    throw Failure(message: "No such find.")
                }
                book.finds[index].accepted = verdict == "accept"
            }
            out("Noted.")
        case let other:
            throw Failure(message: "Unknown “akit analysis bootstrap \(other ?? "")”. Run akit analysis --help.")
        }
        return 0
    }
}
