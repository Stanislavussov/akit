import Foundation
import Testing
import AKitFoundation
@testable import AKitBrain
@testable import AKitRender

/// Layers' JSON files (`.mcp.json`, `.claude/settings.json`) merged key by key.
struct JSONRenderTests {
    let root: URL
    let fm = FileManager.default

    init() throws {
        root = fm.temporaryDirectory.appending(path: "akit-json-render-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func write(_ path: String, _ text: String = "") throws {
        let url = root.appending(path: path)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    /// A layer that brings one template into `to`.
    func layer(_ name: String, to: String = ".mcp.json", _ json: String, override: Bool = false, fields: String = "") throws {
        try write("layers/\(name)/layer.yaml", "\(fields)files:\n  - template: t.json\n    to: \(to)\n    override: \(override)\n")
        try write("layers/\(name)/templates/t.json", json)
    }

    func render(_ layers: [String], values: [String: FieldValue] = [:], forHome: Bool = false) throws -> RenderResult {
        let brain = try #require(Brain.load(from: root))
        return Render.render(ProjectBundle.resolve(ProjectAnswers(layers: layers, values: values, targets: ["claude"]), brain: brain, projectName: "p"),
                             forHome: forHome)
    }

    func output(_ result: RenderResult, _ path: String = ".mcp.json") -> RenderedFile? { result.outputs.first { $0.path == path } }

    @Test func twoLayersMergeIntoOneFile() throws {
        try layer("github", #"{"mcpServers": {"github": {"command": "gh", "args": ["mcp", "serve"]}}}"#)
        try layer("files", #"{"mcpServers": {"files": {"command": "fs"}, "github": {"command": "gh"}}}"#)
        let result = try render(["github", "files"])
        #expect(result.errors.isEmpty, "\(result.errors)")
        let file = try #require(output(result))
        #expect(file.mergesJSON)
        #expect(file.layers == ["github", "files"])
        #expect(file.text == """
            {
              "mcpServers": {
                "files": {
                  "command": "fs"
                },
                "github": {
                  "args": [
                    "mcp",
                    "serve"
                  ],
                  "command": "gh"
                }
              }
            }

            """)
    }

    @Test func aLeafSetDifferentlyByTwoLayersIsAnError() throws {
        try layer("a", #"{"mcpServers": {"x": {"command": "one", "args": ["a"]}}}"#)
        try layer("b", #"{"mcpServers": {"x": {"command": "two", "args": ["a"]}}}"#)
        try layer("c", #"{"mcpServers": {"x": "flat"}}"#)
        let clash = try render(["a", "b"])
        #expect(clash.errors == [".mcp.json: mcpServers.x.command is set differently by a and b. Set override: true in the layer that should win."])
        // A value where the other layer has an object clashes too.
        let shape = try render(["a", "c"])
        #expect(shape.errors == [".mcp.json: mcpServers.x is set differently by a and c. Set override: true in the layer that should win."])
    }

    @Test func overrideWinsFromEitherSide() throws {
        try layer("a", #"{"permissions": {"defaultMode": "plan"}, "x": 1}"#)
        try layer("b", #"{"permissions": {"defaultMode": "acceptEdits"}, "y": 2}"#, override: true)
        try layer("c", #"{"permissions": {"defaultMode": "default"}}"#)
        for (layers, mode) in [(["a", "b"], "acceptEdits"), (["b", "c"], "acceptEdits")] {
            let result = try render(layers)
            #expect(result.errors.isEmpty, "\(result.errors)")
            let tree = try JSONValue.parse(Data(try #require(output(result)?.text).utf8))
            #expect(tree.value(at: ["permissions", "defaultMode"]) == .string(mode))
        }
    }

    @Test func fieldsAreFilledOnlyInsideStrings() throws {
        try layer("x", #"{"mcpServers": {"{{name}}": {"command": "{{tool}}", "args": ["--project", "{{project_name}}", "{{typo}}"], "port": 8080}}}"#,
                  fields: "fields:\n  - id: tool\n  - id: name\n")
        let result = try render(["x"], values: ["tool": .text(#"run "quoted" \ tool"#), "name": .text("srv")])
        #expect(result.errors.isEmpty, "\(result.errors)")
        #expect(result.warnings == ["x/t.json uses {{typo}}, which is not a field; it is left as is."])
        let tree = try JSONValue.parse(Data(try #require(output(result)?.text).utf8))
        // Keys are never filled: a field can't add or rename a key.
        #expect(tree.value(at: ["mcpServers", "{{name}}", "command"]) == .string(#"run "quoted" \ tool"#))
        #expect(tree.value(at: ["mcpServers", "{{name}}", "args"]) == .array([.string("--project"), .string("p"), .string("{{typo}}")]))
        #expect(tree.value(at: ["mcpServers", "{{name}}", "port"]) == .number("8080"))
    }

    @Test func invalidOrNonObjectTemplatesAreErrors() throws {
        try layer("broken", #"{"mcpServers": {"#)
        try layer("list", "[1, 2]")
        let result = try render(["broken", "list"])
        #expect(result.errors.contains { $0.hasPrefix("broken/t.json is not valid JSON: ") })
        #expect(result.errors.contains("list/t.json must be a JSON object ({ … }); it is merged into .mcp.json key by key."))
        #expect(output(result) == nil)
    }

    @Test func layersBringOnlyReferencesUnderEnvAndHeaders() throws {
        try layer("secret", #"{"mcpServers": {"api": {"env": {"TOKEN": "sk-123", "HOME_DIR": "${HOME}"}, "headers": {"Authorization": "Bearer ${TOKEN}"}}}}"#)
        let refused = try render(["secret"])
        #expect(refused.errors.count == 2)
        #expect(refused.errors.contains { $0.hasPrefix("secret/t.json: mcpServers.api.env.TOKEN holds a value.") })
        #expect(refused.errors.contains { $0.hasPrefix("secret/t.json: mcpServers.api.headers.Authorization holds a value.") })
        #expect(output(refused) == nil)

        try layer("secret", #"{"mcpServers": {"api": {"env": {"TOKEN": "${API_TOKEN}"}, "headers": {"Authorization": "${AUTH_HEADER}"}}}, "env": {"DEBUG": "${AKIT_DEBUG}"}}"#)
        let accepted = try render(["secret"])
        #expect(accepted.errors.isEmpty, "\(accepted.errors)")
        #expect(output(accepted)?.text?.contains("${API_TOKEN}") == true)
    }

    @Test func filesWithSecretsAreNeverATarget() throws {
        try layer("local", to: ".claude/settings.local.json", #"{"a": 1}"#)
        try layer("auth", to: ".pi/agent/auth.json", #"{"a": 1}"#)
        let result = try render(["local", "auth"])
        #expect(result.errors == [
            "local/t.json targets .claude/settings.local.json, a file that holds secrets (private settings or credentials); layers can't write it.",
            "auth/t.json targets .pi/agent/auth.json, a file that holds secrets (private settings or credentials); layers can't write it."])
        #expect(result.outputs.isEmpty)
    }

    @Test func onlyClaudeCodesFilesAreMergedOtherJSONIsAWholeFile() throws {
        // tsconfig.json with comments: a whole file, filled as text like any template.
        try layer("ts", to: "tsconfig.json", "// {{project_name}}\n{\"a\": 1,}\n")
        try layer("ts2", to: "./tsconfig.json", "{}", override: true)
        try layer("mcp", to: "./.MCP.json", #"{"mcpServers": {}}"#)
        let whole = try render(["ts"])
        #expect(whole.errors.isEmpty, "\(whole.errors)")
        #expect(output(whole, "tsconfig.json")?.text == "// p\n{\"a\": 1,}\n")
        #expect(output(whole, "tsconfig.json")?.mergesJSON == false)
        // `./` is dropped, so both layers name one file; the overriding one wins.
        #expect(output(try render(["ts", "ts2"]), "tsconfig.json")?.text == "{}")
        // .MCP.json is .mcp.json on macOS: merged.
        #expect(output(try render(["mcp"]), ".MCP.json")?.mergesJSON == true)
    }

    @Test func oneFileSpelledTwoWaysIsAnError() throws {
        try layer("a", #"{"x": 1}"#)
        try layer("b", to: ".MCP.json", #"{"y": 1}"#)
        let result = try render(["a", "b"])
        #expect(result.errors == [".mcp.json and .MCP.json (b) are the same file on macOS. Spell it one way in every layer."])
        #expect(result.outputs.map(\.path) == [".mcp.json"])
    }

    @Test func theHomeFolderGetsNoJSONYet() throws {
        try layer("core", to: ".claude/settings.json", #"{"a": 1}"#)
        let result = try render(["core"], forHome: true)
        #expect(result.errors.isEmpty)
        #expect(result.outputs.isEmpty)
        #expect(result.warnings == [".claude/settings.json (core): JSON files are not rendered into the home folder yet; skipped."])
    }
}
