import Foundation
import Testing
import AKitMCP
@testable import AKitMCPCatalog

/// Catalog parsing, the form built from an entry, search order and the saved copies.
/// Offline: answers are fixtures, the home is a temporary folder.
struct MCPCatalogTests {
    let home: URL

    init() throws {
        home = FileManager.default.temporaryDirectory.appending(path: "akit-mcpcatalog-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    /// The registry's own Context7 entry (2026-10-04), shortened.
    static let context7 = """
    {"server":{"name":"io.github.upstash/context7","description":"Up-to-date code docs for any prompt","title":"Context7",
      "repository":{"url":"https://github.com/upstash/context7","source":"github"},"version":"4.1.1","websiteUrl":"https://context7.com",
      "packages":[
        {"registryType":"npm","identifier":"@upstash/context7-mcp","version":"4.1.1","transport":{"type":"stdio"},
         "environmentVariables":[{"description":"API key for authentication","isSecret":true,"name":"CONTEXT7_API_KEY"}]},
        {"registryType":"mcpb","identifier":"https://github.com/upstash/context7/releases/download/x/context7.mcpb","version":"4.1.1",
         "transport":{"type":"stdio"}}],
      "remotes":[{"type":"streamable-http","url":"https://mcp.context7.com/mcp",
         "headers":[{"description":"API key for authentication.","isSecret":true,"name":"Authorization"}]}]},
     "_meta":{"io.modelcontextprotocol.registry/official":{"status":"active","isLatest":true}}}
    """

    static let linear = """
    {"server":{"name":"app.linear/linear","description":"Long text.","version":"1.0.0","repository":{},
      "remotes":[{"type":"streamable-http","url":"https://mcp.linear.app/mcp"}]},
     "_meta":{"com.anthropic.api/mcp-registry":{"displayName":"Linear","oneLiner":"Manage issues in Linear","isAuthless":false,
        "documentation":"https://linear.app/docs/mcp","slug":"linear","worksWith":["claude","claude-code"]},
        "io.modelcontextprotocol.registry/official":{"status":"active"}}}
    """

    func page(_ entries: [String], next: String? = nil) -> Data {
        let metadata = next.map { #"{"count":\#(entries.count),"nextCursor":"\#($0)"}"# } ?? #"{"count":\#(entries.count)}"#
        return Data(#"{"servers":[\#(entries.joined(separator: ","))],"metadata":\#(metadata)}"#.utf8)
    }

    func server(_ entry: String, source: CatalogSource = .registry) throws -> CatalogServer {
        try #require(try MCPCatalogClient.decode(page([entry]), source: source).first)
    }

    // MARK: - Reading entries

    @Test func readsRemoteAndPackageOptions() throws {
        let server = try server(Self.context7)
        #expect(server.title == "Context7")
        #expect(server.configName == "context7")
        #expect(server.namespace == "io.github.upstash")
        #expect(server.repositoryURL?.absoluteString == "https://github.com/upstash/context7")
        #expect(server.options.map(\.label) == [
            "Remote · mcp.context7.com", "Local · npx @upstash/context7-mcp 4.1.1",
            "Local · mcpb https://github.com/upstash/context7/releases/download/x/context7.mcpb 4.1.1"])
        // The option AKit can't start is listed last, with the reason.
        #expect(server.options.map { $0.unsupported == nil } == [true, true, false])
        let header = try #require(server.options[0].parameters.first)
        #expect(header.place == .header && header.isSecret && !header.isRequired)
    }

    @Test func readsDirectoryExtras() throws {
        let server = try server(Self.linear, source: .directory)
        #expect(server.title == "Linear")
        #expect(server.summary == "Manage issues in Linear")
        #expect(server.configName == "linear")
        #expect(server.needsSignIn == true)
        #expect(server.listsClaudeCode == true)
        #expect(server.documentationURL?.host() == "linear.app")
        #expect(server.repositoryURL == nil)
    }

    @Test func skipsDeletedBrokenAndUnconnectableEntries() throws {
        let deleted = #"{"server":{"name":"a/deleted","remotes":[{"type":"sse","url":"https://a.example/sse"}]},"_meta":{"io.modelcontextprotocol.registry/official":{"status":"deleted"}}}"#
        let noOptions = #"{"server":{"name":"a/empty","description":"x"}}"#
        let broken = #"{"server":{"title":"no name"}}"#
        let deprecated = #"{"server":{"name":"a/old","remotes":[{"type":"sse","url":"https://a.example/sse"}]},"_meta":{"io.modelcontextprotocol.registry/official":{"status":"deprecated"}}}"#
        let servers = try MCPCatalogClient.decode(page([deleted, noOptions, broken, deprecated, deprecated]), source: .registry)
        #expect(servers.map(\.name) == ["a/old"])
        #expect(servers[0].isDeprecated)
        #expect(servers[0].options[0].transport == .sse)
    }

    @Test func reportsAnErrorAnswer() {
        #expect(throws: MCPCatalogClient.Failure.self) {
            try MCPCatalogClient.decode(Data(#"{"title":"Bad Request","status":400,"detail":"limit is too big"}"#.utf8), source: .registry)
        }
        #expect(throws: MCPCatalogClient.Failure.self) {
            try MCPCatalogClient.decode(Data("<html>".utf8), source: .registry)
        }
    }

    @Test(arguments: [
        ("io.github.upstash/context7", "context7"), ("com.notion/mcp", "notion"), ("com.cloudflare.mcp/mcp", "cloudflare"),
        ("io.github.miroapp/mcp-server", "miroapp"), ("com.atlassian/atlassian-mcp-server", "atlassian"),
        ("io.coupler/remote-mcp-server", "coupler"), ("com.stripe/mcp", "stripe"), ("ai.exa/exa", "exa"),
        ("io.github.someone/mcp-server-git", "git"), ("x/My Server!", "my-server"),
    ])
    func derivesConfigNames(name: String, expected: String) {
        #expect(CatalogServer.configName(for: name) == expected)
    }

    // MARK: - The form

    @Test func fillsRemoteFormWithoutOptionalHeader() throws {
        let option = try server(Self.context7).options[0]
        let draft = CatalogDraft.draft(of: option, name: "context7")
        #expect(draft.transport == .http)
        #expect(draft.url == "https://mcp.context7.com/mcp")
        #expect(draft.headers.isEmpty)
        #expect(draft.problems.isEmpty && CatalogDraft.problems(in: draft).isEmpty)

        let withKey = CatalogDraft.draft(of: option, name: "context7", including: ["header:Authorization"])
        #expect(withKey.headers.map(\.key) == ["Authorization"])
        // The secret is typed into the form, never taken from the catalog.
        #expect(withKey.headers[0].isSecret && withKey.headers[0].value.isEmpty)
        #expect(withKey.problems == ["Secret Authorization is empty."])
    }

    @Test func fillsNpmPackageFormPinnedToTheListedVersion() throws {
        let option = try server(Self.context7).options[1]
        let draft = CatalogDraft.draft(of: option, name: "context7", including: ["environment:CONTEXT7_API_KEY"])
        #expect(draft.transport == .stdio)
        #expect(draft.command == "npx")
        #expect(draft.arguments == ["-y", "@upstash/context7-mcp@4.1.1"])
        #expect(draft.environment.map(\.key) == ["CONTEXT7_API_KEY"])
        #expect(CatalogDraft.notes(for: option, including: ["environment:CONTEXT7_API_KEY"]) == ["CONTEXT7_API_KEY. API key for authentication"])
    }

    @Test func buildsPypiAndDockerCommands() throws {
        let pypi = #"{"server":{"name":"a/armor","packages":[{"registryType":"pypi","identifier":"armor-mcp","version":"0.6.1","transport":{"type":"stdio"},"environmentVariables":[{"name":"ARMOR_API_KEY","isRequired":true,"isSecret":true},{"name":"ARMOR_BASE_URL","description":"Self-hosted address","default":"https://api.example"}],"packageArguments":[{"type":"positional","value":"serve"},{"type":"named","name":"--profile","value":"domains"},{"type":"named","name":"--verbose"},{"type":"named","name":"--dir","isRequired":true,"valueHint":"folder"}]}]}}"#
        let option = try server(pypi).options[0]
        let draft = CatalogDraft.draft(of: option, name: "armor", including: ["environment:ARMOR_BASE_URL"])
        #expect(draft.command == "uvx")
        #expect(draft.arguments == ["armor-mcp==0.6.1", "serve", "--profile", "domains", "--dir", "{folder}"])
        #expect(option.cautions.isEmpty)
        #expect(draft.environment.map(\.key) == ["ARMOR_API_KEY", "ARMOR_BASE_URL"])
        // The host can be changed in the form: a plain value, prefilled with the default.
        #expect(draft.environment[1].value == "https://api.example" && !draft.environment[1].isSecret)
        #expect(CatalogDraft.problems(in: draft) == ["Replace {folder} in Arguments."])

        let oci = #"{"server":{"name":"a/spot","packages":[{"registryType":"oci","identifier":"docker.io/a/spotdb","version":"0.1.0","transport":{"type":"stdio"},"runtimeArguments":[{"type":"named","name":"-v","default":"~/.spot:/data"}],"environmentVariables":[{"name":"SPOT_TOKEN","isRequired":true}]}]}}"#
        let spot = try server(oci).options[0]
        // Arguments the entry adds for docker are pointed out, and so is the `-e` rule.
        #expect(spot.cautions == ["The entry adds its own arguments for docker: -v ~/.spot:/data. They change what runs: check them."])
        #expect(CatalogDraft.notes(for: spot).count == 3)
        let docker = CatalogDraft.draft(of: spot, name: "spot")
        #expect(docker.command == "docker")
        #expect(docker.arguments == ["run", "-i", "--rm", "-e", "SPOT_TOKEN", "-v", "~/.spot:/data", "docker.io/a/spotdb:0.1.0"])
        // No isSecret mark in the entry: the name decides.
        #expect(docker.environment[0].isSecret)
    }

    @Test func marksPackagesAKitCannotStart() throws {
        let http = #"{"server":{"name":"a/hapi","packages":[{"registryType":"oci","identifier":"docker.io/a/hapi:1","transport":{"type":"streamable-http","url":"https://{host}/mcp"}}]}}"#
        #expect(try server(http).options[0].unsupported?.contains("own HTTP server") == true)
        let nuget = #"{"server":{"name":"a/net","packages":[{"registryType":"nuget","identifier":"A.Mcp","transport":{"type":"stdio"}}]}}"#
        #expect(try server(nuget).options[0].unsupported?.contains("nuget") == true)
    }

    @Test func keepsUnfilledUrlAndHeaderPartsAsProblems() throws {
        let entry = #"{"server":{"name":"a/rfp","remotes":[{"type":"streamable-http","url":"https://{api_host}/mcp/{tenant}","variables":{"api_host":{"description":"Region host.","isRequired":true,"choices":["api.a.example","api.eu.a.example"]},"tenant":{"default":"main"}},"headers":[{"name":"Authorization","isRequired":true,"isSecret":true,"value":"Bearer {token}","variables":{"token":{"isSecret":true}}},{"name":"X-Region","isRequired":true,"value":"{region}"}]}]}}"#
        let option = try server(entry).options[0]
        let draft = CatalogDraft.draft(of: option, name: "rfp")
        #expect(draft.url == "https://{api_host}/mcp/main")
        #expect(draft.headers.map(\.key) == ["Authorization", "X-Region"])
        #expect(draft.headers[0].value.isEmpty && draft.headers[1].value == "{region}")
        #expect(CatalogDraft.problems(in: draft) == ["Replace {api_host} in the URL.", "Replace {region} in X-Region."])
        #expect(CatalogDraft.notes(for: option) == [
            "{api_host} in the URL: one of api.a.example, api.eu.a.example. Region host.",
            "{tenant} in the URL Prefilled by the catalog: main",
            "Header Authorization: type Bearer <token>",
            "Header X-Region: type <region>",
        ])
        var filled = draft
        filled.url = "https://api.eu.a.example/mcp/main"
        filled.headers[1].value = "${REGION}"
        #expect(CatalogDraft.problems(in: filled).isEmpty)
    }

