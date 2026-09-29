import Foundation
import Testing
import AKitFoundation
@testable import AKitBrain

/// Editing an existing layer from the Brain screen, in a temporary brain.
struct LayerEditorTests {
    let home: URL
    let fm = FileManager.default

    init() throws {
        home = fm.temporaryDirectory.appending(path: "akit-edit-\(UUID().uuidString)")
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
    }

    var env: HarnessEnvironment {
        HarnessEnvironment(homeDirectory: home, variables: [
            "HOME": home.path, "GIT_CONFIG_NOSYSTEM": "1",
            "GIT_AUTHOR_NAME": "Test", "GIT_AUTHOR_EMAIL": "test@example.com",
            "GIT_COMMITTER_NAME": "Test", "GIT_COMMITTER_EMAIL": "test@example.com",
        ], executableSearchPaths: [URL(filePath: "/usr/bin")])
    }

    var root: URL { Brain.defaultRoot(home: home) }

    func brain() async throws -> Brain {
        if !fm.fileExists(atPath: root.path) {
            try await BrainSetup.create(at: root, env: env)
            for name in ["tdd", "grill"] {
                let skill = root.appending(path: "skills/\(name)/SKILL.md")
                try fm.createDirectory(at: skill.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data("---\nname: \(name)\n---\n".utf8).write(to: skill)
            }
            try await LayerWriter.create(LayerWriter.Draft(name: "web"), in: try #require(Brain.load(from: root)), env: env)
        }
        return try #require(Brain.load(from: root))
    }

    func lastCommit() async throws -> String {
        try #require(await ProcessRunner.run(URL(filePath: "/usr/bin/git"), arguments: ["log", "-1", "--format=%s", "--name-only"],
                                              directory: root, environment: env.variables, timeout: 10)).output
    }

