import AKitBrain
import AKitFoundation
import AKitKnowledge
import Foundation

/// Knowledge → Ask Pi (K30): questions about one note to the user's own Pi, with their own setup
/// (MCP servers, skills such as `/akit-context`, context files), so it can look things up in the
/// base and in other systems. Each question is one `pi -p --mode json` that forks the last good
/// answer's session, so Pi keeps the thread; a failed or stopped answer is never forked. Pi may
/// read and run commands but not use its `edit` and `write` tools (`--exclude-tools edit,write`).
/// The prompt goes through the sending policy (origin `.knowledgeBase`) and the scrub, its usage
/// to the send log (purpose `knowledge-ask`).
///
/// A chat lives outside the base's git: `~/.akit/local/knowledge-ask/<base>/<chat id>/` with
/// `chat.json` (the note and the working folder), `chat.jsonl` (one masked entry per question),
/// `sessions/` (Pi's), `streams/` (the masked json stream of each answer) and `system.md`.
public enum KnowledgeAsk {
    /// The send log's purpose.
    public static let purpose = "knowledge-ask"
    /// The tools Pi may not use here: it reads, it doesn't change files.
    static let excludedTools = "edit,write"

    public struct Failure: Error, LocalizedError, Sendable {
        public let message: String
        /// The question went to Pi (it answered, but the chat couldn't be saved): not to be asked again as it is.
        public var sent = false
        public var errorDescription: String? { message }
        public init(message: String, sent: Bool = false) { (self.message, self.sent) = (message, sent) }
    }

    /// The note a chat is about.
    public struct Note: Codable, Sendable, Hashable {
        /// The base's name (its world) and folder.
        public var base: String
        public var baseRoot: String
        /// `payments/orders-api`.
        public var id: String
        /// `areas/payments/orders-api.md`.
        public var path: String
        public var title: String

        public init(base: String, baseRoot: String, id: String, path: String, title: String) {
            (self.base, self.baseRoot, self.id, self.path, self.title) = (base, baseRoot, id, path, title)
        }
    }

    /// One chat about one note (`chat.json`).
    public struct Chat: Codable, Sendable, Hashable, Identifiable {
        /// `20261031-091500-1a2b`: sorts by time.
        public var id: String
        public var note: Note
        /// Where Pi runs: the space's project folder, else the base folder.
        public var cwd: String
        public var created: Date
        /// The chat's folder (not stored).
        public var folder: URL { URL(filePath: folderPath, directoryHint: .isDirectory) }
        var folderPath = ""

        enum CodingKeys: String, CodingKey { case id, note, cwd, created }
    }

    /// One question and its answer (`chat.jsonl`), masked.
    public struct Entry: Codable, Sendable, Hashable, Identifiable {
        /// `q1`, `q2`, … in the order they were asked.
        public var id: String
        public var question: String
        /// The passage of the note the question is about, when asked from one.
        public var passage: String?
        public var asked: Date
        public var answered: Date?
        public var answer: String?
        public var error: String?
        /// Pi's session of the answer: the next question forks it.
        public var session: String?
        /// The proposals (`inbox/<id>.md`) Pi made in this answer (K32), for their cards.
        public var proposals: [ProposalRef]?
        /// The answer can be forked: it has a session and no error.
        public var isGood: Bool { session != nil && error == nil }

        public init(id: String, question: String, passage: String? = nil, asked: Date, answered: Date? = nil, answer: String? = nil,
                    error: String? = nil, session: String? = nil, proposals: [ProposalRef]? = nil) {
            (self.id, self.question, self.passage, self.asked, self.answered) = (id, question, passage, asked, answered)
            (self.answer, self.error, self.session, self.proposals) = (answer, error, session, proposals)
        }
    }

    /// A proposal of an answer: its id and its `created` time. Ids are reused once a proposal has
    /// left `inbox/`, so the card follows the one made at that time (`state(ofProposal:created:)`).
    /// Reads the plain id strings of chats saved before (created nil).
    public struct ProposalRef: Codable, Sendable, Hashable {
        public var id: String
        public var created: String?

        public init(id: String, created: String?) { (self.id, self.created) = (id, created) }

        public init(from decoder: any Decoder) throws {
            if let id = try? decoder.singleValueContainer().decode(String.self) {
                (self.id, created) = (id, nil)
                return
            }
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(String.self, forKey: .id)
            created = try container.decodeIfPresent(String.self, forKey: .created)
        }
    }

    // MARK: - Storage

