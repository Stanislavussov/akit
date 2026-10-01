import Foundation
import Testing
@testable import AKitFoundation

/// Fake tokens are built by concatenation so this file doesn't look like a leak to scanners.
struct ScrubberTests {
    private let mask = SecretFilter.mask
    /// Random-looking bodies: mixed case and digits, as real tokens are.
    private let body = "Zx9Kq2Lm8Np4Rt6Vw1Yb3H" + "c5Jd7Fg0Tq3Ws5EaUoP8iMn"
    private let hex = "3f9ac2b1e8d7" + "40a65b1c9d2e" + "7f30a1b4"

    private func scrub(_ text: String, own: Scrubber.OwnPatterns = .init()) -> Scrubber.Result {
        Scrubber.scrub(text, own: own)
    }

    // MARK: - Rule families

    @Test func privateKeyBlocks() {
        for kind in ["RSA PRIVATE KEY", "OPENSSH PRIVATE KEY", "EC PRIVATE KEY", "PRIVATE KEY", "PGP PRIVATE KEY BLOCK"] {
            let block = "-----BEGIN " + kind + "-----\n" + body + body + "\n" + body + "==\n-----END " + kind + "-----"
            let result = scrub("key file:\n\(block)\ndone")
            #expect(result.text == "key file:\n\(mask)\ndone", "\(kind)")
            #expect(result.counts["private-key"] == 1)
        }
        // Cut off before the END line.
        let head = "-----BEGIN " + "OPENSSH PRIVATE KEY-----\n" + body + body + "\n" + body + "\nmore output"
        #expect(scrub(head).text == "\(mask)\nmore output")
    }

    @Test func awsKeys() {
        let id = "AK" + "IAQ3EGRZ7XWL2N5PMY"
        let secret = "wJalrXUtnFEMI" + "/K7MDENG/bPxRfiCY" + "9xQ2pLm4Kz"
        let result = scrub("aws_access_key_id = \(id)\naws_secret_access_key = \(secret)\n")
        #expect(result.text == "aws_access_key_id = \(mask)\naws_secret_access_key = \(mask)\n")
        #expect(result.counts["aws-access-token"] == 1)
        #expect(result.counts["aws-secret-access-key"] == 1)
        #expect(scrub("ASIA" + "Q3EGRZ7XWL2N5PMY").counts["aws-access-token"] == 1)
    }

    @Test func gitHubTokens() {
        let cases: [(String, String)] = [
            ("github-pat", "gh" + "p_" + body),
            ("github-oauth", "gh" + "o_" + body),
            ("github-app-token", "gh" + "u_" + body),
            ("github-app-token", "gh" + "s_" + body),
            ("github-refresh-token", "gh" + "r_" + body),
            ("github-fine-grained-pat", "github" + "_pat_" + "11ABCDEFG0" + body + "_" + body),
        ]
        for (id, token) in cases {
            let result = scrub("git push with \(token) now")
            #expect(result.text == "git push with \(mask) now", "\(id)")
            #expect(result.counts[id] == 1, "\(id)")
        }
    }

    @Test func gitLabTokens() {
        for (id, token) in [("gitlab-pat", "gl" + "pat-" + body), ("gitlab-deploy-token", "gl" + "dt-" + body),
                            ("gitlab-runner-authentication-token", "gl" + "rt-" + body),
                            ("gitlab-rrt", "GR13" + "48941" + body)] {
            let result = scrub("token \(token).")
            #expect(result.text == "token \(mask).", "\(id)")
            #expect(result.counts[id] == 1, "\(id)")
        }
    }

    @Test func slackTokensAndWebhooks() {
        let bot = "xo" + "xb-1234567890-" + body
        let app = "xa" + "pp-1-A0123BCDE-" + body
        let hook = "https://hooks.slack.com/services/" + "T0ABC1234/B0DEF5678/" + body
        let result = scrub("\(bot)\n\(app)\ncurl \(hook)")
        #expect(result.text == "\(mask)\n\(mask)\ncurl https://hooks.slack.com/services/\(mask)")
        #expect(result.counts["slack-token"] == 1)
        #expect(result.counts["slack-app-token"] == 1)
        #expect(result.counts["slack-webhook-url"] == 1)
    }

