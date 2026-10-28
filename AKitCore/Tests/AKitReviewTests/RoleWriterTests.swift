import AKitFoundation
import AKitLab
@testable import AKitReview
import Foundation
import Testing

extension ReviewProcessTests {
    /// Write with AI… (`ReviewRoleWriter`): Pi drafts a role with the skill the user picked.
    struct RoleWriterTests {
        /// A fake Pi that records its arguments and answers with `~/fake/answer.txt`.
        static let fakePi = #"""
        #!/bin/sh
        case "$*" in *"auth check"*) echo '{"status":"ready"}'; exit 0 ;; esac
        mkdir -p "$HOME/fake"
        printf '%s\n' "$@" > "$HOME/fake/args.txt"
        cat "$HOME/fake/answer.jsonl"
        """#

        func home(answer: String) throws -> TempHome {
            let home = TempHome()
            try ReviewRunFixture.prepare(home)
            home.write("bin/pi", Self.fakePi, executable: true)
            let message: [String: Any] = ["type": "message_end", "message": [
                "role": "assistant", "content": [["type": "text", "text": answer]], "stopReason": "stop",
                "usage": ["input": 1500, "output": 400, "cacheRead": 0, "cacheWrite": 0, "totalTokens": 1900, "cost": ["total": 0.01]],
            ] as [String: Any]]
            home.write("fake/answer.jsonl", String(decoding: try JSONSerialization.data(withJSONObject: message), as: UTF8.self) + "\n")
            home.write("review/layers/review/review.yaml", "models: { passes: fake/m1 }\n")
            return home
        }

        static let draft = """
        Here it is:

