import Foundation
import Testing
@testable import AKitCore

/// Brain repo loading and layer checks, in a temporary folder.
struct BrainTests {
    let root: URL
    let fm = FileManager.default

    init() throws {
        root = fm.temporaryDirectory.appending(path: "akit-brain-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func write(_ path: String, _ text: String = "") throws {
        let url = root.appending(path: path)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    func skill(_ name: String) throws {
        try write("skills/\(name)/SKILL.md", "---\nname: \(name)\ndescription: The \(name) skill\n---\n")
    }

    func load() throws -> Brain { try #require(Brain.load(from: root)) }

    func messages(_ brain: Brain, _ layer: String? = nil) -> [String] {
        brain.problems.filter { layer == nil || $0.layer == layer }.map(\.message)
    }

    @Test func missingFolderIsNoBrain() {
        #expect(Brain.load(from: root.appending(path: "nope")) == nil)
    }

    @Test func readsTheLayerFromTheDesignDoc() throws {
        try skill("grilling")
        try skill("tdd")
        try write("layers/base/layer.yaml", "name: base\ndescription: Always\n")
        try write("layers/take-home/templates/AGENTS.md.d/take-home.md", "# {{company}}\n")
        try write("layers/take-home/templates/REVIEW.md")
        try write("layers/take-home/layer.yaml", """
            name: take-home
            description: Take-home assignment for a job application
            requires: [base]
            conflicts: []

            fields:
              - id: company
                prompt: Company name
                type: text
                required: true
              - id: stack
                prompt: Stack
                type: choice
                options: [node, swift]
                default: node
              - id: reviewer_readme
                prompt: Write a README for the reviewer?
                type: bool
                default: true

            skills:
              - name: grilling
                mode: manual
              - tdd

            files:
              - template: AGENTS.md.d/take-home.md
                to: AGENTS.md
              - template: REVIEW.md
                to: REVIEW.md
                when: reviewer_readme == true
              - template: REVIEW.md
                to: CLAUDE-REVIEW.md
                when: [reviewer_readme, target == "claude"]
            """)

        let brain = try load()
        #expect(brain.problems.isEmpty, "\(brain.problems)")
        #expect(brain.skills.map(\.name) == ["grilling", "tdd"])
        #expect(brain.skills.first?.description == "The grilling skill")
        #expect(brain.layers.map(\.name) == ["base", "take-home"])

        let layer = brain.layers[1]
        #expect(layer.requires == ["base"])
        #expect(layer.conflicts == [])
        #expect(layer.fields.map(\.id) == ["company", "stack", "reviewer_readme"])
        #expect(layer.fields[0].required)
        #expect(layer.fields[1].kind == .choice && layer.fields[1].options == ["node", "swift"])
        #expect(layer.fields[1].defaultValue == .text("node"))
        #expect(layer.fields[2].defaultValue == .bool(true))
        #expect(layer.skills.map(\.mode) == [.manual, .auto])
        #expect(layer.files[0].to == "AGENTS.md")
        #expect(layer.files[1].when == [Condition(field: "reviewer_readme", test: .equals("true"))])
        #expect(layer.files[2].when == [Condition(field: "reviewer_readme", test: .isSet),
                                        Condition(field: "target", test: .equals("claude"))])
    }

    @Test func conditionForms() {
        #expect(Condition(parsing: "a == b") == Condition(field: "a", test: .equals("b")))
        #expect(Condition(parsing: "a != 'x y'") == Condition(field: "a", test: .notEquals("x y")))
        #expect(Condition(parsing: " flag ") == Condition(field: "flag", test: .isSet))
        #expect(Condition(parsing: "a ==") == nil)
        #expect(Condition(parsing: "a b") == nil)
        #expect(Condition(parsing: "a == b == c") == nil)
        #expect(Condition(parsing: "a == x!=y") == nil)
        #expect(Condition(parsing: "a == \"b != c\"") == Condition(field: "a", test: .equals("b != c")))
        #expect(Condition(parsing: "a != 'x == y'") == Condition(field: "a", test: .notEquals("x == y")))
    }

    @Test func nullAndWrongTypesAreNotSilent() throws {
        try write("layers/x/templates/t.md")
        try write("layers/x/layer.yaml", """
            name: ~
            description:
            fields:
              - id: plain
                type:
                required: "true"
              - id: my field
              - id: many
                type: multi
                options: [a, b]
                default: [a, {b: c}]
            requires: [{x: y}]
            skills:
              - name: s
                mode:
                override: 1
            files:
              - template: t.md
                to:
                when:
                  - target: claude
              - template: t.md
                to: .
              - template: t.md
                to: t2.md
                when: !flag
            """)

        let brain = try load()
        let layer = try #require(brain.layers.first)
        #expect(layer.description == "")
        #expect(layer.fields.map(\.id) == ["plain", "many"])
        #expect(layer.fields[0].kind == .text)
        #expect(layer.fields[1].defaultValue == nil)
        #expect(layer.skills.first?.mode == .auto)
        #expect(layer.files.map(\.to) == ["t.md", "t2.md"])

        let problems = messages(brain, "x")
        #expect(!problems.contains { $0.hasPrefix("name ") })
        #expect(problems.contains("Field “plain”: required must be true or false."))
        #expect(problems.contains("Field “my field”: an id may use only letters, digits, _ and -."))
        #expect(problems.contains("Field “many”: default doesn't fit type multi."))
        #expect(problems.contains("“requires” must be a list of names."))
        #expect(problems.contains("Skill “s”: override must be true or false."))
        #expect(problems.contains("File “t.md”: “.” must be a relative file path inside the folder."))
        #expect(problems.contains { $0.hasPrefix("File “t.md”: can't read when “target: claude") })
        #expect(problems.contains { $0.hasPrefix("File “t.md”: can't read when “!flag") }, "\(problems)")
    }

    @Test func conflictsThroughRequires() throws {
        try write("layers/a/layer.yaml", "requires: [b]\nconflicts: [c]\n")
        try write("layers/b/layer.yaml", "requires: [c]\n")
        try write("layers/c/layer.yaml", "")
        try write("layers/d/layer.yaml", "requires: [b, e]\n")
        try write("layers/e/layer.yaml", "conflicts: [c]\n")

        let brain = try load()
        #expect(messages(brain, "a").contains("Conflicts with “c”, which it requires itself."))
        #expect(messages(brain, "d").contains("Requires “e”, which conflicts with “c” that this layer also needs."))
        #expect(messages(brain, "b").isEmpty)
    }

    @Test func manyRedundantRequiresLoadFast() throws {
        // Each layer requires every earlier one: walking every path would take minutes.
        for i in 0..<40 {
            let requires = (0..<i).map { "l\($0)" }.joined(separator: ", ")
            try write("layers/l\(i)/layer.yaml", "requires: [\(requires)]\n")
        }
        let start = Date()
        let brain = try load()
        #expect(Date().timeIntervalSince(start) < 2)
        #expect(brain.problems.isEmpty)
    }

    @Test func templatesMustBeFilesInsideTemplates() throws {
        try write("layers/x/templates/folder/inner.md")
        try write("secret.txt", "token")
        try fm.createSymbolicLink(at: root.appending(path: "layers/x/templates/link.md"),
                                  withDestinationURL: root.appending(path: "secret.txt"))
        try write("layers/x/layer.yaml", """
            files:
              - template: folder
              - template: link.md
            """)

        let problems = messages(try load(), "x")
        #expect(problems.contains("Template “folder” is a folder, not a file."))
        #expect(problems.contains("Template “link.md” points outside templates/."))
    }

    @Test func brokenYamlIsReportedAndOtherLayersStillLoad() throws {
        try write("layers/good/layer.yaml", "description: fine\n")
        try write("layers/bad/layer.yaml", "fields: [unclosed\n")
        try write("layers/empty/README.md")

        let brain = try load()
        #expect(brain.layers.map(\.name) == ["good"])
        let problems = messages(brain)
        #expect(problems.contains { $0.hasPrefix("layers/bad: layer.yaml is not valid YAML") })
        #expect(problems.contains("layers/empty has no layer.yaml."))
    }

    @Test func manifestMistakesBecomeProblems() throws {
        try write("layers/x/layer.yaml", """
            name: other
            colour: blue
            fields:
              - id: a
                type: number
              - id: pick
                type: choice
              - id: flag
                type: bool
                default: maybe
              - prompt: no id
              - id: a
              - id: target
            skills:
              - name: s
                mode: sometimes
            files:
              - template: ../outside.md
              - template: ok.md
                when: "a =="
            """)

        let problems = messages(try load(), "x")
        #expect(problems.contains("name “other” differs from the folder “x”; the folder name is used."))
        #expect(problems.contains("Unknown key “colour”."))
        #expect(problems.contains("Field “a”: unknown type “number” (text, choice, bool or multi)."))
        #expect(problems.contains("Field “pick”: a choice field needs options."))
        #expect(problems.contains("Field “flag”: default doesn't fit type bool."))
        #expect(problems.contains("A field has no id."))
        #expect(problems.contains("Field “target” is built in; pick another id."))
        #expect(problems.contains("Skill “s”: unknown mode “sometimes” (auto, manual or off)."))
        #expect(problems.contains("File “../outside.md”: “../outside.md” must be a relative file path inside the folder."))
        #expect(problems.contains("File “ok.md”: can't read when “a ==” (use field == value, field != value or field)."))
        #expect(problems.contains("Template “ok.md” is missing in templates/."))
    }

    @Test func crossLayerChecks() throws {
        try skill("tdd")
        try write("layers/a/layer.yaml", """
            requires: [b, ghost]
            conflicts: b
            fields:
              - id: own
            skills: [tdd, tdd, missing]
            files:
              - template: f.md
                when: [own, from_b, from_c, target != pi]
            """)
        try write("layers/a/templates/f.md")
        try write("layers/b/layer.yaml", "requires: [a]\nfields:\n  - id: from_b\n")
        try write("layers/c/layer.yaml", "fields:\n  - id: from_c\n")

        let brain = try load()
        let a = messages(brain, "a")
        #expect(a.contains("Requires “ghost”, which doesn't exist."))
        #expect(a.contains("Conflicts with “b”, which it requires itself."))
        #expect(messages(brain, "b").contains("Requires “a”, which conflicts with this layer."))
        #expect(a.contains("Skill “tdd” is listed twice."))
        #expect(a.contains("Skill “missing” is not in skills/."))
        #expect(a.contains("when uses “from_c”, which is not a field of this layer or the layers it requires."))
        #expect(!a.contains { $0.contains("“own”") || $0.contains("“from_b”") || $0.contains("“target”") })
        #expect(a.contains("requires goes in a circle: a → b → a."))
        #expect(messages(brain).filter { $0.contains("circle") }.count == 1)
    }
}

/// Creating a brain repo in a temporary folder, with a throwaway git identity.
struct BrainSetupTests {
    let home: URL
    let fm = FileManager.default