    @Test func addsSkillsAndChangesTheirModeWithCommits() async throws {
        try await LayerEditor.addSkills(["tdd", "grill"], mode: .auto, toLayer: "web", in: try await brain(), env: env)
        var layer = try #require(try await brain().layers.first { $0.name == "web" })
        #expect(layer.skills.map(\.name) == ["tdd", "grill"] && layer.skills.allSatisfy { $0.mode == .auto })
        #expect(try await lastCommit() == "Add tdd, grill to layer web\n\nlayers/web/layer.yaml\n")

        try await LayerEditor.setMode(.manual, ofSkill: "grill", inLayer: "web", in: try await brain(), env: env)
        layer = try #require(try await brain().layers.first { $0.name == "web" })
        #expect(layer.skills.map(\.mode) == [.auto, .manual])
        #expect(try await lastCommit() == "Make grill manual in layer web\n\nlayers/web/layer.yaml\n")

        await #expect(throws: LayerEditor.Failure.self) {
            try await LayerEditor.addSkills(["tdd"], mode: .auto, toLayer: "web", in: try await brain(), env: env)
        }
        await #expect(throws: LayerEditor.Failure.self) {
            try await LayerEditor.addSkills(["nope"], mode: .auto, toLayer: "web", in: try await brain(), env: env)
        }
    }

    @Test func editsDetailsAndAddsTheAgentsSection() async throws {
        let details = LayerEditor.Details(description: "Web apps: #1", requires: ["core"], agentsSection: "## Web\nUse {{project_name}}.\n\n")
        try await LayerEditor.update("web", to: details, in: try await brain(), env: env)

        let brain = try await brain()
        #expect(brain.problems.isEmpty, "\(brain.problems)")
        let layer = try #require(brain.layers.first { $0.name == "web" })
        #expect(LayerEditor.details(of: layer) == LayerEditor.Details(description: "Web apps: #1", requires: ["core"],
                                                                     agentsSection: "## Web\nUse {{project_name}}."))
        #expect(layer.files == [LayerFile(template: "AGENTS.md", to: "AGENTS.md", when: [], override: false)])
        #expect(try await lastCommit() == "Edit layer web\n\nlayers/web/layer.yaml\nlayers/web/templates/AGENTS.md\n")

        // Only the section changes: layer.yaml stays as it is.
        let before = try String(contentsOf: layer.manifest, encoding: .utf8)
        try await LayerEditor.update("web", to: LayerEditor.Details(description: "Web apps: #1", requires: ["core"]), in: brain, env: env)
        #expect(try String(contentsOf: layer.manifest, encoding: .utf8) == before)
        #expect(try String(contentsOf: layer.templates.appending(path: "AGENTS.md"), encoding: .utf8) == "")
        #expect(try await lastCommit() == "Edit layer web\n\nlayers/web/templates/AGENTS.md\n")
    }

    @Test func refusesARequiresCycle() async throws {
        let brain = try await brain()
        #expect(LayerEditor.requirable(by: "web", in: brain) == ["core"])
        try await LayerEditor.update("core", to: LayerEditor.Details(requires: ["web"]), in: brain, env: env)
        let after = try await self.brain()
        #expect(LayerEditor.requirable(by: "web", in: after).isEmpty)
        await #expect(throws: LayerEditor.Failure.self) {
            try await LayerEditor.update("web", to: LayerEditor.Details(requires: ["core"]), in: after, env: env)
        }
    }

    @Test func aMissingRequiredLayerDoesNotBlockOtherEdits() async throws {
        let brain = try await brain()
        let manifest = root.appending(path: "layers/web/layer.yaml")
        try Data("name: web\nrequires: [gone]\n".utf8).write(to: manifest)
        try await LayerEditor.update("web", to: LayerEditor.Details(description: "Web", requires: ["gone"]), in: brain, env: env)
        #expect(try String(contentsOf: manifest, encoding: .utf8) == "name: web\ndescription: Web\nrequires: [gone]\n")
        await #expect(throws: LayerEditor.Failure.self) {
            try await LayerEditor.update("web", to: LayerEditor.Details(requires: ["gone", "other"]), in: brain, env: env)
        }
    }

    @Test func modeEditsKeepTheRestOfTheFile() throws {
        let text = "name: x\n# skills\nskills:\n  - name: a\n    mode: manual\n  - b  # note\n  - mode: auto\n    name: c\n  - name: d\n    when: flag\nfiles: []\n"
        #expect(try LayerEditor.settingMode(.auto, of: "a", in: text)
                == "name: x\n# skills\nskills:\n  - name: a\n    mode: auto\n  - b  # note\n  - mode: auto\n    name: c\n  - name: d\n    when: flag\nfiles: []\n")
        #expect(try LayerEditor.settingMode(.manual, of: "b", in: text)
                == "name: x\n# skills\nskills:\n  - name: a\n    mode: manual\n  - name: b\n    mode: manual\n  - mode: auto\n    name: c\n  - name: d\n    when: flag\nfiles: []\n")
        #expect(try LayerEditor.settingMode(.off, of: "c", in: text)
                == "name: x\n# skills\nskills:\n  - name: a\n    mode: manual\n  - b  # note\n  - mode: off\n    name: c\n  - name: d\n    when: flag\nfiles: []\n")
        #expect(try LayerEditor.settingMode(.manual, of: "d", in: text)
                == "name: x\n# skills\nskills:\n  - name: a\n    mode: manual\n  - b  # note\n  - mode: auto\n    name: c\n  - name: d\n    mode: manual\n    when: flag\nfiles: []\n")
        #expect(try LayerEditor.settingMode(.manual, of: "a", in: text) == text)
        // keep_auto (akit recommend's pin) stays and doesn't make the edit look unsafe.
        let pinned = "skills:\n  - name: e\n    mode: auto\n    keep_auto: true\n"
        #expect(try LayerEditor.settingMode(.manual, of: "e", in: pinned) == "skills:\n  - name: e\n    mode: manual\n    keep_auto: true\n")
        #expect(throws: LayerEditor.Failure.self) { try LayerEditor.settingMode(.auto, of: "z", in: text) }
        #expect(throws: LayerEditor.Failure.self) { try LayerEditor.settingMode(.manual, of: "a", in: "skills: [a]\n") }
    }

    @Test func detailEditsKeepTheRestOfTheFile() throws {
        let text = "name: x\n# about\ndescription: >\n  Old\n  text\nskills:\n  - a\n"
        #expect(try LayerEditor.settingDetails(description: "New: one", requires: ["base"], in: text)
                == "name: x\n# about\ndescription: 'New: one'\nrequires: [base]\nskills:\n  - a\n")
        #expect(try LayerEditor.settingDetails(description: "", requires: [], in: "name: x\ndescription: Old\nrequires:\n  - base\nskills: []\n")
                == "name: x\nskills: []\n")
        #expect(try LayerEditor.settingDetails(description: "Old", requires: [], in: "description: Old # kept\n")
                == "description: Old # kept\n")
        #expect(try LayerEditor.settingDetails(description: "D", requires: [], in: "") == "description: D\n")
        // A folded description the user didn't change stays as written.
        #expect(try LayerEditor.settingDetails(description: "Old text", requires: ["base"], in: text)
                == "name: x\n# about\ndescription: >\n  Old\n  text\nrequires: [base]\nskills:\n  - a\n")
        #expect(try LayerEditor.addingAgentsFile(to: "name: x\nfiles:\n- template: a.md\n  to: A.md\n")
                == "name: x\nfiles:\n- template: a.md\n  to: A.md\n- template: AGENTS.md\n  to: AGENTS.md\n")
    }
}