    @Test func wholeUrlPlaceholderLeavesTheUrlEmpty() throws {
        let entry = #"{"server":{"name":"com.acme/own","remotes":[{"type":"streamable-http","url":"{url}"}]}}"#
        let option = try server(entry).options[0]
        #expect(option.label == "Remote · your own URL")
        #expect(option.parameters.map(\.id) == ["url:url"])
        let draft = CatalogDraft.draft(of: option, name: "own")
        #expect(draft.url.isEmpty)
        #expect(draft.problems == ["URL must look like https://host/path."])
        #expect(CatalogDraft.notes(for: option) == ["URL: type the address of your own server"])
    }

    @Test func referencesAreNotPlaceholders() {
        #expect(CatalogDraft.placeholders(in: "https://${HOST}/{env:TOKEN}/{tenant}/{tenant}") == ["tenant"])
        #expect(CatalogDraft.placeholders(in: #"{"json": true}"#).isEmpty)
        #expect(CatalogDraft.placeholders(in: "{_x} {1st} {/path/to/dir}") == ["_x", "1st", "/path/to/dir"])
    }

    @Test(arguments: [("/path/to/dir", "{/path/to/dir}"), ("host:port", "{host_port}"), ("--dir", "{dir}"),
                      ("<path>", "{<path>}"), ("{x}", "{_x_}"), ("  ", "{value}"), ("api key (optional)", "{api key (optional)}")])
    func hintsOfAnyShapeBecomePlaceholdersThatBlockPreview(hint: String, expected: String) {
        let word = CatalogDraft.placeholder(hint)
        #expect(word == expected)
        #expect(CatalogDraft.placeholders(in: word).count == 1)
    }