    /// `~/.akit/local/knowledge-ask/<base>`.
    public static func folder(base: String, env: HarnessEnvironment) -> URL {
        let name = base.replacingOccurrences(of: "/", with: "-")
        return env.homeDirectory.appending(path: ".akit/local/knowledge-ask/\(name.isEmpty ? "base" : name)", directoryHint: .isDirectory)
    }

    /// A new chat about `note`, run in `cwd`: its folder and `chat.json`.
    public static func newChat(note: Note, cwd: URL, env: HarnessEnvironment, now: Date = .now) throws(Failure) -> Chat {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let id = formatter.string(from: now) + "-" + UUID().uuidString.prefix(4).lowercased()
        var chat = Chat(id: id, note: note, cwd: cwd.path, created: now)
        chat.folderPath = folder(base: note.base, env: env).appending(path: id).path
        do {
            try FileManager.default.createDirectory(at: chat.folder.appending(path: "sessions"), withIntermediateDirectories: true)
            try encoder.encode(chat).write(to: chat.folder.appending(path: "chat.json"), options: .atomic)
        } catch {
            throw Failure(message: "Couldn't make the chat folder \(chat.folder.path): \(error.localizedDescription)")
        }
        return chat
    }

    /// The chats of a base, newest first.
    public static func chats(base: String, env: HarnessEnvironment) -> [Chat] {
        FileWalk.children(of: folder(base: base, env: env))
            .compactMap { folder -> Chat? in
                guard let data = try? Data(contentsOf: folder.appending(path: "chat.json")),
                      var chat = try? decoder.decode(Chat.self, from: data) else { return nil }
                chat.folderPath = folder.path
                return chat
            }
            .sorted { ($0.created, $0.id) > ($1.created, $1.id) }
    }

    /// The newest chat about the note `id` of the base, for the panel on reopen.
    public static func latestChat(note id: String, base: String, env: HarnessEnvironment) -> Chat? {
        chats(base: base, env: env).first { $0.note.id == id }
    }

    /// The chat's questions and answers, oldest first.
    public static func entries(_ chat: Chat) -> [Entry] {
        guard let data = try? Data(contentsOf: chat.folder.appending(path: "chat.jsonl")) else { return [] }
        return data.split(separator: 0x0A).compactMap { try? decoder.decode(Entry.self, from: Data($0)) }
    }

