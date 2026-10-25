import Foundation
import Testing
import AKitFoundation
@testable import AKitKnowledge

/// The notebook (docs/design/notebook.md): tabs as files in `notebook/`, checked saves, images,
/// and the text edits `akit notebook` makes.
final class KnowledgeNotebookTests {
    deinit { try? FileManager.default.removeItem(at: home) }

    let home: URL
    init() throws { home = try FakeHome.make("akit-kb-notebook") }
    var env: HarnessEnvironment { FakeHome.env(home) }

    func notebook() async throws -> KnowledgeNotebook { KnowledgeNotebook(base: try await TemplateBase.base(home: home)) }

    func log(_ notebook: KnowledgeNotebook) async throws -> String {
        try await FakeHome.git(["log", "--format=%s", "--name-status", "-1"], in: notebook.base.root, env: env)
    }

    @Test func aNewNotebookShowsInboxAndItsFirstSaveWritesIt() async throws {
        let book = try await notebook()
        #expect(book.tabs().isEmpty)
        #expect(try book.text(KnowledgeNotebook.firstTab) == "")
        let saved = try book.save("Inbox", bytes: Data("- [ ] a\n".utf8), expectedHash: nil)
        #expect(saved.path == "notebook/Inbox.md")
        #expect(saved.outcome == .saved(hash: KnowledgeWrite.hash(Data("- [ ] a\n".utf8))))
        #expect(book.tabs() == ["Inbox"])
        // A second "first save" finds the file there: a conflict, nothing written.
        if case .conflict = try book.save("Inbox", bytes: Data("x".utf8), expectedHash: nil).outcome {} else { Issue.record("no conflict") }
        #expect(try book.text("Inbox") == "- [ ] a\n")
    }

    @Test func aSaveNeedsTheFileAsAKitLastSawIt() async throws {
        let book = try await notebook()
        try await book.add(tab: "Plans", env: env)
        let first = try #require(KnowledgeWrite.hash(of: book.file("Plans")))
        let saved = try book.save("Plans", bytes: Data("one\n".utf8), expectedHash: first)
        guard case .saved(let hash) = saved.outcome else { Issue.record("not saved"); return }
        // Obsidian writes the file: AKit's next save is refused.
        try Data("theirs\n".utf8).write(to: book.file("Plans"))
        #expect(try book.save("Plans", bytes: Data("mine\n".utf8), expectedHash: hash).outcome == .conflict(diskHash: KnowledgeWrite.hash(Data("theirs\n".utf8))))
        #expect(try book.text("Plans") == "theirs\n")
        #expect(throws: KnowledgeBase.Failure.self) { try book.save("../kb", bytes: Data(), expectedHash: nil) }
    }

    @Test func tabsAreAddedRenamedReorderedAndDeletedEachInOneCommit() async throws {
        let book = try await notebook()
        try await book.add(tab: "Inbox", env: env)
        try await book.add(tab: "Plans", env: env)
        try await book.add(tab: "Done today", env: env)
        #expect(book.tabs() == ["Inbox", "Plans", "Done today"])
        #expect(try await log(book).hasPrefix("Add notebook tab Done today"))
        await #expect(throws: KnowledgeBase.Failure.self) { try await book.add(tab: "plans", env: self.env) }
        await #expect(throws: KnowledgeBase.Failure.self) { try await book.add(tab: "a/b", env: self.env) }
        await #expect(throws: KnowledgeBase.Failure.self) { try await book.add(tab: ".hidden", env: self.env) }

        try await book.rename(tab: "plans", to: "Week", env: env)
        #expect(book.tabs() == ["Inbox", "Week", "Done today"])
        let renamed = try await log(book)
        #expect(renamed.contains("Rename notebook tab Plans to Week") && renamed.contains("notebook/Week.md"))

        try await book.reorder(["Done today", "Inbox"], env: env)
        #expect(book.tabs() == ["Done today", "Inbox", "Week"])
        #expect(try await log(book).hasPrefix("Reorder notebook tabs"))

        var trashed: [URL] = []
        try await book.delete(tab: "Inbox", env: env) { url in
            trashed.append(url)
            try FileManager.default.removeItem(at: url)
            return nil
        }
        #expect(trashed.map(\.lastPathComponent) == ["Inbox.md"])
        #expect(book.tabs() == ["Done today", "Week"])
        #expect(try await log(book).contains("D\tnotebook/Inbox.md"))
    }