    // MARK: - Untrusted entries

    @Test func secretsInArgumentsOrUrlMakeAnOptionUnsupported() throws {
        // What the user types into Arguments or the URL is written into the file as it is.
        let flagged = #"{"server":{"name":"a/one","packages":[{"registryType":"npm","identifier":"one","version":"1.0.0","transport":{"type":"stdio"},"packageArguments":[{"type":"positional","isRequired":true,"isSecret":true,"valueHint":"license"}]}]}}"#
        #expect(try server(flagged).options[0].unsupported?.contains("secret as a command-line argument (license)") == true)
        let named = #"{"server":{"name":"a/two","packages":[{"registryType":"npm","identifier":"two","version":"1.0.0","transport":{"type":"stdio"},"packageArguments":[{"type":"named","name":"--api-key","isRequired":true,"valueHint":"key"}]}]}}"#
        #expect(try server(named).options[0].unsupported?.contains("--api-key") == true)
        let inURL = #"{"server":{"name":"a/three","remotes":[{"type":"streamable-http","url":"https://mcp.a.example/{workspace}/mcp","variables":{"workspace":{"isSecret":true}}}]}}"#
        #expect(try server(inURL).options[0].unsupported?.contains("secret inside its URL ({workspace})") == true)
        let namedInURL = #"{"server":{"name":"a/four","remotes":[{"type":"sse","url":"https://mcp.a.example/sse?api_key={api_key}"}]}}"#
        #expect(try server(namedInURL).options[0].unsupported != nil)
        // A fixed word the entry gives is not the user's secret.
        let fixed = #"{"server":{"name":"a/five","packages":[{"registryType":"npm","identifier":"five","version":"1.0.0","transport":{"type":"stdio"},"packageArguments":[{"type":"named","name":"--auth-mode","value":"oauth"}]}]}}"#
        #expect(try server(fixed).options[0].unsupported == nil)
    }

