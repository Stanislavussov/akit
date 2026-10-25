import AKitBrain
import AKitFoundation
import Foundation

/// The Pi template (K16, option D0 of the plan): a short section about the base in the core
/// layer, `templates/kb-pi.md`, listed in `files:` as `{template: kb-pi.md, to: AGENTS.md,
/// when: target == pi}`. The core layer renders once per target, so `akit apply --home` puts it
/// only into the AGENTS.md Pi reads in `~/.pi/agent`, never into `~/.claude/CLAUDE.md`. The text
/// was chosen in slice 3.4; edit it in the brain layer to change it (the next run of
/// `akit kb pi-template` writes this text back).
public enum KnowledgePiTemplate {
    public static let layer = "core"
    public static let template = "kb-pi.md"
    public static let target = "AGENTS.md"
    public static let when = [Condition(field: "target", test: .equals("pi"))]

    public static let text = """
        ## Knowledge base
        This Mac has a knowledge base of the systems around your repositories. At the start of a task that touches other services, events or repositories, run `akit kb context --json` and read the card; then `akit kb search QUERY --json` and `akit kb show NOTE --json` for details.
        Never edit the base yourself: propose changes with `akit kb propose`, and follow the /akit-context skill for what you may run.

        """

    public struct Failure: Error, LocalizedError {
        public let message: String
        public var errorDescription: String? { message }
    }

    /// What `apply` would write, read from disk now; `isEmpty` = already set.
    public static func plan(brain: Brain) throws(Failure) -> LayerEditor.FileEdit {
        guard let core = brain.layers.first(where: { $0.name == layer }) else {
            throw Failure(message: "The brain at \(brain.root.path) has no core layer.")
        }
        do {
            return try LayerEditor.fileEdit(template: template, to: target, when: when, text: text, in: core)
        } catch {
            throw Failure(message: error.message)
        }
    }

    /// Commits the base's pending edits first (when there is a base), so nothing else waits while
    /// the brain changes, then writes `edit` through `LayerEditor` (read-back verify, the work-Mac
    /// identity check, one brain commit). An empty edit writes nothing.
    public static func apply(_ edit: LayerEditor.FileEdit, base: KnowledgeBase?, brain: Brain, env: HarnessEnvironment) async throws(Failure) {
        if let base, KnowledgeBase.isBase(base.root) {
            _ = await KnowledgeCommitQueue(base: base.root, env: env).flush()
        }
        guard !edit.isEmpty else { return }
        do {
            try await LayerEditor.apply(edit, to: target, when: when,
                                        message: edit.changesLayer ? "Add the knowledge base section for Pi to layer core" : "Update the knowledge base section for Pi in layer core",
                                        in: brain, env: env)
        } catch {
            throw Failure(message: error.message)
        }
    }
}