    @Test func otherProviderTokens() {
        let cases: [(String, String)] = [
            ("stripe-access-token", "sk" + "_live_" + body),
            ("stripe-access-token", "sk" + "_test_" + body),
            ("stripe-access-token", "rk" + "_live_" + body),
            ("stripe-access-token", "pk" + "_live_" + body),
            ("gcp-api-key", "AI" + "za" + "SyD4" + "Zx9Kq2Lm8Np4Rt6Vw1Yb3Hc5Jd7Fg0T"),
            ("gcp-oauth-client-secret", "GOC" + "SPX-" + "Zx9Kq2Lm8Np4Rt6Vw1Yb3Hc5Jd7"),
            ("openai-api-key", "sk" + "-" + body),
            ("openai-api-key", "sk" + "-proj-" + body + "_" + body),
            ("anthropic-api-key", "sk" + "-ant-api03-" + body + "-" + body),
            ("huggingface-access-token", "hf" + "_" + body),
            ("npm-access-token", "np" + "m_" + body),
            ("pypi-upload-token", "pypi-" + "AgEIcHlwaS5vcmc" + body + body + body),
            ("sendgrid-api-token", "S" + "G." + "Zx9Kq2Lm8Np4Rt6Vw1Yb3H" + "." + body),
            ("mailgun-private-api-token", "ke" + "y-" + "3f9ac2b1e8d740a65b1c9d2e7f30a1b4"),
            ("shopify-token", "shp" + "at_" + "3f9ac2b1e8d740a65b1c9d2e7f30a1b4"),
            ("shopify-token", "shp" + "ss_" + "3f9ac2b1e8d740a65b1c9d2e7f30a1b4"),
            ("digitalocean-token", "do" + "p_v1_" + hex + hex),
            ("digitalocean-token", "do" + "o_v1_" + hex + hex),
            ("doppler-api-token", "dp" + ".pt." + body),
            ("linear-api-key", "lin" + "_api_" + body),
            ("atlassian-api-token", "ATA" + "TT3" + body + body + "=F1A2B3C4"),
            ("databricks-api-token", "da" + "pi" + "3f9ac2b1e8d740a65b1c9d2e7f30a1b4"),
            ("grafana-cloud-api-token", "gl" + "c_" + body + body + "=="),
            ("grafana-service-account-token", "gl" + "sa_" + "Zx9Kq2Lm8Np4Rt6Vw1Yb3Hc5Jd7Fg0Tq" + "_" + "3f9ac2b1"),
        ]
        for (id, token) in cases {
            let result = scrub("value \(token) end")
            #expect(result.text == "value \(mask) end", "\(id): \(result.text)")
            #expect(result.counts[id] == 1, "\(id): \(result.counts)")
        }
    }

    @Test func twilioKeyNeedsContext() {
        let key = "S" + "K" + "3f9ac2b1e8d740a65b1c9d2e7f30a1b4"
        let result = scrub("TWILIO_API_KEY_SID: \(key)")
        #expect(result.text == "TWILIO_API_KEY_SID: \(mask)")
        #expect(result.counts["twilio-api-key"] == 1)
        // Without a nearby key word it is just a hex-ish id.
        #expect(scrub("build \(key) finished").counts["twilio-api-key"] == nil)
    }

