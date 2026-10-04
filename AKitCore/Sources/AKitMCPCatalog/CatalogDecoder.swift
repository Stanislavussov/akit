import AKitMCP
import Foundation

/// Reads a `servers` page in the MCP Registry format (`server.json` entries). Both catalogs
/// answer in it; the directory adds its own block under `_meta`.
enum CatalogDecoder {
    struct Page {
        var servers: [CatalogServer]
        var nextCursor: String?
    }

    static func decode(_ data: Data, source: CatalogSource) throws -> Page {
        let list: RawList
        do {
            list = try JSONDecoder().decode(RawList.self, from: data)
        } catch {
            throw MCPCatalogClient.Failure.server("\(source.title) sent an answer AKit can't read.")
        }
        guard let entries = list.servers else {
            throw MCPCatalogClient.Failure.server(list.detail ?? list.title ?? list.error ?? "\(source.title) sent no server list.")
        }
        var seen: Set<String> = []
        let readable = entries.compactMap(\.value)
        // The directory's own format changed: an error, not an empty catalog.
        if source == .directory, !entries.isEmpty, readable.isEmpty {
            throw MCPCatalogClient.Failure.server("\(source.title) sent entries AKit can't read.")
        }
        let servers = readable.compactMap { server(from: $0, source: source) }
            .filter { seen.insert($0.name).inserted }
        return Page(servers: servers, nextCursor: list.metadata?.nextCursor.flatMap { $0.isEmpty ? nil : $0 })
    }

    private static func server(from entry: RawEntry, source: CatalogSource) -> CatalogServer? {
        let raw = entry.server
        let name = raw.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let status = entry.meta?.value?.official?.value?.status?.lowercased()
        guard !name.isEmpty, status != "deleted" else { return nil }
        let directory = entry.meta?.value?.directory?.value
        var options: [CatalogOption] = []
        for (index, remote) in (raw.remotes ?? []).compactMap(\.value).enumerated() {
            if let option = self.remote(remote, id: "remote:\(index)") { options.append(option) }
        }
        for (index, package) in (raw.packages ?? []).compactMap(\.value).enumerated() {
            if let option = self.package(package, id: "package:\(index)") { options.append(option) }
        }
        guard !options.isEmpty else { return nil }
        // Options AKit can fill come first; the picker starts on the first one.
        options = options.filter { $0.unsupported == nil } + options.filter { $0.unsupported != nil }
        let slug = directory?.slug.flatMap { CatalogServer.configName(for: $0).isEmpty ? nil : CatalogServer.configName(for: $0) }
        return CatalogServer(
            name: name,
            title: text(directory?.displayName) ?? text(raw.title) ?? name,
            summary: text(directory?.oneLiner) ?? text(raw.description) ?? "",
            version: text(raw.version),
            source: source,
            repositoryURL: webURL(raw.repository?.url),
            websiteURL: webURL(raw.websiteUrl),
            documentationURL: webURL(directory?.documentation),
            isDeprecated: status == "deprecated",
            listsClaudeCode: directory?.worksWith.map { $0.contains("claude-code") },
            needsSignIn: directory?.isAuthless.map { !$0 },
            configName: slug ?? CatalogServer.configName(for: name),
            options: options)
    }

    // MARK: - Remote

    private static let noSecretsInFiles = "AKit keeps secrets out of config files, so it can't fill this one. Set it up from the server's documentation."

