import Foundation
import Testing
import AKitBrain
import AKitFoundation
@testable import AKitKnowledge

/// K24: kinds in `kb.yaml`, note properties as one-line frontmatter edits (P4), `area.yaml`.
final class KnowledgeSettingsTests {
    deinit { try? FileManager.default.removeItem(at: home) }

    let home: URL
    let fm = FileManager.default

    init() throws {
        home = try FakeHome.make("akit-kb-settings")
    }

    var env: HarnessEnvironment { FakeHome.env(home) }

    func git(_ args: String..., in folder: URL) async throws -> String {
        try await FakeHome.git(args, in: folder, env: env)
    }

    func write(_ url: URL, _ text: String) throws {
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    // MARK: - Note properties

    @Test func settingReplacesOnlyThatLine() throws {
        let text = "---\nkind: service\nrepo: git@example.com:shop/a.git\n# a comment\n---\n# A\nowner: not this one\n"
        let note = KnowledgeNote(text: text)
        let changed = try note.setting("kind", to: .string("flow"))
        #expect(changed.text == text.replacingOccurrences(of: "kind: service", with: "kind: flow"))
        // A new key goes before the closing ---; the `owner:` in the body is untouched.
        let added = try note.setting("owner", to: .string("team-a"))
        #expect(added.text == "---\nkind: service\nrepo: git@example.com:shop/a.git\n# a comment\nowner: team-a\n---\n# A\nowner: not this one\n")
        #expect(added.frontmatter["owner"] as? String == "team-a")
        // Unchanged value → the same bytes.
        #expect(try note.setting("kind", to: .string("service")) == note)
    }

    @Test func settingWithoutFrontmatterAddsTheBlock() throws {
        #expect(try KnowledgeNote(text: "# A\nkind: in the body\n").setting("kind", to: .string("team")).text
            == "---\nkind: team\n---\n# A\nkind: in the body\n")
        #expect(try KnowledgeNote(text: "").setting("owner", to: .string("x")).text == "---\nowner: x\n---\n")
        #expect(try KnowledgeNote(text: "\u{FEFF}# A\r\n").setting("owner", to: .string("x")).text
            == "\u{FEFF}---\r\nowner: x\r\n---\r\n# A\r\n")
    }

    @Test func settingKeepsCRLFAndListsAndBlockValues() throws {
        let text = "---\r\nkind: service\r\nfiles:\r\n  - a.ts\r\n  - b.ts\r\nnote: |\r\n  line one\r\n\r\n  line two\r\nowner: x\r\n---\r\nBody\r\n"
        let note = KnowledgeNote(text: text)
        let files = try note.setting("files", to: .list(["c.ts", "d e.ts"]))
        #expect(files.text == "---\r\nkind: service\r\nfiles: [c.ts, d e.ts]\r\nnote: |\r\n  line one\r\n\r\n  line two\r\nowner: x\r\n---\r\nBody\r\n")
        #expect(files.files == ["c.ts", "d e.ts"])
        // The block value with a blank line inside is one span.
        let block = try note.setting("note", to: .string("short"))
        #expect(block.text == "---\r\nkind: service\r\nfiles:\r\n  - a.ts\r\n  - b.ts\r\nnote: short\r\nowner: x\r\n---\r\nBody\r\n")
        // A zero-indented block list belongs to its key too.
        let flat = KnowledgeNote(text: "---\nfiles:\n- a\n- b\nkind: x\n---\n")
        #expect(try flat.setting("files", to: .list(["c"])).text == "---\nfiles: [c]\nkind: x\n---\n")
    }

    @Test func valuesAreQuotedOnlyWhenNeeded() throws {
        let note = KnowledgeNote(text: "---\nkind: a\n---\n")
        for value in ["team: a", "#channel", "yes", "123", "1e3", "[x", "a \"b\" c", "- x", "", "two\nlines"] {
            let edited = try note.setting("owner", to: .string(value))
            #expect(edited.frontmatter["owner"] as? String == value, "\(value): \(edited.text)")
        }
        #expect(try note.setting("owner", to: .string("team-a")).text.contains("owner: team-a\n"))
        #expect(try note.setting("url", to: .string("https://example.com/a")).text.contains("url: https://example.com/a\n"))
        let list = try note.setting("files", to: .list(["a,b", "c]", "plain"]))
        #expect(list.files == ["a,b", "c]", "plain"])
        #expect(list.text.contains("files: [\"a,b\", \"c]\", plain]\n"))
        #expect(throws: KnowledgeNote.Failure.self) { try note.setting("bad key", to: .string("x")) }
        #expect(throws: KnowledgeNote.Failure.self) { try KnowledgeNote(text: "---\n: [broken\n---\n").setting("kind", to: .string("x")) }
    }

    @Test func removingDropsTheLinesAndAnEmptyBlock() {
        let note = KnowledgeNote(text: "---\r\nkind: a\r\nfiles:\r\n  - x\r\nowner: b\r\n---\r\nkind: body\r\n")
        #expect(note.removing("files").text == "---\r\nkind: a\r\nowner: b\r\n---\r\nkind: body\r\n")
        #expect(note.removing("nope") == note)
        #expect(KnowledgeNote(text: "\u{FEFF}---\nkind: a\n---\n# A\n").removing("kind").text == "\u{FEFF}# A\n")
        #expect(KnowledgeNote(text: "# A\nkind: a\n").removing("kind").text == "# A\nkind: a\n")
    }

    @Test func parseReadsListsAndStrings() {
        #expect(KnowledgeNote.PropertyValue.parse(" team-a ") == .string("team-a"))
        #expect(KnowledgeNote.PropertyValue.parse("[a, b, ]") == .list(["a", "b"]))
        #expect(KnowledgeNote.PropertyValue.parse("[]") == .list([]))
        #expect(KnowledgeNote.PropertyValue(["a", 2] as [Any]).display == "[a, 2]")
        #expect(KnowledgeNote(text: "---\nkind:\n---\n").properties["kind"] == .string(""))
    }

    // MARK: - kb.yaml

    @Test func kindsDefaultsReadAndWrite() async throws {
        let base = try await TemplateBase.base(home: home)
        #expect(try base.kinds() == KnowledgeKinds.defaults)
        #expect(KnowledgeKinds.defaults.names == ["service", "flow", "team", "database", "queue", "external", "folder"])
        #expect(try await git("ls-files", in: base.root).split(separator: "\n").contains("kb.yaml"))
        // A base without the file reads the defaults.
        try fm.removeItem(at: base.root.appending(path: "kb.yaml"))
        #expect(try base.kinds() == KnowledgeKinds.defaults)

        let text = "kinds:\n  zeta:\n    fields: [a]\n    color: red\n  alpha:\n    fields: b\n  empty:\n"
        try write(base.root.appending(path: "kb.yaml"), text)
        let kinds = try base.kinds()
        #expect(kinds.names == ["zeta", "alpha", "empty"])
        #expect(kinds.kind("zeta") == KnowledgeKinds.Kind(name: "zeta", fields: ["a"], color: "red"))
        #expect(kinds.kind("alpha")?.fields == ["b"])
        #expect(try KnowledgeKinds.parse(kinds.text) == kinds)

        let changed = try kinds.adding("queue", fields: ["owner", " owner", "topic"]).settingFields(of: "zeta", to: ["x"])
            .removing("empty").renaming("alpha", to: "beta")
        #expect(changed.names == ["zeta", "beta", "queue"])
        #expect(changed.kind("queue")?.fields == ["owner", "topic"])
        try base.save(kinds: changed)
        #expect(try base.kinds() == changed)

        #expect(throws: KnowledgeBase.Failure.self) { try kinds.adding("zeta", fields: []) }
        #expect(throws: KnowledgeBase.Failure.self) { try kinds.adding("two words", fields: []) }
        #expect(throws: KnowledgeBase.Failure.self) { try kinds.adding("ok", fields: ["bad field"]) }
        #expect(throws: KnowledgeBase.Failure.self) { try kinds.removing("nope") }
        #expect(throws: KnowledgeBase.Failure.self) { try kinds.renaming("zeta", to: "beta").renaming("beta", to: "zeta").renaming("zeta", to: "alpha") }
        // A file with keys AKit doesn't know is read, never rewritten.
        let unknown = try KnowledgeKinds.parse("version: 2\nkinds:\n  a:\n    icon: x\n")
        #expect(unknown.unknownKeys == ["version", "kinds.a.icon"])
        #expect(throws: KnowledgeBase.Failure.self) { try unknown.write(base: base.root) }
        #expect(throws: KnowledgeBase.Failure.self) { try KnowledgeKinds.parse("kinds: [a, b]") }
    }

    @Test func renameKindIsAllOrNothingInOneCommit() async throws {
        let base = try await TemplateBase.base(home: home)
        try await base.newNote(area: "payments", name: "orders-api", kind: "service", env: env)
        try await base.newNote(area: "logistics", name: "warehouse", kind: "service", env: env)
        try await base.newNote(area: "logistics", name: "pick", kind: "flow", env: env)
        let commits = try await git("rev-list", "--count", "HEAD", in: base.root)

        let paths = try await base.renameKind("service", to: "system", env: env)
        #expect(paths == ["kb.yaml", "areas/logistics/warehouse.md", "areas/payments/orders-api.md"])
        #expect(try base.kinds().names.first == "system")
        #expect(try base.notes().map(\.kind) == ["flow", "system", "system"])
        #expect(Int(try await git("rev-list", "--count", "HEAD", in: base.root)) == Int(commits)! + 1)
        #expect(try await git("show", "--name-only", "--format=%s", "HEAD", in: base.root)
            == "Rename kind service to system in 2 notes\n\nareas/logistics/warehouse.md\nareas/payments/orders-api.md\nkb.yaml")
        #expect(try await git("status", "--porcelain", in: base.root).isEmpty)

        // The second note can't be written (its folder is read-only): the first one is put back,
        // kb.yaml is unchanged, nothing is committed.
        try await base.newNote(area: "payments", name: "order-flow", kind: "flow", env: env)
        let before = try String(contentsOf: base.noteFile("logistics/pick"), encoding: .utf8)
        let kindsBefore = try Data(contentsOf: base.root.appending(path: "kb.yaml"))
        let payments = base.areasFolder.appending(path: "payments").path
        try fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: payments)
        defer { try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: payments) }
        await #expect(throws: KnowledgeBase.Failure.self) { try await base.renameKind("flow", to: "path", env: env) }
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: payments)
        #expect(try String(contentsOf: base.noteFile("logistics/pick"), encoding: .utf8) == before)
        #expect(try Data(contentsOf: base.root.appending(path: "kb.yaml")) == kindsBefore)
        #expect(try await git("status", "--porcelain", in: base.root).isEmpty)
        #expect(Int(try await git("rev-list", "--count", "HEAD", in: base.root)) == Int(commits)! + 2)
        await #expect(throws: KnowledgeBase.Failure.self) { try await base.renameKind("nope", to: "x", env: env) }
        await #expect(throws: KnowledgeBase.Failure.self) { try await base.renameKind("flow", to: "system", env: env) }
    }

    @Test func setPropertiesSavesOnlyWhenChanged() async throws {
        let base = try await TemplateBase.base(home: home)
        try await base.newNote(area: "payments", name: "orders-api", kind: "service", env: env)
        let set = try base.setProperties(note: "payments/orders-api", set: [("owner", .string("team-a")), ("kind", .string("flow"))])
        #expect(set.path == "areas/payments/orders-api.md" && set.changed)
        #expect(try String(contentsOf: base.noteFile("payments/orders-api"), encoding: .utf8) == "---\nkind: flow\nowner: team-a\n---\n# orders-api\n")
        #expect(try base.setProperties(note: "payments/orders-api", set: [("owner", .string("team-a"))]).changed == false)
        #expect(try base.setProperties(note: "payments/orders-api", set: [], unset: ["owner"]).changed)
        #expect(throws: KnowledgeBase.Failure.self) { try base.setProperties(note: "payments/nope", set: [("a", .string("b"))]) }
        #expect(try base.noteID("[[orders-api]]") == "payments/orders-api")
        #expect(throws: KnowledgeBase.Failure.self) { try base.noteID("nope") }
    }

    // MARK: - area.yaml

    @Test func areaSettingsReadAndWrite() async throws {
        let base = try await TemplateBase.base(home: home)
        try base.newArea("payments")
        #expect(try base.settings(area: "payments") == KnowledgeArea())
        #expect(base.areas().first?.projects == [])
        try write(base.areasFolder.appending(path: "payments/area.yaml"),
                  "title: Payments\ndescription: Orders and billing.\nprojects: [git@example.com:shop/orders-api.git, ~/Projects/billing]\n")
        let settings = try base.settings(area: "payments")
        #expect(settings == KnowledgeArea(title: "Payments", description: "Orders and billing.",
                                          projects: ["git@example.com:shop/orders-api.git", "~/Projects/billing"]))
        let area = try #require(base.areas().first)
        #expect(area.title == "Payments" && area.projects.count == 2)

        var edited = settings
        edited.title = "  "
        edited.projects += ["~/work/pay-*", "~/Projects/billing", " "]
        let path = try base.save(area: "payments", settings: edited)
        #expect(path == "areas/payments/area.yaml")
        #expect(try String(contentsOf: base.root.appending(path: path), encoding: .utf8)
            == "description: Orders and billing.\nprojects: [git@example.com:shop/orders-api.git, ~/Projects/billing, ~/work/pay-*]\n")
        #expect(try base.settings(area: "payments").projects.last == "~/work/pay-*")
        // area.yaml is not a note.
        #expect(try base.notes().isEmpty)

        #expect(throws: KnowledgeBase.Failure.self) { try base.settings(area: "nope") }
        try write(base.areasFolder.appending(path: "payments/area.yaml"), "title: [a\n")
        #expect(throws: KnowledgeBase.Failure.self) { try base.settings(area: "payments") }
        #expect(base.areas().first?.title == nil)
        try write(base.areasFolder.appending(path: "payments/area.yaml"), "title: A\nowner: x\n")
        #expect(throws: KnowledgeBase.Failure.self) { try base.save(area: "payments", settings: try base.settings(area: "payments")) }
    }
}
