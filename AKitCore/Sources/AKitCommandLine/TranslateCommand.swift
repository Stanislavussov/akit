import AKitErrorAnalysis
import AKitFoundation
import AKitLab
import AKitReview
import Foundation

/// `akit translate …`: model-written output in another language (docs/design/translate.md).
extension AKitCLI {
    static var translateUsage: String {
        """
        akit translate — model-written output in another language, with the translation model
        (Settings → Translation model). The original is never changed.

          akit translate --to LANG FILE|- --origin code|claude|pi:PROVIDER|merge-request [--json]
                                          Translate a file or stdin. --origin (required): where its
                                          text came from, for the sending policy. code: repository
                                          code or your setup (the harness's own account; on a work
                                          Mac only the allowed list); claude: a Claude Code session;
                                          pi:PROVIDER: a Pi session; merge-request: an AKit Review
          akit translate --to LANG --notes SESSION [--json]
                                          A reviewed session's notes: conclusion, paragraph,
                                          improvements, the model's notes and the verifier's reasons
          akit translate --to LANG --lab-run ID [--json]
                                          A Lab review run's own paragraph and improvements
          akit translate --to LANG --review RUN [--json]
                                          An AKit Review run's brief and requests (the drafts AKit
                                          sends to GitLab stay the originals). When the policy
                                          refuses the translation model, the review's own Pi model
                                          translates it: the passes sent it there already
          akit translate model [HARNESS [MODEL [EFFORT]]]
                                          Show the translation model, or set it (claude-code|pi;
                                          default: Claude Code · haiku · low)

        LANG: \(LabLanguage.codes). One call per output, through the sending policy, the scrub,
        the monthly limit and the send log (purpose translate). Notes, Lab runs and reviews keep
        the translation in a translations folder next to them, so asking again costs nothing.
        """
    }

    static func translate(_ arguments: [String], env: HarnessEnvironment, cwd: URL, out: (String) -> Void,
                          input: () -> Data) async throws -> Int32 {
        var args = Arguments(arguments)
        if args.flag("--help") || args.flag("-h") || args.isEmpty {
            out(translateUsage)
            return 0
        }
        let json = args.flag("--json")
        let languageText = args.value("--to")
        let originText = args.value("--origin")
        let notesText = args.value("--notes")
        let labRunText = args.value("--lab-run")
        let reviewText = args.value("--review")
        if args.peek == "model", languageText == nil {
            _ = args.positional()
            return try translationModel(&args, env: env, out: out)
        }
        let path = args.positional()
        try args.finish()
        guard let languageText else { throw Failure(message: "Which language? --to LANG, one of \(LabLanguage.codes).") }
        guard let language = LabLanguage(rawValue: languageText.lowercased()) else {
            throw Failure(message: "--to is one of \(LabLanguage.codes).")
        }
        guard [path, notesText, labRunText, reviewText].compactMap({ $0 }).count == 1 else {
            throw Failure(message: "Translate one thing: FILE, - (stdin), --notes SESSION, --lab-run ID or --review RUN.")
        }
        if originText != nil, path == nil { throw Failure(message: "--origin is only for FILE or -; the others know their origin.") }
        let settings = try LabSettings.loadForSending(env: env)
        let agent = OutputTranslation.agent(settings: settings)

        let source: OutputTranslation.Source
        if let notesText {
            guard let notes = NotesStore(env: env).load(try sessionKey(notesText, cwd: cwd, env: env)) else {
                throw Failure(message: "No notes for \(notesText). Review it first: akit lab new review \(notesText).")
            }
            source = notes.translationSource(env: env)
        } else if let labRunText {
            guard let run = LabStore.load(labRunText, env: env) else { throw Failure(message: "There is no Lab run \(labRunText) (akit lab list).") }
            guard let found = OutputTranslation.Source.labReview(run) else { throw Failure(message: "\(labRunText) is not a session review.") }
            source = found
        } else if let reviewText {
            source = try ReviewWorkflow.load(try runFolder(reviewText, env: env)).translationSource
        } else {
            let data: Data
            if path == "-" {
                data = input()
            } else {
                let file = resolve(path ?? "", cwd: cwd, env: env)
                guard let read = try? Data(contentsOf: file) else { throw Failure(message: "Can't read \(file.path).") }
                data = read
            }
            source = OutputTranslation.Source(parts: [OutputTranslation.Part("text", String(decoding: data, as: UTF8.self))],
                                        origins: [try origin(originText, agent: agent)], cacheFolder: nil)
        }
        guard !source.isEmpty else { throw Failure(message: "There is no text to translate.") }

        let result: OutputTranslation.Result
        if let cached = OutputTranslation.cached(source, to: language, configured: agent) {
            result = cached
        } else {
            // A review the translation model may not get goes to the review's own Pi model.
            let plan = try await OutputTranslation.plan(source, configured: agent, env: env)
            guard let gate = plan.gate else { throw Failure(message: plan.refusal ?? "Not sent.") }
            result = try await OutputTranslation.translate(source, to: language, agent: plan.agent, own: plan.isOwnModel, gate: gate, env: env)
        }
        if json {
            out(try labJSON(result))
        } else if path != nil {
            out(result.text("text", original: source.parts[0].text))
        } else {
            out(result.label)
            for part in source.parts {
                out("\n[\(part.key)]\n" + result.text(part.key, original: part.text))
            }
        }
        return 0
    }