    @Test func jwtAndAzureKey() {
        let jwt = "ey" + "JhbGciOiJIUzI1NiJ9" + ".ey" + "JzdWIiOiIxMjM0NTY3ODkwIn0" + "." + "dBjftJeZ4CVPmB92K27uhbUJU1p1r_wW1gFWFOEjXk"
        let result = scrub("cookie: \(jwt);")
        #expect(result.text == "cookie: \(mask);")
        #expect(result.counts["jwt"] == 1)

        let azure = "DefaultEndpointsProtocol=https;AccountName=acme;AccountKey=" + body + body + body + "==;EndpointSuffix=core.windows.net"
        let scrubbed = scrub(azure)
        #expect(scrubbed.text == "DefaultEndpointsProtocol=https;AccountName=acme;AccountKey=\(mask);EndpointSuffix=core.windows.net")
        #expect(scrubbed.counts["azure-storage-account-key"] == 1)
    }

    @Test func urlCredentialsKeepSchemeUserAndHost() {
        let result = scrub("connect postgres://admin:" + "s3cr3tP4ss" + "@db.example.com:5432/app and redis://:" + "hunter22" + "@cache:6379")
        #expect(result.text == "connect postgres://admin:\(mask)@db.example.com:5432/app and redis://:\(mask)@cache:6379")
        #expect(result.counts["url-credentials"] == 2)
        // No credentials: unchanged.
        for plain in ["see https://example.com/api/v2/users/12345/profile?tab=settings#top",
                      "open http://localhost:8080/login and ssh://git@github.com:22/org/repo.git"] {
            #expect(scrub(plain).text == plain)
        }
    }