    private static func remote(_ raw: RawRemote, id: String) -> CatalogOption? {
        guard let url = text(raw.url) else { return nil }
        let parts = CatalogDraft.placeholders(in: url)
        var unsupported: String?
        var parameters: [CatalogParameter] = []
        for name in parts {
            let variable = raw.variables?[name]?.value
            // A secret typed into the URL would be written into the file as it is.
            if variable?.isSecret == true || isCredentialName(name) {
                unsupported = "This server takes a secret inside its URL ({\(name)}). " + noSecretsInFiles
            }
            parameters.append(CatalogParameter(place: .url, name: name, details: variable?.description ?? "", isRequired: true,
                                               defaultValue: variable?.default?.text.flatMap(urlPart),
                                               choices: (variable?.choices ?? []).compactMap(urlPart)))
        }
        parameters += unique((raw.headers ?? []).compactMap(\.value).compactMap { input($0, place: .header) })
        // `{url}` alone: every user has an address of their own (a company instance).
        let host = CatalogDraft.isWholePlaceholder(url) ? "your own URL"
            : parts.isEmpty ? URL(string: url)?.host() ?? url : url.replacingOccurrences(of: "https://", with: "")
        return CatalogOption(id: id, kind: .remote, transport: raw.type?.lowercased() == "sse" ? .sse : .http, url: url,
                             parameters: parameters, unsupported: unsupported, label: "Remote · \(host)")
    }

