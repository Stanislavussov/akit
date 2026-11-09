import Foundation
import Testing
import AKitFoundation
@testable import AKitSkills

/// Port to Pi's extra rules and questions: parsing, order, regex, forbid lint, presets, the
/// detectors, answers → rules, on a vitest skill with scripts and a plugin command (no OMC roles).
struct SkillPortRulesTests {
    let home: URL
    let fm = FileManager.default

    /// A made-up testing skill of another shape than the interview one: scripts/, a config
    /// reference, a plugin command, npm commands, vitest; no roles, no questions tool.
    static let testing = """
        ---
        name: unit-tests
        description: Write unit tests for a TypeScript module
        allowed-tools: Bash
        ---
        # Unit tests

        Mock with `vi.fn()` and `vi.spyOn(api, 'get')`; timers with vi.useFakeTimers().
        Start with `import { describe, it, vi } from 'vitest'` and keep vitest.config.ts as is.
        Run `npm run test` or `npx vitest run`, then /test-kit:coverage.
        Use scripts/run.sh for CI. A test may take at most 5 seconds.
        """

    init() throws {
        home = fm.temporaryDirectory.appending(path: "akit-port-rules-\(UUID().uuidString)")
        try write(".claude/skills/unit-tests/SKILL.md", Self.testing)
        try write(".claude/skills/unit-tests/scripts/run.sh", "#!/bin/sh\nnpx vitest run --coverage\n")
    }

    var env: HarnessEnvironment { HarnessEnvironment(homeDirectory: home) }
    var source: URL { home.appending(path: ".claude/skills/unit-tests") }

