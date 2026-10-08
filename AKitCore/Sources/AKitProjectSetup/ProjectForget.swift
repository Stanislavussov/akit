import AKitBrain
import AKitFoundation
import Foundation

/// Forgets a project (or a home folder): the files AKit wrote there go to the Trash (an empty
/// render), then its record leaves the project store. `akit remove project` and the Brain
/// screen's Forget Project… share it.
public enum ProjectForget {
    public struct Preview: Sendable {
        public let id: String
        public let store: ProjectStore
        /// The empty render of the folder; nil when the folder is not on this Mac.
        public let plan: ProjectSetup.Plan?
        /// The store has the record (false on a work Mac whose record is only in the brain).
        public let ownRecord: Bool
        /// The brain still has `projects/<id>` from before this became a work Mac. AKit leaves
        /// it alone: other Macs may read it.
        public let brainCopyLeft: Bool
        /// Files AKit wrote that go to the Trash.
        public var removals: [String] { plan?.changes.filter { $0.kind == .remove }.map(\.path) ?? [] }
        /// JSON files the project keeps, with the keys AKit merged into them taken out.
        public var keysTakenOut: [String] { plan?.changes.filter { $0.mergesJSON && $0.kind == .update }.map(\.path) ?? [] }
        /// Instruction files (home folder) the user keeps, with AKit's block taken out.
        public var blocksTakenOut: [String] { plan?.changes.filter { $0.block && $0.kind == .update }.map(\.path) ?? [] }
        /// JSON files where AKit's keys stay although the record goes: AKit can't read the file
        /// as JSON (or it is a link or a folder), so it can't take them out.
        public var keysLeft: [String] { plan?.jsonRecords.keys.sorted() ?? [] }
        /// Instruction files where AKit's block stays although the record goes: edited by hand,
        /// found without a record, or a file AKit can't safely write (a link, broken markers).
        public var blocksLeft: [String] {
            guard let plan else { return [] }
            let left = plan.changes.filter { $0.block && [.keepEdited, .suggest, .own].contains($0.kind) }.map(\.path)
            return Set(left + plan.blockSkipped).sorted()
        }
        /// Files AKit wrote and the user edited since: kept.
        public var kept: [String] { plan?.changes.filter { $0.kind == .keepEdited && !$0.block }.map(\.path) ?? [] }
    }

    /// What forgetting would do; nil when nothing is saved for the id. Only reads.
    /// `piAgentDirSetting`: see `ProjectSetup.plan`.
    public static func preview(id: String, folder: URL?, forHome: Bool, brain: Brain, store: ProjectStore,
                               piAgentDirSetting: String? = nil) -> Preview? {
        guard var empty = ProjectRecords.savedAnswers(id: id, in: store) else { return nil }
        empty.layers = []
        empty.skills = []
        let plan = folder.map { ProjectSetup.plan(project: $0, id: id, answers: empty, brain: brain, store: store, forHome: forHome,
                                                  piAgentDirSetting: piAgentDirSetting) }
        let fm = FileManager.default
        return Preview(id: id, store: store, plan: plan,
                       ownRecord: !store.isLocal || fm.fileExists(atPath: store.folder(id: id).path),
                       brainCopyLeft: store.isLocal && store.readFallback.map { fm.fileExists(atPath: $0.appending(path: id).path) } == true)
    }

    /// Trashes the files AKit wrote (unless `keepFiles`), then the record, committed when the
    /// store is the brain's.
    public static func run(_ preview: Preview, keepFiles: Bool, brain: Brain, home: URL, env: HarnessEnvironment,
                           trash: (URL) throws -> URL? = Trash.move) async throws {
        // The Mac may have become a work Mac (or stopped being one) since the preview.
        guard preview.store.isSamePlace(as: .current(brain: preview.store.brain ?? brain.root, home: home)) else {
            throw ProjectSetup.Failure(message: "This Mac's role (akit machine) changed since the preview; preview again.")
        }
        if !keepFiles, let plan = preview.plan, !preview.removals.isEmpty || !preview.keysTakenOut.isEmpty || !preview.blocksTakenOut.isEmpty {
            _ = try await ProjectSetup.apply(plan, brain: brain, home: home, env: env, trash: trash)
        }
        // Apply saved a lock again, in a local store too; forget the project with it.
        let store = preview.store
        if !store.isLocal || FileManager.default.fileExists(atPath: store.folder(id: preview.id).path) {
            try await BrainRemove.forgetProject(preview.id, in: store, env: env, trash: trash)
        }
    }
}