    init() throws {
        home = fm.temporaryDirectory.appending(path: "akit-brain-setup-\(UUID().uuidString)")
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
    }

    var env: HarnessEnvironment {
        HarnessEnvironment(homeDirectory: home, variables: [
            "HOME": home.path, "GIT_CONFIG_NOSYSTEM": "1",
            "GIT_AUTHOR_NAME": "Test", "GIT_AUTHOR_EMAIL": "test@example.com",
            "GIT_COMMITTER_NAME": "Test", "GIT_COMMITTER_EMAIL": "test@example.com",
        ], executableSearchPaths: [URL(filePath: "/usr/bin")])
    }

    @Test func createsALoadableBrainWithOneCommit() async throws {
        let root = Brain.defaultRoot(home: home)
        try await BrainSetup.create(at: root, env: env)

        let brain = try #require(Brain.load(from: root))
        #expect(brain.layers.map(\.name) == ["core"])
        #expect(brain.problems.isEmpty, "\(brain.problems)")
        #expect(fm.fileExists(atPath: root.appending(path: "projects").path))

        let log = try #require(await ProcessRunner.run(URL(filePath: "/usr/bin/git"), arguments: ["log", "--oneline"],
                                                        directory: root, environment: env.variables, timeout: 10))
        #expect(log.succeeded)
        #expect(log.output.contains("Create brain repo"))
    }

    @Test func refusesAFolderWithFiles() async throws {
        let root = home.appending(path: "busy")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("mine".utf8).write(to: root.appending(path: "notes.md"))

        await #expect(throws: BrainSetup.Failure.self) { try await BrainSetup.create(at: root, env: env) }
        #expect(try fm.contentsOfDirectory(atPath: root.path) == ["notes.md"])
    }
}
