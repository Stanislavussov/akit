import Darwin
import Foundation
import Testing
@testable import AKitFoundation
@testable import AKitHarnesses
import AKitModel

/// Packages come from settings a cloned repository may bring: nothing they list may leave the
/// package, read a device or walk forever. Fake home only; the "secrets" are made-up files.
extension PiPackagesTests {
    func link(_ path: String, to target: String) throws {
        let url = home.appending(path: path)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.createSymbolicLink(atPath: url.path, withDestinationPath: target)
    }

    /// Every file a package lists, of every type.
    func listed(_ package: PiPackage) -> [URL] {
        package.extensions + package.skills + package.prompts + package.themes
    }

    @Test func manifestPathsCannotLeaveThePackage() throws {
        // The reviewer's case: a repo's `.pi/settings.json` points at a local kit whose manifest
        // names files elsewhere, by absolute path, absolute glob and `..`.
        let project = home.appending(path: "Projects/cloned")
        try write(".pi/agent/auth.json", #"{"token": "fake"}"#)
        try write("outside/s/SKILL.md")
        try write("outside/p.md")
        try write("Projects/cloned/.pi/settings.json", #"{"packages": ["./kit"]}"#)
        try write("Projects/cloned/.pi/kit/package.json", """
            {"name": "kit", "pi": {
              "skills": ["\(home.path)/.pi/agent/auth.json", "\(home.path)/outside/s", "\(home.path)/*/s/SKILL.md", "../../../../outside/s"],
              "prompts": ["../../../../outside/*.md", "/**/p.md", "~/outside/p.md"],
              "themes": ["../../../../.pi/agent/auth.json"]}}
            """)

        let kit = try #require(packages(projects: [project]).first)
        #expect(kit.isInstalled)
        #expect(listed(kit).isEmpty)
    }

    @Test func symlinksOutOfThePackageAreNotFollowed() throws {
        let pkg = ".pi/agent/npm/node_modules/sly"
        try write(".pi/agent/settings.json", #"{"packages": ["npm:sly"]}"#)
        try write(".pi/agent/auth.json", #"{"token": "fake"}"#)
        try write("outside/stolen/SKILL.md")
        try write("\(pkg)/package.json", #"{"name": "sly"}"#)
        try write("\(pkg)/skills/own/SKILL.md")
        try link("\(pkg)/skills/stolen", to: home.appending(path: "outside/stolen").path)
        try link("\(pkg)/prompts/auth.md", to: home.appending(path: ".pi/agent/auth.json").path)
        try link("\(pkg)/themes", to: home.appending(path: "outside").path)
        try write("\(pkg)/prompts/inside.md")
        try link("\(pkg)/prompts/alias.md", to: "inside.md") // a link inside the package is fine

        let sly = try #require(packages().first)
        #expect(names(sly.skills, in: sly) == ["skills/own/SKILL.md"])
        #expect(names(sly.prompts, in: sly) == ["prompts/alias.md", "prompts/inside.md"])
        #expect(sly.themes.isEmpty)
    }

    @Test func secretFilesInsideAPackageAreNeverListed() throws {
        let pkg = ".pi/agent/npm/node_modules/leaky"
        try write(".pi/agent/settings.json", #"{"packages": ["npm:leaky", "~/.pi/agent/auth.json"]}"#)
        try write(".pi/agent/auth.json", #"{"token": "fake"}"#)
        try write("\(pkg)/package.json", #"{"name": "leaky", "pi": {"themes": ["./auth.json", "./settings.local.json", "./ok.json"]}}"#)
        try write("\(pkg)/auth.json")
        try write("\(pkg)/settings.local.json")
        try write("\(pkg)/ok.json")

        let list = packages()
        #expect(names(list[0].themes, in: list[0]) == ["ok.json"])
        // A local source may point anywhere (Pi's rule), but a non-script file is not shown.
        #expect(list[1].isInstalled)
        #expect(listed(list[1]).isEmpty)
    }

    @Test func linkLoopsEnd() throws {
        let pkg = ".pi/agent/npm/node_modules/loop"
        try write(".pi/agent/settings.json", #"{"packages": ["npm:loop"]}"#)
        try write("\(pkg)/skills/a/SKILL.md")
        try write("\(pkg)/prompts/p.md")
        try link("\(pkg)/skills/again", to: ".")
        try link("\(pkg)/prompts/self", to: ".")
        try link("\(pkg)/prompts/up", to: "../..") // out of the package

        let loop = try #require(packages().first)
        #expect(names(loop.skills, in: loop) == ["skills/a/SKILL.md"])
        #expect(names(loop.prompts, in: loop) == ["prompts/p.md"])
    }

    @Test func devicesAndPipesAreNeverRead() throws {
        // FIFOs stand in for /dev/zero: opening one for reading would block, so a regression hangs
        // (the memory guard's timeout ends it) instead of passing.
        let pkg = home.appending(path: ".pi/agent/npm/node_modules/pipes")
        try write(".pi/agent/settings.json", #"{"packages": ["npm:pipes", "./pipe.json"]}"#)
        try fm.createDirectory(at: pkg.appending(path: "skills/s"), withIntermediateDirectories: true)
        try fm.createDirectory(at: pkg.appending(path: "prompts"), withIntermediateDirectories: true)
        #expect(mkfifo(pkg.appending(path: "package.json").path, 0o600) == 0)
        #expect(mkfifo(pkg.appending(path: "skills/s/SKILL.md").path, 0o600) == 0)
        #expect(mkfifo(pkg.appending(path: "prompts/p.md").path, 0o600) == 0)
        #expect(mkfifo(agent.appending(path: "pipe.json").path, 0o600) == 0)
        try link(".pi/agent/npm/node_modules/pipes/prompts/zero.md", to: "/dev/zero")

        let list = packages()
        #expect(list.count == 2)
        #expect(list.allSatisfy { listed($0).isEmpty })
        #expect(FileWalk.jsonObject(pkg.appending(path: "package.json")) == nil)
        #expect(FileWalk.head(of: URL(filePath: "/dev/zero"), limit: 8) == nil)
    }

    @Test func aHugePackageIsMarkedNotWalked() throws {
        let pkg = home.appending(path: ".pi/agent/npm/node_modules/huge/prompts")
        try write(".pi/agent/settings.json", #"{"packages": ["npm:huge"]}"#)
        try fm.createDirectory(at: pkg, withIntermediateDirectories: true)
        for index in 0...PiPackages.entryBudget {
            fm.createFile(atPath: pkg.appending(path: "p\(index).md").path, contents: nil)
        }
        let huge = try #require(packages().first)
        #expect(huge.isInstalled)
        #expect(huge.isTooLarge)
        #expect(listed(huge).isEmpty)
    }

    @Test func credentialsInSourceURLsAreLeftOut() throws {
        try write(".pi/agent/settings.json", """
            {"packages": ["https://x-access-token:ghp_fake123@github.com/acme/repo.git",
                          "git:https://user@gitlab.com/team/kit@v1"]}
            """)
        try write(".pi/agent/git/github.com/acme/repo/skills/s/SKILL.md")
        let list = packages()
        #expect(list.map(\.source) == ["https://github.com/acme/repo.git", "git:https://gitlab.com/team/kit@v1"])
        #expect(list.map(\.identity) == ["git:github.com/acme/repo", "git:gitlab.com/team/kit"])
        let origin = try #require(PiPackages.skillRoots(list).first?.origin)
        #expect(!origin.contains("ghp_"))
    }

    @Test func npmNamesCannotClimbOutOfTheNpmFolder() throws {
        try write(".pi/agent/settings.json", #"{"packages": ["npm:../../../outside", "npm:@x/../../y", "npm:.."]}"#)
        try write("outside/skills/s/SKILL.md")
        let list = packages()
        #expect(list.count == 3)
        #expect(list.allSatisfy { !$0.isInstalled })
    }

    @Test func onlyLocalFoldersFallBackToOneExtension() throws {
        try write(".pi/agent/settings.json", #"{"packages": ["npm:bare", "./bare"]}"#)
        try write(".pi/agent/npm/node_modules/bare/README.md")
        try write(".pi/agent/bare/README.md")
        let list = packages()
        #expect(list[0].extensions.isEmpty)
        #expect(list[1].extensions.map(\.path) == [agent.appending(path: "bare").path])
    }

    @Test func duplicatesAreListedOnceAndEntriesKeepTheirOwnIDs() throws {
        let pkg = ".pi/agent/npm/node_modules/dup"
        try write(".pi/agent/settings.json", #"{"packages": ["npm:dup", "npm:dup"]}"#)
        try write("\(pkg)/package.json", #"{"name": "dup", "pi": {"skills": ["./skills", "./skills/a", "skills/*"]}}"#)
        try write("\(pkg)/skills/a/SKILL.md")

        let list = packages()
        #expect(Set(list.map(\.id)).count == 2)
        #expect(names(list[0].skills, in: list[0]) == ["skills/a/SKILL.md"])
    }

    @Test func globsSkipDotFoldersLikePi() throws {
        let pkg = ".pi/agent/npm/node_modules/dots"
        try write(".pi/agent/settings.json", #"{"packages": ["npm:dots"]}"#)
        try write("\(pkg)/package.json", #"{"name": "dots", "pi": {"prompts": ["./**/*.md", "./.hidden/exact.md"]}}"#)
        try write("\(pkg)/docs/a.md")
        try write("\(pkg)/.hidden/b.md")
        try write("\(pkg)/.hidden/exact.md")

        let dots = try #require(packages().first)
        // A glob skips dot folders; an exact path may name one.
        #expect(names(dots.prompts, in: dots) == [".hidden/exact.md", "docs/a.md"])
    }

    @Test func globsMatchLikeMinimatchWithoutBacktracking() throws {
        typealias G = PiPackages.Glob
        let cases: [(String, String, Bool)] = [
            ("*.md", "a.md", true), ("*.md", "dir/a.md", false), ("**/*.md", "a.md", true),
            ("**/*.md", "x/y/a.md", true), ("skills/**", "skills/a/b", true), ("a?c", "abc", true),
            ("a?c", "a/c", false), ("[a-c]x", "bx", true), ("[!a-c]x", "bx", false),
            ("themes/{dark,light}.json", "themes/light.json", true), ("{a,{b,c}}", "c", true),
            ("extensions/*.ts", "extensions/legacy.ts", true), ("x", "xx", false),
        ]
        for (pattern, text, expected) in cases {
            #expect(try #require(G(pattern)).matches(text) == expected, "\(pattern) vs \(text)")
        }
        #expect(G(String(repeating: "*a", count: 300)) == nil) // too long
        #expect(G("{a,b") == nil)
        #expect(G("{a,b}{c,d}{e,f}{g,h}{i,j}{k,l}{m,n}") == nil) // 128 alternatives
        // Exponential for a backtracking regex; one pass per token here.
        let text = String(repeating: "a", count: 4_000)
        #expect(try #require(G("*a*a*a*a*a*a*a*a*a*a*a*a*b")).matches(text) == false)
    }

    @Test func projectEntryHidesTheGlobalPackageSkillsItReplaces() throws {
        let project = home.appending(path: "Projects/app")
        try write(".pi/agent/settings.json", #"{"packages": ["npm:tools", "npm:other"]}"#)
        try write(".pi/agent/npm/node_modules/tools/skills/a/SKILL.md")
        try write(".pi/agent/npm/node_modules/tools/skills/b/SKILL.md")
        try write(".pi/agent/npm/node_modules/other/skills/c/SKILL.md")
        try write("Projects/app/.pi/settings.json", #"{"packages": [{"source": "npm:tools", "autoload": false, "skills": ["-skills/a"]}]}"#)

        let list = packages(projects: [project])
        let hidden = PiPackages.skillsHidden(in: project, packages: list)
        #expect(hidden == [agent.appending(path: "npm/node_modules/tools/skills/a/SKILL.md").resolvingSymlinksInPath().path])
        #expect(PiPackages.skillsHidden(in: home.appending(path: "Projects/else"), packages: list).isEmpty)
    }
}
