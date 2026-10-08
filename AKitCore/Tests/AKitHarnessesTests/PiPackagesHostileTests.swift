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
                          "git:https://user@gitlab.com/team/kit@v1",
                          "https://bitbucket.org/team/tool.git?access_token=fake456#v2"]}
            """)
        try write(".pi/agent/git/github.com/acme/repo/skills/s/SKILL.md")
        let list = packages()
        #expect(list.map(\.source) == ["https://github.com/acme/repo.git", "git:https://gitlab.com/team/kit@v1",
                                       "https://bitbucket.org/team/tool.git#v2"])
        #expect(list.map(\.identity) == ["git:github.com/acme/repo", "git:gitlab.com/team/kit", "git:bitbucket.org/team/tool"])
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
        try write(".pi/agent/settings.json", #"{"packages": ["npm:dup", "npm:other", "npm:dup@2"]}"#)
        try write("\(pkg)/package.json", #"{"name": "dup", "pi": {"skills": ["./skills", "./skills/a", "skills/*"]}}"#)
        try write("\(pkg)/skills/a/SKILL.md")

        let listing = PiPackages.list(configRoot: agent, projects: [], in: env)
        // Like Pi, a global file keeps the first entry of a package.
        #expect(listing.packages.map(\.source) == ["npm:dup", "npm:other"])
        #expect(Set(listing.packages.map(\.id)).count == 2)
        #expect(listing.notes.contains { $0.contains("1 repeated entry skipped") })
        let dup = listing.packages[0]
        #expect(names(dup.skills, in: dup) == ["skills/a/SKILL.md"])
    }

    @Test func aProjectFileKeepsTheLastRepeatedEntry() throws {
        let project = home.appending(path: "Projects/app")
        try write("Projects/app/.pi/settings.json", #"{"packages": ["npm:tools", {"source": "npm:tools", "skills": []}]}"#)
        let list = packages(projects: [project])
        #expect(list.count == 1)
        #expect(list.first?.index == 1)
        #expect(list.first?.isFiltered == true)
    }

    @Test func endlessSettingsFinishFast() throws {
        // 50,000 copies of one entry fit in 1 MB; 300 different ones go over the entry limit.
        let copies = Array(repeating: #""./kit""#, count: 50_000)
        let distinct = (0..<300).map { #""./k\#($0)""# }
        try write(".pi/agent/settings.json", #"{"packages": [\#((copies + distinct).joined(separator: ","))]}"#)
        try write(".pi/agent/kit/prompts/p.md")

        let start = Date()
        let listing = PiPackages.list(configRoot: agent, projects: [], in: env)
        #expect(Date().timeIntervalSince(start) < 5)
        #expect(listing.packages.count == PiPackages.maxEntries)
        #expect(listing.packages.first?.prompts.count == 1)
        #expect(listing.notes.contains { $0.contains("49999 repeated entries skipped") })
        #expect(listing.notes.contains { $0.contains("only the first 200 of 301 packages") })
    }

    @Test func heavyPatternsUseUpTheRefreshLimitQuickly() throws {
        let pkg = home.appending(path: ".pi/agent/npm/node_modules/heavy/prompts")
        try fm.createDirectory(at: pkg, withIntermediateDirectories: true)
        for index in 0..<1_000 {
            fm.createFile(atPath: pkg.appending(path: "p\(index).md").path, contents: nil)
        }
        // 8 alternatives, 127 characters, many times: about the most work a pattern may ask for.
        let heavy = "{" + (0..<8).map { "*\($0)*a*a*a" }.joined(separator: ",") + "}" + String(repeating: "*b", count: 27)
        #expect(heavy.count <= PiPackages.Glob.maxLength)
        #expect(PiPackages.Glob(heavy)?.alternatives.count == 8)
        let patterns = Array(repeating: heavy, count: 256).map { "\"!\($0)\"" }.joined(separator: ",")
        try write(".pi/agent/settings.json", #"{"packages": [{"source": "npm:heavy", "prompts": [\#(patterns)]}, "npm:after"]}"#)
        try write(".pi/agent/npm/node_modules/after/prompts/x.md")

        let start = Date()
        let listing = PiPackages.list(configRoot: agent, projects: [], in: env)
        #expect(Date().timeIntervalSince(start) < 10)
        #expect(listing.packages.allSatisfy { $0.isTooLarge && listed($0).isEmpty })
        #expect(listing.notes.contains { $0.contains("limit for one settings file") })
    }

    @Test func oneLimitCoversThePackagesOfASettingsFile() throws {
        // The two global packages share one limit; a project's packages get their own.
        let project = home.appending(path: "Projects/app")
        try write(".pi/agent/settings.json", #"{"packages": ["npm:first", "npm:second"]}"#)
        try write("Projects/app/.pi/settings.json", #"{"packages": ["npm:third"]}"#)
        for folder in [".pi/agent/npm/node_modules/first", ".pi/agent/npm/node_modules/second",
                       "Projects/app/.pi/npm/node_modules/third"] {
            for index in 0..<30 { try write("\(folder)/prompts/p\(index).md") }
        }
        let ceiling = PiPackages.Ceiling()
        let listing = PiPackages.list(configRoot: agent, projects: [project], ceiling: ceiling,
                                      limits: { .init(entries: 200, ceiling: ceiling) }, in: env)
        #expect(listing.packages.map(\.isTooLarge) == [false, true, false])
        #expect(listing.packages.map(\.prompts.count) == [30, 0, 30])
        #expect(listing.notes.contains { $0.contains("settings.json: AKit stopped reading packages") })
    }

    @Test func linkedPackagesAndProjectsCountOnceAndFinishFast() throws {
        // One project lists 200 local packages that are links to one folder; that folder has 30
        // extension subfolders whose package.json lists 256 entries each; 20 more project folders
        // are links to the project.
        let evil = home.appending(path: "Projects/evil")
        let kit = "Projects/evil/.pi/k0"
        let entries = (0..<200).map { "\"./k\($0)\"" }.joined(separator: ",")
        try write("Projects/evil/.pi/settings.json", #"{"packages": [\#(entries)]}"#)
        let listed = (0..<256).map { "\"./f\($0).ts\"" }.joined(separator: ",")
        for index in 0..<30 {
            try write("\(kit)/extensions/e\(index)/package.json", #"{"pi": {"extensions": [\#(listed)]}}"#)
        }
        for index in 1..<200 { try link("Projects/evil/.pi/k\(index)", to: "k0") }
        var projects = [evil]
        for index in 1...20 {
            try link("Projects/alias\(index)", to: evil.path)
            projects.append(home.appending(path: "Projects/alias\(index)"))
        }

        let start = Date()
        let listing = PiPackages.list(configRoot: agent, projects: projects, in: env)
        #expect(Date().timeIntervalSince(start) < 5)
        #expect(listing.packages.count == 1) // one real package, one real project
        #expect(listing.notes.contains { $0.contains("199 repeated entries skipped") })
    }

    @Test func theDeadlineStopsTheWholeListing() throws {
        let project = home.appending(path: "Projects/app")
        try write(".pi/agent/settings.json", #"{"packages": ["npm:tools"]}"#)
        try write(".pi/agent/npm/node_modules/tools/prompts/p.md")
        try write("Projects/app/.pi/settings.json", #"{"packages": ["npm:mine"]}"#)

        let ceiling = PiPackages.Ceiling(seconds: 0)
        let listing = PiPackages.list(configRoot: agent, projects: [project], ceiling: ceiling,
                                      limits: { .init(ceiling: ceiling) }, in: env)
        #expect(listing.packages.isEmpty) // not even the settings files are read
        #expect(listing.notes == ["AKit stopped reading Pi packages after 0 s; later ones are not read."])    }

    @Test func theRefreshCeilingCoversEverySettingsFile() throws {
        let project = home.appending(path: "Projects/app")
        try write(".pi/agent/settings.json", #"{"packages": ["npm:first"]}"#)
        try write("Projects/app/.pi/settings.json", #"{"packages": ["npm:second"]}"#)
        for folder in [".pi/agent/npm/node_modules/first", "Projects/app/.pi/npm/node_modules/second"] {
            for index in 0..<30 { try write("\(folder)/prompts/p\(index).md") }
        }
        let ceiling = PiPackages.Ceiling(entries: 100)
        let listing = PiPackages.list(configRoot: agent, projects: [project], ceiling: ceiling,
                                      limits: { .init(ceiling: ceiling) }, in: env)
        #expect(listing.packages.allSatisfy { $0.isTooLarge })
        #expect(listing.notes.contains { $0.hasPrefix("AKit stopped reading Pi packages after its limit for one refresh;") })
    }

    @Test func linkedSubfoldersSharingAHugePackageJSONFinishFast() throws {
        // 4,990 links to one folder whose package.json is 1 MB: read once at most, never parsed.
        let pkg = home.appending(path: ".pi/agent/npm/node_modules/fan")
        try write(".pi/agent/settings.json", #"{"packages": ["npm:fan"]}"#)
        try write(".pi/agent/npm/node_modules/fan/shared/index.ts")
        let padding = String(repeating: "x", count: 1 << 20)
        try write(".pi/agent/npm/node_modules/fan/shared/package.json",
                  #"{"pi": {"extensions": ["./index.ts"]}, "padding": "\#(padding)"}"#)
        let extensions = pkg.appending(path: "extensions")
        try fm.createDirectory(at: extensions, withIntermediateDirectories: true)
        for index in 0..<4_990 {
            try fm.createSymbolicLink(atPath: extensions.appending(path: "d\(index)").path, withDestinationPath: "../shared")
        }

        let start = Date()
        let fan = try #require(packages().first)
        #expect(Date().timeIntervalSince(start) < 5)
        #expect(fan.isTooLarge || fan.extensions.count <= 1)
    }

    @Test func listsOverTheCapAreCutAndNoted() throws {
        let pkg = ".pi/agent/npm/node_modules/long"
        let files = (0..<300).map { "\"./prompts/p\($0).md\"" }.joined(separator: ",")
        try write(".pi/agent/settings.json", #"{"packages": ["npm:long"]}"#)
        try write("\(pkg)/package.json", #"{"name": "long", "pi": {"prompts": [\#(files)]}}"#)
        for index in 0..<300 { try write("\(pkg)/prompts/p\(index).md") }

        let listing = PiPackages.list(configRoot: agent, projects: [], in: env)
        let long = try #require(listing.packages.first)
        #expect(long.prompts.count == PiPackages.maxPatterns)
        #expect(!long.isTooLarge)
        #expect(listing.notes.contains { $0.hasPrefix("long: a list") && $0.contains("more than 256") })
    }

    @Test func packageJSONMustBeTheirOwnFile() throws {
        // A package.json linked to a secret or to a file outside the package isn't read.
        try write(".pi/agent/settings.json", #"{"packages": ["npm:a", "npm:b"]}"#)
        try write(".pi/agent/auth.json", #"{"name": "stolen", "pi": {"prompts": ["./x.md"]}}"#)
        try write("outside/package.json", #"{"name": "outside", "version": "9"}"#)
        try write(".pi/agent/npm/node_modules/a/x.md")
        try link(".pi/agent/npm/node_modules/a/package.json", to: agent.appending(path: "auth.json").path)
        try fm.createDirectory(at: agent.appending(path: "npm/node_modules/b"), withIntermediateDirectories: true)
        try link(".pi/agent/npm/node_modules/b/package.json", to: home.appending(path: "outside/package.json").path)

        let list = packages()
        #expect(list.map(\.name) == ["a", "b"])
        #expect(list.allSatisfy { $0.version == nil && listed($0).isEmpty })
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
            // `**` spans folders only as a whole segment; elsewhere it is `*`.
            ("a**", "abc", true), ("a**", "a/b", false), ("**a", "xa", true), ("**a", "x/a", false),
            ("a/**/b", "a/b", true), ("a/**/b", "a/x/y/b", true),
            // Wildcards don't match a name's leading dot unless the pattern spells it.
            ("*", ".hidden", false), ("?x", ".x", false), ("[.]x", ".x", false), ("*.md", ".md", false),
            ("**/a.md", ".h/a.md", false), ("skills/**", "skills/.x", false), ("a/**/b", "a/.x/b", false),
            (".*", ".hidden", true), ("x/.h/*", "x/.h/a", true), ("a*", "a.b", true),
            // A segment of only `*` needs a name.
            ("*", "", false), ("a/*/b", "a//b", false), ("a*", "a", true),
            // `{a}` and unbalanced braces stay literal.
            ("{a}", "{a}", true), ("{a}", "a", false), ("{a,b", "{a,b", true),
            // A leading `]` is a class member; `\` escapes.
            ("[]a]", "]", true), ("[]a]", "a", true), ("[]a]", "b", false), ("[!]]", "]", false),
            (#"\*"#, "*", true), (#"\*"#, "a", false), (#"\{a,b\}"#, "{a,b}", true), (#"[\]]"#, "]", true),
        ]
        for (pattern, text, expected) in cases {
            #expect(try #require(G(pattern)).matches(text) == expected, "\(pattern) vs \(text)")
        }
        #expect(G(String(repeating: "a", count: G.maxLength + 1)) == nil) // too long
        #expect(G("{a,b}{c,d}{e,f}")?.alternatives.count == 8)
        #expect(G("{a,b}{c,d}{e,f}{g,h}") == nil) // 16 alternatives
        // The most work one pattern may ask for stays small.
        let worst = try #require(G(String(repeating: "*a", count: 64)))
        let start = Date()
        #expect(!worst.matches(String(repeating: "a", count: 4_000) + "b"))
        #expect(Date().timeIntervalSince(start) < 1)
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
