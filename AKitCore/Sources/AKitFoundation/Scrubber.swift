import Foundation

/// The outgoing pass before AKit sends session text to a model. `SecretFilter.masked` keeps
/// secrets off the screen; this is stronger because the text leaves the machine: gitleaks'
/// default rules ported to Swift, a generic keyword rule and an entropy detector (both
/// gated by entropy so code stays readable), `.env` dumps, and the user's own patterns
/// (internal hosts, e-mails, anything else). Found keys are never verified online: that
/// would send them to their provider. Keys, schemes and surrounding text stay readable.
public enum Scrubber {
    /// Bumped whenever rules change; part of done keys and the send log.
    public static let version = 2
    public static let hostMask = "[host hidden]"
    public static let emailMask = "[email hidden]"

    /// User-configured extra patterns (Settings → Lab).
    public struct OwnPatterns: Codable, Sendable, Hashable {
        /// Regexes for internal host names, e.g. `[a-z0-9.-]+\.corp\.example\.com`; case-insensitive.
        public var hosts: [String]
        public var maskEmails: Bool
        /// Any other regexes to mask as secrets.
        public var extra: [String]

        public init(hosts: [String] = [], maskEmails: Bool = true, extra: [String] = []) {
            self.hosts = hosts
            self.maskEmails = maskEmails
            self.extra = extra
        }
    }

    public struct Result: Sendable, Hashable {
        public let text: String
        /// Rule id → number of masked matches; rules without matches are left out.
        public let counts: [String: Int]
    }

    public static func scrub(_ text: String, own: OwnPatterns = OwnPatterns()) -> Result {
        var counts: [String: Int] = [:]
        var current = text as NSString
        let present = presentHints(in: text)
        for rule in rules {
            current = apply(rule, to: current, present: present, counts: &counts)
        }
        current = maskDotenv(current, counts: &counts)
        current = apply(genericRule, to: current, present: present, counts: &counts)
        current = apply(flagRule, to: current, present: present, counts: &counts)
        current = apply(entropyRule, to: current, present: present, counts: &counts)

        let before = occurrences(of: SecretFilter.mask, in: current)
        current = SecretFilter.masked(current as String) as NSString
        let added = occurrences(of: SecretFilter.mask, in: current) - before
        if added > 0 { counts["secret-filter", default: 0] += added }

        for rule in ownRules(own) {
            current = apply(rule, to: current, present: present, counts: &counts)
        }
        return Result(text: current as String, counts: counts)
    }

    /// Invalid user regexes, with the error, so Settings can show them.
    public static func invalidPatterns(_ own: OwnPatterns) -> [String] {
        (own.hosts + own.extra).compactMap { pattern in
            if pattern.isEmpty { return "(empty pattern): an empty pattern matches nothing useful" }
            do {
                _ = try NSRegularExpression(pattern: pattern)
                return nil
            } catch {
                return "\(pattern): \(error.localizedDescription)"
            }
        }
    }

    // MARK: - Rules

    private struct Rule: Sendable {
        let id: String
        let regex: NSRegularExpression
        /// The capture group that is masked; 0 masks the whole match. Text around it stays.
        let group: Int
        /// Literals one of which must occur for the rule to run: a cheap check that skips
        /// most regexes on most texts.
        let hints: [String]
        let mask: String
        let accept: @Sendable (NSString, NSTextCheckingResult) -> Bool

        init(_ id: String, _ pattern: String, group: Int = 0, hints: [String] = [], mask: String = SecretFilter.mask,
             options: NSRegularExpression.Options = [],
             accept: @escaping @Sendable (NSString, NSTextCheckingResult) -> Bool = { _, _ in true }) {
            self.init(id, regex: try! NSRegularExpression(pattern: pattern, options: options), group: group,
                      hints: hints, mask: mask, accept: accept)
        }