    private static let credentialName = try! NSRegularExpression(
        pattern: #"(?i)(token|secret|passw|pwd|api[-_ ]?key|access[-_ ]?key|private[-_ ]?key|credential|bearer)"#)

    /// A name that can only be a credential (`--api-key`, `{token}`). `MCPDraft.looksSecret` is
    /// wider (`--keyword`, `{project_key}`): good for choosing the Keychain, too wide for refusing an option.
    static func isCredentialName(_ name: String) -> Bool {
        credentialName.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)) != nil
    }

    /// A catalog value may fill one part of a URL, never add a host, a path or a query of its own.
    private static func urlPart(_ value: String) -> String? {
        value.range(of: "^[A-Za-z0-9._-]+$", options: .regularExpression) == nil ? nil : value
    }

    private static func input(_ raw: RawInput, place: CatalogParameter.Place) -> CatalogParameter? {
        guard let name = text(raw.name) else { return nil }
        let template = raw.value?.text.flatMap { CatalogDraft.placeholders(in: $0).isEmpty ? nil : $0 }
        let fallback = template == nil ? raw.value?.text ?? raw.default?.text : raw.default?.text
        // An entry without the mark still gets the Keychain when the name looks like a credential,
        // or when a part of its value is marked secret or named like one. An explicit "not secret"
        // with a real default (`SESSION_TIMEOUT` = 30) stays a plain value; a name that can only be
        // a credential (`GITHUB_TOKEN`) is a secret whatever the entry says.
        let declaredPlain = raw.isSecret == false && !(fallback ?? "").isEmpty
        let namedSecret = isCredentialName(name) || (MCPDraft.looksSecret(name: name) && !declaredPlain)
        let secretPart = (raw.variables ?? [:]).values.contains { $0.value?.isSecret == true }
            || CatalogDraft.placeholders(in: template ?? "").contains(where: MCPDraft.looksSecret(name:))
        return CatalogParameter(place: place, name: name, details: raw.description ?? "",
                                isRequired: raw.isRequired ?? false,
                                isSecret: raw.isSecret == true || namedSecret || secretPart,
                                defaultValue: fallback, choices: raw.choices ?? [], template: template)
    }

    /// The first parameter of every name: a repeated name would be written twice.
    private static func unique(_ parameters: [CatalogParameter]) -> [CatalogParameter] {
        var seen: Set<String> = []
        return parameters.filter { seen.insert($0.id).inserted }
    }

    // MARK: - Package

    private static func package(_ raw: RawPackage, id: String) -> CatalogOption? {
        guard let type = text(raw.registryType)?.lowercased(), let identifier = text(raw.identifier),
              // A name that reads as an option would change what the runner does.
              !identifier.hasPrefix("-"), !identifier.contains(where: \.isWhitespace) else { return nil }
        let listed = text(raw.version).flatMap { $0.lowercased() == "latest" ? nil : $0 }
        // Only a full version pins; `1`, `1.x` or a tag such as `next` moves.
        let version = listed.flatMap { $0.range(of: #"^v?\d+\.\d+\.\d+"#, options: .regularExpression) == nil ? nil : $0 }
        let hint = text(raw.runtimeHint)?.lowercased()
        let runtime = words(raw.runtimeArguments)
        let own = words(raw.packageArguments)
        let parameters = unique((raw.environmentVariables ?? []).compactMap(\.value).compactMap { input($0, place: .environment) })
        var command = ""
        var leading: [String] = []
        var trailing: [String] = []
        var byFlag = false
        var unsupported: String?
        var cautions: [String] = []
        switch type {
        case "npm":
            command = hint == "bunx" ? "bunx" : "npx"
            // Without -y npx asks before the first download and the server never starts.
            let confirms = runtime.words.contains("-y") || runtime.words.contains("--yes")
            leading = command == "npx" && !confirms ? ["-y"] + runtime.words : runtime.words
            trailing = [(version ?? listed).map { "\(identifier)@\($0)" } ?? identifier]
        case "pypi":
            command = "uvx"
            leading = runtime.words
            trailing = [version.map { "\(identifier)==\($0)" } ?? identifier]
        case "oci":
            command = hint == "podman" ? "podman" : "docker"
            leading = ["run", "-i", "--rm"]
            byFlag = true
            let image = String(identifier.split(separator: "/").last ?? "")
            let tagged = image.contains(":") || image.contains("@")
            trailing = runtime.words + [tagged ? identifier : (version ?? listed).map { "\(identifier):\($0)" } ?? identifier]
            if tagged ? image.hasSuffix(":latest") : version == nil { cautions.append(unpinned) }
        default:
            unsupported = "AKit can't start “\(type)” packages. The server's repository says how to set it up."
        }
        if type == "npm" || type == "pypi", version == nil { cautions.append(unpinned) }
        let extra = runtime.words.filter { $0 != "-y" && $0 != "--yes" }
        if !extra.isEmpty, unsupported == nil {
            cautions.append("The entry adds its own arguments for \(command): \(MCPDraft.joinArguments(extra)). They change what runs: check them.")
        }
        if unsupported == nil, let transport = text(raw.transport?.type)?.lowercased(), transport != "stdio" {
            unsupported = "This package runs its own HTTP server. Start it yourself, then add its URL with Add Server…"
        }
        if unsupported == nil, let secret = runtime.secret ?? own.secret {
            unsupported = "This server takes a secret as a command-line argument (\(secret)). " + noSecretsInFiles
        }
        if unsupported == nil, runtime.open || own.open {
            cautions.append("Arguments are written into the file as they are: don't put a secret there.")
        }
        trailing += own.words
        let shown = [command.isEmpty ? type : command, identifier, version ?? listed].compactMap { $0 }.joined(separator: " ")
        return CatalogOption(id: id, kind: .package, transport: .stdio, command: command, leadingArguments: leading,
                             trailingArguments: trailing, passesEnvironmentByFlag: byFlag, parameters: parameters,
                             unsupported: unsupported, cautions: cautions, label: "Local · \(shown)")
    }

    private static let unpinned = "No version is pinned: the newest release runs at every start."

    private struct Words {
        var words: [String] = []
        /// An argument the user would have to type a secret into.
        var secret: String?
        /// Some word is a `{placeholder}` for the user to replace.
        var open = false
    }

    /// Command-line words of registry arguments. A required argument without a value becomes a
    /// `{hint}` word the user has to replace; an optional one without a value is left out.
    private static func words(_ arguments: [Lossy<RawArgument>]?) -> Words {
        var result = Words()
        for argument in (arguments ?? []).compactMap(\.value) {
            let value = argument.value?.text ?? argument.default?.text
            let required = argument.isRequired ?? false
            let hint = text(argument.valueHint)
            let name = text(argument.name)
            let named = argument.type?.lowercased() == "named"
            var added: [String] = []
            if named {
                guard let name else { continue }
                if let value { added = [name, value] }
                else if required { added = hint.map { [name, CatalogDraft.placeholder($0)] } ?? [name] }
            } else if let value {
                added = [value]
            } else if required {
                added = [CatalogDraft.placeholder(hint ?? name ?? "value")]
            }
            // What goes into Arguments is written into the file. The user types the word when it is
            // a placeholder, and also when the entry only suggests a value (`default`), not fixes it.
            let open = added.contains { !CatalogDraft.placeholders(in: $0).isEmpty }
            let typed = open || (!added.isEmpty && argument.value?.text == nil)
            let secret = argument.isSecret == true || [name, hint].compactMap { $0 }.contains(where: isCredentialName)
                || (argument.variables ?? [:]).values.contains { $0.value?.isSecret == true }
            if typed, secret {
                result.secret = result.secret ?? name ?? hint ?? "a value"
            }
            result.open = result.open || open
            result.words += added
        }
        return result
    }

    // MARK: - Helpers

    private static func text(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Only http(s) links: these are opened in the browser.
    private static func webURL(_ value: String?) -> URL? {
        guard let url = text(value).flatMap(URL.init(string:)), ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              url.host() != nil else { return nil }
        return url
    }
}

// MARK: - Raw JSON

/// An element that can't be read is dropped instead of failing the whole list.
struct Lossy<Wrapped: Decodable>: Decodable {
    let value: Wrapped?
    init(from decoder: Decoder) throws { value = try? Wrapped(from: decoder) }
}

/// A string, or a number or boolean written without quotes.
struct LooseText: Decodable {
    let text: String?
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let string = try? container.decode(String.self) { text = string }
        else if let bool = try? container.decode(Bool.self) { text = bool ? "true" : "false" }
        else if let int = try? container.decode(Int.self) { text = String(int) }
        else if let double = try? container.decode(Double.self) { text = String(double) }
        else { text = nil }
    }
}

private struct RawList: Decodable {
    let servers: [Lossy<RawEntry>]?
    let metadata: Metadata?
    // An error answer has one of these instead of `servers`.
    let detail: String?
    let title: String?
    let error: String?

    struct Metadata: Decodable { let nextCursor: String? }
}

/// Reads fields by name; a field that is missing or has another type reads as nil, so one odd
/// field doesn't drop its entry.
private struct Fields {
    private struct Key: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init(_ name: String) { stringValue = name }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    private let container: KeyedDecodingContainer<Key>?

    init(_ decoder: Decoder) { container = try? decoder.container(keyedBy: Key.self) }

    func callAsFunction<Value: Decodable>(_ name: String) -> Value? {
        guard let container else { return nil }
        return (try? container.decodeIfPresent(Value.self, forKey: Key(name))) ?? nil
    }

    /// A boolean, also when it is written as `"true"` or `1`.
    func flag(_ name: String) -> Bool? {
        let loose: LooseText? = self(name)
        switch loose?.text?.lowercased() {
        case "true", "1", "yes": return true
        case "false", "0", "no": return false
        default: return nil
        }
    }
}

private struct RawEntry: Decodable {
    let server: RawServer
    let meta: Lossy<Meta>?

    enum CodingKeys: String, CodingKey { case server, meta = "_meta" }

    struct Meta: Decodable {
        let official: Lossy<Official>?
        let directory: Lossy<Directory>?

        enum CodingKeys: String, CodingKey {
            case official = "io.modelcontextprotocol.registry/official"
            case directory = "com.anthropic.api/mcp-registry"
        }
    }

    struct Official: Decodable {
        let status: String?
        init(from decoder: Decoder) { status = Fields(decoder)("status") }
    }

    struct Directory: Decodable {
        let displayName: String?
        let oneLiner: String?
        let documentation: String?
        let slug: String?
        let isAuthless: Bool?
        let worksWith: [String]?

        init(from decoder: Decoder) {
            let fields = Fields(decoder)
            displayName = fields("displayName")
            oneLiner = fields("oneLiner")
            documentation = fields("documentation")
            slug = fields("slug")
            isAuthless = fields.flag("isAuthless")
            worksWith = fields("worksWith")
        }
    }
}

private struct RawServer: Decodable {
    let name: String
    let title: String?
    let description: String?
    let version: String?
    let websiteUrl: String?
    let repository: Repository?
    let remotes: [Lossy<RawRemote>]?
    let packages: [Lossy<RawPackage>]?

    init(from decoder: Decoder) throws {
        let fields = Fields(decoder)
        guard let name: String = fields("name") else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "A server needs a name."))
        }
        self.name = name
        title = fields("title")
        description = fields("description")
        version = fields("version")
        websiteUrl = fields("websiteUrl")
        repository = fields("repository")
        remotes = fields("remotes")
        packages = fields("packages")
    }

    struct Repository: Decodable {
        let url: String?
        init(from decoder: Decoder) { url = Fields(decoder)("url") }
    }
}

