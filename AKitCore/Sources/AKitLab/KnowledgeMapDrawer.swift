import AKitFoundation
import AKitKnowledge
import Foundation

/// Knowledge → Draw Map with Pi… (5.4, K21, R-AP): AKit starts Pi without a session on the
/// person's prompt plus fixed instructions: draw the map with `excalidraw-cli` (run through `npx`
/// when it isn't installed; AKit ships no Node), label blocks with the area's note names, then
/// send the draft with `akit kb propose --map AREA/NAME`. The draft arrives in the Inbox like any
/// agent's map. Pi gets the `bash`, `read` and `write` tools and none of the user's skills,
/// context files, prompt templates or extensions. The prompt goes through the sending policy
/// (origin `.knowledgeBase`: it carries the area's note names), the scrub, the monthly limit and
/// the send log (purpose `kb-draw`), as `ModelCall` does for a call without tools.
public enum KnowledgeMapDrawer {
    /// The send log's purpose.
    public static let purpose = "kb-draw"
    /// Pi's tools for the run: excalidraw-cli and akit run in bash.
    public static let tools = "bash,read,write"

    public struct Request: Sendable, Equatable {
        public var area: String
        public var name: String
        /// What the person wants on the map.
        public var prompt: String
        /// A Pi model (Settings → Knowledge check model unless the sheet picks another).
        public var agent: LabAgent

        public init(area: String, name: String, prompt: String, agent: LabAgent) {
            (self.area, self.name, self.prompt, self.agent) = (area, name, prompt, agent)
        }
    }

    public struct Outcome: Sendable {
        /// The map proposals Pi made in this run (ids), oldest first.
        public let proposals: [String]
        /// Pi's last answer, masked.
        public let answer: String?
        public let usage: SendUsage
    }

    public struct Failure: Error, LocalizedError, Sendable {
        public let message: String
        public var errorDescription: String? { message }
    }

    /// The prompt Pi gets: the person's words, then what to do with them.
    public static func prompt(_ request: Request, notes: [String], akit: String, base: URL, output: URL) -> String {
        let labels = notes.isEmpty
            ? "The area \(request.area) has no notes yet: label each block with a short name for the system it stands for."
            : "Use these note names as block labels where a block stands for one of them, exactly as written, so AKit links the block to its note: \(notes.joined(separator: ", "))."
        return """
            \(request.prompt.trimmingCharacters(in: .whitespacesAndNewlines))

            Draw this as a map for the AKit knowledge base: area \(request.area), map \(request.name).
            1. Draw it with excalidraw-cli: `excalidraw-cli create --inline '<DSL>' -o \(output.path)`. When excalidraw-cli isn't installed, run it as `npx --yes @swiftlysingh/excalidraw-cli create …`. The DSL has one arrow per line, like `[orders-api] -> "events" -> [billing]`; a block alone is `[name]`.
            2. \(labels) Name each arrow by what flows along it.
            3. Then send the draft to the user: `\(akit) kb propose --map \(request.area)/\(request.name) --file \(output.path) --reason "<one line: what the map shows>" --base \(base.path)`.
            Write no other file. Never run akit kb accept or reject: the user decides in AKit. End with one line that says what you proposed.
            """
    }

    /// `pi -p --mode json` without a session or the user's customizations, with three tools.
    public static func arguments(_ request: Request, prompt: String) -> [String] {
        ["-p", "--mode", "json", "--no-session", "--offline", "--no-skills", "--no-context-files", "--no-prompt-templates",
         "--no-extensions", "--tools", tools] + request.agent.flags + ["--", prompt]
    }

