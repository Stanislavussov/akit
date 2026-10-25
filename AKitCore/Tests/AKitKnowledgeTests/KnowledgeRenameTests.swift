import Foundation
import Testing
import AKitFoundation
@testable import AKitKnowledge

/// Renaming notes and maps (R3) on a base in a temporary fake home.
final class KnowledgeRenameTests {
    deinit { try? FileManager.default.removeItem(at: home) }

    let home: URL
    let fm = FileManager.default

    init() throws {
        home = URL(filePath: FileWalk.realPath(fm.temporaryDirectory) ?? fm.temporaryDirectory.path)
            .appending(path: "akit-kbr-\(UUID().uuidString)")
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
    }

    func env() -> HarnessEnvironment {
        HarnessEnvironment(homeDirectory: home,
                           variables: ["HOME": home.path, "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1"],
                           executableSearchPaths: [URL(filePath: "/usr/bin")])
    }

    func git(_ base: KnowledgeBase, _ args: String...) async throws -> String {
        let result = try #require(await ProcessRunner.run(URL(filePath: "/usr/bin/git"), arguments: args, directory: base.root,
                                                           environment: env().variables, timeout: 20))
        return result.output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A base with these files (path under areas/ → text), committed.
    func makeBase(_ files: [String: String]) async throws -> KnowledgeBase {
        let base = try await TemplateBase.base(home: home)
        for (path, text) in files {
            let url = base.areasFolder.appending(path: path)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
        }
        _ = try await KnowledgeGit(base: base.root, env: env()).commit(paths: ["areas"], message: "Files")
        return base
    }

    func text(_ base: KnowledgeBase, _ path: String) throws -> String {
        try String(contentsOf: base.areasFolder.appending(path: path), encoding: .utf8)
    }

    /// A map whose blocks link these values, written like Excalidraw does (indented, with nulls).
    func map(_ links: [String: String?]) -> String {
        let elements = links.sorted { $0.key < $1.key }.map { id, link in
            let value = link.map { "\"\($0)\"" } ?? "null"
            return """
                {
                  "id": "\(id)",
                  "type": "rectangle",
                  "x": 0, "y": 0, "width": 10, "height": 10,
                  "isDeleted": false,
                  "link": \(value)
                }
            """
        }
        return "{\n  \"type\": \"excalidraw\",\n  \"version\": 2,\n  \"elements\": [\n" + elements.joined(separator: ",\n") + "\n  ],\n  \"files\": {}\n}\n"
    }

    @Test func theRenameTable() async throws {
        let overview = map(["blk-a": "[[billing]]", "blk-b": "[[orders-api]]", "blk-c": nil, "blk-d": "[[maps/detail]]"])
        let base = try await makeBase([
            "payments/billing.md": "# billing\n",
            "payments/orders-api.md": "Sends [[billing]], see [[billing#Invoices|the invoices]] and [[payments/billing.md]].\n| [[billing\\|Billing]] |\nExact: akit:note/payments/billing.\n",
            "payments/maps/overview.excalidraw": overview,
            "payments/maps/detail.excalidraw": map(["blk-x": "[[overview]]"]),
            "logistics/routes.md": "Pays through [[payments/billing]]; the map [[payments/maps/detail]].\n",
            "logistics/maps/routes.excalidraw": map(["blk-p": "[[payments/maps/detail]]", "blk-q": "[[payments/billing]]"]),
        ])
        let plan = try base.planRename("payments/billing", to: "invoicing")
        #expect(plan.from == "payments/billing" && plan.to == "payments/invoicing" && plan.kind == .note)
        #expect(plan.files.first?.path == "areas/payments/billing.md" && plan.files.first?.newPath == "areas/payments/invoicing.md")
        #expect(plan.files.first { $0.path == "areas/payments/orders-api.md" }?.links.map(\.new)
            == ["[[invoicing]]", "[[invoicing#Invoices|the invoices]]", "[[payments/invoicing.md]]", "[[invoicing\\|Billing]]", "akit:note/payments/invoicing"])
        try await base.apply(plan, env: env())
        #expect(try text(base, "payments/orders-api.md")
            == "Sends [[invoicing]], see [[invoicing#Invoices|the invoices]] and [[payments/invoicing.md]].\n| [[invoicing\\|Billing]] |\nExact: akit:note/payments/invoicing.\n")
        #expect(try text(base, "logistics/routes.md") == "Pays through [[payments/invoicing]]; the map [[payments/maps/detail]].\n")
        // In a map only the link value changes; every other byte stays.
        #expect(try text(base, "payments/maps/overview.excalidraw") == overview.replacingOccurrences(of: "\"[[billing]]\"", with: "\"[[invoicing]]\""))
        #expect(try text(base, "logistics/maps/routes.excalidraw").contains("\"link\": \"[[payments/invoicing]]\""))
        #expect(try text(base, "payments/invoicing.md") == "# billing\n" && !fm.fileExists(atPath: base.noteFile("payments/billing").path))
        #expect(try await git(base, "status", "--porcelain").isEmpty)
        #expect(try await git(base, "log", "-1", "--format=%s") == "Rename note payments/billing to payments/invoicing, 8 links in 4 files")
        // After a rename every map still parses.
        for map in try base.mapGraph().maps { #expect(map.error == nil, "\(map.id)") }

        // A map: [[maps/detail]] in its area, [[payments/maps/detail]] from logistics, in notes and maps.
        let mapPlan = try base.planRename("payments/maps/detail", to: "billing-detail")
        try await base.apply(mapPlan, env: env())
        #expect(try text(base, "payments/maps/overview.excalidraw").contains("\"link\": \"[[maps/billing-detail]]\""))
        #expect(try text(base, "logistics/maps/routes.excalidraw").contains("\"link\": \"[[payments/maps/billing-detail]]\""))
        #expect(try text(base, "logistics/routes.md").contains("[[payments/maps/billing-detail]]"))
        #expect(fm.fileExists(atPath: base.mapFile("payments/maps/billing-detail").path))
        #expect(try await git(base, "status", "--porcelain").isEmpty)
    }

    @Test func aSilentRetargetIsRefused() async throws {
        // [[bar]] in c/ points to b/bar today; after a/foo → a/bar it would be ambiguous.
        let base = try await makeBase([
            "a/foo.md": "# foo\n", "b/bar.md": "# bar\n", "c/note.md": "See [[bar]] and [[foo]].\n",
        ])
        let before = try text(base, "c/note.md")
        #expect(throws: KnowledgeBase.Failure.self) { try base.planRename("a/foo", to: "bar") }
        do { _ = try base.planRename("a/foo", to: "bar") } catch {
            #expect(error.message.contains("[[bar]] in areas/c/note.md would point to several"), "\(error.message)")
            #expect(error.message.contains("nothing was written") && error.message.contains("Planned:\nareas/a/foo.md → areas/a/bar.md"))
        }
        #expect(try text(base, "c/note.md") == before && fm.fileExists(atPath: base.noteFile("a/foo").path))
    }

    @Test func aBrokenMapIsRefused() async throws {
        let base = try await makeBase([
            "payments/billing.md": "# billing\n",
            "payments/maps/broken.excalidraw": "{\"type\": \"excalidraw\", \"elements\": [{\"id\": \"x\", \"link\": \"[[billing]]\"}, \n",
        ])
        #expect(throws: KnowledgeBase.Failure.self) { try base.planRename("billing", to: "invoicing") }
        #expect(fm.fileExists(atPath: base.noteFile("payments/billing").path))
    }

    @Test func refusals() async throws {
        let base = try await makeBase(["payments/billing.md": "# billing\n", "payments/orders.md": "# orders\n"])
        #expect(throws: KnowledgeBase.Failure.self) { try base.planRename("billing", to: "orders") }
        #expect(throws: KnowledgeBase.Failure.self) { try base.planRename("billing", to: "billing") }
        #expect(throws: KnowledgeBase.Failure.self) { try base.planRename("payments", to: "pay") }
        #expect(throws: KnowledgeBase.Failure.self) { try base.planRename("billing", to: "payments/maps/x") }
        #expect(throws: KnowledgeBase.Failure.self) { try base.planRename("billing", to: "nowhere/x") }
        #expect(throws: KnowledgeBase.Failure.self) { try base.planRename("billing", to: ".hidden") }
        // A file changed after planning: nothing is written.
        let plan = try base.planRename("billing", to: "invoicing")
        try Data("# changed\n".utf8).write(to: base.noteFile("payments/billing"))
        await #expect(throws: KnowledgeBase.Failure.self) { try await base.apply(plan, env: env()) }
        #expect(fm.fileExists(atPath: base.noteFile("payments/billing").path) && !fm.fileExists(atPath: base.noteFile("payments/invoicing").path))
    }

    @Test func pendingEditsAreCommittedFirst() async throws {
        let base = try await makeBase(["payments/billing.md": "# billing\n", "payments/orders.md": "See [[billing]].\n"])
        try Data("# orders\nSee [[billing]].\n".utf8).write(to: base.noteFile("payments/orders"))
        #expect(KnowledgeCommitQueue(base: base.root, env: env()).enqueue(["areas/payments/orders.md"]) == .queued(refused: []))
        try await base.apply(try base.planRename("billing", to: "invoicing"), env: env())
        #expect(try await git(base, "log", "-2", "--format=%s") == "Rename note payments/billing to payments/invoicing, 1 link in 1 file\nEdit payments/orders")
        #expect(try text(base, "payments/orders.md") == "# orders\nSee [[invoicing]].\n")
    }

    /// A write that fails after a file was moved: every file is back as it was, the moved one at
    /// its old name, and no temporary `.akit-rename-*` is left. A rename, a change of case only,
    /// and a failure in a later file.
    @Test func aWriteFailingAfterTheMoveRestoresEverything() async throws {
        struct Refused: Error {}
        let files = ["payments/billing.md": "# billing\n", "payments/orders.md": "See [[billing]].\n"]
        let base = try await makeBase(files)
        func unchanged() throws {
            for (path, text) in files { #expect(try self.text(base, path) == text, "\(path)") }
            let names = try fm.contentsOfDirectory(atPath: base.areasFolder.appending(path: "payments").path).sorted()
            #expect(names == ["billing.md", "orders.md"], "\(names)")
        }
        for (target, failing) in [("invoicing", "invoicing.md"), ("Billing", "Billing.md"), ("invoicing", "orders.md")] {
            let plan = try base.planRename("billing", to: target)
            await #expect(throws: KnowledgeBase.Failure.self) {
                try await base.apply(plan, env: env()) { data, url in
                    if url.lastPathComponent == failing { throw Refused() }
                    try data.write(to: url, options: .atomic)
                }
            }
            try unchanged()
        }
        #expect(try await git(base, "status", "--porcelain").isEmpty)
        // The real writer still renames.
        try await base.apply(try base.planRename("billing", to: "invoicing"), env: env())
        #expect(try fm.contentsOfDirectory(atPath: base.areasFolder.appending(path: "payments").path).sorted() == ["invoicing.md", "orders.md"])
    }

    /// A change of case only (a disk that ignores case, like the Mac's): one commit with the
    /// rename and the rewritten links, `git status` clean, and an edit staged elsewhere stays out.
    @Test func aCaseOnlyRenameOfANoteAndAMapCommitsOnce() async throws {
        let base = try await makeBase([
            "payments/billing.md": "# billing\n",
            "payments/orders.md": "See [[billing]] on [[payments/maps/overview]].\n",
            "payments/maps/overview.excalidraw": map(["blk-a": "[[billing]]"]),
            "logistics/routes.md": "# routes\n",
        ])
        let before = try await git(base, "rev-list", "--count", "HEAD")
        try Data("# routes, staged\n".utf8).write(to: base.areasFolder.appending(path: "logistics/routes.md"))
        _ = try await git(base, "add", "areas/logistics/routes.md")

        try await base.apply(try base.planRename("billing", to: "Billing"), env: env())
        #expect(try await git(base, "rev-list", "--count", "HEAD") == String((Int(before) ?? 0) + 1))
        #expect(try await git(base, "log", "-1", "-M", "--name-status", "--format=%s")
            == "Rename note payments/billing to payments/Billing, 2 links in 2 files\n\n"
            + "R100\tareas/payments/billing.md\tareas/payments/Billing.md\nM\tareas/payments/maps/overview.excalidraw\nM\tareas/payments/orders.md")
        #expect(try text(base, "payments/orders.md") == "See [[Billing]] on [[payments/maps/overview]].\n")
        #expect(try text(base, "payments/maps/overview.excalidraw").contains("\"[[Billing]]\""))
        #expect(try await git(base, "status", "--porcelain") == "M  areas/logistics/routes.md")

        try await base.apply(try base.planRename("payments/maps/overview", to: "Overview"), env: env())
        #expect(try await git(base, "log", "-1", "-M", "--name-status", "--format=%s")
            == "Rename map payments/maps/overview to payments/maps/Overview, 1 link in 1 file\n\n"
            + "R100\tareas/payments/maps/overview.excalidraw\tareas/payments/maps/Overview.excalidraw\nM\tareas/payments/orders.md")
        #expect(try text(base, "payments/orders.md") == "See [[Billing]] on [[payments/maps/Overview]].\n")
        #expect(try await git(base, "ls-files", "areas/payments") == "areas/payments/Billing.md\nareas/payments/maps/Overview.excalidraw\nareas/payments/orders.md")
        #expect(try await git(base, "status", "--porcelain") == "M  areas/logistics/routes.md")
    }
}
