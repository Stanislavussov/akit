import Foundation
import Testing
import AKitFoundation
@testable import AKitLab

/// Translate: the prompt and answer, the cache next to the output, and the call through
/// `ModelCall` with a fake `claude` in a temporary home.
@Suite(.serialized)
struct TranslationTests {
    let home: URL
    let fm = FileManager.default

    init() throws {
        home = fm.temporaryDirectory.appending(path: "akit-translate-\(UUID().uuidString)")
        try fm.createDirectory(at: home.appending(path: "bin"), withIntermediateDirectories: true)
    }

    var env: HarnessEnvironment {
        HarnessEnvironment(homeDirectory: home, variables: ["HOME": home.path],
                           executableSearchPaths: [home.appending(path: "bin"), URL(filePath: "/usr/bin"), URL(filePath: "/bin")])
    }

    let claudeAccount = SendDestination(harness: .claudeCode, provider: "anthropic", account: "me@example.com", org: "Me")

    /// A fake `claude` that answers with `parts`, records its stdin and arguments and counts calls.
    func fakeClaude(parts: [String]) throws {
        let answer = String(decoding: try JSONSerialization.data(withJSONObject: ["parts": parts]), as: UTF8.self)
        let url = home.appending(path: "bin/claude")
        try Data("""
            #!/bin/sh
            cat > "$HOME/stdin.txt"
            echo "$@" > "$HOME/args.txt"
            echo x >> "$HOME/calls.txt"
            echo '{"type":"result","is_error":false,"result":"","structured_output":\(answer),"usage":{"input_tokens":10,"output_tokens":5},"total_cost_usd":0.001}'

            """.utf8).write(to: url)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    var calls: Int {
        ((try? String(contentsOf: home.appending(path: "calls.txt"), encoding: .utf8)) ?? "").split(separator: "\n").count
    }

    /// Unset, Translate uses Claude Code · haiku, or Pi on a Mac with Pi and no Claude Code.
    @Test func theDefaultModelIsAHarnessThisMacHas() throws {
        // Only this test's bin: no claude or pi of the machine running the tests.
        let only = HarnessEnvironment(homeDirectory: home, variables: ["HOME": home.path], executableSearchPaths: [home.appending(path: "bin")])
        func tool(_ name: String) throws {
            let url = home.appending(path: "bin/\(name)")
            try Data("#!/bin/sh\n".utf8).write(to: url)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
        #expect(OutputTranslation.agent(settings: LabSettings(), env: only) == OutputTranslation.defaultAgent, "neither: the documented default")
        try tool("pi")
        #expect(OutputTranslation.agent(settings: LabSettings(), env: only) == OutputTranslation.piAgent)
        try tool("claude")
        #expect(OutputTranslation.agent(settings: LabSettings(), env: only) == OutputTranslation.defaultAgent)
        var chosen = LabSettings()
        chosen.translationAgent = LabAgent(harness: .claudeCode, model: "sonnet", effort: "low", mode: .call)
        try fm.removeItem(at: home.appending(path: "bin/claude"))
        #expect(OutputTranslation.agent(settings: chosen, env: only).model == "sonnet", "the user's choice stays")
    }

    @Test func aSourceDropsEmptyTextsAndRepeatedKeys() {
        let source = OutputTranslation.Source(parts: [.init("a", "One"), .init("b", "  \n"), .init("a", "Again"), .init("c", "Two")],
                                        origins: [.claudeSession], cacheFolder: nil)
        #expect(source.parts.map(\.key) == ["a", "c"])
        #expect(source.characters == 6)
    }

    @Test func thePromptKeepsCodeAndTheAnswerHasOnePartPerInput() throws {
        let system = OutputTranslation.system(to: .russian)
        #expect(system.contains("Russian"))
        #expect(system.contains("Markdown") && system.contains("file paths") && system.contains("JSON keys"))
        let source = OutputTranslation.Source(parts: [.init("title", "Fix `run()`"), .init("body", "See Sources/a.swift")],
                                        origins: [.claudeSession], cacheFolder: nil)
        let input = try JSONSerialization.jsonObject(with: Data(OutputTranslation.input(source).utf8)) as? [String: [String]]
        #expect(input?["parts"] == ["Fix `run()`", "See Sources/a.swift"])
        let texts = try OutputTranslation.texts(fromAnswer: #"Here: {"parts":["Исправить `run()`","См. Sources/a.swift"]}"#, source: source)
        #expect(texts == ["title": "Исправить `run()`", "body": "См. Sources/a.swift"])
        #expect(throws: OutputTranslation.Failure.self) { try OutputTranslation.texts(fromAnswer: #"{"parts":["one"]}"#, source: source) }
        #expect(throws: OutputTranslation.Failure.self) { try OutputTranslation.texts(fromAnswer: "no json", source: source) }
    }

    @Test func theKeyChangesWithTextLanguageAndModel() {
        let source = OutputTranslation.Source(parts: [.init("a", "Hello")], origins: [.claudeSession], cacheFolder: nil)
        let other = OutputTranslation.Source(parts: [.init("a", "Hello!")], origins: [.claudeSession], cacheFolder: nil)
        let haiku = OutputTranslation.defaultAgent
        let sonnet = LabAgent(harness: .claudeCode, model: "sonnet", effort: "low", mode: .call)
        let key = OutputTranslation.key(source, language: .russian, agent: haiku)
        #expect(key == OutputTranslation.key(source, language: .russian, agent: haiku))
        #expect(key != OutputTranslation.key(other, language: .russian, agent: haiku))
        #expect(key != OutputTranslation.key(source, language: .czech, agent: haiku))
        #expect(key != OutputTranslation.key(source, language: .russian, agent: sonnet))
        #expect(!key.contains("Hello"))
    }

    /// One call: scrubbed, logged as translate, cached next to the output; the next time comes
    /// from the cache, and the original file is untouched.
    @Test func aTranslationIsSentOnceAndCached() async throws {
        try fakeClaude(parts: ["Привет", "Исправь это"])
        let output = home.appending(path: "run")
        try fm.createDirectory(at: output, withIntermediateDirectories: true)
        let original = output.appending(path: "review.json")
        try Data("{}".utf8).write(to: original)
        let token = "ghp_" + String(repeating: "a1B2", count: 9)
        let source = OutputTranslation.Source(parts: [.init("summary", "Hello"), .init("finding:0", "Fix this \(token)")],
                                        origins: [.claudeSession], cacheFolder: output)
        let gate = SendGate(destination: claudeAccount, isWork: false, settings: LabSettings())
        let agent = OutputTranslation.defaultAgent
        #expect(OutputTranslation.cached(source, to: .russian, agent: agent) == nil)
        let result = try await OutputTranslation.translate(source, to: .russian, agent: agent, gate: gate, env: env)
        #expect(result.texts == ["summary": "Привет", "finding:0": "Исправь это"])
        #expect(result.label == "Translated to Russian · Claude Code · haiku")
        #expect(result.text("missing", original: "kept") == "kept")
        let sent = try String(contentsOf: home.appending(path: "stdin.txt"), encoding: .utf8)
        #expect(sent.contains("Hello") && !sent.contains(token))
        let args = try String(contentsOf: home.appending(path: "args.txt"), encoding: .utf8)
        #expect(args.contains("--model haiku") && args.contains("--json-schema"))
        let records = SendLog.records(env: env)
        #expect(records.count == 1 && records[0].purpose == "translate")
        // Cached by hash; the file holds the translation, not the source text.
        let file = try #require(OutputTranslation.cacheFile(source, language: .russian, agent: agent))
        #expect(file.deletingLastPathComponent().lastPathComponent == "translations")
        let cachedText = try String(contentsOf: file, encoding: .utf8)
        #expect(cachedText.contains("Привет") && !cachedText.contains("Hello") && !cachedText.contains(token))
        let again = try await OutputTranslation.translate(source, to: .russian, agent: agent, gate: gate, env: env)
        #expect(again.texts == result.texts)
        #expect(calls == 1)
        #expect(SendLog.records(env: env).count == 1)
        #expect(try String(contentsOf: original, encoding: .utf8) == "{}")
        // Another language is another call.
        _ = try await OutputTranslation.translate(source, to: .german, agent: agent, gate: gate, env: env)
        #expect(calls == 2)
    }

    /// The policy decides as for every send: data of another origin on a work Mac with an empty
    /// list goes nowhere, and nothing is cached.
    @Test func aRefusedTranslationSendsNothing() async throws {
        try fakeClaude(parts: ["x"])
        let source = OutputTranslation.Source(parts: [.init("text", "data")], origins: [.mergeRequest], cacheFolder: home.appending(path: "out"))
        let gate = SendGate(destination: claudeAccount, isWork: true, settings: LabSettings())
        await #expect(throws: SendAccounts.Failure.self) {
            _ = try await OutputTranslation.translate(source, to: .russian, agent: OutputTranslation.defaultAgent, gate: gate, env: env)
        }
        #expect(calls == 0)
        #expect(!fm.fileExists(atPath: home.appending(path: "out/translations").path))
    }

    /// An answer with the wrong number of parts is an error and isn't cached.
    @Test func aWrongAnswerIsNotCached() async throws {
        try fakeClaude(parts: ["only one"])
        let source = OutputTranslation.Source(parts: [.init("a", "One"), .init("b", "Two")], origins: [.claudeSession],
                                        cacheFolder: home.appending(path: "out"))
        let gate = SendGate(destination: claudeAccount, isWork: false, settings: LabSettings())
        await #expect(throws: OutputTranslation.Failure.self) {
            _ = try await OutputTranslation.translate(source, to: .russian, agent: OutputTranslation.defaultAgent, gate: gate, env: env)
        }
        #expect(OutputTranslation.cached(source, to: .russian, agent: OutputTranslation.defaultAgent) == nil)
    }

    /// An empty translated part is a dropped part: an error, not cached.
    @Test func anEmptyPartIsAFailure() throws {
        let source = OutputTranslation.Source(parts: [.init("a", "One"), .init("b", "Two")], origins: [.claudeSession], cacheFolder: nil)
        #expect(throws: OutputTranslation.Failure.self) { try OutputTranslation.texts(fromAnswer: #"{"parts":["Один"," "]}"#, source: source) }
    }

    /// A review's data may go to its own Pi model, not to Claude Code · haiku: the plan picks
    /// the review's model and says so in the label; when both are refused, the reason of each.
    @Test func aRefusedTranslationModelFallsBackToTheOutputsOwnModel() async throws {
        let piModel = LabAgent(harness: .pi, model: "zai/glm-5", effort: "low", mode: .call)
        let piAccount = SendDestination(harness: .pi, provider: "zai", account: "", org: "")
        let claude = claudeAccount
        func gates(work: Bool) -> @Sendable (LabAgent) async throws -> SendGate {
            { agent in SendGate(destination: agent.harness == .pi ? piAccount : claude, isWork: work, settings: LabSettings()) }
        }
        let review = OutputTranslation.Source(parts: [.init("request:r1", "Fix it")], origins: [.mergeRequest], cacheFolder: nil,
                                              ownAgent: piModel, ownAgentName: "the review's model")
        let plan = try await OutputTranslation.plan(review, configured: OutputTranslation.defaultAgent, env: env, open: gates(work: false))
        #expect(plan.agent == piModel && plan.isOwnModel && plan.gate != nil && plan.refusal == nil)
        #expect(OutputTranslation.label(plan.agent, own: plan.isOwnModel, source: review) == "Pi · zai/glm-5 (the review's model)")
        // Allowed for the translation model: no fallback.
        let session = OutputTranslation.Source(parts: [.init("a", "Hi")], origins: [.claudeSession], cacheFolder: nil, ownAgent: piModel)
        let direct = try await OutputTranslation.plan(session, configured: OutputTranslation.defaultAgent, env: env, open: gates(work: false))
        #expect(direct.agent == OutputTranslation.defaultAgent && !direct.isOwnModel)
        // A local review on a work Mac: repository code goes only to the (empty) allowed list.
        let local = OutputTranslation.Source(parts: [.init("a", "Hi")], origins: [.code(.pi)], cacheFolder: nil, ownAgent: piModel,
                                             ownAgentName: "the review's model")
        let refused = try await OutputTranslation.plan(local, configured: OutputTranslation.defaultAgent, env: env, open: gates(work: true))
        #expect(refused.gate == nil)
        #expect(refused.refusal?.contains("The translation model (Claude Code · haiku)") == true)
        #expect(refused.refusal?.contains("The review's model (Pi · zai/glm-5)") == true)
        #expect(refused.refusal?.contains("Add Destination") == true)
        // An account check that fails is a refusal too, not a crash.
        let failing = try await OutputTranslation.plan(session, configured: OutputTranslation.defaultAgent, env: env, open: { _ in
            throw SendAccounts.Failure(message: "Couldn't check the account.")
        })
        #expect(failing.gate == nil && failing.refusal?.contains("Couldn't check the account.") == true)
    }

    /// The label of a translation by the output's own model says so, and the cache finds it.
    @Test func theOwnModelsTranslationIsLabelledAndCached() async throws {
        try fakeClaude(parts: ["Привет"])
        let own = LabAgent(harness: .claudeCode, model: "sonnet", effort: "low", mode: .call)
        let source = OutputTranslation.Source(parts: [.init("a", "Hello")], origins: [.claudeSession], cacheFolder: home.appending(path: "out"),
                                              ownAgent: own, ownAgentName: "the review's model")
        let gate = SendGate(destination: claudeAccount, isWork: false, settings: LabSettings())
        let result = try await OutputTranslation.translate(source, to: .russian, agent: own, own: true, gate: gate, env: env)
        #expect(result.label == "Translated to Russian · Claude Code · sonnet (the review's model)")
        let cached = OutputTranslation.cached(source, to: .russian, configured: OutputTranslation.defaultAgent)
        #expect(cached?.label == result.label && cached?.texts == result.texts)
    }

    /// Old settings files have no translation model, and old run specs keep their language.
    @Test func settingsWithoutATranslationModelStillDecode() throws {
        let old = try JSONDecoder().decode(LabSettings.self, from: Data(#"{"reportLanguage":"cs","monthlyLimit":5}"#.utf8))
        #expect(old.reportLanguage == .czech && old.monthlyLimit == 5 && old.translationAgent == nil)
        #expect(OutputTranslation.agent(settings: old) == OutputTranslation.defaultAgent)
        #expect(LabSettings.strictly(Data(#"{"reportLanguage":"ru"}"#.utf8)) != nil)
        var settings = LabSettings()
        settings.translationAgent = LabAgent(harness: .pi, model: "zai/glm-5-air", effort: "low", mode: .call)
        let decoded = try JSONDecoder().decode(LabSettings.self, from: try JSONEncoder().encode(settings))
        #expect(decoded == settings)
        #expect(OutputTranslation.agent(settings: decoded).model == "zai/glm-5-air")
        // Claude Code needs a model: a blank one (Settings while typing) is the default's.
        settings.translationAgent = LabAgent(harness: .claudeCode, model: "", effort: "medium", mode: .call)
        #expect(OutputTranslation.agent(settings: settings) == LabAgent(harness: .claudeCode, model: "haiku", effort: "medium", mode: .call))
        // The first three codes are the ones stored before.
        #expect(LabLanguage.allCases.prefix(3).map(\.rawValue) == ["en", "ru", "cs"])
        #expect(LabLanguage(rawValue: "zh")?.name == "Chinese (Simplified)")
        #expect(LabLanguage.allCases.count == 17)
    }

    /// Settings' edit of the translation model lands on what is on disk, as the other fields do.
    @Test func theSettingsEditKeepsOtherChanges() {
        let old = LabSettings()
        var new = old
        new.translationAgent = LabAgent(harness: .claudeCode, model: "sonnet", effort: "low", mode: .call)
        var disk = LabSettings(monthlyLimit: 3)
        disk.apply(from: old, to: new)
        #expect(disk.monthlyLimit == 3 && disk.translationAgent?.model == "sonnet")
    }
}