private struct RawRemote: Decodable {
    let type: String?
    let url: String?
    let headers: [Lossy<RawInput>]?
    let variables: [String: Lossy<RawVariable>]?

    init(from decoder: Decoder) {
        let fields = Fields(decoder)
        type = fields("type")
        url = fields("url")
        headers = fields("headers")
        variables = fields("variables")
    }
}

private struct RawVariable: Decodable {
    let description: String?
    let `default`: LooseText?
    let choices: [String]?
    let isSecret: Bool?

    init(from decoder: Decoder) {
        let fields = Fields(decoder)
        description = fields("description")
        `default` = fields("default")
        choices = fields("choices")
        isSecret = fields.flag("isSecret")
    }
}

private struct RawInput: Decodable {
    let name: String?
    let description: String?
    let value: LooseText?
    let `default`: LooseText?
    let isRequired: Bool?
    let isSecret: Bool?
    let choices: [String]?
    let variables: [String: Lossy<RawVariable>]?

    init(from decoder: Decoder) {
        let fields = Fields(decoder)
        name = fields("name")
        description = fields("description")
        value = fields("value")
        `default` = fields("default")
        isRequired = fields.flag("isRequired")
        isSecret = fields.flag("isSecret")
        choices = fields("choices")
        variables = fields("variables")
    }
}