    static func append(_ entry: Entry, to chat: Chat) throws {
        var line = try encoder.encode(entry)
        line.append(0x0A)
        let url = chat.folder.appending(path: "chat.jsonl")
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: line)
        } else {
            try line.write(to: url)
        }
    }

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    // MARK: - What Pi gets

    /// Where Pi runs: the first project of the space's `area.yaml` that is a folder on this Mac
    /// (a `~/` or absolute path, not a glob; or a remote whose local copy `copies` knows), else
    /// the base folder.
    public static func workingFolder(area: KnowledgeArea, baseRoot: URL, home: URL, copies: [String: URL] = [:]) -> URL {
        for project in area.projects where !project.contains("*") {
            if let url = KnowledgeLocal.url(project, home: home) {
                if FileWalk.isDirectory(url) { return url }
            } else if let id = ProjectRecords.normalizedRemote(project), let copy = copies[id], FileWalk.isDirectory(copy) {
                return copy
            }
        }
        return baseRoot
    }

    /// The text appended to Pi's system prompt (`system.md`).
    static func systemPrompt(_ note: Note) -> String {
        """
        You answer questions in AKit about a note of the user's knowledge base.
        The knowledge base "\(note.base)" is the folder \(note.baseRoot); the note is \(note.id) (\(note.path)).
        Read the note, the rest of the base (akit kb search, akit kb show, or the files) and other systems \
        (the user's MCP servers, repositories, documentation) with your tools when the answer needs them.
        Never edit, write, move or delete files yourself, and don't commit: not in the base and not anywhere else. Create or \
        update nothing in other systems either (no tickets, comments or messages).
        The one change you may make: when the user asks to change, fix or add something in the knowledge base (or you find \
        the note wrong and the user agrees), propose it with akit kb propose; the user sees the diff and accepts or rejects it. \
        Keep the quotes around the base folder. \
        For a note: akit kb propose --base \(quoted(note.baseRoot)) --author pi --note AREA/NAME --stdin --reason "why", the text on \
        stdin: for an existing note, the changed sections as whole `## Heading` blocks (each replaces the section with that \
        heading, or is added at the end); for a new note, its whole text. --set KEY=VALUE changes one frontmatter field. For an arrow on a map: akit kb propose --base \(quoted(note.baseRoot)) --author pi \
        --arrow "A -kind-> B" --reason "why". Say in your answer what you proposed.
        Answer in the language of the question, short and to the point; say where a fact comes from.
        """
    }

    /// The prompt of one question. The first carries the base, the note and its whole text, or
    /// only the passage and the note's path when asked from a passage; a follow-up carries the
    /// question (and its passage): Pi has the thread through the fork.
    static func prompt(question: String, passage: String?, note: Note, noteText: String, first: Bool) -> String {
        let question = question.trimmingCharacters(in: .whitespacesAndNewlines)
        let quoted = passage.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.flatMap { $0.isEmpty ? nil : $0 }
            .map { $0.split(separator: "\n", omittingEmptySubsequences: false).map { "> " + $0 }.joined(separator: "\n") }
        guard first else {
            return quoted.map { "About this passage of the note \(note.id):\n\n\($0)\n\n\(question)" } ?? question
        }
        var text = """
            The knowledge base "\(note.base)" is at \(note.baseRoot).
            The note: \(note.id), file \(note.path), title "\(note.title)".
            """
        if let quoted {
            text += "\n\nMy question is about this passage of the note (read the whole note at \(note.path) when you need it):\n\n\(quoted)"
        } else {
            text += "\n\nThe note's text:\n\n<note>\n\(noteText)\n</note>"
        }
        return text + "\n\nMy question: \(question)"
    }

    /// The session file the next question forks: the last good answer's; nil for the first.
    /// Throws when that session file is gone.
    static func fork(_ chat: Chat, entries: [Entry]) throws(Failure) -> URL? {
        guard let last = entries.last(where: \.isGood), let session = last.session else { return nil }
        guard let file = PiJSONStream.sessionFile(id: session, in: chat.folder.appending(path: "sessions")) else {
            throw Failure(message: "The Pi session of \(last.id) is gone from \(chat.folder.path)/sessions, so Pi can't go on with the thread. Start a New Chat.")
        }
        return file
    }

    /// Pi's options (before the prompt): the fork, the chat's sessions folder, the model and
    /// thinking, no edit or write tool, and the system prompt file. The user's skills,
    /// extensions, MCP servers and context files stay on.
    static func options(chat: Chat, fork: URL?, agent: LabAgent) -> [String] {
        var options: [String] = []
        if let fork { options += ["--fork", fork.path] }
        options += ["--session-dir", chat.folder.appending(path: "sessions").path]
        if !agent.model.isEmpty { options += ["--model", agent.model] }
        if !agent.effort.isEmpty { options += ["--thinking", agent.effort] }
        options += ["--exclude-tools", excludedTools, "--append-system-prompt", chat.folder.appending(path: "system.md").path]
        return options
    }

    // MARK: - Asking

    /// One question to Pi in `chat`: the gate (origin `.knowledgeBase`), `confirm` with the
    /// destination (false: not sent), then Pi in the chat's folder, its answer recorded (masked)
    /// and its usage logged. Throws when nothing was asked (empty question, no Pi, the gate,
    /// not confirmed); a failed or stopped answer is recorded with its error and returned.
    /// Stop: cancel the caller's `Cancellation` scope.
    public static func ask(_ question: String, passage: String? = nil, noteText: String, in chat: Chat, agent: LabAgent,
                           env: HarnessEnvironment, timeout: TimeInterval = 15 * 60,
                           confirm: @Sendable (SendDestination) async -> Bool = { _ in true },
                           progress: @escaping @Sendable (String) -> Void = { _ in }) async throws(Failure) -> Entry {
        let body = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { throw Failure(message: "Write the question first.") }
        guard agent.harness == .pi else { throw Failure(message: "Ask Pi runs Pi; pick a Pi model.") }
        guard let pi = env.findExecutable("pi") else {
            throw Failure(message: "Pi (pi) is not installed, or AKit can't find it on the PATH. Install Pi, then ask again.")
        }
        let earlier = entries(chat)
        let fork = try fork(chat, entries: earlier)
        let gate: SendGate
        let cwd = URL(filePath: chat.cwd, directoryHint: .isDirectory)
        do {
            gate = try await SendGate.open(agent: agent, env: env)
            try gate.check(.knowledgeBase)
        } catch {
            throw Failure(message: error.localizedDescription)
        }
        // On a work Mac Pi in a project folder reads that project's code: it may go only where
        // repository code may (the allowed list).
        if gate.isWork, !runsInBase(cwd, chat: chat), !gate.decide(.code(.pi)).allowed {
            throw Failure(message: "Not sent: this is a work Mac, and Pi would run in the space's project folder \(chat.cwd), so the project's code "
                + "could reach \(gate.destination.label), which isn't on the allowed list. Pick a Pi model whose provider is on the list "
                + "(Settings → Sending policy), or ask about a note whose space has no project folder.")
        }
        if Cancellation.isCancelled { throw Failure(message: "Stopped.") }
        guard await confirm(gate.destination) else { throw Failure(message: "Not sent.") }
        if Cancellation.isCancelled { throw Failure(message: "Stopped.") }

        let scrubbed = gate.scrub(prompt(question: body, passage: passage, note: chat.note, noteText: noteText, first: fork == nil))
        let number = earlier.count + 1
        var entry = Entry(id: "q\(number)", question: SecretFilter.masked(body), passage: passage.map(SecretFilter.masked), asked: .now)
        do {
            try Data(systemPrompt(chat.note).utf8).write(to: chat.folder.appending(path: "system.md"), options: .atomic)
            try FileManager.default.createDirectory(at: chat.folder.appending(path: "streams"), withIntermediateDirectories: true)
        } catch {
            throw Failure(message: "Couldn't write to \(chat.folder.path): \(error.localizedDescription)")
        }
        let arguments = ["-p", "--mode", "json", "--offline"] + options(chat: chat, fork: fork, agent: agent) + ["--", scrubbed.text]
        let environment = PiJSONStream.shellEnvironment(await LoginShell.variables(in: env), env: env)
        let base = KnowledgeBase(root: URL(filePath: chat.note.baseRoot, directoryHint: .isDirectory))
        let before = base.proposalIDs()
        progress("Pi is reading the question…")
        let (output, stream) = await run(pi, arguments: arguments, directory: FileWalk.isDirectory(cwd) ? cwd : chat.folder, environment: environment,
                               timeout: timeout, stream: chat.folder.appending(path: "streams/q\(number).jsonl"), progress: progress)
        entry.answered = .now
        entry.session = output.session
        entry.answer = output.answer.map(SecretFilter.masked)
        entry.error = output.error ?? (output.answer == nil ? "Pi gave no answer." : nil)
        let made = proposals(in: base, before: before, stream: stream)
        entry.proposals = made.isEmpty ? nil : made
        // Logged whenever Pi started, also when it was stopped or timed out: the prompt went out.
        if output.started {
            let system = systemPrompt(chat.note).count
            _ = SendLog.appendAfterRun(SendRecord(purpose: purpose, session: output.session, runID: chat.id, destination: gate.destination,
                                                  model: agent.model, inputCharacters: scrubbed.text.count + system,
                                                  systemCharacters: system, usage: output.usage,
                                                  scrubbed: scrubbed.counts.isEmpty ? nil : scrubbed.counts),
                                       env: env, out: { _ in })
        }
        do { try append(entry, to: chat) } catch {
            throw Failure(message: "Pi answered, but AKit couldn't save the chat: \(error.localizedDescription)", sent: true)
        }
        return entry
    }

    /// Runs one `pi -p --mode json` (`PiJSONStream.run`, the stream masked as JSON), with a short
    /// progress line per tool call; also every line, for finding the answer's proposals.
    static func run(_ pi: URL, arguments: [String], directory: URL, environment: [String: String], timeout: TimeInterval,
                    stream: URL, progress: @escaping @Sendable (String) -> Void) async -> (PiJSONStream.Output, [String]) {
        await PiJSONStream.run(pi, arguments: arguments, directory: directory, environment: environment, timeout: timeout, stream: stream,
                               timeoutMessage: "Pi took longer than \(Int(timeout / 60)) minutes and was stopped.") { line in
            if let step = progressLine(line) { progress(step) }
        }
    }

    /// Pi runs in the base folder itself (no project folder of the space).
    static func runsInBase(_ cwd: URL, chat: Chat) -> Bool {
        cwd.standardizedFileURL.path == URL(filePath: chat.note.baseRoot, directoryHint: .isDirectory).standardizedFileURL.path
    }

    /// The proposals Pi made in one answer (K32): read only from the output of its own `bash`
    /// calls that ran `kb propose` (the printed `inbox/<id>.md` path, plain or `--json`), and only
    /// ids whose file is new in `inbox/` since the question was sent. So another session's
    /// proposal, or one an `akit kb inbox` in the same answer lists, never shows.
    static func proposals(in base: KnowledgeBase, before: Set<String>, stream: [String]) -> [ProposalRef] {
        let printed = proposeOutputIDs(stream)
        let new = base.proposalIDs().subtracting(before)
        return printed.filter(new.contains).sorted().map { id in
            ProposalRef(id: id, created: try? base.proposal(id).created)
        }
    }

    /// The ids `akit kb propose` printed in this stream: the result of each `bash` call whose
    /// command runs `kb propose`, matched by its call id (else the next `bash` result).
    static func proposeOutputIDs(_ stream: [String]) -> Set<String> {
        var calls = Set<String>()
        var unnamed = 0
        var ids = Set<String>()
        for line in stream where line.hasPrefix("{") && line.contains("tool_execution_") {
            guard let event = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
                  event["toolName"] as? String == "bash" else { continue }
            let call = event["toolCallId"] as? String
            switch event["type"] as? String {
            case "tool_execution_start":
                let command = (event["args"] as? [String: Any])?["command"] as? String ?? ""
                guard command.contains("kb propose") else { continue }
                if let call { calls.insert(call) } else { unnamed += 1 }
            case "tool_execution_end":
                if let call {
                    guard calls.remove(call) != nil else { continue }
                } else {
                    guard unnamed > 0 else { continue }
                    unnamed -= 1
                }
                guard event["isError"] as? Bool != true else { continue }
                let text = resultText(event["result"])
                for match in text.matches(of: /inbox\/([^\s"\/\\]+)\.md/) { ids.insert(String(match.output.1)) }
            default:
                break
            }
        }
        return ids
    }

    /// A tool result's text: its text parts, or the value itself when it is a string.
    static func resultText(_ value: Any?) -> String {
        if let text = value as? String { return text }
        let parts = ((value as? [String: Any])?["content"] as? [[String: Any]]) ?? (value as? [[String: Any]]) ?? []
        return parts.compactMap { $0["text"] as? String }.joined(separator: "\n")
    }

    /// What Pi does now, from one event: a tool call (with its command or path, cut and masked),
    /// or the answer being written.
    static func progressLine(_ line: String) -> String? {
        guard line.hasPrefix("{"), let event = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] else { return nil }
        switch event["type"] as? String {
        case "tool_execution_start":
            let name = event["toolName"] as? String ?? "a tool"
            let args = event["args"] as? [String: Any] ?? [:]
            let detail = (args["command"] as? String) ?? (args["path"] as? String) ?? (args["query"] as? String) ?? (args["pattern"] as? String)
            let shown = detail.map { " " + SecretFilter.masked(String($0.replacingOccurrences(of: "\n", with: " ").prefix(100))) } ?? ""
            return "Runs \(name)\(shown)"
        case "message_start":
            guard (event["message"] as? [String: Any])?["role"] as? String == "assistant" else { return nil }
            return "Pi is thinking and writing…"
        default:
            return nil
        }
    }

    // MARK: - Open in Pi

    /// `open.command` in the chat: interactive Pi in the chat's folder, forking the last good
    /// answer, with the same options as the questions. Throws when there is no answer to go on from.
    public static func openScript(_ chat: Chat, agent: LabAgent, env: HarnessEnvironment) throws(Failure) -> URL {
        guard let pi = env.findExecutable("pi") else { throw Failure(message: "Pi (pi) is not installed.") }
        guard let fork = try fork(chat, entries: entries(chat)) else {
            throw Failure(message: "Ask a question first: Open in Pi goes on from Pi's last answer.")
        }
        let text = """
            #!/bin/sh
            # Ask Pi in AKit, continued in the terminal. Written by AKit; it writes it again each time.
            cd \(quoted(chat.cwd)) || exit 1
            printf '%s\\n' \(quoted("AKit: Pi goes on with your questions about \(chat.note.id.filter { !$0.isNewline })."))
            exec \(quoted(pi.path)) \(options(chat: chat, fork: fork, agent: agent).map(quoted).joined(separator: " "))

            """
        let url = chat.folder.appending(path: "open.command")
        do {
            try Data(systemPrompt(chat.note).utf8).write(to: chat.folder.appending(path: "system.md"), options: .atomic)
            try Data(text.utf8).write(to: url)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        } catch {
            throw Failure(message: "Couldn't write \(url.path): \(error.localizedDescription)")
        }
        return url
    }

    static func quoted(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