    func write(_ path: String, _ text: String) throws {
        let url = home.appending(path: path)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    @Test func parsesEveryKindOfLine() throws {
        let rules = try SkillPortRules.parse("""
            # comment
            a.b => c.d
            re:x(\\d+) => y$1
            forbid: vi.
            allow: AskUserQuestion
            answer: questions=keep
            note: use jest
            """)
        #expect(rules.replacements == [.init(from: "a.b", to: "c.d"), .init(from: #"x(\d+)"#, to: "y$1", isRegex: true)])
        #expect(rules.forbids == ["vi."] && rules.allows == ["AskUserQuestion"] && rules.notes == ["use jest"])
        #expect(rules.answers == ["questions": "keep"])
        #expect(try SkillPortRules.parse(rules.text) == rules)
        #expect(throws: SkillPortRules.Failure.self) { try SkillPortRules.parse("no arrow") }
        #expect(throws: SkillPortRules.Failure.self) { try SkillPortRules.parse("re:( => x") }
        #expect(throws: SkillPortRules.Failure.self) { try SkillPortRules.parse("allow: nothing") }
        #expect((try? SkillPortRules.parse("ok => x\nbad")) == nil)
    }

    @Test func replacementsRunInOrderLiteralAndRegex() throws {
        let rules = try SkillPortRules.parse("a => b\nb => c\nre:n(\\d) => m$1\n$x => [y]")
        #expect(rules.apply(to: "a n1 $x") == "c m1 [y]")
        // A literal starting with a letter matches at a word start only.
        #expect(try SkillPortRules.parse("vi. => jest.").apply(to: "vi.fn navi.x") == "jest.fn navi.x")
    }

    @Test func userRulesRunAfterTheBuiltInOnesAndAreLinted() throws {
        let rules = try SkillPortRules.parse("/skill:coverage => /skill:cov\nforbid: npx")
        let draft = try SkillPort.port(folder: source, env: env, rules: rules)
        #expect(draft.skillText.contains("/skill:cov."))
        #expect(draft.changes.contains("Your replacements changed 1 file"))
        let hits = SkillPortCheck.check(draft).hits.filter { $0.source == "user" }
        #expect(Set(hits.map(\.rule)) == ["forbid: npx"])
        #expect(Set(hits.map(\.file)) == ["SKILL.md", "scripts/run.sh"])
        // allow: turns a built-in rule off.
        let allowed = try SkillPortRules.parse("allow: AskUserQuestion")
        #expect(SkillPortCheck.lint(["a.md": "AskUserQuestion"], extra: allowed).isEmpty)
        #expect(SkillPortCheck.lint(["a.md": "AskUserQuestion"]).count == 1)
    }

    @Test func vitestToJestPresetOnTheFixture() throws {
        let rules = try SkillPortRules.parse(try #require(SkillPortRules.preset("vitest-to-jest", env: env)))
        let draft = try SkillPort.port(folder: source, env: env, rules: rules)
        #expect(draft.skillText.contains("`jest.fn()` and `jest.spyOn(api, 'get')`; timers with jest.useFakeTimers()."))
        #expect(draft.skillText.contains("from '@jest/globals'` and keep jest.config.ts"))
        #expect(draft.texts["scripts/run.sh"] == "#!/bin/sh\nnpx jest --coverage\n")
        let report = SkillPortCheck.check(draft)
        // Nothing of vitest is left for the forbid rules; numbers and headings survive.
        #expect(report.hits.filter { $0.source == "user" }.isEmpty, "\(report.lines)")
        #expect(report.missingNumbers.isEmpty && report.problems.isEmpty)
        // A leftover the preset didn't cover is a hit of the user's rules.
        #expect(SkillPortCheck.lint(["a.md": "await vi.hoisted(() => 1)"], extra: rules).map(\.rule) == ["forbid: vi."])
    }

    @Test func presetsSaveAndLoad() throws {
        #expect(throws: SkillPortRules.Failure.self) { try SkillPortRules.save(preset: "Bad Name", text: "", env: env) }
        #expect(throws: SkillPortRules.Failure.self) { try SkillPortRules.save(preset: "vitest-to-jest", text: "", env: env) }
        #expect(throws: SkillPortRules.Failure.self) { try SkillPortRules.save(preset: "mine", text: "broken", env: env) }
        let file = try SkillPortRules.save(preset: "mine", text: "a => b\nanswer: test-framework=keep", env: env)
        #expect(file.path.hasSuffix(".akit/port-presets/mine.rules"))
        #expect(SkillPortRules.savedPresets(env: env) == ["mine": "a => b\nanswer: test-framework=keep"])
        #expect(SkillPortRules.preset("mine", env: env) != nil && SkillPortRules.preset("nope", env: env) == nil)
    }

    @Test func detectsTheTestingSkillsChoicePoints() throws {
        let draft = try SkillPort.port(folder: source, env: env)
        let questions = SkillPortQuestions.analyze(draft.originals, skill: draft.name)
        #expect(questions.map(\.id) == ["test-framework", "package-manager"])
        let framework = questions[0]
        #expect(framework.evidence == ["vitest"] && framework.recommended == "keep")
        #expect(framework.options.map(\.id) == ["keep", "vitest-to-jest", "vitest-to-mocha", "vitest-to-bun-test"])
        #expect(framework.options[1].rules == SkillPortRules.builtIns["vitest-to-jest"])
        // A pair the catalog doesn't know: a note and the member's forbidden tokens.
        #expect(framework.options[2].rules.hasPrefix("note: Use Mocha instead of Vitest") && framework.options[2].rules.contains("forbid: vi."))
        #expect(questions[1].evidence == ["npm"] && questions[1].family == "package-manager")
    }

    @Test func detectsTheInterviewSkillsChoicePoints() {
        let texts = ["SKILL.md": SkillPortTests.interview]
        let questions = SkillPortQuestions.analyze(texts, skill: "interview")
        #expect(questions.map(\.id) == ["subagents", "questions", "state", "model-hints"])
        #expect(questions[0].evidence == ["critic", "Agent("])
        #expect(questions[3].evidence == ["opus"])
    }

    @Test func answersBecomeRulesAndDefaultsAreListed() throws {
        let texts = ["SKILL.md": SkillPortTests.interview + "\nThen Skill(\"oh-my-claudecode:plan\")."]
        let questions = SkillPortQuestions.analyze(texts, skill: "interview")
        let defaults = try SkillPortQuestions.rules(questions, answers: [:])
        #expect(defaults.defaulted == questions.map(\.id))
        #expect(defaults.chosen["state"] == "skill-folder" && defaults.rules.answers == defaults.chosen)
        // The state folder rule doesn't nest on a second run.
        #expect(defaults.rules.apply(to: defaults.rules.apply(to: ".pi/state/x.md")) == ".pi/state/interview/x.md")

        let picked = try SkillPortQuestions.rules(questions, answers: ["questions": "keep", "handoffs": "drop"])
        #expect(picked.rules.allows == ["AskUserQuestion"])
        #expect(picked.rules.notes.contains { $0.hasPrefix("Drop handoffs") })
        #expect(!picked.defaulted.contains("questions"))
        #expect(throws: SkillPortRules.Failure.self) { try SkillPortQuestions.rules(questions, answers: ["questions": "maybe"]) }
        #expect(throws: SkillPortRules.Failure.self) { try SkillPortQuestions.rules(questions, answers: ["nope": "x"]) }
    }

    @Test func npmToPnpmFromTheCatalog() throws {
        let draft = try SkillPort.port(folder: source, env: env)
        let question = try #require(SkillPortQuestions.analyze(draft.originals, skill: draft.name).first { $0.id == "package-manager" })
        let picked = try SkillPortQuestions.rules([question], answers: ["package-manager": "npm-to-pnpm"])
        let ported = try SkillPort.port(folder: source, env: env, rules: picked.rules)
        #expect(ported.skillText.contains("Run `pnpm run test` or `pnpm dlx vitest run`"))
        #expect(ported.texts["scripts/run.sh"] == "#!/bin/sh\npnpm dlx vitest run --coverage\n")
        #expect((try? SkillPortRules.parse(picked.rules.text)) != nil)
        #expect(try SkillPortRules.parse("re:\\bnpm (?:install|i) (\\S) => pnpm add $1").apply(to: "npm install zod") == "pnpm add zod")
        let report = SkillPortCheck.check(ported)
        #expect(report.hits.filter { $0.source == "user" }.isEmpty, "\(report.lines)")
        // A leftover is grouped under the change that forbids it.
        let left = SkillPortCheck.lint(["a.md": "then npm publish"], extra: picked.rules)
        #expect(left.map(\.change) == ["package-manager: Switch npm to pnpm"])
        let grouped = SkillPortCheck.Report(hits: left, problems: [], missingNumbers: [], missingHeadings: [])
        #expect(grouped.groups.map(\.title) == ["package-manager: Switch npm to pnpm"])
    }

    @Test func axiosToFetchFromTheCatalog() throws {
        try write(".claude/skills/api/SKILL.md", "---\nname: api\ndescription: Call the API\n---\n# API\n```ts\nimport axios from 'axios';\nconst r = await axios.get(url)\n```\n")
        let folder = home.appending(path: ".claude/skills/api")
        let draft = try SkillPort.port(folder: folder, env: env)
        let question = try #require(SkillPortQuestions.analyze(draft.originals, skill: "api").first)
        #expect(question.id == "http-client" && question.evidence == ["axios"])
        #expect(question.options.map(\.id) == ["keep", "axios-to-fetch", "axios-to-got", "axios-to-ky"])
        let picked = try SkillPortQuestions.rules([question], answers: ["http-client": "axios-to-fetch"])
        let ported = try SkillPort.port(folder: folder, env: env, rules: picked.rules)
        #expect(ported.skillText.contains("```ts\nconst r = await fetch(url)\n```"))
        #expect(picked.rules.notes.contains { $0.contains("response.ok") })
        #expect(SkillPortCheck.check(ported).hits.isEmpty)
    }

    @Test func theUsersCatalogAddsFamiliesAndPairs() throws {
        try write(".akit/port-presets/catalog.json", #"""
            {"families": [
              {"id": "logger", "title": "logger", "members": [],
               "pairs": [{"from": "winston", "to": "pino", "rules": "winston => pino\nforbid: winston"}]},
              {"id": "cloud-cli", "title": "cloud CLI", "pairs": [], "members": [
                {"id": "aws", "title": "AWS CLI", "tokens": ["\\baws s3\\b"], "forbid": ["aws "]},
                {"id": "gcloud", "title": "gcloud", "tokens": ["\\bgcloud\\b"], "forbid": ["gcloud"]}]}
            ]}
            """#)
        let catalog = try SkillPortCatalog.load(env: env)
        #expect(catalog.presets["winston-to-pino"] == "winston => pino\nforbid: winston")
        #expect(SkillPortRules.preset("winston-to-pino", env: env) != nil)
        let questions = SkillPortQuestions.analyze(["SKILL.md": "Upload with aws s3 cp."], skill: "x", catalog: catalog)
        #expect(questions.map(\.id) == ["cloud-cli"])
        #expect(questions[0].options.map(\.id) == ["keep", "aws-to-gcloud"])
        try write(".akit/port-presets/catalog.json", "not json")
        #expect(throws: SkillPortRules.Failure.self) { try SkillPortCatalog.load(env: env) }
    }

    @Test func otherAnswersBecomeFreeChanges() throws {
        let questions = SkillPortQuestions.analyze(["SKILL.md": "Run npm run build."], skill: "x")
        let result = try SkillPortQuestions.rules(questions, answers: ["package-manager": "other: use deno tasks"])
        #expect(result.others == ["The skill uses npm as its package manager. Keep it or switch? → use deno tasks"])
        #expect(throws: SkillPortRules.Failure.self) { try SkillPortQuestions.rules(questions, answers: ["package-manager": "other:"]) }
        // The model's questions merge by family: a family the catalog asked is not asked twice.
        let more = [SkillPortQuestion(id: "pm", question: "?", options: [], recommended: "keep", evidence: ["model"], family: "package-manager"),
                    SkillPortQuestion(id: "branch-naming", question: "?", options: [], recommended: "keep", evidence: ["model"], family: "git")]
        #expect(SkillPortQuestions.merge(questions, more).map(\.id) == ["package-manager", "branch-naming"])
    }
}