    static let originChoices = "code (repository code or your setup), claude (a Claude Code session), pi:PROVIDER (a Pi session "
        + "answered by PROVIDER) or merge-request (an AKit Review)"

    /// `--origin` of a file or stdin: required, AKit can't tell where a file's text came from.
    static func origin(_ text: String?, agent: LabAgent) throws -> SendOrigin {
        switch text {
        case nil: throw Failure(message: "Where does the text come from? --origin is required for FILE and -: \(originChoices).")
        case "code": return .code(agent.harness)
        case "claude", "claude-code": return .claudeSession
        case "merge-request": return .mergeRequest
        case let text? where text.hasPrefix("pi:") && text.count > 3: return .piSession(providers: [String(text.dropFirst(3))])
        case let text?: throw Failure(message: "--origin is \(originChoices), not \(text).")
        }
    }

    /// `akit translate model [HARNESS [MODEL [EFFORT]]]`.
    static func translationModel(_ args: inout Arguments, env: HarnessEnvironment, out: (String) -> Void) throws -> Int32 {
        guard let harnessText = args.positional() else {
            try args.finish()
            let agent = OutputTranslation.agent(settings: LabSettings.load(env: env))
            out("\(OutputTranslation.modelLabel(agent)) · \(agent.effort)")
            return 0
        }
        guard let harness = LabHarness(rawValue: harnessText) else { throw Failure(message: "HARNESS is claude-code or pi, not \(harnessText).") }
        let model = args.positional() ?? (harness == OutputTranslation.defaultAgent.harness ? OutputTranslation.defaultAgent.model : "")
        let effort = args.positional() ?? (harness.efforts.contains(OutputTranslation.defaultAgent.effort) ? OutputTranslation.defaultAgent.effort : harness.efforts[0])
        try args.finish()
        guard harness.efforts.contains(effort) else { throw Failure(message: "EFFORT for \(harness.title) is one of \(harness.efforts.joined(separator: ", ")).") }
        guard harness != .claudeCode || !model.isEmpty else { throw Failure(message: "Claude Code needs a MODEL (haiku, sonnet, opus or a full id).") }
        let agent = LabAgent(harness: harness, model: model, effort: effort, mode: .call)
        do {
            try LabSettings.update(env: env) { $0.translationAgent = agent == OutputTranslation.defaultAgent ? nil : agent }
        } catch {
            throw Failure(message: error.localizedDescription)
        }
        out("Translation model: \(OutputTranslation.modelLabel(agent)) · \(effort)")
        return 0
    }
}