    @Test func authorizationHeaders() {
        let token = "abc" + "DEF123ghi456JKL789"
        let text = """
        Authorization: Bearer \(token)
        authorization: basic dXNlcjpwYXNzd29yZA==
        curl -H "x-api-key: \(token)" -H "Authorization: Bearer $TOKEN"
        Bearer \(token)
        """
        let result = scrub(text)
        #expect(result.text == """
        Authorization: Bearer \(mask)
        authorization: basic \(mask)
        curl -H "x-api-key: \(mask)" -H "Authorization: Bearer $TOKEN"
        Bearer \(mask)
        """)
        #expect(result.counts["authorization-header"] == 3)
        #expect(result.counts["api-key-header"] == 1)
    }

    @Test func genericKeyMasksRandomValuesOnly() {
        let value = "q8Xv2LmN" + "4pRt7Wz"
        let text = """
        api_key = "\(value)"
        "clientSecret": "\(value)",
        DB_PASSWORD: \(value)
        password = os.environ["DB_PASSWORD"]
        let tokenizer = TokenizerConfiguration(vocabSize: 32000)
        "max_tokens": 4096, "input_tokens": 123456789
        secret_key = settings.SECRET_KEY_V2
        key: value
        let cacheKey = "user-profile-cache"
        password = "correct-horse-battery"
        """
        let result = scrub(text)
        #expect(result.text == """
        api_key = "\(mask)"
        "clientSecret": "\(mask)",
        DB_PASSWORD: \(mask)
        password = os.environ["DB_PASSWORD"]
        let tokenizer = TokenizerConfiguration(vocabSize: 32000)
        "max_tokens": 4096, "input_tokens": 123456789
        secret_key = settings.SECRET_KEY_V2
        key: value
        let cacheKey = "user-profile-cache"
        password = "\(mask)"
        """)
        #expect(result.counts["generic-api-key"] == 4)
    }

    @Test func entropyDetectorMasksStandAloneTokens() {
        let token = "q8Xv2LmN4pRt7Wz" + "K3yB9cD6fH1jG5sA0"
        let base64 = "dGhpcyBpcyBh" + "IHNlY3JldCB2YWx1ZSAxMjM0NTY3ODkw"
        let result = scrub("session id \(token) and blob \(base64).")
        #expect(result.text == "session id \(mask) and blob \(mask).")
        #expect(result.counts["entropy"] == 2)
    }

    // MARK: - Allowlist and readable text

    @Test func hexAndUUIDsAreNeverMasked() {
        let text = """
        commit 8beb67b0c2a1f56e3ee7fb1c1d2e3f4a5b6c7d8e
        sha256:9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08
        digest=9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08
        session 3F2504E0-4F89-11D3-9A0C-0305E82C3301 and 7c9e6679-7425-40de-944b-e07fc1f90ae7
        "session_key": "7c9e6679-7425-40de-944b-e07fc1f90ae7"
        cache_key = 9f86d081884c7d659a2feaa0c55ad015
        """
        #expect(scrub(text).text == text)
    }

    @Test func testScrubberKeepsLongCamelCaseIdentifiers() {
        let text = """
        func testScrubberKeepsLongCamelCaseIdentifiers() async throws {}
        let digest = makeSHA256DigestForBase64EncodedPayloadV2(input)
        export const useWorkspaceSessionTokenRefreshHandler2 = () => {}
        AKitFoundationTests2/ScrubberTests.swift and NSRegularExpressionMatchingOptions
        XCTAssertEqualWithAccuracy(value, expectedValue2, accuracy: 0.001)
        """
        #expect(scrub(text).text == text)
    }

    @Test func pathsUrlsAndNumbersStayUnchanged() {
        let text = """
        /Users/stanislav.ussov/Projects/akit/AKitCore/Sources/AKitFoundation/Scrubber.swift
        ~/.claude/projects/-Users-me-Projects-akit2/7c9e6679-7425-40de-944b-e07fc1f90ae7.jsonl
        src/components/UserProfile3Card/index.tsx and node_modules/@types/node/index.d.ts
        https://github.com/anthropics/claude-code/blob/main/src/x2.ts?line=120
        Took 12345678901234567890 ns, 3.14159265358979323846, 1,234,567
        """
        #expect(scrub(text).text == text)
    }

    // MARK: - .env, own patterns, SecretFilter

    @Test func dotenvBlocks() {
        let text = """
        DATABASE_URL=postgres://localhost/app
        APP_NAME=storefront
        DEBUG=true
        PORT=8080
        export STRIPE_KEY=whatever
        """
        let result = scrub(text)
        #expect(result.text == """
        DATABASE_URL=\(mask)
        APP_NAME=\(mask)
        DEBUG=true
        PORT=8080
        export STRIPE_KEY=\(mask)
        """)
        #expect(result.counts["dotenv"] == 3)

        // A single line is masked only when the name sounds secret.
        #expect(scrub("NODE_ENV=production").text == "NODE_ENV=production")
        #expect(scrub("SESSION_ID=abc12").text == "SESSION_ID=\(mask)")
    }

    @Test func ownPatterns() {
        let own = Scrubber.OwnPatterns(hosts: [#"[a-z0-9.-]+\.corp\.example\.com"#], extra: [#"ACME-[0-9]{4}"#])
        let result = scrub("ssh build01.corp.example.com, mail jane.doe@example.org about ACME-1234", own: own)
        #expect(result.text == "ssh \(Scrubber.hostMask), mail \(Scrubber.emailMask) about \(mask)")
        #expect(result.counts["host"] == 1)
        #expect(result.counts["email"] == 1)
        #expect(result.counts["extra"] == 1)

        // E-mails can be kept; SSH remotes and @2x images are not e-mails.
        #expect(scrub("jane.doe@example.org", own: .init(maskEmails: false)).text == "jane.doe@example.org")
        #expect(scrub("git@github.com:org/repo.git icon_16x16@2x.png").text == "git@github.com:org/repo.git icon_16x16@2x.png")
    }

    @Test func invalidUserRegexIsReportedAndSkipped() {
        let own = Scrubber.OwnPatterns(hosts: ["([a-z", #"internal\.example"#], extra: ["", "*oops"])
        let invalid = Scrubber.invalidPatterns(own)
        #expect(invalid.count == 3)
        #expect(invalid.contains { $0.hasPrefix("([a-z") })
        #expect(invalid.contains { $0.hasPrefix("*oops") })
        let result = scrub("host internal.example here", own: own)
        #expect(result.text == "host \(Scrubber.hostMask) here")
        #expect(Scrubber.invalidPatterns(.init(hosts: [#"a\.b"#])).isEmpty)
    }

    @Test func secretFilterRunsToo() {
        // Low entropy for the generic rule, not at a line start for .env: SecretFilter catches it.
        let result = scrub("run with DB_PASSWORD=hunter2hunter2 now")
        #expect(result.text == "run with DB_PASSWORD=\(mask) now")
        #expect(result.counts["secret-filter"] == 1)
    }

    @Test func countsAddUpPerRule() {
        let text = "gh" + "p_" + body + " gh" + "p_" + body + "\nuser jane@example.org\nAK" + "IAQ3EGRZ7XWL2N5PMY"
        let result = scrub(text)
        #expect(result.counts == ["github-pat": 2, "email": 1, "aws-access-token": 1])
        #expect(scrub("nothing to see here").counts.isEmpty)
    }

    @Test func versionIsSet() {
        #expect(Scrubber.version >= 1)
    }

    // MARK: - Performance

    @Test func twoMegabyteTranscriptIsFast() {
        let lines = [
            "The user asked to refactor SessionIndexer.swift; I read /Users/me/Projects/app/Sources/App/SessionIndexer.swift.",
            #"{"type":"tool_use","name":"Bash","input":{"command":"swift test --filter ScrubberTests"},"max_tokens":4096}"#,
            "commit 8beb67b0c2a1f56e3ee7fb1c1d2e3f4a5b6c7d8e Merge branch 'banner-name' into master",
            "    let configuration = URLSessionConfiguration.default // keep the token budget small",
            "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.bbbbbbbbbbbbbbbbbbbbbbbb",
            "key key key token token secret password auth = = = : : : ===== ::::: -----BEGIN -----END PRIVATE KEY",
            "export API_TOKEN=" + body + "\nDB_HOST=localhost",
            "Authorization: Bearer " + body + " and x-api-key: " + body,
            "postgres://user:" + "pw123456" + "@db.example.com/app jane@example.org " + "gh" + "p_" + body,
        ]
        var text = ""
        var index = 0
        while text.utf8.count < 2_000_000 {
            text += lines[index % lines.count] + "\n"
            index += 1
        }
        // A long run without separators must not slow anything down either.
        text += String(repeating: "Ab1+", count: 50_000) + "\n"

        var result: Scrubber.Result?
        let seconds = cpuSeconds { result = Scrubber.scrub(text) }
        #expect(seconds < 5, "took \(seconds) s of CPU")
        #expect(result?.counts["github-pat"] ?? 0 > 0)
        #expect(!(result?.text.contains("gh" + "p_" + body) ?? true))
    }

    /// CPU time of this thread: wall time stretches many times over while the other suites
    /// run in parallel, CPU time doesn't. The work is synchronous, on this thread.
    private func cpuSeconds(_ work: () -> Void) -> Double {
        let start = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
        work()
        return Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - start) / 1e9
    }

    /// Inputs that make careless patterns backtrack: unterminated key blocks, `://` and `@`
    /// without the rest, long dotted and keyword-only runs.
    @Test func adversarialInputStaysFast() {
        let pieces = [
            String(repeating: "-----BEGIN RSA PRIVATE KEY-----\n", count: 300),
            String(repeating: "://user:", count: 20_000),
            String(repeating: "a.", count: 100_000) + "@",
            String(repeating: "key=", count: 50_000),
            String(repeating: "x", count: 200_000) + "@" + String(repeating: "y.", count: 50_000),
            String(repeating: "Authorization: ", count: 20_000),
            String(repeating: "A", count: 300_000),
        ]
        let text = pieces.joined(separator: "\n")
        let seconds = cpuSeconds { _ = Scrubber.scrub(text) }
        #expect(seconds < 5, "took \(seconds) s of CPU")
    }
}
