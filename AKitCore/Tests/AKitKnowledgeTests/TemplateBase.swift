import Foundation
import AKitFoundation
@testable import AKitKnowledge

/// One new base and one sample base, each made once per test process (`KnowledgeBase.create`,
/// `KnowledgeSeed.seed` run their git commands once), copied into a test's own home. For tests
/// that need "a base", not the making of one: those keep calling `create` and `seed` themselves.
enum TemplateBase {
    /// The folder of both templates; removed when the test process exits.
    static let folder: URL = {
        let fm = FileManager.default
        let url = URL(filePath: FileWalk.realPath(fm.temporaryDirectory) ?? fm.temporaryDirectory.path)
            .appending(path: "akit-kb-template-\(UUID().uuidString)")
        atexit { try? FileManager.default.removeItem(at: TemplateBase.folder) }
        return url
    }()

    private static let made = Task { () throws -> (base: URL, seeded: URL) in
        func env(_ home: URL) -> HarnessEnvironment {
            HarnessEnvironment(homeDirectory: home,
                               variables: ["HOME": home.path, "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1"],
                               executableSearchPaths: [URL(filePath: "/usr/bin")])
        }
        let plain = folder.appending(path: "plain"), sample = folder.appending(path: "sample")
        try FileManager.default.createDirectory(at: plain, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sample, withIntermediateDirectories: true)
        let base = try await KnowledgeBase.create(world: "work", env: env(plain))
        let seeded = try await KnowledgeSeed.seed(env: env(sample)).base
        return (base.root, seeded.root)
    }

    /// A new, empty base (what `create` makes, with its first commit) as the base of `world` in `home`.
    static func base(world: String = "work", home: URL) async throws -> KnowledgeBase {
        try await copy(made.value.base, world: world, home: home)
    }

    /// The sample base (`kb seed`) as the base of `world` in `home`.
    static func seeded(world: String = KnowledgeSeed.world, home: URL) async throws -> KnowledgeBase {
        try await copy(made.value.seeded, world: world, home: home)
    }

    private static func copy(_ template: URL, world: String, home: URL) throws -> KnowledgeBase {
        let root = KnowledgeBase.root(world: world, home: home)
        try FileManager.default.createDirectory(at: root.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: template, to: root)
        return KnowledgeBase(root: root, world: world)
    }
}