    @Test func aFileAddedOutsideIsATabAfterTheOrderedOnes() async throws {
        let book = try await notebook()
        try await book.add(tab: "B", env: env)
        try Data().write(to: book.file("A"))
        try Data().write(to: book.file(".scratch"))
        try FileManager.default.createDirectory(at: book.folder.appending(path: "sub"), withIntermediateDirectories: true)
        try Data().write(to: book.folder.appending(path: "sub/C.md"))
        #expect(book.tabs() == ["B", "A"])
    }

    @Test func anImageIsSavedOnceUnderItsHashAndItsLinkStaysInTheNotebook() async throws {
        let book = try await notebook()
        let png = Data([0x89, 0x50, 0x4E, 0x47, 1, 2, 3])
        let first = try book.saveAsset(png, ext: "PNG", date: "2026-10-25")
        #expect(first.link.hasPrefix("assets/2026-10-25-") && first.link.hasSuffix(".png"))
        #expect(first.path == "notebook/" + first.link)
        #expect(try book.saveAsset(png, ext: "png", date: "2026-10-25") == first)
        #expect(book.asset(first.link) != nil)
        #expect(book.asset("../kb.yaml") == nil)
        #expect(book.asset("/etc/hosts") == nil)
        #expect(throws: KnowledgeBase.Failure.self) { try book.saveAsset(png, ext: "html", date: "2026-10-25") }
        #expect(throws: KnowledgeBase.Failure.self) { try book.saveAsset(Data(), ext: "png", date: "2026-10-25") }
    }

    @Test(arguments: [
        // An empty tab gets the heading alone.
        ("", "## 2026-10-25\n", 0),
        // Above the old days, under a title and frontmatter.
        ("## 2026-10-24\n\n- [x] a\n", "## 2026-10-25\n\n## 2026-10-24\n\n- [x] a\n", 0),
        ("# Log\n\n## 2026-10-24\n", "# Log\n\n## 2026-10-25\n\n## 2026-10-24\n", 2),
        ("---\ntags: [log]\n---\ntext\n", "---\ntags: [log]\n---\n\n## 2026-10-25\n\ntext\n", 4),
        // Today's heading is there already: nothing changes.
        ("a\n\n## 2026-10-25\n", "a\n\n## 2026-10-25\n", 2),
    ])
    func todayGoesAtTheTop(text: String, expected: String, line: Int) {
        let result = KnowledgeNotebook.addingToday(text, date: "2026-10-25")
        #expect(result.text == expected)
        #expect(result.line == line)
    }

    @Test func aLineGoesAtTheTopOrUnderTodayAndJoinsTheList() {
        let add = KnowledgeNotebook.adding
        #expect(add("- [ ] b", "", nil) == "- [ ] b\n")
        #expect(add("- [ ] b", "- [ ] a\n", nil) == "- [ ] b\n- [ ] a\n")
        #expect(add("note", "- [ ] a\n", nil) == "note\n\n- [ ] a\n")
        #expect(add("- [ ] b", "# Plans\n\n- [ ] a\n", nil) == "# Plans\n\n- [ ] b\n- [ ] a\n")
        #expect(add("- [ ] b", "", "2026-10-25") == "## 2026-10-25\n\n- [ ] b\n")
        #expect(add("- [ ] b", "## 2026-10-25\n\n- [x] a\n", "2026-10-25") == "## 2026-10-25\n\n- [ ] b\n- [x] a\n")
        #expect(add("- [ ] b", "## 2026-10-24\n\n- [x] a\n", "2026-10-25") == "## 2026-10-25\n\n- [ ] b\n\n## 2026-10-24\n\n- [x] a\n")
    }