    @Test func headerWithASecretPartIsASecret() throws {
        let entry = #"{"server":{"name":"a/ws","remotes":[{"type":"streamable-http","url":"https://a.example/mcp","headers":[{"name":"X-Workspace","isRequired":true,"value":"{id}","variables":{"id":{"isSecret":true}}}]}]}}"#
        let draft = CatalogDraft.draft(of: try server(entry).options[0], name: "ws")
        #expect(draft.headers[0].isSecret && draft.headers[0].value.isEmpty)
    }

    @Test func namedLikeASecretButDeclaredPlainWithADefaultStaysPlain() throws {
        let entry = #"{"server":{"name":"a/t","packages":[{"registryType":"npm","identifier":"t","version":"1.0.0","transport":{"type":"stdio"},"environmentVariables":[{"name":"SESSION_TIMEOUT","isRequired":true,"isSecret":false,"default":30},{"name":"SESSION_ID","isRequired":true,"isSecret":false},{"name":"SESSION_TIMEOUT","default":"99"}]}]}}"#
        let option = try server(entry).options[0]
        // The repeated name is read once.
        #expect(option.parameters.map(\.name) == ["SESSION_TIMEOUT", "SESSION_ID"])
        let draft = CatalogDraft.draft(of: option, name: "t")
        #expect(!draft.environment[0].isSecret && draft.environment[0].value == "30")
        #expect(draft.environment[1].isSecret)
        #expect(CatalogDraft.notes(for: option) == ["SESSION_TIMEOUT Prefilled by the catalog: 30", "SESSION_ID"])
    }

