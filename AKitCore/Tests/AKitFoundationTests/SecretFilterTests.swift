import Foundation
import Testing
@testable import AKitFoundation

struct SecretFilterTests {
    @Test func masksTokenShapes() {
        let text = """
        ANTHROPIC_API_KEY=sk-ant-api03-abcdefghijklmnopqrstuvwxyz0123456789
        Authorization: Bearer abcdefghijklmnopqrstuvwx
        gh auth token ghp_abcdefghijklmnopqrstuvwxyz0123456789
        {"apiKey": "k-1234567890abcdef", "max_tokens": 4096}
        """
        let masked = SecretFilter.masked(text)
        #expect(!masked.contains("sk-ant-api03"))
        #expect(!masked.contains("abcdefghijklmnopqrstuvwx"))
        #expect(!masked.contains("ghp_"))
        #expect(!masked.contains("k-1234567890abcdef"))
        #expect(masked.contains("ANTHROPIC_API_KEY="))
        #expect(masked.contains("Authorization: Bearer [secret hidden]"))
        #expect(masked.contains("\"max_tokens\": 4096")) // short numbers are not secrets
    }

    @Test func weakPasswordsAreMaskedOnScreenToo() {
        let mask = SecretFilter.mask
        #expect(SecretFilter.masked("db_password: " + "Summer2024") == "db_password: \(mask)")
        #expect(SecretFilter.masked("password=" + "Welcome1!") == "password=\(mask)")
        #expect(SecretFilter.masked("mysql --password " + "hunter22") == "mysql --password \(mask)")
        #expect(SecretFilter.masked("PGPASSWORD=" + "abc1234" + " psql") == "PGPASSWORD=\(mask) psql")
        #expect(SecretFilter.masked("password: string") == "password: string")
        #expect(SecretFilter.masked("password: ${DB_PASSWORD}") == "password: ${DB_PASSWORD}")
    }

    /// The token shapes are the Scrubber's: what one masks, the other does too.
    @Test func tokenShapesMatchTheScrubber() {
        let body = "Zx9Kq2Lm8Np4Rt6Vw1Yb3H" + "c5Jd7Fg0Tq3Ws5EaUoP8iMn"
        for token in ["xo" + "xe-1234567890-" + body, "gh" + "u_" + body, "github" + "_pat_" + "11ABCDEFG0" + body,
                      "ey" + "JhbGciOiJIUzI1NiJ9" + ".ey" + "JzdWIiOiIxMjM0NTY3ODkwIn0" + "." + "sig", "ASIA" + "Q3EGRZ7XWL2N5PMY",
                      "gl" + "pat-" + body, "np" + "m_" + body] {
            #expect(SecretFilter.masked("value \(token) end") == "value \(SecretFilter.mask) end", "\(token)")
            #expect(Scrubber.scrub("value \(token) end").text == "value \(SecretFilter.mask) end", "\(token)")
        }
        // Kebab-case names that start with "sk-" have no digit: not a key on either side.
        #expect(SecretFilter.masked("npm run sk-build-production-bundle-now") == "npm run sk-build-production-bundle-now")
    }

    @Test func environmentStyleNeedsUpperCaseName() {
        #expect(SecretFilter.masked("DB_PASSWORD=hunter2hunter2") == "DB_PASSWORD=[secret hidden]")
        #expect(SecretFilter.masked("echo tokenlen=${#TOKEN}") == "echo tokenlen=${#TOKEN}")
    }

    @Test func plainTextAndCodeStayAsIs() {
        for text in [
            "Run swift test, then commit. The token budget is small; keep prompts short.",
            "Never display or copy secrets: auth.json files, tokens, MCP env/headers",
            "const schema = z.object({ maxTokens: z.number().int().positive() })",
            "private static let secretFileNames: Set<String> = []",
            #"API_KEY = os.environ["X"]"#,
        ] {
            #expect(SecretFilter.masked(text) == text)
        }
    }

    @Test func toolsReadingSecretFiles() {
        #expect(SecretFilter.readsSecretFile(["file_path": "/Users/me/.pi/agent/auth.json"]))
        #expect(SecretFilter.readsSecretFile(["path": "/app/.env"]))
        #expect(SecretFilter.readsSecretFile(["command": "cat .env.local | head"]))
        #expect(SecretFilter.readsSecretFile(["command": "less ~/.claude/settings.local.json"]))
        #expect(SecretFilter.readsSecretFile(["command": "cat ~/.ssh/id_ed25519"]))
        #expect(!SecretFilter.readsSecretFile(["command": "cat ~/.ssh/id_ed25519.pub"]))
        #expect(!SecretFilter.readsSecretFile(["command": "cat environment.swift src/.envelope.ts"]))
        #expect(!SecretFilter.readsSecretFile(["file_path": "/app/settings.json"]))
        // Mentions are not reads.
        #expect(!SecretFilter.readsSecretFile(["prompt": "never show auth.json"]))
        #expect(!SecretFilter.readsSecretFile(["command": "cat > notes.md <<'EOF' auth.json\nnever show auth.json\nEOF"]))
        #expect(SecretFilter.readsSecretFile(["command": "cd app\ncat .env"])) // any line before a heredoc
        #expect(SecretFilter.readsSecretFile(["command": "grep KEY .env*"]))
        #expect(SecretFilter.readsSecretFile(["file_path": "/p/.mcp.json"]))
        #expect(SecretFilter.readsSecretFile(["file_path": "/Users/me/.claude.json"]))
        #expect(SecretFilter.readsSecretFile(["path": "/Users/me/.pi/agent/mcp.json"]))
        #expect(SecretFilter.readsSecretFile(["command": "cat ~/.docker/config.json ~/.git-credentials"]))
        #expect(!SecretFilter.readsSecretFile(["path": "/app/tools/mcp.json"]))
    }

    @Test func writesToSecretFilesHideTheContent() throws {
        let write = try #require(SecretFilter.redactedInput(["file_path": "/app/.env", "content": "A=1"]) as? [String: String])
        #expect(write["content"] == SecretFilter.hiddenOutput)
        #expect(write["file_path"] == "/app/.env")
        let shell = try #require(SecretFilter.redactedInput(["command": "cat > .env <<'EOF'\nDB=secret\nEOF"]) as? [String: String])
        #expect(shell["command"] == "cat > .env <<'EOF'\n" + SecretFilter.hiddenOutput)
        let other = try #require(SecretFilter.redactedInput(["file_path": "/app/main.swift", "content": "x"]) as? [String: String])
        #expect(other["content"] == "x")
    }
}
