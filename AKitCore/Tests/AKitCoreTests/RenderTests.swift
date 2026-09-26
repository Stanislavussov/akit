import Foundation
import Testing
@testable import AKitCore

/// Rendering layers + answers into project files, from a brain in a temporary folder.
struct RenderTests {
    let root: URL
    let fm = FileManager.default

    init() throws {
        root = fm.temporaryDirectory.appending(path: "akit-render-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func write(_ path: String, _ text: String = "") throws {
        let url = root.appending(path: path)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    func brain() throws -> Brain { try #require(Brain.load(from: root)) }

    func text(_ result: Render.Result, _ path: String) -> String? {
        result.outputs.first { $0.path == path }?.text
    }

    /// The take-home example from docs/design/layers.md.
    func takeHome() throws {
        try write("skills/grilling/SKILL.md", "---\nname: grilling\ndescription: Grill {{company}}\n---\nAsk hard questions.\n")
        try write("skills/tdd/SKILL.md", "---\nname: tdd\ndescription: Tests first\n---\nRed, green.\n")
        try write("skills/tdd/references/guide.md", "Use {{ project_name }} and {{handlebars}}.\n")
        try write("layers/base/layer.yaml", "files:\n  - template: base.md\n    to: AGENTS.md\n")
        try write("layers/base/templates/base.md", "# {{project_name}}\n\nBe brief.\n")
        try write("layers/take-home/layer.yaml", """
            requires: [base]
            fields:
              - id: company
                prompt: Company name
                required: true
              - id: reviewer_readme
                type: bool
                default: true
            skills:
              - name: grilling
                mode: manual
              - tdd
              - name: claude-only
                when: target == claude
            files:
              - template: take-home.md
                to: AGENTS.md
              - template: REVIEW.md
                to: REVIEW.md
                when: reviewer_readme
            """)
        try write("layers/take-home/templates/take-home.md", "## Take-home for {{company}}\n\n{{typo}}\n")
        try write("layers/take-home/templates/REVIEW.md", "Review for {{company}}\n")
        try write("skills/claude-only/SKILL.md", "---\nname: claude-only\ndescription: x\n---\n")
    }

    @Test func rendersTheTakeHomeExample() throws {
        try takeHome()
        let answers = ProjectAnswers(layers: ["take-home"], values: ["company": .text("Acme")], targets: ["claude", "pi"])
        let result = Render.render(answers, brain: try brain(), projectName: "acme-task")

        #expect(result.errors.isEmpty, "\(result.errors)")
        #expect(result.layers == ["base", "take-home"])
        #expect(result.warnings == ["take-home/take-home.md uses {{typo}}, which is not a field; it is left as is."])
        #expect(text(result, "AGENTS.md") == "# acme-task\n\nBe brief.\n\n## Take-home for Acme\n\n{{typo}}\n")
        #expect(result.outputs.first { $0.path == "AGENTS.md" }?.layers == ["base", "take-home"])
        #expect(text(result, "REVIEW.md") == "Review for Acme\n")
        #expect(text(result, "CLAUDE.md") == "@AGENTS.md\n")
        #expect(result.outputs.first { $0.path == ".claude/skills" }?.content == .link("../.agents/skills"))
        #expect(text(result, ".agents/skills/grilling/SKILL.md")
                == "---\nname: grilling\ndescription: Grill Acme\ndisable-model-invocation: true\n---\nAsk hard questions.\n")
        #expect(text(result, ".agents/skills/tdd/SKILL.md")?.contains("disable-model-invocation") == false)
        #expect(text(result, ".agents/skills/tdd/references/guide.md") == "Use acme-task and {{handlebars}}.\n")
        #expect(text(result, ".agents/skills/claude-only/SKILL.md") != nil)
    }

    @Test func piOnlyGetsNoClaudeShimsAndConditionsApply() throws {
        try takeHome()
        let answers = ProjectAnswers(layers: ["take-home"], values: ["company": .text("Acme"), "reviewer_readme": .bool(false)],
                                     targets: ["pi"])
        let result = Render.render(answers, brain: try brain(), projectName: "p")
        let paths = result.outputs.map(\.path)
        #expect(!paths.contains("CLAUDE.md"))
        #expect(!paths.contains(".claude/skills"))
        #expect(!paths.contains("REVIEW.md"))
        #expect(!paths.contains { $0.contains("claude-only") })
    }

    @Test func missingRequiredFieldUnknownLayerAndConflicts() throws {
        try takeHome()
        try write("layers/solo/layer.yaml", "conflicts: [base]\n")
        let result = Render.render(ProjectAnswers(layers: ["take-home", "solo", "ghost"], targets: []),
                                   brain: try brain(), projectName: "p")
        #expect(result.errors.contains("“Company name” (company) is required by take-home."))
        #expect(result.errors.contains("Layer “ghost” is not in the brain."))
        #expect(result.errors.contains("“solo” can't be used together with “base”."))
    }

    @Test func sameSkillOrFileFromTwoLayersNeedsOverride() throws {
        try write("skills/tdd/SKILL.md", "---\nname: tdd\n---\n")
        try write("layers/a/layer.yaml", "skills: [tdd]\nfiles:\n  - template: x.json\n")
        try write("layers/a/templates/x.json", "{\"a\": 1}")
        try write("layers/b/layer.yaml", "skills: [tdd]\nfiles:\n  - template: x.json\n")
        try write("layers/b/templates/x.json", "{\"b\": 1}")
        try write("layers/c/layer.yaml", "skills:\n  - name: tdd\n    mode: manual\n    override: true\nfiles:\n  - template: x.json\n    override: true\n")
        try write("layers/c/templates/x.json", "{\"c\": 1}")

        let clash = Render.render(ProjectAnswers(layers: ["a", "b"]), brain: try brain(), projectName: "p")
        #expect(clash.errors.contains { $0.hasPrefix("Skill “tdd” comes from both a and b.") })
        #expect(clash.errors.contains { $0.hasPrefix("x.json comes from a and b.") })

        let overridden = Render.render(ProjectAnswers(layers: ["a", "c"]), brain: try brain(), projectName: "p")
        #expect(overridden.errors.isEmpty, "\(overridden.errors)")
        #expect(text(overridden, "x.json") == "{\"c\": 1}")
        #expect(text(overridden, ".agents/skills/tdd/SKILL.md")?.contains("disable-model-invocation: true") == true)
    }

    @Test func requiresCycleDoesNotHang() throws {
        try write("layers/a/layer.yaml", "requires: [b]\n")
        try write("layers/b/layer.yaml", "requires: [a]\n")
        let result = Render.render(ProjectAnswers(layers: ["a"]), brain: try brain(), projectName: "p")
        #expect(Set(result.layers) == ["a", "b"])
    }

    @Test func pieces() {
        #expect(Render.substitute("{{a}} {{ b }} {{c}} {{", ["a": .text("1"), "b": .list(["x", "y"])])
                == ("1 x, y {{c}} {{", ["c"]))
        #expect(Render.manualOnly("---\nname: x\ndisable-model-invocation: false\n---\nbody") == "---\nname: x\ndisable-model-invocation: true\n---\nbody")
        #expect(Render.manualOnly("no header") == nil)
        #expect(Render.matches([Condition(parsing: "target == pi")!], ["target": .list(["claude", "pi"])]))
        #expect(!Render.matches([Condition(parsing: "flag")!], ["flag": .bool(false)]))
        #expect(Render.matches([Condition(parsing: "flag != false")!], ["flag": .bool(true)]))
    }
}