    @Test func runnerOptionsFromAnEntryAreRefusedOrPointedOut() throws {
        // A package name that reads as an option is not a package.
        let dash = #"{"server":{"name":"a/dash","packages":[{"registryType":"npm","identifier":"--call=evil","transport":{"type":"stdio"}}],"remotes":[{"type":"sse","url":"https://a.example/sse"}]}}"#
        #expect(try server(dash).options.map(\.kind) == [.remote])
        let extra = #"{"server":{"name":"a/extra","packages":[{"registryType":"npm","identifier":"good","version":"1.0.0","transport":{"type":"stdio"},"runtimeArguments":[{"type":"positional","value":"-y"},{"type":"named","name":"--registry","value":"https://evil.example"}]}]}}"#
        let option = try server(extra).options[0]
        #expect(CatalogDraft.draft(of: option, name: "extra").arguments == ["-y", "--registry", "https://evil.example", "good@1.0.0"])
        #expect(option.cautions == ["The entry adds its own arguments for npx: --registry https://evil.example. They change what runs: check them."])
    }

    @Test func unpinnedPackagesCarryACaution() throws {
        func option(_ fields: String) throws -> CatalogOption {
            try server(#"{"server":{"name":"a/p","packages":[{\#(fields),"transport":{"type":"stdio"}}]}}"#).options[0]
        }
        let caution = ["No version is pinned: the newest release runs at every start."]
        #expect(try option(#""registryType":"npm","identifier":"p""#).cautions == caution)
        #expect(try option(#""registryType":"npm","identifier":"p","version":"latest""#).cautions == caution)
        let tag = try option(#""registryType":"npm","identifier":"p","version":"next""#)
        #expect(tag.cautions == caution && tag.trailingArguments == ["p@next"])
        #expect(try option(#""registryType":"pypi","identifier":"p""#).cautions == caution)
        #expect(try option(#""registryType":"oci","identifier":"ghcr.io/a/p""#).cautions == caution)
        #expect(try option(#""registryType":"oci","identifier":"host:5000/a/p@sha256:abc""#).trailingArguments == ["host:5000/a/p@sha256:abc"])
        #expect(try option(#""registryType":"oci","identifier":"host:5000/a/p","version":"1.2.0""#).trailingArguments == ["host:5000/a/p:1.2.0"])
    }

    @Test func urlDefaultsCannotBringAHostOfTheirOwn() throws {
        let entry = #"{"server":{"name":"a/u","remotes":[{"type":"streamable-http","url":"https://{tenant}.good.example/mcp","variables":{"tenant":{"default":"evil.example/x?","choices":["eu","evil.example/"]}}}]}}"#
        let option = try server(entry).options[0]
        #expect(option.label == "Remote · {tenant}.good.example/mcp")
        #expect(option.parameters[0].defaultValue == nil && option.parameters[0].choices == ["eu"])
        #expect(CatalogDraft.draft(of: option, name: "u").url == "https://{tenant}.good.example/mcp")
    }

    @Test func oddFieldsDoNotDropAnEntry() throws {
        // Fields of another type than expected read as missing.
        let odd = #"{"server":{"name":"app.linear/linear","title":7,"repository":"https://github.com/x","remotes":[{"type":"streamable-http","url":"https://mcp.linear.app/mcp","headers":[{"name":"X-Team","isRequired":"yes","choices":"a"}]}]},"_meta":{"com.anthropic.api/mcp-registry":{"displayName":"Linear","isAuthless":"false","worksWith":[{"id":"claude-code"}]},"io.modelcontextprotocol.registry/official":"active"}}"#
        let server = try server(odd, source: .directory)
        #expect(server.title == "Linear" && server.needsSignIn == nil && server.listsClaudeCode == nil)
        #expect(server.options[0].parameters.map(\.name) == ["X-Team"])
    }

    @Test func aDirectoryPageNobodyCanReadIsAnError() {
        #expect(throws: MCPCatalogClient.Failure.self) {
            try MCPCatalogClient.decode(page([#"{"entry":{"name":"a/b"}}"#, #"{"entry":{"name":"a/c"}}"#]), source: .directory)
        }
    }

    // MARK: - Search

    @Test func ranksNameMatchesBeforeDescriptionMatches() throws {
        func make(_ name: String, _ title: String, _ summary: String, deprecated: Bool = false) -> CatalogServer {
            CatalogServer(name: name, title: title, summary: summary, source: .directory, isDeprecated: deprecated,
                          configName: CatalogServer.configName(for: name), options: [])
        }
        let servers = [
            make("a/docs", "Docs Hub", "Works with Linear issues"),
            make("b/linear-tools", "Tools for Linear", "x"),
            make("app.linear/linear", "Linear", "Issues"),
            make("c/linear-old", "Linear Old", "x", deprecated: true),
            make("d/other", "Other", "nothing"),
        ]
        #expect(MCPCatalog.search(servers, query: " Linear ").map(\.name) == ["app.linear/linear", "b/linear-tools", "a/docs", "c/linear-old"])
        #expect(MCPCatalog.search(servers, query: "linear issues").map(\.name) == ["app.linear/linear", "a/docs"])
        #expect(MCPCatalog.search(servers, query: "").count == 5)
    }

    // MARK: - Downloads and saved copies

    /// Answers by URL and counts the calls.
    final class FakeNetwork: @unchecked Sendable {
        private let lock = NSLock()
        private var answers: [String: Result<Data, Error>] = [:]
        private(set) var calls: [String] = []

        func set(_ url: URL, _ data: Data) { lock.withLock { answers[url.absoluteString] = .success(data) } }
        func fail(_ url: URL) { lock.withLock { answers[url.absoluteString] = .failure(URLError(.notConnectedToInternet)) } }

        var fetch: MCPCatalogClient.Fetch {
            { [self] request in
                let key = request.url!.absoluteString
                let answer = lock.withLock { () -> Result<Data, Error>? in
                    calls.append(key)
                    return answers[key]
                }
                return try (answer ?? .failure(URLError(.badURL))).get()
            }
        }
    }

    @Test func downloadsEveryDirectoryPageAndStopsOnARepeatedCursor() async throws {
        let network = FakeNetwork()
        network.set(MCPCatalogClient.directoryURL(), page([Self.linear], next: "p2"))
        // The second page points back at itself.
        network.set(MCPCatalogClient.directoryURL(cursor: "p2"), page([Self.context7, Self.linear], next: "p2"))
        let servers = try await MCPCatalogClient.directory(fetch: network.fetch)
        #expect(servers.map(\.name) == ["app.linear/linear", "io.github.upstash/context7"])
        #expect(network.calls.count == 2)
    }

    @Test func directoryIsSavedForADayAndSurvivesAFailedRefresh() async throws {
        let network = FakeNetwork()
        network.set(MCPCatalogClient.directoryURL(), page([Self.linear]))
        let monday = Date(timeIntervalSince1970: 1_790_000_000)
        let first = await MCPCatalog.directory(home: home, now: monday, fetch: network.fetch)
        #expect(first.servers.count == 1 && first.problem == nil && first.savedAt == monday)

        // Fresh: no second download.
        let second = await MCPCatalog.directory(home: home, now: monday.addingTimeInterval(3600), fetch: network.fetch)
        #expect(second.servers == first.servers)
        #expect(network.calls.count == 1)

        // A day later the download fails: the old list stays, with the reason.
        network.fail(MCPCatalogClient.directoryURL())
        let later = await MCPCatalog.directory(home: home, now: monday.addingTimeInterval(25 * 3600), fetch: network.fetch)
        #expect(later.servers == first.servers && later.savedAt == monday && later.problem != nil)
        #expect(network.calls.count == 2)
    }

    @Test func anEmptyDirectoryAnswerKeepsTheSavedList() async throws {
        let network = FakeNetwork()
        network.set(MCPCatalogClient.directoryURL(), page([Self.linear]))
        let monday = Date(timeIntervalSince1970: 1_790_000_000)
        _ = await MCPCatalog.directory(home: home, now: monday, fetch: network.fetch)
        network.set(MCPCatalogClient.directoryURL(), page([]))
        let later = await MCPCatalog.directory(home: home, now: monday, refresh: true, fetch: network.fetch)
        #expect(later.servers.map(\.name) == ["app.linear/linear"] && later.problem != nil)
        #expect(MCPCatalogCache.load(home: home).directory?.servers.count == 1)
    }

    @Test func directoryDownloadKeepsSearchesSavedMeanwhile() async throws {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let home = home
        // The download answers only after a search was saved.
        let fetch: MCPCatalogClient.Fetch = { [linear = Self.linear] _ in
            var cache = MCPCatalogCache.load(home: home)
            cache.remember(search: "context7", servers: [], now: now)
            try cache.save(home: home)
            return Data(#"{"servers":[\#(linear)],"metadata":{}}"#.utf8)
        }
        _ = await MCPCatalog.directory(home: home, now: now, fetch: fetch)
        let saved = MCPCatalogCache.load(home: home)
        #expect(saved.directory?.servers.count == 1 && saved.searches["context7"] != nil)
    }

    @Test func directoryPagingStopsAtTheLimit() async throws {
        // Every page names a new cursor.
        let counter = Counter()
        let fetch: MCPCatalogClient.Fetch = { [linear = Self.linear] _ in
            let page = counter.next()
            return Data(#"{"servers":[\#(linear)],"metadata":{"nextCursor":"p\#(page)"}}"#.utf8)
        }
        let servers = try await MCPCatalogClient.directory(fetch: fetch)
        #expect(servers.count == 1 && counter.value == MCPCatalogClient.maximumDirectoryPages)
    }

    final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var value = 0
        func next() -> Int { lock.withLock { value += 1; return value } }
    }

    @Test func registrySearchIsAskedOncePerQuery() async throws {
        let network = FakeNetwork()
        network.set(MCPCatalogClient.registrySearchURL(query: "context7"), page([Self.context7]))
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let first = try await MCPCatalog.registry(matching: "  Context7 ", home: home, now: now, fetch: network.fetch)
        let second = try await MCPCatalog.registry(matching: "context7", home: home, now: now.addingTimeInterval(60), fetch: network.fetch)
        #expect(first.map(\.name) == ["io.github.upstash/context7"] && second == first)
        #expect(network.calls.count == 1)
        // Too short: nothing is asked.
        #expect(try await MCPCatalog.registry(matching: "c", home: home, now: now, fetch: network.fetch).isEmpty)
        #expect(network.calls.count == 1)
    }

    @Test func cacheKeepsOnlyTheNewestSearches() {
        var cache = MCPCatalogCache()
        let start = Date(timeIntervalSince1970: 1_790_000_000)
        for index in 0..<(MCPCatalogCache.maximumSearches + 5) {
            cache.remember(search: "q\(index)", servers: [], now: start.addingTimeInterval(Double(index)))
        }
        #expect(cache.searches.count == MCPCatalogCache.maximumSearches)
        #expect(cache.searches["q0"] == nil && cache.searches["q44"] != nil)
    }
}
