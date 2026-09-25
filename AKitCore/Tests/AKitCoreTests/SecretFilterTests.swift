import Foundation
import Testing
@testable import AKitCore

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
        #expect(!SecretFilter.readsSecretFile(["command": "cd app && swift test\ncat auth.json"]))
    }
}
