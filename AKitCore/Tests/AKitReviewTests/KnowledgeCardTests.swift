import AKitFoundation
import AKitKnowledge
@testable import AKitReview
import Foundation
import Testing

extension ReviewProcessTests {
    /// The knowledge card of Gather (K18): the systems a change touches, from a knowledge base.
    struct KnowledgeCardTests {
        static let secret = "glpat-abcdefghijklmnopqrst"

        /// A workspace `work/shop` (origin `remote`) whose feature branch changes `src/Cart.swift`
        /// and `src/Price.swift`, and a knowledge base at `base` (a git repo with `areas/`): area
        /// `shop` names the repository as `areaProject` in its area.yaml, or (nil) a note's
        /// `repo:` does as `noteRepo`. An inbox proposal and note text below the first sentence
        /// must never reach the pack.
        func setUp(remote: String, areaProject: String?, noteRepo: String? = nil, base: String,
                   profile: String) throws -> (home: TempHome, repo: URL, base: URL) {
            let home = TempHome()
            let repo = home.url.appending(path: "work/shop")
            try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
            home.git(repo, "init", "-q", "-b", "main")
            home.git(repo, "remote", "add", "origin", remote)
            home.write("work/shop/src/Cart.swift", "struct Cart {}\n")
            home.write("work/shop/src/Price.swift", "let vat = 20\n")
            home.git(repo, "add", ".")
            home.git(repo, "commit", "-q", "-m", "Add the cart")
            home.git(repo, "checkout", "-q", "-b", "feature/total")
            home.write("work/shop/src/Cart.swift", "struct Cart { var total = 0 }\n")
            home.write("work/shop/src/Price.swift", "let vat = 21\n")
            home.git(repo, "commit", "-q", "-am", "Add a total")

            let root = home.url.appending(path: base)
            try FileManager.default.createDirectory(at: root.appending(path: "areas/shop"), withIntermediateDirectories: true)
            home.git(root, "init", "-q", "-b", "main")
            if let areaProject { home.write("\(base)/areas/shop/area.yaml", "projects: [\"\(areaProject)\"]\n") }
            home.write("\(base)/areas/shop/aaa-catalog.md", """
            ---
            kind: service
            ---
            # Catalog

            Lists the products. BODY-ONLY-TEXT stays in the note.
            """)
            home.write("\(base)/areas/shop/cart.md", """
            ---
            kind: service
            \(noteRepo.map { "repo: \"\($0)\"" } ?? "")
            files: [src/Cart.swift]
            description: Keeps the items; its admin token is \(Self.secret).
            ---
            # Cart

            ## Rules

            SECTION-ONLY-TEXT: a cart never goes below zero.
            """)
            home.write("\(base)/areas/shop/price.md", """
            ---
            kind: service
            files: [src/]
            ---
            # Price

            Sets the VAT of each item.
            """)
            home.write("\(base)/areas/other/unrelated.md", "# Unrelated\n\nAnother system: UNRELATED-TEXT.\n")
            home.write("\(base)/inbox/20261025-proposal.md", "INBOX-TEXT of a proposal.\n")
            home.write(".akit/local/review/projects/shop.yaml", profile)
            try ReviewRunFixture.prepare(home)
            return (home, repo, root)
        }

        /// A local review of the feature branch, gathered only.
        func gather(_ home: TempHome, _ repo: URL, choices: ReviewRunChoices = ReviewRunFixture.choices) async throws -> (ReviewGather.Result, URL) {
            let inspection = try await ReviewLocal.inspect(path: repo, env: home.env)
            let target = try await ReviewLocal.target(inspection, mode: .commits, env: home.env)
            let result = try await ReviewRuns.startLocal(target, project: "shop", choices: choices, env: home.env, brain: nil)
            return (result, ReviewPaths(home: home.url).run(result.spec.id))
        }

