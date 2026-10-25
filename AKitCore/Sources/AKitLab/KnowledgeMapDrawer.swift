import AKitFoundation
import AKitKnowledge
import Foundation

/// Knowledge → Draw Map with Pi… (5.4, K21, R-AP): Pi only writes the map's text, AKit draws and
/// proposes it. One `ModelCall` (Pi with no tools, no session, none of the user's skills, context
/// files or prompt templates; through the sending policy with origin `.knowledgeBase`, the scrub,
/// the monthly limit and the send log, purpose `kb-draw`) gets the person's words and the area's
/// note names and answers with excalidraw-cli's DSL. AKit then runs excalidraw-cli itself, without
/// a shell (`excalidraw-cli` when it is on the PATH, else `npx --yes @swiftlysingh/excalidraw-cli`;
/// AKit ships no Node), and puts the draft in the Inbox with `propose(.map …)`, in this process.
/// The person accepts or rejects it there. Pi in the terminal draws the same way through the
/// /akit skill (it runs excalidraw-cli and `akit kb propose --map` itself).
public enum KnowledgeMapDrawer {
    /// The send log's purpose.
    public static let purpose = "kb-draw"
    /// The npm package `npx` runs when `excalidraw-cli` isn't installed.
    public static let package = "@swiftlysingh/excalidraw-cli"
    /// The longest DSL AKit draws (characters).
    static let maxDSL = 20_000

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
        /// The map proposal AKit made from Pi's DSL (one id).
        public let proposals: [String]
        /// Pi's one line on what the map shows (the proposal's reason), masked.
        public let answer: String?
        public let usage: SendUsage
    }

    public struct Failure: Error, LocalizedError, Sendable {
        public let message: String
        public var errorDescription: String? { message }
    }

    /// What Pi is told; the data (the person's words, the note names) goes in the input.
    static let system = """
        You draw maps for a knowledge base of software systems with excalidraw-cli's DSL. The input names the area, the map, \
        what the person wants on it, and the area's notes. Answer with the DSL and one line on what the map shows.
        The DSL has one arrow per line, like `[orders-api] -> "events" -> [billing]`; a block alone is `[name]`. \
        Name each arrow by what flows along it. Where a block stands for one of the area's notes, label it with the note's \
        name exactly as written, so AKit links the block to its note. Draw only what the person asked for.
        """

    /// The answer's shape: the DSL and a one-line reason.
    static let schema = """
        {"type":"object","properties":{"dsl":{"type":"string","description":"excalidraw-cli DSL, one arrow or block per line"},\
        "reason":{"type":"string","description":"one line: what the map shows"}},"required":["dsl","reason"],"additionalProperties":false}
        """

    /// The data Pi gets: the person's words and the note names (scrubbed by `ModelCall`).
    static func input(_ request: Request, notes: [String]) -> String {
        let labels = notes.isEmpty
            ? "The area has no notes yet: label each block with a short name for the system it stands for."
            : "The area's notes (use these names as block labels): \(notes.joined(separator: ", "))."
        return """
            Area: \(request.area). Map: \(request.name).
            What the map shows: \(request.prompt.trimmingCharacters(in: .whitespacesAndNewlines))
            \(labels)
            """
    }

    /// The DSL and reason of Pi's answer: the JSON object, else a fenced block (```…```) with the
    /// DSL. Refused when empty, too long, or starting with `-` (it is passed as an argument).
    static func drawing(fromAnswer text: String) throws(Failure) -> (dsl: String, reason: String?) {
        var dsl: String?, reason: String?
        if let data = ModelCall.jsonObject(in: text),
           let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            dsl = object["dsl"] as? String
            reason = (object["reason"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if dsl == nil, let open = text.range(of: "```") {
            let rest = text[open.upperBound...]
            let body = rest.drop { $0 != "\n" }.dropFirst()
            if let close = body.range(of: "```") { dsl = String(body[..<close.lowerBound]) }
        }
        let drawn = (dsl ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !drawn.isEmpty else {
            throw Failure(message: "Pi's answer has no map: " + SecretFilter.masked(String(text.prefix(300))))
        }
        guard drawn.count <= maxDSL else { throw Failure(message: "Pi's map is \(drawn.count) characters; AKit draws at most \(maxDSL).") }
        guard !drawn.hasPrefix("-") else { throw Failure(message: "Pi's map starts with “-”, which excalidraw-cli would read as an option.") }
        return (drawn, reason.flatMap { $0.isEmpty ? nil : String($0.prefix(300)) })
    }

    /// The program that draws and the arguments before `create`: `excalidraw-cli` on the PATH,
    /// else `npx --yes @swiftlysingh/excalidraw-cli`; nil when neither is there.
    public static func drawer(env: HarnessEnvironment) -> (program: URL, arguments: [String])? {
        if let cli = env.findExecutable("excalidraw-cli") { return (cli, []) }
        if let npx = env.findExecutable("npx") { return (npx, ["--yes", package]) }
        return nil
    }

    /// Why Draw Map can't run on this Mac, for the sheet; nil when it can.
    public static func missingDrawer(env: HarnessEnvironment) -> String? {
        drawer(env: env) == nil
            ? "Draw Map needs excalidraw-cli, or Node's npx to run it (\(package), Node 20.19 or later). Install Node, or run npm install -g \(package)."
            : nil
    }

    /// The arguments of the draw: `[npx args] create --inline DSL -o OUTPUT`.
    static func drawArguments(_ prefix: [String], dsl: String, output: URL) -> [String] {
        prefix + ["create", "--inline", dsl, "-o", output.path]
    }

    /// Asks Pi for the map's DSL, draws it, and proposes the draft. Throws when the request isn't
    /// valid, Pi or excalidraw-cli (or npx) isn't installed, the settings can't be read, the gate or
    /// the monthly limit refuses, Pi fails or answers without a map, excalidraw-cli fails, or the
    /// proposal's checks refuse the draft. `progress` gets one line per step (masked).
    public static func run(_ request: Request, in base: KnowledgeBase, env: HarnessEnvironment, timeout: TimeInterval = 15 * 60,
                           drawTimeout: TimeInterval = 5 * 60,
                           progress: @escaping @Sendable (String) -> Void = { _ in }) async throws(Failure) -> Outcome {
        guard request.agent.harness == .pi else { throw Failure(message: "Draw Map runs Pi; pick a Pi model.") }
        for (what, value) in [("area", request.area), ("map name", request.name)]
        where value.isEmpty || value.hasPrefix(".") || value.contains("/") || value.contains("..") {
            throw Failure(message: "“\(value)” can't be the \(what): one folder or file name, without /, not hidden.")
        }
        guard !request.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw Failure(message: "Say what the map shows.")
        }
        guard env.findExecutable("pi") != nil else { throw Failure(message: "Pi (pi) is not installed.") }
        guard let drawer = drawer(env: env) else { throw Failure(message: missingDrawer(env: env) ?? "") }
        var request = request
        do { request.agent = try await KnowledgeCheckModel.resolved(request.agent, env: env) } catch { throw Failure(message: error.message) }
        let notes = ((try? base.notes()) ?? []).filter { $0.area == request.area }.map { String($0.id.split(separator: "/").last ?? "") }
        let folder = FileManager.default.temporaryDirectory.appending(path: "akit-kb-draw-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: folder) }
        do { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) } catch {
            throw Failure(message: "Couldn't make \(folder.path): \(error.localizedDescription)")
        }
        let call = ModelCall.Request(agent: request.agent, purpose: purpose, system: system, input: input(request, notes: notes),
                                     schema: schema, origin: .knowledgeBase)
        progress("Pi writes the map: \(request.agent.model.isEmpty ? "its default model" : request.agent.model)…")
        let answer: ModelCall.Answer
        do {
            let gate = try await SendGate.open(agent: request.agent, env: env)
            answer = try await ModelCall.run(call, gate: gate, folder: folder, env: env, timeout: timeout)
        } catch is CancellationError {
            throw Failure(message: "Stopped.")
        } catch {
            throw Failure(message: error.localizedDescription)
        }
        let map = try drawing(fromAnswer: answer.text)
        let lines = map.dsl.split(whereSeparator: \.isNewline).count
        progress("Pi: \(lines) line\(lines == 1 ? "" : "s") of DSL" + (map.reason.map { ": " + SecretFilter.masked($0) } ?? ""))

        let output = folder.appending(path: "\(request.name).excalidraw")
        progress("runs " + ([drawer.program.lastPathComponent] + drawer.arguments + ["create", "--inline", "…", "-o", output.lastPathComponent])
            .joined(separator: " "))
        let log = Lines()
        let exit = await ChildProcess.run(drawer.program, arguments: drawArguments(drawer.arguments, dsl: map.dsl, output: output),
                                          directory: folder, environment: ChildProcess.harnessEnvironment(env), timeout: drawTimeout) {
            log.add($0)
        }
        guard let exit else { throw Failure(message: "Couldn't start \(drawer.program.path).") }
        if exit.cancelled { throw Failure(message: "Stopped.") }
        if exit.timedOut { throw Failure(message: "excalidraw-cli took longer than \(Int(drawTimeout / 60)) minutes and was stopped.") }
        let said = SecretFilter.masked(String(log.lines.joined(separator: "\n").suffix(300)))
        guard exit.succeeded, let draft = try? Data(contentsOf: output) else {
            throw Failure(message: "excalidraw-cli couldn't draw Pi's map (status \(exit.status))" + (said.isEmpty ? "." : ": \(said)"))
        }
        let reason = map.reason ?? "Drawn with Pi: " + String(request.prompt.trimmingCharacters(in: .whitespacesAndNewlines).prefix(120))
        let proposal: KnowledgeProposal
        do {
            proposal = try base.propose(.init(.map("\(request.area)/\(request.name)", draft: draft), reason: reason, author: "pi")).proposal
        } catch {
            throw Failure(message: error.message)
        }
        progress("Proposed \(proposal.id).")
        return Outcome(proposals: [proposal.id], answer: map.reason.map(SecretFilter.masked), usage: answer.usage)
    }

    private final class Lines: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [String] = []
        func add(_ line: String) { lock.withLock { stored.append(line) } }
        var lines: [String] { lock.withLock { stored } }
    }
}