    @Test func doneTicksTheFirstOpenTaskThatMatches() {
        let text = "- [x] Fix maps\n- [ ] fix maps in the list\n  * [ ] write the guide\n- [ ] fix maps again\n"
        let ticked = KnowledgeNotebook.ticking("FIX MAPS", in: text)
        #expect(ticked?.text == "- [x] Fix maps\n- [x] fix maps in the list\n  * [ ] write the guide\n- [ ] fix maps again\n")
        #expect(ticked?.line == "- [x] fix maps in the list")
        #expect(KnowledgeNotebook.ticking("guide", in: text)?.line == "* [x] write the guide")
        #expect(KnowledgeNotebook.ticking("nothing", in: text) == nil)
        #expect(KnowledgeNotebook.openTasks(in: text) == ["fix maps in the list", "write the guide", "fix maps again"])
    }

    @Test func agentsAddAndTickWithACommitEach() async throws {
        let book = try await notebook()
        // The first tab is made by the first add; another missing tab is refused.
        try await book.append("call the bank", to: "Inbox", task: true, today: "2026-10-25", env: env)
        #expect(try book.text("Inbox") == "## 2026-10-25\n\n- [ ] call the bank\n")
        #expect(try await log(book).hasPrefix("Notebook: add to Inbox"))
        await #expect(throws: KnowledgeBase.Failure.self) { try await book.append("x", to: "Plans", task: false, today: nil, env: self.env) }
        await #expect(throws: KnowledgeBase.Failure.self) { try await book.append("a\nb", to: "Inbox", task: false, today: nil, env: self.env) }
        #expect(try await book.tick("bank", in: "inbox", env: env) == "- [x] call the bank")
        #expect(try book.text("Inbox") == "## 2026-10-25\n\n- [x] call the bank\n")
        #expect(try await log(book).hasPrefix("Notebook: done in Inbox"))
        await #expect(throws: KnowledgeBase.Failure.self) { try await book.tick("bank", in: "Inbox", env: self.env) }
    }

    @Test func theWatcherQueuesNotebookEditsWithoutReindexing() {
        #expect(WatchFilter.classify("notebook/Inbox.md") == .notebook("notebook/Inbox.md"))
        #expect(WatchFilter.classify("notebook/.tabs.json") == .ignore)
        let batch = WatchFilter.batch(["notebook/Inbox.md", "notebook/assets/a.png"], own: ["notebook/assets/a.png": "h"]) { $0.hasSuffix("png") ? "h" : "x" }
        #expect(batch.notebook && !batch.reindex)
        #expect(batch.enqueue == ["notebook/Inbox.md"] && batch.outside == ["notebook/Inbox.md"])
        #expect(KnowledgeCommitQueue.message(for: ["notebook/Inbox.md", "notebook/assets/a.png"]) == "Edit notebook: Inbox, assets/a.png")
    }

    @Test func theSweepQueuesANotebookEditMadeWhileAKitWasClosed() async throws {
        let book = try await notebook()
        try await book.add(tab: "Plans", env: env)
        try Data("edited\n".utf8).write(to: book.file("Plans"))
        #expect(try await KnowledgeGit(base: book.base.root, env: env).changedPaths() == ["notebook/Plans.md"])
    }
}

/// Drawings (NB10): an Excalidraw scene and its SVG picture in `notebook/drawings/`.
final class KnowledgeNotebookDrawingTests {
    deinit { try? FileManager.default.removeItem(at: home) }

    let home: URL
    init() throws { home = try FakeHome.make("akit-kb-drawing") }

    @Test func aDrawingIsItsSceneAndItsPictureAndASaveNeedsTheSceneAsRead() async throws {
        let book = KnowledgeNotebook(base: try await TemplateBase.base(home: home))
        let name = book.newDrawingName(date: "2026-10-25")
        #expect(name.hasPrefix("2026-10-25-") && name.count == "2026-10-25-".count + 6)
        #expect(book.drawing(name).hash == nil)
        let svg = Data("<svg xmlns=\"http://www.w3.org/2000/svg\"></svg>".utf8)
        let saved = try book.saveDrawing(name, scene: Data("{\"elements\":[1]}".utf8), svg: svg, expectedHash: nil)
        #expect(saved.link == "drawings/\(name).excalidraw.svg")
        #expect(saved.paths == ["notebook/drawings/\(name).excalidraw", "notebook/drawings/\(name).excalidraw.svg"])
        #expect(KnowledgeNotebook.drawing(ofLink: saved.link) == name)
        #expect(KnowledgeNotebook.drawing(ofLink: saved.link + "?v=2") == name)
        #expect(book.asset(saved.link) != nil)
        let read = book.drawing(name)
        #expect(read.text == "{\"elements\":[1]}")
        // Someone changed the scene since: refused, the picture stays.
        try Data("{\"elements\":[2]}".utf8).write(to: book.drawingFile(name))
        if case .conflict = try book.saveDrawing(name, scene: Data("{}".utf8), svg: svg, expectedHash: read.hash).outcome {} else {
            Issue.record("no conflict")
        }
        #expect(throws: KnowledgeBase.Failure.self) { try book.saveDrawing(name, scene: Data(), svg: Data("<html>".utf8), expectedHash: nil) }
        #expect(KnowledgeNotebook.drawing(ofLink: "assets/a.png") == nil)
        #expect(KnowledgeNotebook.drawing(ofLink: "drawings/../x.excalidraw.svg") == nil)
    }
}