        /// Every file of the pack, by its path under `context/`.
        func pack(_ folder: URL) -> [String: String] {
            let context = folder.appending(path: "context")
            var files: [String: String] = [:]
            for case let url as URL in FileManager.default.enumerator(at: context, includingPropertiesForKeys: nil) ?? .init()
            where FileWalk.isRegularFile(url) {
                files[String(url.resolvingSymlinksInPath().path.dropFirst(context.resolvingSymlinksInPath().path.count + 1))] =
                    (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            }
            return files
        }

        /// A `knowledge:` folder that is a base gives only the card: no note dump, no inbox. The
        /// https origin finds the area whose area.yaml names the repository in scp form; touched
        /// systems come first; the card is scrubbed.
        @Test func aBaseRootGivesOnlyTheCard() async throws {
            let (home, repo, _) = try setUp(remote: "https://gitlab.test/team/shop.git", areaProject: "git@gitlab.test:team/shop.git",
                                            base: "kb", profile: """
            gitlab: { host: https://gitlab.test, project_path: team/shop }
            knowledge: [~/kb, ~/notes]
            """)
            home.write("notes/plain.md", "# Plain\n\nPLAIN-NOTE-TEXT\n")
            let (result, folder) = try await gather(home, repo)
            let files = pack(folder)
            let card = try #require(files["knowledge-card.md"])
            #expect(card.contains("untrusted text"))
            #expect(card.contains("Repository: gitlab.test/team/shop · areas: shop"))
            let lines = card.split(separator: "\n").filter { $0.hasPrefix("- shop/") }.map(String.init)
            #expect(lines.map { $0.split(separator: " ")[1] } == ["shop/price", "shop/cart", "shop/aaa-catalog"],
                    "touched systems first (the most changed files first), then the rest of the area")
            #expect(lines[0].contains("touched: src/Cart.swift, src/Price.swift") && lines[1].contains("touched: src/Cart.swift"))
            #expect(!card.contains(Self.secret), "the card is scrubbed")
            #expect(!card.contains("UNRELATED-TEXT") && !card.contains("other/unrelated"), "only the repository's areas")
            for (name, text) in files {
                #expect(!name.hasPrefix("knowledge/kb"), "no note of the base is dumped: \(name)")
                for marker in ["BODY-ONLY-TEXT", "SECTION-ONLY-TEXT", "INBOX-TEXT"] { #expect(!text.contains(marker), "\(marker) in \(name)") }
            }
            #expect(files["knowledge/notes/plain.md"]?.contains("PLAIN-NOTE-TEXT") == true, "a plain folder still gives its notes")
            #expect(try String(contentsOf: folder.appending(path: "context/README.md"), encoding: .utf8).contains("knowledge-card.md"))
            #expect(result.scrubbed.values.reduce(0, +) > 0)
            #expect(FileManager.default.fileExists(atPath: home.url.appending(path: "kb/\(KnowledgeIndex.fileName)").path),
                    "Gather builds the index first")
        }

        /// `knowledge_base:` names a world; the scp origin finds the note whose `repo:` is the
        /// https form. The card stays within `knowledge_budget`, cut from the end and marked.
        @Test func theCardStaysWithinItsBudget() async throws {
            let (home, repo, _) = try setUp(remote: "git@gitlab.test:team/shop.git", areaProject: nil,
                                            noteRepo: "https://gitlab.test/team/shop", base: ".akit/local/knowledge/work", profile: """
            gitlab: { host: https://gitlab.test, project_path: team/shop }
            knowledge_base: work
            knowledge_budget: 8000
            """)
            let (full, fullFolder) = try await gather(home, repo)
            #expect(full.spec.knowledgeBase == Sourced("work", .project) && full.spec.knowledgeBudget == Sourced(8000, .project))
            let card = try #require(pack(fullFolder)["knowledge-card.md"])
            #expect(card.contains("- shop/cart (Cart), touched: src/Cart.swift"))
            #expect(!card.contains("cut here") && Budget.tokens(card) <= 8000)

            var choices = ReviewRunFixture.choices
            choices.knowledgeBudget = 120
            let (small, smallFolder) = try await gather(home, repo, choices: choices)
            #expect(small.spec.knowledgeBudget == Sourced(120, .run))
            let cut = try #require(pack(smallFolder)["knowledge-card.md"])
            #expect(Budget.tokens(cut) <= 120 && cut.contains("knowledge_budget 120 tokens"))
            #expect(cut.hasPrefix("# Knowledge card"), "cut from the end")
            #expect(small.gaps.contains { $0.needed == "The whole knowledge card" })
        }

