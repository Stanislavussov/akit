import Foundation
import Testing
import AKitBrain
import AKitFoundation
@testable import AKitKnowledge

/// K25: the base folder per world in `bases.json`, its refusals, move and reset, the Obsidian vault.
/// Everything in a temporary fake home.
final class KnowledgeBaseFolderTests {
    deinit { try? FileManager.default.removeItem(at: home) }

    let home: URL
    let fm = FileManager.default

    init() throws {
        home = URL(filePath: FileWalk.realPath(fm.temporaryDirectory) ?? fm.temporaryDirectory.path)
            .appending(path: "akit-kb-folder-\(UUID().uuidString)")
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
    }

    func env() -> HarnessEnvironment {
        HarnessEnvironment(homeDirectory: home, variables: ["HOME": home.path, "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1"],
                           executableSearchPaths: [URL(filePath: "/usr/bin")])
    }

    func git(_ args: String..., in folder: URL) async throws -> String {
        let result = try #require(await ProcessRunner.run(URL(filePath: "/usr/bin/git"), arguments: args, directory: folder,
                                                           environment: env().variables, timeout: 20))
        #expect(result.succeeded, "git \(args.joined(separator: " ")): \(result.output)")
        return result.output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func write(_ url: URL, _ text: String) throws {
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    func basesJSON() throws -> [String: String] {
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: KnowledgeBase.basesFile(home: home))) as? [String: Any]
        return try #require(object?["bases"] as? [String: String])
    }

    func choose() async throws -> KnowledgeBase? {
        try await KnowledgeBase.choose(option: nil, folder: home, env: env(), projectsRoot: home.appending(path: "Projects"))
    }

    @Test func basesJSONIsReadAndWrittenWithTildePaths() throws {
        #expect(try KnowledgeBase.Folders.load(home: home) == KnowledgeBase.Folders())
        try KnowledgeBase.Folders(bases: ["work": "~/Notes/kb", "personal": "/Volumes/x/kb", "bad": "rel/kb"]).save(home: home)
        let folders = try KnowledgeBase.Folders.load(home: home)
        #expect(folders.url(of: "work", home: home) == home.appending(path: "Notes/kb").standardized)
        #expect(folders.url(of: "personal", home: home)?.path == "/Volumes/x/kb")
        #expect(folders.url(of: "bad", home: home) == nil)
        #expect(KnowledgeBase.root(world: "work", home: home).path == home.appending(path: "Notes/kb").path)
        #expect(KnowledgeBase.root(world: "other", home: home).path == KnowledgeBase.world("other", home: home).path)
        // A broken file is an error for writers and empty for readers, and is never overwritten.
        try write(KnowledgeBase.basesFile(home: home), "{not json")
        #expect(throws: KnowledgeBase.Failure.self) { try KnowledgeBase.Folders.load(home: home) }
        #expect(KnowledgeBase.root(world: "work", home: home).path == KnowledgeBase.world("work", home: home).path)
        #expect(throws: KnowledgeBase.Failure.self) { try KnowledgeBase.resetFolder(world: "work", home: home) }
        #expect(try String(contentsOf: KnowledgeBase.basesFile(home: home), encoding: .utf8) == "{not json")
    }

    @Test func aVaultBecomesTheWorldsBaseAndIsChosen() async throws {
        let vault = home.appending(path: "Vault")
        try write(vault.appending(path: ".obsidian/app.json"), "{}")
        try write(vault.appending(path: "Daily/2026-10-24.md"), "# today\n")
        let change = try await KnowledgeBase.setFolder(world: "work", to: vault, env: env())
        #expect(change.created && change.previous == nil)
        #expect(change.base.root.path == vault.path && change.base.name == "work")
        #expect(try basesJSON() == ["work": "~/Vault"])
        #expect(try await git("log", "--format=%s", in: vault) == "Create the knowledge base")
        // The vault's own notes stay untracked; .obsidian/ is ignored.
        #expect(try await git("status", "--porcelain", in: vault) == "?? Daily/")
        #expect(KnowledgeBase.all(home: home) == [KnowledgeBase(root: vault)])
        #expect(KnowledgeBase.all(home: home).first?.world == "work")
        #expect(try await choose()?.root.path == vault.path)
        let named = try await KnowledgeBase.choose(option: "work", folder: home, env: env(), projectsRoot: home)
        #expect(named?.root.path == vault.path)
        #expect(KnowledgeBase.worlds(home: home) == ["personal", "work"])
    }

    @Test func theConfiguredFolderComesBeforeTheDefaultOne() async throws {
        let old = try await KnowledgeBase.create(world: "work", env: env())
        let other = home.appending(path: "Documents/kb")
        let change = try await KnowledgeBase.setFolder(world: "work", to: other, env: env())
        #expect(change.previous?.path == old.root.path)
        // The old default base is hidden: the world has one base, the set one.
        #expect(KnowledgeBase.all(home: home).map(\.root.path) == [other.path])
        #expect(try await choose()?.root.path == other.path)
        // Create Base… for the world goes to its set folder too.
        try KnowledgeBase.resetFolder(world: "work", home: home)
        #expect(try basesJSON().isEmpty)
        #expect(KnowledgeBase.all(home: home).map(\.root.path) == [old.root.path])
        #expect(KnowledgeBase.isBase(other), "reset moves and deletes nothing")
        // Setting the default folder keeps no entry.
        try KnowledgeBase.Folders(bases: ["personal": "~/P"]).save(home: home)
        try await KnowledgeBase.setFolder(world: "work", to: KnowledgeBase.world("work", home: home), env: env())
        #expect(try basesJSON() == ["personal": "~/P"])
        let unset = home.appending(path: "New/kb")
        try KnowledgeBase.Folders(bases: ["side": "~/New/kb"]).save(home: home)
        #expect(try await KnowledgeBase.create(world: "side", env: env()).root.path == unset.path)
    }

    @Test func syncedFoldersTheBrainAndRemotesAreRefused() async throws {
        for synced in ["Library/Mobile Documents/com~apple~CloudDocs/kb", "Library/CloudStorage/GoogleDrive-me/kb", "Dropbox/kb", "Google Drive/kb"] {
            do {
                try await KnowledgeBase.setFolder(world: "work", to: home.appending(path: synced), env: env())
                Issue.record("\(synced) was allowed")
            } catch {
                #expect(error.message.contains("synced folder"), "\(synced): \(error.message)")
            }
        }
        let team = home.appending(path: "Team")
        try write(team.appending(path: ".dropbox"), "{}")
        do {
            try await KnowledgeBase.setFolder(world: "work", to: team.appending(path: "notes/kb"), env: env())
            Issue.record("a folder in a Dropbox folder was allowed")
        } catch {
            #expect(error.message.contains("Dropbox"))
        }
        do {
            try await KnowledgeBase.setFolder(world: "work", to: Brain.defaultRoot(home: home).appending(path: "kb"), env: env())
            Issue.record("the brain was allowed")
        } catch {
            #expect(error.message.contains("inside the brain"))
        }
        let repo = home.appending(path: "Vault")
        try fm.createDirectory(at: repo.appending(path: ".obsidian"), withIntermediateDirectories: true)
        _ = try await git("init", "-q", in: repo)
        _ = try await git("remote", "add", "origin", "git@example.com:me/vault.git", in: repo)
        do {
            try await KnowledgeBase.setFolder(world: "work", to: repo, env: env())
            Issue.record("a repo with a remote was allowed")
        } catch {
            #expect(error.message.contains("remote"))
        }
        // A base that got a remote can't be set either.
        let base = try await KnowledgeBase.create(at: home.appending(path: "kb"), env: env())
        _ = try await git("remote", "add", "origin", "git@example.com:me/kb.git", in: base.root)
        await #expect(throws: KnowledgeBase.Failure.self) { try await KnowledgeBase.setFolder(world: "work", to: base.root, env: env()) }
        #expect(!fm.fileExists(atPath: KnowledgeBase.basesFile(home: home).path))
        await #expect(throws: KnowledgeBase.Failure.self) { try await KnowledgeBase.setFolder(world: "../x", to: home, env: env()) }
    }

    /// A vault with Obsidian Sync on (sync.json, or the core plugin in core-plugins.json or its
    /// migration file, as an object or the older list) uploads every folder in it: refused on a
    /// work Mac, allowed with a warning on another. Sync off: neither.
    @Test func obsidianSyncIsRefusedOnAWorkMacAndAWarningElsewhere() async throws {
        let vault = home.appending(path: "Notes/Vault")
        try write(vault.appending(path: ".obsidian/core-plugins.json"), #"{"file-explorer": true, "sync": false}"#)
        #expect(!Obsidian.syncIsOn(vault) && KnowledgeBase.syncWarning(folder: vault.appending(path: "kb"), home: home) == nil)
        for (file, text) in [("core-plugins.json", #"{"file-explorer": true, "sync": true}"#), ("core-plugins.json", #"["file-explorer", "sync"]"#),
                             ("core-plugins-migration.json", #"{"sync": true}"#), ("sync.json", "{}")] {
            let folder = home.appending(path: "Synced/\(UUID().uuidString)")
            try write(folder.appending(path: ".obsidian/\(file)"), text)
            #expect(Obsidian.syncedVault(containing: folder.appending(path: "deep/kb"))?.path == folder.path, "\(file) \(text)")
        }
        try write(vault.appending(path: ".obsidian/sync.json"), "{}")

        let personal = try await KnowledgeBase.setFolder(world: "personal", to: vault.appending(path: "kb"), env: env())
        #expect(personal.created && personal.warning?.contains("has Obsidian Sync on") == true)
        #expect(personal.warning?.contains("~/Notes/Vault") == true)
        #expect(try KnowledgeBase.check(folder: vault.appending(path: "other"), home: home) == personal.warning)

        try MachineProfile(kind: .work, name: "work").save(home: home)
        do {
            try await KnowledgeBase.setFolder(world: "work", to: vault.appending(path: "work-kb"), env: env())
            Issue.record("a vault with Obsidian Sync was allowed on a work Mac")
        } catch {
            #expect(error.message.contains("Obsidian Sync on") && error.message.contains("work Mac"), "\(error.message)")
        }
        #expect(!fm.fileExists(atPath: vault.appending(path: "work-kb").path))
        await #expect(throws: KnowledgeBase.Failure.self) { try await KnowledgeBase.create(at: vault.appending(path: "x"), env: self.env()) }
        #expect(KnowledgeBase.syncWarning(folder: vault.appending(path: "kb"), home: home) == nil)
    }

    @Test func oneFolderIsTheBaseOfOneWorld() async throws {
        let folder = home.appending(path: "kb")
        try await KnowledgeBase.setFolder(world: "work", to: folder, env: env())
        await #expect(throws: KnowledgeBase.Failure.self) { try await KnowledgeBase.setFolder(world: "personal", to: folder, env: env()) }
        // Set again to the same world: used as it is, nothing created.
        let again = try await KnowledgeBase.setFolder(world: "work", to: folder, env: env())
        #expect(!again.created && again.previous == nil)
    }

    @Test func moveOnTheSameDiskKeepsTheHistoryAndCommitsThePendingEdits() async throws {
        let base = try await KnowledgeBase.create(world: "work", env: env())
        try await base.newNote(area: "payments", name: "orders-api", kind: "service", env: env())
        try write(base.root.appending(path: "areas/payments/orders-api.md"), "# Orders API\n")
        #expect(KnowledgeCommitQueue(base: base.root, env: env()).enqueue(["areas/payments/orders-api.md"]) == .queued(refused: []))
        let target = home.appending(path: "Notes/Vault/kb")
        try fm.createDirectory(at: target, withIntermediateDirectories: true) // an empty folder is fine
        let moved = try await KnowledgeBase.move(world: "work", to: target, env: env(), trash: { _ in Issue.record("no Trash on a rename"); return nil })
        #expect(moved.root.path == target.path)
        #expect(!fm.fileExists(atPath: base.root.path))
        #expect(try await git("log", "--format=%s", in: target) == "Edit payments/orders-api\nAdd note payments/orders-api\nCreate the knowledge base")
        #expect(try await git("status", "--porcelain", in: target).isEmpty)
        #expect(try basesJSON() == ["work": "~/Notes/Vault/kb"])
        #expect(KnowledgeBase.all(home: home).map(\.root.path) == [target.path])
        // Back to the default folder: the entry goes.
        try await KnowledgeBase.move(world: "work", to: KnowledgeBase.world("work", home: home), env: env())
        #expect(try basesJSON().isEmpty)
        #expect(KnowledgeBase.isBase(KnowledgeBase.world("work", home: home)))
    }

    @Test func moveAcrossDisksCopiesComparesAndTrashesTheOld() async throws {
        let base = try await KnowledgeBase.create(world: "work", env: env())
        try await base.newNote(area: "logistics", name: "warehouse", kind: nil, env: env())
        let trashed = home.appending(path: "trash")
        try fm.createDirectory(at: trashed, withIntermediateDirectories: true)
        var thrown: [URL] = []
        let target = home.appending(path: "Other/kb")
        let moved = try await KnowledgeBase.move(world: "work", to: target, env: env(), trash: { url in
            let place = trashed.appending(path: UUID().uuidString)
            try FileManager.default.moveItem(at: url, to: place)
            thrown.append(url)
            return place
        }, copy: true)
        #expect(thrown.map(\.path) == [base.root.path])
        #expect(moved.root.path == target.path && KnowledgeBase.isBase(target))
        #expect(try await git("rev-list", "--count", "HEAD", in: target) == "2")
        // A failing Trash leaves the copy as the base and says what to remove.
        let next = home.appending(path: "Third/kb")
        do {
            try await KnowledgeBase.move(world: "work", to: next, env: env(), trash: { _ in throw CocoaError(.fileWriteNoPermission) }, copy: true)
            Issue.record("no error")
        } catch {
            #expect(error.message.contains("Remove \(target.path) by hand"))
        }
        #expect(KnowledgeBase.root(world: "work", home: home).path == next.path)
    }

    @Test func moveRefusesWithoutABaseIntoAFullFolderAndWhileTheLockIsHeld() async throws {
        await #expect(throws: KnowledgeBase.Failure.self) {
            try await KnowledgeBase.move(world: "work", to: home.appending(path: "kb"), env: env())
        }
        let base = try await KnowledgeBase.create(world: "work", env: env())
        let full = home.appending(path: "full")
        try write(full.appending(path: "a.txt"), "x")
        await #expect(throws: KnowledgeBase.Failure.self) { try await KnowledgeBase.move(world: "work", to: full, env: env()) }
        await #expect(throws: KnowledgeBase.Failure.self) {
            try await KnowledgeBase.move(world: "work", to: base.root.appending(path: "areas/x"), env: env())
        }
        await #expect(throws: KnowledgeBase.Failure.self) {
            try await KnowledgeBase.move(world: "work", to: home.appending(path: "Dropbox/kb"), env: env())
        }
        // The queue can't be flushed while another process holds the lock: nothing moves.
        try write(base.root.appending(path: "areas/a/x.md"), "# x\n")
        #expect(KnowledgeCommitQueue(base: base.root, env: env()).enqueue(["areas/a/x.md"]) == .queued(refused: []))
        let lock = try #require(try FileLock.acquire(base.root.appending(path: KnowledgeBase.queueLockName)))
        do {
            try await KnowledgeBase.move(world: "work", to: home.appending(path: "kb"), env: env())
            Issue.record("moved while the lock was held")
        } catch {
            #expect(error.message.contains("nothing was moved"), "\(error.message)")
        }
        lock.release()
        #expect(KnowledgeBase.isBase(base.root) && !fm.fileExists(atPath: home.appending(path: "kb").path))
    }

    @Test func theVaultIsFoundAndTheURLNamesIt() throws {
        let vault = home.appending(path: "My Notes")
        try fm.createDirectory(at: vault.appending(path: ".obsidian"), withIntermediateDirectories: true)
        let note = vault.appending(path: "kb/areas/pay & co/Café #1.md")
        #expect(Obsidian.vault(containing: note.deletingLastPathComponent())?.standardized.path == vault.path)
        #expect(Obsidian.openURL(note: note)?.absoluteString == "obsidian://open?vault=My%20Notes&file=kb%2Fareas%2Fpay%20%26%20co%2FCaf%C3%A9%20%231.md")
        #expect(Obsidian.vault(containing: home) == nil)
        #expect(Obsidian.openURL(note: home.appending(path: "x.md"))?.absoluteString.hasPrefix("obsidian://open?path=") == true)
    }
}