    /// Runs Pi once and returns the map proposals it made. Throws when the settings can't be read,
    /// the gate or the monthly limit refuses, Pi or akit isn't installed, Pi fails, or Pi made no
    /// map proposal. `progress` gets one line per tool Pi runs and per answer (masked).
    public static func run(_ request: Request, in base: KnowledgeBase, env: HarnessEnvironment, timeout: TimeInterval = 15 * 60,
                           progress: @escaping @Sendable (String) -> Void = { _ in }) async throws(Failure) -> Outcome {
        guard request.agent.harness == .pi else { throw Failure(message: "Draw Map runs Pi; pick a Pi model.") }
        for (what, value) in [("area", request.area), ("map name", request.name)]
        where value.isEmpty || value.hasPrefix(".") || value.contains("/") || value.contains("..") {
            throw Failure(message: "“\(value)” can't be the \(what): one folder or file name, without /, not hidden.")
        }
        guard !request.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw Failure(message: "Say what the map shows.")
        }
        guard let pi = env.findExecutable("pi") else { throw Failure(message: "Pi (pi) is not installed.") }
        guard let akit = env.findExecutable("akit") else {
            throw Failure(message: "akit isn't on the PATH, and Pi needs it to send the draft (akit kb propose). Install the command first (make install-cli).")
        }
        let gate: SendGate
        do {
            gate = try await SendGate.open(agent: request.agent, env: env)
            try gate.check(.knowledgeBase)
        } catch {
            throw Failure(message: error.localizedDescription)
        }
        let notes = ((try? base.notes()) ?? []).filter { $0.area == request.area }.map { String($0.id.split(separator: "/").last ?? "") }
        let folder = FileManager.default.temporaryDirectory.appending(path: "akit-kb-draw-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: folder) }
        do { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) } catch {
            throw Failure(message: "Couldn't make \(folder.path): \(error.localizedDescription)")
        }
        // The person's words and the note names are scrubbed; AKit's own instructions (paths of
        // this Mac, which the scrub would take for tokens) are not data.
        var scrubbed = request
        scrubbed.prompt = gate.scrub(request.prompt).text
        let text = prompt(scrubbed, notes: notes.map { gate.scrub($0).text }, akit: akit.path, base: base.root,
                          output: folder.appending(path: "\(request.name).excalidraw"))
        do {
            try SendLog.checkLimit(estimate: SendLog.estimate(characters: text.count, purpose: purpose, harness: .pi, model: request.agent.model,
                                                              records: SendLog.records(env: env)),
                                   settings: gate.settings, env: env)
        } catch {
            throw Failure(message: error.localizedDescription)
        }
        let before = Set(base.proposals().map(\.id))
        let collector = Lines()
        progress("Pi starts: \(request.agent.model.isEmpty ? "its default model" : request.agent.model)…")
        let exit = await ChildProcess.run(pi, arguments: arguments(request, prompt: text), directory: folder,
                                          environment: ChildProcess.harnessEnvironment(env), timeout: timeout) { line in
            collector.add(line)
            if let shown = liveLine(line) { progress(shown) }
        }
        var usage = SendUsage(), answer: String?, error: String?
        do {
            let read = try ModelCall.piAnswer(collector.lines)
            (usage, answer) = (read.usage, SecretFilter.masked(String(read.text.suffix(500))))
        } catch let failure as ModelCall.Failure {
            (usage, error) = (failure.usage ?? SendUsage(), failure.message)
        } catch {}
        var record = SendRecord(purpose: purpose, session: nil, runID: nil, destination: gate.destination, model: request.agent.model,
                                inputCharacters: text.count, usage: usage)
        if exit == nil { error = "Pi couldn't start." } else if exit?.cancelled == true { error = "Stopped." }
        else if exit?.timedOut == true { error = "Pi took longer than \(Int(timeout / 60)) minutes and was stopped." }
        else if exit?.succeeded != true, error == nil { error = "Pi exited with status \(exit?.status ?? -1)." }
        record.error = error
        _ = SendLog.appendAfterRun(record, env: env, out: progress)
        let made = base.proposals().filter { !before.contains($0.id) && $0.kind == .map }.map(\.id)
        if let error, made.isEmpty { throw Failure(message: error) }
        guard !made.isEmpty else {
            throw Failure(message: "Pi finished but proposed no map." + (answer.map { " Its last words: \($0)" } ?? ""))
        }
        return Outcome(proposals: made, answer: answer, usage: usage)
    }

    /// One Pi event as a line of the sheet's log: the tool it runs (a bash command's start), a
    /// failed tool, an answer. Masked; never a whole tool output.
    static func liveLine(_ line: String) -> String? {
        guard line.hasPrefix("{"), line.contains("\"tool_execution_start\"") || line.contains("\"tool_execution_end\"")
                || line.contains("\"message_end\""),
              let event = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] else { return nil }
        switch event["type"] as? String {
        case "tool_execution_start":
            let name = event["toolName"] as? String ?? "?"
            let args = event["args"] as? [String: Any] ?? [:]
            if name == "bash", let command = args["command"] as? String {
                let first = command.split(whereSeparator: \.isNewline).first.map(String.init) ?? command
                return "runs " + SecretFilter.masked(String(first.prefix(160)))
            }
            return "\(name) " + SecretFilter.masked((args["path"] as? String) ?? "")
        case "tool_execution_end":
            guard event["isError"] as? Bool == true else { return nil }
            return "\(event["toolName"] as? String ?? "a tool") failed"
        case "message_end":
            guard let message = event["message"] as? [String: Any], message["role"] as? String == "assistant" else { return nil }
            if message["stopReason"] as? String == "error" {
                return "model error: " + SecretFilter.masked(String((message["errorMessage"] as? String ?? "").prefix(200)))
            }
            let text = (message["content"] as? [[String: Any]] ?? []).filter { $0["type"] as? String == "text" }
                .compactMap { $0["text"] as? String }.joined(separator: " ")
            return text.isEmpty ? nil : "Pi: " + SecretFilter.masked(String(text.prefix(200)))
        default:
            return nil
        }
    }

    private final class Lines: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [String] = []
        func add(_ line: String) { lock.withLock { stored.append(line) } }
        var lines: [String] { lock.withLock { stored } }
    }
}