        /// A base that names no system of the repository gives a gap, not a guess.
        @Test func anUnknownRepositoryIsAGap() async throws {
            let (home, repo, _) = try setUp(remote: "git@gitlab.test:team/elsewhere.git", areaProject: "git@gitlab.test:team/shop.git",
                                            base: "kb", profile: """
            gitlab: { host: https://gitlab.test, project_path: team/shop }
            knowledge_base: ~/kb
            """)
            let (result, folder) = try await gather(home, repo)
            #expect(pack(folder)["knowledge-card.md"]?.contains("No area or note of this base names the repository") == true)
            #expect(result.gaps.contains { $0.system == "knowledge" && $0.needed.hasPrefix("The systems of gitlab.test/team/elsewhere") })
        }
    }
}

struct KnowledgeCardUnitTests {
    @Test func filesPrefixes() {
        #expect(ReviewKnowledgeCard.touches(prefix: "src/events/order-created.ts", path: "src/events/order-created.ts"))
        #expect(ReviewKnowledgeCard.touches(prefix: "src/events", path: "src/events/order-created.ts"))
        #expect(ReviewKnowledgeCard.touches(prefix: "./src/events/", path: "src/events/a.ts"))
        #expect(!ReviewKnowledgeCard.touches(prefix: "src/event", path: "src/events/a.ts"))
        #expect(!ReviewKnowledgeCard.touches(prefix: "", path: "src/a.ts"))
    }

    @Test func fittedCutsFromTheEnd() {
        let lines = ["# Knowledge card", ""] + (1...200).map { "- system \($0): " + String(repeating: "x", count: 60) }
        for budget in [50, 300, 1000] {
            let card = ReviewKnowledgeCard.fitted(lines, budget: budget, scrub: Scrubber.OwnPatterns())
            #expect(card.truncated && Budget.tokens(card.text) <= budget && card.text.hasPrefix("# Knowledge card"))
        }
        let whole = ReviewKnowledgeCard.fitted(Array(lines.prefix(5)), budget: 8000, scrub: Scrubber.OwnPatterns())
        #expect(!whole.truncated && !whole.text.contains("cut here"))
    }

    @Test func profileFields() throws {
        let profile = try ReviewProfile.parse("gitlab: { host: https://g, project_path: a/b }\nknowledge_base: work\nknowledge_budget: 5000\n", slug: "b")
        #expect(profile.knowledgeBase == "work" && profile.knowledgeBudget == 5000)
        #expect(throws: (any Error).self) { try ReviewProfile.parse("gitlab: { host: https://g, project_path: a/b }\nknowledge_budget: 0\n", slug: "b") }
        #expect(throws: (any Error).self) { try ReviewProfile.parse("gitlab: { host: https://g, project_path: a/b }\nknowledge_base: [x]\n", slug: "b") }
    }

    @Test func settingsSaveSetsOnlyTheTwoKeys() throws {
        let home = TempHome()
        let original = "project: b  # mine\ngitlab: { host: https://g, project_path: a/b }\nknowledge_budget: 100 # small\n"
        home.write(".akit/local/review/projects/b.yaml", original)
        let save = try ReviewConfigEditor.knowledge(base: "work", budget: 9000, profile: "b", home: home.url, brain: home.url.appending(path: "brain"))
        #expect(save.new == "project: b  # mine\ngitlab: { host: https://g, project_path: a/b }\nknowledge_budget: 9000 # small\nknowledge_base: \"work\"\n")
        let cleared = ReviewConfigEditor.settingTopLevel("knowledge_budget", nil, in: save.new)
        #expect(!cleared.contains("knowledge_budget") && cleared.contains("knowledge_base: \"work\""))
        #expect(throws: (any Error).self) { try ReviewConfigEditor.knowledge(base: "a\"b", budget: nil, profile: "b", home: home.url, brain: home.url) }
    }
}
