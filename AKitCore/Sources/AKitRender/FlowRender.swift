import AKitBrain
import Foundation

/// Pi files of the layers' flows (flows.md F3, F20): each flow as `.pi/flows/<name>.yaml` and the
/// runner extension as a folder `.pi/extensions/akit-flow/` (home: under `.pi/agent/`). Pi loads
/// only `index.ts` of an extension folder, so the guard and the handoff extension next to it load
/// only in the children that name them with `-e`. Every file is AKit's: the lock keeps its hash,
/// and Apply refuses to overwrite one that was edited by hand.
public enum FlowRender {
    public static let extensionName = "akit-flow"

    /// The runner's files by name, from the templates in `Resources/flows/`, plus `index.ts`.
    public static let extensionFiles: [(name: String, data: Data)] = [
        ("index.ts", Data("""
            // akit-flow: written by AKit Apply (docs/design/flows.md F3); Apply refuses to overwrite a hand edit.
            // Pi loads this entry point of the folder; the other files load from it or in a step's child (-e).
            export { default } from "./akit-flow.ts";

            """.utf8)),
        ("akit-flow.ts", Data(PackageResources.akit_flow_ts)),
        ("akit-flow-guard.ts", Data(PackageResources.akit_flow_guard_ts)),
        ("akit-flow-handoff.ts", Data(PackageResources.akit_flow_handoff_ts)),
        ("flow-core.ts", Data(PackageResources.flow_core_ts)),
        ("flow-git.ts", Data(PackageResources.flow_git_ts)),
        ("flow-record.ts", Data(PackageResources.flow_record_ts)),
        ("flow-view.ts", Data(PackageResources.flow_view_ts)),
        ("pi-adapter.ts", Data(PackageResources.pi_adapter_ts)),
    ]

    /// Pi's folder relative to the rendered root: the project's `.pi`, the home's `.pi/agent`.
    public static func piFolder(forHome: Bool) -> String { forHome ? ".pi/agent" : ".pi" }

    /// Every path these renders write: a flow file or a file of the extension folder.
    public static func isFlowPath(_ path: String) -> Bool {
        [".pi/flows/", ".pi/agent/flows/", ".pi/extensions/\(extensionName)/", ".pi/agent/extensions/\(extensionName)/"]
            .contains { path.hasPrefix($0) }
    }

    static func outputs(_ bundle: ProjectBundle, forHome: Bool) -> [RenderedFile] {
        guard !bundle.flows.isEmpty else { return [] }
        let pi = piFolder(forHome: forHome)
        var outputs = bundle.flows.map {
            RenderedFile(path: "\(pi)/flows/\($0.name).yaml", content: .data($0.data), layers: [$0.layer])
        }
        let layers = bundle.flows.map(\.layer).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        outputs += extensionFiles.map {
            RenderedFile(path: "\(pi)/extensions/\(extensionName)/\($0.name)", content: .data($0.data), layers: layers)
        }
        return outputs
    }
}