/// Review round 1: names outside ASCII, late saves, what the editor's file route serves.
final class KnowledgeNotebookReviewTests {
    deinit { try? FileManager.default.removeItem(at: home) }

    let home: URL
    init() throws { home = try FakeHome.make("akit-kb-notebook-review") }
    var env: HarnessEnvironment { FakeHome.env(home) }

    @Test func aCyrillicTabIsRenamedAndDeletedInItsCommits() async throws {
        let book = KnowledgeNotebook(base: try await TemplateBase.base(home: home))
        try await book.add(tab: "Планы", env: env)
        try await book.rename(tab: "Планы", to: "Неделя", env: env)
        try await book.delete(tab: "Неделя", env: env) { url in try FileManager.default.removeItem(at: url); return nil }
        // Nothing of the notebook stays uncommitted.
        #expect(try await KnowledgeGit(base: book.base.root, env: env).changedPaths().isEmpty)
        #expect(try await FakeHome.git(["ls-files", "notebook"], in: book.base.root, env: env) == "notebook/.tabs.json")
    }

    @Test func aLateSaveNeverBringsBackADeletedTab() async throws {
        let book = KnowledgeNotebook(base: try await TemplateBase.base(home: home))
        try await book.add(tab: "Inbox", env: env)
        try await book.add(tab: "Old", env: env)
        try await book.delete(tab: "Old", env: env) { url in try FileManager.default.removeItem(at: url); return nil }
        if case .conflict = try book.save("Old", bytes: Data("late".utf8), expectedHash: nil).outcome {} else { Issue.record("saved") }
        #expect(!FileManager.default.fileExists(atPath: book.file("Old").path))
    }

    @Test func theFileRouteServesImagesOnlyAndNoLinkOut() async throws {
        let book = KnowledgeNotebook(base: try await TemplateBase.base(home: home))
        let secret = home.appending(path: "secret.png")
        try Data("x".utf8).write(to: secret)
        try FileManager.default.createDirectory(at: book.assetsFolder, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: book.assetsFolder.appending(path: "link.png"), withDestinationURL: secret)
        try Data("alert(1)".utf8).write(to: book.assetsFolder.appending(path: "x.js"))
        try Data("y".utf8).write(to: book.assetsFolder.appending(path: "ok.png"))
        #expect(book.asset("assets/link.png") == nil)
        #expect(book.asset("assets/x.js") == nil)
        #expect(book.asset(".tabs.json") == nil)
        #expect(book.asset("assets/ok.png") != nil)
    }

    @Test func aTabNamedInObsidianCanBeSavedAndADrawingNeedsItsJSON() async throws {
        let book = KnowledgeNotebook(base: try await TemplateBase.base(home: home))
        try FileManager.default.createDirectory(at: book.folder, withIntermediateDirectories: true)
        try Data("a".utf8).write(to: book.file("Q4 #plans"))
        let hash = try #require(KnowledgeWrite.hash(of: book.file("Q4 #plans")))
        if case .saved = try book.save("Q4 #plans", bytes: Data("b".utf8), expectedHash: hash).outcome {} else { Issue.record("not saved") }
        #expect(throws: KnowledgeBase.Failure.self) {
            try book.saveDrawing("d", scene: Data(), svg: Data("<svg/>".utf8), expectedHash: nil)
        }
    }
}