private struct RawPackage: Decodable {
    let registryType: String?
    let identifier: String?
    let version: String?
    let runtimeHint: String?
    let transport: Transport?
    let environmentVariables: [Lossy<RawInput>]?
    let packageArguments: [Lossy<RawArgument>]?
    let runtimeArguments: [Lossy<RawArgument>]?

    init(from decoder: Decoder) {
        let fields = Fields(decoder)
        registryType = fields("registryType")
        identifier = fields("identifier")
        version = fields("version")
        runtimeHint = fields("runtimeHint")
        transport = fields("transport")
        environmentVariables = fields("environmentVariables")
        packageArguments = fields("packageArguments")
        runtimeArguments = fields("runtimeArguments")
    }

    struct Transport: Decodable {
        let type: String?
        init(from decoder: Decoder) { type = Fields(decoder)("type") }
    }
}

private struct RawArgument: Decodable {
    let type: String?
    let name: String?
    let value: LooseText?
    let `default`: LooseText?
    let valueHint: String?
    let isRequired: Bool?
    let isSecret: Bool?
    let variables: [String: Lossy<RawVariable>]?

    init(from decoder: Decoder) {
        let fields = Fields(decoder)
        type = fields("type")
        name = fields("name")
        value = fields("value")
        `default` = fields("default")
        valueHint = fields("valueHint")
        isRequired = fields.flag("isRequired")
        isSecret = fields.flag("isSecret")
        variables = fields("variables")
    }
}