        init(_ id: String, regex: NSRegularExpression, group: Int = 0, hints: [String] = [], mask: String,
             accept: @escaping @Sendable (NSString, NSTextCheckingResult) -> Bool = { _, _ in true }) {
            self.id = id
            self.regex = regex
            self.group = group
            self.hints = hints
            self.mask = mask
            self.accept = accept
        }
    }

    /// Token shapes with a recognizable prefix or context, after gitleaks' default config.
    /// The constants are ours; a typo is a programming error, so they compile with `try!`.
    /// Every quantifier is on a single class or bounded, so nothing backtracks badly.
    private static let rules: [Rule] = [
        Rule("private-key",
             #"-----BEGIN[ A-Z0-9_-]{0,100}PRIVATE KEY(?: BLOCK)?-----[\s\S]{0,65536}?-----END[ A-Z0-9_-]{0,100}PRIVATE KEY(?: BLOCK)?-----"#,
             hints: ["PRIVATE KEY"]),
        // A key cut off before its END line (`head id_rsa`): the header and the base64 lines
        // after it. This also spares SecretFilter's unbounded block pattern a scan to the end.
        Rule("private-key", #"-----BEGIN[ A-Z0-9_-]{0,100}PRIVATE KEY(?: BLOCK)?-----(?:\r?\n[A-Za-z0-9+/=]{16,100})*"#,
             hints: ["PRIVATE KEY"]),
        Rule("aws-access-token", #"\b(?:A3T[A-Z0-9]|AKIA|ASIA|ABIA|ACCA)[A-Z0-9]{16}(?![A-Za-z0-9])"#,
             hints: ["AKIA", "ASIA", "ABIA", "ACCA", "A3T"]),
        Rule("aws-secret-access-key",
             #"\b(aws_?secret_?(?:access_?)?key["']?[ \t]{0,3}(?::=|=>|=|:)[ \t]{0,3}["']?)([A-Za-z0-9/+=]{40})(?![A-Za-z0-9/+=])"#,
             group: 2, hints: ["secret"], options: .caseInsensitive),
        Rule("github-pat", #"\bghp_[A-Za-z0-9]{30,}"#, hints: ["ghp_"]),
        Rule("github-oauth", #"\bgho_[A-Za-z0-9]{30,}"#, hints: ["gho_"]),
        Rule("github-app-token", #"\bgh[us]_[A-Za-z0-9]{30,}"#, hints: ["ghu_", "ghs_"]),
        Rule("github-refresh-token", #"\bghr_[A-Za-z0-9]{30,}"#, hints: ["ghr_"]),
        Rule("github-fine-grained-pat", #"\bgithub_pat_[A-Za-z0-9_]{40,}"#, hints: ["github_pat_"]),
        Rule("gitlab-pat", #"\bglpat-[A-Za-z0-9_-]{20,}"#, hints: ["glpat-"]),
        Rule("gitlab-deploy-token", #"\bgldt-[A-Za-z0-9_-]{20,}"#, hints: ["gldt-"]),
        Rule("gitlab-runner-authentication-token", #"\bglrt-[A-Za-z0-9_-]{20,}"#, hints: ["glrt-"]),
        Rule("gitlab-rrt", #"\bGR1348941[A-Za-z0-9_-]{20,}"#, hints: ["GR1348941"]),
        Rule("slack-token", #"\bxox[abprse]-[A-Za-z0-9-]{10,}"#, hints: ["xox"]),
        Rule("slack-app-token", #"\bxapp-[A-Za-z0-9-]{20,}"#, hints: ["xapp-"]),
        Rule("slack-webhook-url", #"(hooks\.slack\.com/(?:services|workflows|triggers)/)([A-Za-z0-9+/_-]{20,})"#,
             group: 2, hints: ["hooks.slack.com"]),
        Rule("stripe-access-token", #"\b(?:(?:sk|rk)_(?:test|live|prod)|pk_live)_[A-Za-z0-9]{10,}"#,
             hints: ["sk_", "rk_", "pk_live"]),
        Rule("gcp-api-key", #"\bAIza[0-9A-Za-z_-]{35}(?![0-9A-Za-z_-])"#, hints: ["AIza"]),
        Rule("gcp-oauth-client-secret", #"\bGOCSPX-[A-Za-z0-9_-]{24,}"#, hints: ["GOCSPX-"]),
        // Before OpenAI: sk-ant- would match its looser shape too.
        Rule("anthropic-api-key", #"\bsk-ant-[A-Za-z0-9_-]{20,}"#, hints: ["sk-ant-"]),
        // At least one digit, so kebab-case names that start with "sk-" stay.
        Rule("openai-api-key", #"\bsk-(?:proj-|svcacct-|admin-)?(?=[A-Za-z_-]{0,200}[0-9])[A-Za-z0-9_-]{20,}"#,
             hints: ["sk-"]),
        Rule("huggingface-access-token", #"\bhf_[A-Za-z0-9]{30,}"#, hints: ["hf_"]),
        Rule("npm-access-token", #"\bnpm_[A-Za-z0-9]{36,}"#, hints: ["npm_"]),
        Rule("pypi-upload-token", #"\bpypi-AgEIcHlwaS5vcmc[A-Za-z0-9_-]{50,}"#, hints: ["pypi-AgEIcHlwaS5vcmc"]),
        Rule("sendgrid-api-token", #"\bSG\.[A-Za-z0-9_-]{16,}\.[A-Za-z0-9_-]{16,}"#, hints: ["SG."]),
        // "SK" + 32 hex is too common to mask without a nearby Twilio-ish word.
        Rule("twilio-api-key", #"(?i:twilio|api[_-]?key|key[_-]?sid|sid|secret)[^\n]{0,40}?\b(SK[0-9a-fA-F]{32})(?![0-9A-Za-z])"#,
             group: 1, hints: ["SK"]),
        Rule("mailgun-private-api-token", #"\bkey-[a-f0-9]{32}(?![0-9A-Za-z])"#, hints: ["key-"]),
        Rule("shopify-token", #"\bshp(?:at|ss|ca|pa)_[a-fA-F0-9]{32}(?![0-9A-Za-z])"#, hints: ["shp"]),
        Rule("digitalocean-token", #"\bdo[opr]_v1_[a-f0-9]{64}(?![0-9A-Za-z])"#, hints: ["_v1_"]),
        Rule("doppler-api-token", #"\bdp\.pt\.[A-Za-z0-9]{40,}"#, hints: ["dp.pt."]),
        Rule("linear-api-key", #"\blin_api_[A-Za-z0-9]{40,}"#, hints: ["lin_api_"]),
        Rule("atlassian-api-token", #"\bATATT3[A-Za-z0-9_=+/-]{50,}"#, hints: ["ATATT3"]),
        Rule("databricks-api-token", #"\bdapi[a-f0-9]{32}(?:-[0-9])?(?![0-9A-Za-z])"#, hints: ["dapi"]),
        Rule("grafana-cloud-api-token", #"\bglc_[A-Za-z0-9+/]{32,}={0,2}"#, hints: ["glc_"]),
        Rule("grafana-service-account-token", #"\bglsa_[A-Za-z0-9]{32}_[A-Fa-f0-9]{8}(?![0-9A-Za-z])"#, hints: ["glsa_"]),
        Rule("jwt", #"\beyJ[A-Za-z0-9_-]{10,}\.ey[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]*"#, hints: ["eyJ"]),
        Rule("azure-storage-account-key", #"(AccountKey=)([A-Za-z0-9+/]{40,}={0,2})"#, group: 2, hints: ["AccountKey="]),
        // scheme://user:password@host keeps scheme, user and host.
        // Starts at the literal "://" so the regex engine can skip to it.
        Rule("url-credentials", #"://[^\s:/?#@"'<>\[\]]{0,256}:([^\s/?#@"'<>]{1,256})(?=@[^\s@/])"#,
             group: 1, hints: ["://"]),
        Rule("authorization-header",
             #"\b((?:proxy-)?authorization["']?[ \t]{0,3}[:=][ \t]{0,3}["']?(?:bearer|basic|token|digest|negotiate)[ \t]+)([A-Za-z0-9._~+/=-]{8,})"#,
             group: 2, hints: ["authorization"], options: .caseInsensitive),
        // A bare "Bearer <token>" (curl lines, logs); a digit tells a token from prose.
        Rule("authorization-header", #"\b(bearer[ \t]+)([A-Za-z0-9._~+/-]{16,}=*)"#,
             group: 2, hints: ["bearer"], options: .caseInsensitive) { text, match in
            hasDigit(text.substring(with: match.range(at: 2)))
        },
        Rule("api-key-header",
             #"\b((?:x-api-key|x-auth-token|x-access-token|x-goog-api-key|api-key)["']?[ \t]{0,3}[:=][ \t]{0,3}["']?)([A-Za-z0-9._~+/=-]{8,})"#,
             group: 2, hints: ["key", "token"], options: .caseInsensitive),
    ]

    /// gitleaks' generic-api-key: a keyword anywhere in a name (`DB_PASSWORD`, `apiKey`,
    /// `client_secret`), an assignment, and a value. Only the value is masked, and only
    /// when it looks random enough, so `password = os.environ["X"]` stays readable.
    private static let genericRule = Rule(
        "generic-api-key",
        #"(key|token|secret|passw(?:or)?d|pwd|credential|auth)[\w.-]{0,20}?["']?[ \t]{0,3}(?::=|=>|=|:)[ \t]{0,3}(["'`]?)([^\s"'`,;&\[\]{}()<>\\]{8,})"#,
        group: 3, options: .caseInsensitive
    ) { text, match in
        let keyword = text.substring(with: match.range(at: 1)).lowercased()
        return looksLikeSecretValue(text.substring(with: match.range(at: 3)), quoted: match.range(at: 2).length > 0,
                                    passwordLike: keyword.hasPrefix("pas") || keyword == "pwd" || keyword == "secret",
                                    hashName: isHashName(nameBefore(match.range.location, in: text) + keyword))
    }

    /// `--token VALUE`, `--api-key=VALUE`: secrets passed on a command line.
    private static let flagRule = Rule(
        "cli-flag-secret", #"--(?:token|api-key|apikey|access-token|auth-token|password|secret|client-secret)(?:[ \t]+|=)["']?([^\s"'`]{8,})"#,
        group: 1, hints: ["--"], options: .caseInsensitive
    ) { text, match in
        looksLikeSecretValue(text.substring(with: match.range(at: 1)), quoted: true, passwordLike: true, hashName: false)
    }

    /// The identifier just before a keyword match (`commit_` of `commit_sha_key`), up to 32 chars.
    static func nameBefore(_ location: Int, in text: NSString) -> String {
        var start = location
        while start > 0, location - start < 32 {
            let char = text.character(at: start - 1)
            guard let scalar = UnicodeScalar(char), CharacterSet.alphanumerics.contains(scalar) || scalar == "_" || scalar == "-" || scalar == "." else { break }
            start -= 1
        }
        return text.substring(with: NSRange(location: start, length: location - start)).lowercased()
    }

    /// A name for a hash, not a secret: its hex value is fine to send.
    static func isHashName(_ name: String) -> Bool {
        ["sha", "hash", "digest", "commit", "checksum", "etag", "revision", "cache"].contains(where: name.contains)
    }

    /// Stand-alone random tokens without a known prefix.
    private static let entropyRule = Rule(
        "entropy", #"(?<![A-Za-z0-9+/=_-])[A-Za-z0-9+/=_-]{24,}(?![A-Za-z0-9+/=_-])"#
    ) { text, match in
        looksLikeRandomToken(text.substring(with: match.range))
    }

    private static let dotenvLine = try! NSRegularExpression(
        pattern: #"^[ \t]*(?:export[ \t]+)?([A-Z][A-Z0-9_]{2,})[ \t]*=[ \t]*([^\s][^\r\n]*)"#, options: .anchorsMatchLines)
    private static let sensitiveName = try! NSRegularExpression(
        pattern: "KEY|TOKEN|SECRET|PASS|PWD|AUTH|CRED|DSN|PRIVATE|SESSION|COOKIE")
    private static let plainValue = try! NSRegularExpression(
        pattern: #"^["']?(?:true|false|yes|no|[0-9.]+)["']?$"#, options: .caseInsensitive)

    private static let emailRule = Rule(
        "email",
        #"(?<![A-Za-z0-9._%+-])([A-Za-z0-9._%+-]{1,64})@([A-Za-z0-9-]{1,63}(?:\.[A-Za-z0-9-]{1,63}){0,8}\.[A-Za-z]{2,24})(?![A-Za-z0-9-])"#,
        hints: ["@"], mask: emailMask
    ) { text, match in
        // git@github.com:org/repo is an SSH remote; icon@2x.png is an image.
        let local = text.substring(with: match.range(at: 1))
        let domain = text.substring(with: match.range(at: 2))
        return local != "git" && domain.range(of: #"^[0-9]+x\."#, options: .regularExpression) == nil
    }

    /// The user's patterns; an invalid one is skipped (Settings lists it via `invalidPatterns`).
    private static func ownRules(_ own: OwnPatterns) -> [Rule] {
        func compiled(_ pattern: String, _ options: NSRegularExpression.Options) -> NSRegularExpression? {
            pattern.isEmpty ? nil : try? NSRegularExpression(pattern: pattern, options: options)
        }
        var result: [Rule] = own.maskEmails ? [emailRule] : []
        result += own.hosts.compactMap { compiled($0, .caseInsensitive) }.map { Rule("host", regex: $0, mask: hostMask) }
        result += own.extra.compactMap { compiled($0, []) }.map { Rule("extra", regex: $0, mask: SecretFilter.mask) }
        return result
    }

    // MARK: - Applying

    private static func apply(_ rule: Rule, to text: NSString, present: Set<String>,
                              counts: inout [String: Int]) -> NSString {
        if !rule.hints.isEmpty {
            let found = rule.regex.options.contains(.caseInsensitive)
                ? rule.hints.contains { text.range(of: $0, options: .caseInsensitive).location != NSNotFound }
                : rule.hints.contains(where: present.contains)
            guard found else { return text }
        }
        let matches = rule.regex.matches(in: text as String, range: NSRange(location: 0, length: text.length))
        return replace(matches, in: text, group: rule.group, mask: rule.mask, id: rule.id, counts: &counts) { _, match in
            rule.accept(text, match)
        }
    }

    /// The case-sensitive hints that occur in the input, each found once with `memmem`.
    /// Checking the input is enough: masks never form a hint with the text around them.
    private static func presentHints(in text: String) -> Set<String> {
        var text = text
        return text.withUTF8 { haystack in
            Set(caseSensitiveHints.filter { hint in
                var hint = hint
                return hint.withUTF8 { needle in
                    memmem(haystack.baseAddress, haystack.count, needle.baseAddress, needle.count) != nil
                }
            })
        }
    }

    private static let caseSensitiveHints: Set<String> = Set(
        (rules + [genericRule, flagRule, entropyRule, emailRule])
            .filter { !$0.regex.options.contains(.caseInsensitive) }
            .flatMap(\.hints)
    )

    /// Builds the result front to back (in-place replacement would move the tail once per
    /// match). Empty matches and matches overlapping an earlier mask are skipped.
    private static func replace(_ matches: [NSTextCheckingResult], in text: NSString, group: Int, mask: String, id: String,
                                counts: inout [String: Int], accept: (Int, NSTextCheckingResult) -> Bool) -> NSString {
        var out: NSMutableString?
        var cursor = 0
        var count = 0
        for (index, match) in matches.enumerated() {
            let range = match.range(at: group)
            guard range.location != NSNotFound, range.length > 0, range.location >= cursor, accept(index, match) else { continue }
            let result = out ?? NSMutableString(capacity: text.length)
            result.append(text.substring(with: NSRange(location: cursor, length: range.location - cursor)))
            result.append(mask)
            out = result
            cursor = NSMaxRange(range)
            count += 1
        }
        guard let out else { return text }
        out.append(text.substring(from: cursor))
        counts[id, default: 0] += count
        return out
    }

    /// `.env` lines: the value is masked when the name sounds secret, or when the line is
    /// part of a dump (two or more such lines in a row) and the value isn't a flag or number.
    private static func maskDotenv(_ text: NSString, counts: inout [String: Int]) -> NSString {
        guard text.range(of: "=").location != NSNotFound else { return text }
        let matches = dotenvLine.matches(in: text as String, range: NSRange(location: 0, length: text.length))
        guard !matches.isEmpty else { return text }
        var inDump = [Bool](repeating: false, count: matches.count)
        for index in matches.indices.dropFirst() {
            let gapStart = NSMaxRange(matches[index - 1].range)
            let gap = text.substring(with: NSRange(location: gapStart, length: matches[index].range.location - gapStart))
            if gap == "\n" || gap == "\r\n" {
                inDump[index - 1] = true
                inDump[index] = true
            }
        }
        return replace(matches, in: text, group: 2, mask: SecretFilter.mask, id: "dotenv", counts: &counts) { index, match in
            let value = text.substring(with: match.range(at: 2))
            if value.contains(SecretFilter.mask) || value.contains(hostMask) || value.contains(emailMask) { return false }
            if plainValue.firstMatch(in: value, range: NSRange(location: 0, length: (value as NSString).length)) != nil {
                return false
            }
            let name = text.substring(with: match.range(at: 1))
            if sensitiveName.firstMatch(in: name, range: NSRange(location: 0, length: (name as NSString).length)) != nil {
                return true
            }
            return inDump[index] && value.count >= 6
        }
    }

    private static func occurrences(of needle: String, in text: NSString) -> Int {
        var count = 0
        var searchRange = NSRange(location: 0, length: text.length)
        while true {
            let found = text.range(of: needle, options: .literal, range: searchRange)
            guard found.location != NSNotFound else { return count }
            count += 1
            let next = NSMaxRange(found) // needle is non-empty, so this always moves forward
            searchRange = NSRange(location: next, length: text.length - next)
        }
    }

    // MARK: - Heuristics

    /// A generic-rule value worth masking: random enough, and not a hash, number, path,
    /// URL, variable or (when unquoted) code like `os.environ` or `settings.apiKey`. Lower-case
    /// words like `"user-profile-cache"` name keys and tokens, but may be a password.
    /// The hex/UUID allowlist is for stand-alone runs (the entropy detector): after a secret's
    /// name, a long hex value or a UUID is a key (Datadog, Heroku, Rails), unless the name says
    /// it is a hash.
    static func looksLikeSecretValue(_ value: String, quoted: Bool, passwordLike: Bool, hashName: Bool) -> Bool {
        if isHexLike(value) { return value.count >= 20 && !hashName }
        if value.allSatisfy({ $0.isNumber || $0 == "." }) { return false }
        for prefix in ["$", "/", "~/", "./", "../"] where value.hasPrefix(prefix) { return false }
        if value.contains("://") { return false }
        if !passwordLike, value.utf8.allSatisfy({ kind($0) == 0 || "-_.:/".utf8.contains($0) }) { return false }
        if !quoted {
            guard hasDigit(value), value.contains(where: \.isLetter) else { return false }
            if isDottedIdentifier(value) { return false }
        }
        return shannonEntropy(value) >= 3.0
    }

    /// A stand-alone run (≥ 24 chars): a digit and a letter, entropy ≥ 4.2, not hex or a
    /// UUID, and not made of words like an identifier or a path (`sha256HexDigestV2`,
    /// `Projects/app2/Sources`): random tokens switch letter case and digits every char or two.
    static func looksLikeRandomToken(_ run: String) -> Bool {
        let bytes = Array(run.utf8)
        guard bytes.count >= 24, bytes.contains(where: isDigit), bytes.contains(where: isLetter) else { return false }
        if isHexLike(run) { return false }
        guard shannonEntropy(run) >= 4.2 else { return false }
        let chunks = bytes.split(whereSeparator: { "/_-+=".utf8.contains($0) }).filter { !$0.allSatisfy(isHex) }
        guard !chunks.isEmpty else { return false }
        let letters = chunks.reduce(0) { $0 + $1.count }
        let words = chunks.reduce(0) { $0 + wordCount($1) }
        return Double(letters) / Double(words) < 3.0
    }

    /// Hex only (git SHAs, sha256 sums), UUIDs and other dash-joined hex, optionally after
    /// an `algo:` prefix like `sha256:`.
    static func isHexLike(_ value: String) -> Bool {
        var bytes = Substring(value).utf8[...]
        if let colon = bytes.firstIndex(of: UInt8(ascii: ":")), bytes.distance(from: bytes.startIndex, to: colon) <= 10,
           bytes[..<colon].allSatisfy({ isLetter($0) || isDigit($0) }) {
            bytes = bytes[bytes.index(after: colon)...]
        }
        return !bytes.isEmpty && bytes.contains(where: isHex) && bytes.allSatisfy { isHex($0) || $0 == UInt8(ascii: "-") }
    }

    /// `settings.apiKey`, `process.env.API_KEY_2`: dotted names are code, not values.
    private static func isDottedIdentifier(_ value: String) -> Bool {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 2 else { return false }
        return parts.allSatisfy { part in
            guard let first = part.utf8.first, isLetter(first) || first == UInt8(ascii: "_") else { return false }
            return part.utf8.allSatisfy { isLetter($0) || isDigit($0) || $0 == UInt8(ascii: "_") }
        }
    }

    /// Words split at letter/digit changes and camelCase humps (`AKitFoundation` → A, Kit, Foundation).
    private static func wordCount(_ chunk: ArraySlice<UInt8>) -> Int {
        let chars = Array(chunk)
        var words = 0
        for index in chars.indices {
            guard index > 0 else { words += 1; continue }
            let previous = kind(chars[index - 1]), current = kind(chars[index])
            if current != previous && !(previous == 1 && current == 0) {
                words += 1
            } else if previous == 1 && current == 1 && index + 1 < chars.count && kind(chars[index + 1]) == 0 {
                words += 1
            }
        }
        return max(words, 1)
    }

    /// 0 lower-case, 1 upper-case, 2 digit, 3 other.
    private static func kind(_ byte: UInt8) -> Int {
        switch byte {
        case UInt8(ascii: "a")...UInt8(ascii: "z"): 0
        case UInt8(ascii: "A")...UInt8(ascii: "Z"): 1
        case UInt8(ascii: "0")...UInt8(ascii: "9"): 2
        default: 3
        }
    }

    static func shannonEntropy(_ value: String) -> Double {
        var frequencies: [UInt8: Int] = [:]
        var total = 0
        for byte in value.utf8 {
            frequencies[byte, default: 0] += 1
            total += 1
        }
        guard total > 0 else { return 0 }
        return frequencies.values.reduce(0) { sum, count in
            let p = Double(count) / Double(total)
            return sum - p * log2(p)
        }
    }

    private static func hasDigit(_ value: String) -> Bool { value.utf8.contains(where: isDigit) }
    private static func isDigit(_ byte: UInt8) -> Bool { kind(byte) == 2 }
    private static func isLetter(_ byte: UInt8) -> Bool { kind(byte) < 2 }
    private static func isHex(_ byte: UInt8) -> Bool {
        isDigit(byte) || (UInt8(ascii: "a")...UInt8(ascii: "f")).contains(byte) || (UInt8(ascii: "A")...UInt8(ascii: "F")).contains(byte)
    }
}
