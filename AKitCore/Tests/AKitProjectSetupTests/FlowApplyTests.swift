import Foundation
import Testing
@testable import AKitBrain
import AKitFoundation
import AKitRender
@testable import AKitProjectSetup

/// Flows in layers (flows.md F3): Apply renders `.pi/flows/` and the runner extension, refuses a
/// hand edit, keeps run records out of git and writes nothing of a work project to the brain.
struct FlowApplyTests {
    let f: GitProjectFixture

    init() throws { f = try GitProjectFixture("flows") }

    static let flowYAML = """
        akit-flow-format: 1
        name: feature
        steps:
          - id: plan
            agent: planner
            model: m/a
          - id: review
            agent: reviewer
            model: m/b
            routes:
              failed:*: plan
        """

    func setUpBrain() async throws -> Brain {
        _ = try await f.setUpBrain()
        try f.write(".akit/registry/flows/feature.yaml", Self.flowYAML)
        try f.write(".akit/registry/layers/flows/layer.yaml", "description: Flows\nflows:\n  - feature\n")
        try await f.git("add", "-A", in: f.brainRoot)
        try await f.git("commit", "-qm", "Add flows", in: f.brainRoot)
        return try #require(Brain.load(from: f.brainRoot))
    }

    var answers: ProjectAnswers { ProjectAnswers(layers: ["flows"], values: [:], targets: ["pi"], localOnly: false) }

    @Test func aLayerIncludesAFlowAndApplyRendersItWithTheExtension() async throws {
        let brain = try await setUpBrain()
        #expect(brain.layers.first { $0.name == "flows" }?.flows == ["feature"])
        try await f.initRepo()
        let plan = f.plan(answers, brain: brain)
        let paths = plan.changes.filter { $0.kind == .create }.map(\.path)
        #expect(paths.contains(".pi/flows/feature.yaml"))
        #expect(paths.contains(".pi/extensions/akit-flow/index.ts"))
        #expect(paths.contains(".pi/extensions/akit-flow/akit-flow-guard.ts"))
        #expect(paths.contains(".pi/extensions/akit-flow/akit-flow-handoff.ts"))
        #expect(plan.notes.contains { $0.contains("/.pi/akit-flow") })
        try await ProjectSetup.apply(plan, brain: brain, home: f.home, env: f.env, trash: f.trash)
        // JSON is YAML: the runner reads it without a YAML package.
        let text = try #require(f.read(".pi/flows/feature.yaml"))
        let json = try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        #expect(json["akit-flow-format"] as? Int == 1)
        #expect(f.read(".pi/extensions/akit-flow/flow-core.ts")?.contains("export function") == true)
        #expect(f.exclude.contains("/.pi/akit-flow"))
    }

    @Test func aHandEditedRunnerFileIsShownWithItsDiffAndNotOverwritten() async throws {
        let brain = try await setUpBrain()
        try await f.initRepo()
        try await ProjectSetup.apply(f.plan(answers, brain: brain), brain: brain, home: f.home, env: f.env, trash: f.trash)
        let path = ".pi/extensions/akit-flow/akit-flow.ts"
        try f.write("Projects/task/\(path)", "// my own runner\n")
        let plan = f.plan(answers, brain: brain)
        let change = try #require(plan.changes.first { $0.path == path })
        #expect(change.kind == .keepEdited && change.editedSinceRender)
        #expect(change.oldText == "// my own runner\n" && change.newText?.contains("akit-flow.ts: written by AKit") == true)
        #expect(plan.render.warnings.contains { $0.contains(path) })
        try await ProjectSetup.apply(plan, brain: brain, home: f.home, env: f.env, trash: f.trash)
        #expect(f.read(path) == "// my own runner\n")
        // Still refused on the next Apply: the lock keeps the hash AKit wrote.
        #expect(f.plan(answers, brain: brain).changes.first { $0.path == path }?.kind == .keepEdited)
    }

    @Test func aWorkProjectWritesNothingToTheBrain() async throws {
        let brain = try await setUpBrain()
        try await f.initRepo()
        try MachineProfile(kind: .work).save(home: f.home)
        let store = ProjectStore.current(brain: f.brainRoot, home: f.home)
        #expect(store.isLocal)
        let head = try await f.git("rev-parse", "HEAD", in: f.brainRoot)
        let plan = f.plan(ProjectAnswers(layers: ["flows"], values: [:], targets: ["pi"]), brain: brain, store: store)
        try await ProjectSetup.apply(plan, brain: brain, home: f.home, env: f.env, trash: f.trash)
        #expect(f.read(".pi/flows/feature.yaml") != nil)
        #expect(try await f.git("rev-parse", "HEAD", in: f.brainRoot) == head)
        #expect(try await f.git("status", "--porcelain", in: f.brainRoot).isEmpty)
        #expect(!f.fm.fileExists(atPath: f.brainRoot.appending(path: "projects/\(f.id)").path))
    }

    @Test func forgetTakesTheFlowsBlockOut() async throws {
        let brain = try await setUpBrain()
        try await f.initRepo()
        try await ProjectSetup.apply(f.plan(answers, brain: brain), brain: brain, home: f.home, env: f.env, trash: f.trash)
        #expect(f.exclude.contains("# >>> akit flows"))
        #expect(LocalOnly.takeOut(of: f.project, env: f.env) == nil)
        #expect(!f.exclude.contains("akit flows"))
    }

    @Test func theHomeLayerRendersUnderPisAgentFolder() throws {
        let bundle = ProjectBundle(projectName: "home", targets: ["pi"], layers: ["core"], files: [], skills: [],
                                   flows: [.init(name: "feature", layer: "core", data: Data("{}\n".utf8))], errors: [], warnings: [])
        let paths = Render.render(bundle, forHome: true).outputs.map(\.path)
        #expect(paths.contains(".pi/agent/flows/feature.yaml"))
        #expect(paths.contains(".pi/agent/extensions/akit-flow/index.ts"))
    }

    @Test func aMissingFlowOrNoPiTargetIsSaid() async throws {
        let brain = try await setUpBrain()
        try f.write(".akit/registry/layers/flows/layer.yaml", "flows:\n  - feature\n  - missing\n")
        let reloaded = try #require(Brain.load(from: f.brainRoot))
        let bundle = ProjectBundle.resolve(answers, brain: reloaded, projectName: "task")
        #expect(bundle.errors.contains { $0.contains("missing") })
        let claudeOnly = ProjectBundle.resolve(ProjectAnswers(layers: ["flows"], targets: ["claude"]), brain: brain, projectName: "task")
        #expect(claudeOnly.flows.isEmpty && claudeOnly.warnings.contains { $0.contains("Pi") })
    }

    /// The templates are embedded in the code; they must equal the files `make test-flows` tests.
    @Test func theEmbeddedRunnerEqualsTheTemplates() throws {
        let folder = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "../../Sources/AKitRender/Resources/flows").standardized
        for (name, data) in FlowRender.extensionFiles where name != "index.ts" {
            #expect(try Data(contentsOf: folder.appending(path: name)) == data, "\(name)")
        }
        let files = try f.fm.contentsOfDirectory(atPath: folder.path).filter { $0.hasSuffix(".ts") }
        #expect(Set(files) == Set(FlowRender.extensionFiles.map(\.name)).subtracting(["index.ts"]))
    }
}