        ```markdown
        ---
        name: review-i18n
        description: "Review a change for text users see that isn't translated"
        akit-review:
          min_severity: medium
          max_findings: 2
          needs: [diff]
          do_not_comment:
            - style and naming
        ---

        - New UI strings in code instead of the translation files.
        ```
        """

        @Test func piWritesTheRoleWithThePickedSkillAndNoTools() async throws {
            let home = try home(answer: Self.draft)
            home.write(".claude/skills/house-style/SKILL.md", "---\nname: house-style\ndescription: Our rules\n---\nUSE-HOUSE-STYLE\n")
            let brain = home.url.appending(path: "review")
            let skills = ReviewRoleWriter.skills(brain: brain, home: home.url)
            #expect(skills.first == .builtIn && skills.contains { $0.name == "house-style" && $0.place == "Claude Code" })
            let skill = try ReviewRoleWriter.skill(named: "house-style", brain: brain, home: home.url, cwd: home.url)
            let request = ReviewRoleWriter.Request(id: "i18n", description: "Strings must come from the translation files.", skill: skill, level: .brain)
            let result = try await ReviewRoleWriter.write(request, brain: brain, env: home.env)
            #expect(result.save.new.hasPrefix("---\nname: review-i18n\n") && !result.save.new.contains("Here it is"))
            #expect(result.save.old == nil && result.save.diff.contains("+ name: review-i18n") && result.model == "fake/m1")
            let args = try String(contentsOf: home.url.appending(path: "fake/args.txt"), encoding: .utf8)
            for flag in ["--no-tools", "--no-mcp", "--no-skills", "--no-extensions", "fake/m1"] { #expect(args.contains(flag), "\(flag)") }
            #expect(args.contains("Strings must come from the translation files."))
            // The picked skill reaches Pi in the system prompt, with AKit's format.
            let folder = try #require(FileWalk.children(of: ReviewPaths(home: home.url).folder.appending(path: "role-writer")).first)
            let prompt = try String(contentsOf: folder.appending(path: "prompt.md"), encoding: .utf8)
            #expect(prompt.contains("USE-HOUSE-STYLE") && prompt.contains("min_severity") && prompt.contains("- bug-hunter:"))
            #expect(SendLog.records(env: home.env).contains { $0.purpose == "review-role-writer" })
            // Nothing is saved before the user approves.
            #expect(!FileManager.default.fileExists(atPath: result.save.file.path))
        }

        /// A project's own model and the thinking it sets; secrets in the skill are masked; only a skill passes as one.
        @Test func theProjectModelAndMaskedSkill() async throws {
            let home = try home(answer: Self.draft.replacingOccurrences(of: "review-i18n", with: "review-text"))
            home.write(".akit/local/review/projects/shop.yaml", "gitlab: { host: https://gitlab.test, project_path: team/shop }\nreview: { models: { passes: fake/m2 }, thinking: { passes: high } }\n")
            let token = "ghp_" + String(repeating: "a1B2", count: 9)
            let skill = home.write("skills/mine/SKILL.md", "---\nname: mine\n---\nToken \(token)\n")
            let brain = home.url.appending(path: "review")
            #expect(throws: ReviewRoleWriter.Failure.self) {
                try ReviewRoleWriter.skill(named: home.url.appending(path: ".pi/agent/auth.json").path, brain: brain, home: home.url, cwd: home.url)
            }
            let picked = try ReviewRoleWriter.skill(named: skill.deletingLastPathComponent().path, brain: brain, home: home.url, cwd: home.url)
            let request = ReviewRoleWriter.Request(id: "text", description: "Copy", skill: picked, level: .project("shop"))
            let result = try await ReviewRoleWriter.write(request, brain: brain, env: home.env)
            #expect(result.model == "fake/m2" && result.save.level == .project("shop"))
            let args = try String(contentsOf: home.url.appending(path: "fake/args.txt"), encoding: .utf8)
            #expect(args.contains("fake/m2") && args.contains("high"), "\(args)")
            let folder = try #require(FileWalk.children(of: ReviewPaths(home: home.url).folder.appending(path: "role-writer")).first)
            #expect(!(try String(contentsOf: folder.appending(path: "prompt.md"), encoding: .utf8)).contains(token))
        }

        @Test func aDraftThatIsNoRoleIsRefusedWithTheDraft() async throws {
            let home = try home(answer: "---\nname: review-other\n---\nchecks\n")
            let request = ReviewRoleWriter.Request(id: "i18n", description: "Translations", level: .brain)
            await #expect {
                try await ReviewRoleWriter.write(request, brain: home.url.appending(path: "review"), env: home.env)
            } throws: { error in
                guard let failure = error as? ReviewRoleWriter.Failure else { return false }
                return failure.message.contains("isn't a valid role") && failure.draft?.contains("review-other") == true
            }
            let prompt = try String(contentsOf: try #require(FileWalk.children(of: ReviewPaths(home: home.url).folder.appending(path: "role-writer")).first)
                .appending(path: "prompt.md"), encoding: .utf8)
            #expect(prompt.contains("name: review-role-writer"), "the built-in skill by default")
            #expect(throws: ReviewRoleWriter.Failure.self) { try ReviewRoleWriter.skill(named: "nope", brain: nil, home: home.url, cwd: home.url) }
        }

        @Test func theAnswerIsCutToTheSkillFile() {
            #expect(ReviewRoleWriter.role(from: "```\n---\nname: review-x\n---\nbody\n```\nThanks") == "---\nname: review-x\n---\nbody\n")
            #expect(ReviewRoleWriter.role(from: "Sure.\n---\nname: review-x\n---\nbody") == "---\nname: review-x\n---\nbody\n")
            // Text after the closing fence, a code block inside the role, a fence with a trailing space.
            #expect(ReviewRoleWriter.role(from: "```markdown \n---\nname: review-x\n---\nbody\n```\n\nUsage:\n```bash\nakit x\n```")
                    == "---\nname: review-x\n---\nbody\n")
            #expect(ReviewRoleWriter.role(from: "```markdown\n---\nname: review-x\n---\nE.g.\n```swift\nlet a = 1\n```\nend\n```\nBye")
                    == "---\nname: review-x\n---\nE.g.\n```swift\nlet a = 1\n```\nend\n")
            #expect((try? ReviewRole.parse(ReviewRoleWriter.builtInSkill.replacingOccurrences(of: "review-role-writer", with: "review-x"),
                                           source: .brain)) != nil, "the built-in skill has a valid frontmatter")
        }
    }
}
