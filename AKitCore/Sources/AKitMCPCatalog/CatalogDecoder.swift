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
        let servers = entries.compactMap(\.value).compactMap { server(from: $0, source: source) }
            .filter { seen.insert($0.name).inserted }
        return Page(servers: servers, nextCursor: list.metadata?.nextCursor.flatMap { $0.isEmpty ? nil : $0 })
    }

    private static func server(from entry: RawEntry, source: CatalogSource) -> CatalogServer? {
        let raw = entry.server
        let name = raw.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let status = entry.meta?.official?.status?.lowercased()
        guard !name.isEmpty, status != "deleted" else { return nil }
        let directory = entry.meta?.directory
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

    private static func remote(_ raw: RawRemote, id: String) -> CatalogOption? {
        guard let url = text(raw.url) else { return nil }
        var parameters = (raw.variables ?? [:]).sorted { $0.key < $1.key }.compactMap { key, variable -> CatalogParameter? in
            guard let variable = variable.value else { return nil }
            return CatalogParameter(place: .url, name: key, details: variable.description ?? "", isRequired: true,
                                    defaultValue: variable.default?.text, choices: variable.choices ?? [])
        }
        // A `{part}` of the URL the entry doesn't describe is still something to fill in.
        for name in CatalogDraft.placeholders(in: url) where !parameters.contains(where: { $0.name == name }) {
            parameters.append(CatalogParameter(place: .url, name: name, isRequired: true))
        }
        parameters += (raw.headers ?? []).compactMap(\.value).compactMap { input($0, place: .header) }
        // `{url}` alone: every user has an address of their own (a company instance).
        let host = CatalogDraft.isWholePlaceholder(url) ? "your own URL" : URL(string: url)?.host() ?? url
        return CatalogOption(id: id, kind: .remote, transport: raw.type?.lowercased() == "sse" ? .sse : .http, url: url,
                             parameters: parameters, label: "Remote · \(host)")
    }

    private static func input(_ raw: RawInput, place: CatalogParameter.Place) -> CatalogParameter? {
        guard let name = text(raw.name) else { return nil }
        let template = raw.value?.text.flatMap { CatalogDraft.placeholders(in: $0).isEmpty ? nil : $0 }
        return CatalogParameter(place: place, name: name, details: raw.description ?? "",
                                isRequired: raw.isRequired ?? false,
                                // An entry without the mark still gets the Keychain when the name looks like a credential.
                                isSecret: raw.isSecret == true || MCPDraft.looksSecret(name: name),
                                defaultValue: template == nil ? raw.value?.text ?? raw.default?.text : raw.default?.text,
                                choices: raw.choices ?? [], template: template)
    }

    // MARK: - Package

    private static func package(_ raw: RawPackage, id: String) -> CatalogOption? {
        guard let type = text(raw.registryType)?.lowercased(), let identifier = text(raw.identifier) else { return nil }
        let version = text(raw.version).flatMap { $0.lowercased() == "latest" ? nil : $0 }
        let hint = text(raw.runtimeHint)?.lowercased()
        let runtime = tokens(raw.runtimeArguments)
        let parameters = (raw.environmentVariables ?? []).compactMap(\.value).compactMap { input($0, place: .environment) }
        var command = ""
        var leading: [String] = []
        var trailing: [String] = []
        var byFlag = false
        var unsupported: String?
        switch type {
        case "npm":
            command = hint == "bunx" ? "bunx" : "npx"
            // Without -y npx asks before the first download and the server never starts.
            leading = command == "npx" && !runtime.contains("-y") && !runtime.contains("--yes") ? ["-y"] + runtime : runtime
            trailing = [version.map { "\(identifier)@\($0)" } ?? identifier]
        case "pypi":
            command = "uvx"
            leading = runtime
            trailing = [version.map { "\(identifier)==\($0)" } ?? identifier]
        case "oci":
            command = hint == "podman" ? "podman" : "docker"
            leading = ["run", "-i", "--rm"]
            byFlag = true
            let tagged = identifier.split(separator: "/").last.map { $0.contains(":") || $0.contains("@") } ?? false
            trailing = runtime + [tagged ? identifier : version.map { "\(identifier):\($0)" } ?? identifier]
        default:
            unsupported = "AKit can't start “\(type)” packages. The server's repository says how to set it up."
        }
        if unsupported == nil, let transport = text(raw.transport?.type)?.lowercased(), transport != "stdio" {
            unsupported = "This package runs its own HTTP server. Start it yourself, then add its URL with Add Server…"
        }
        trailing += tokens(raw.packageArguments)
        let shown = [command.isEmpty ? type : command, identifier, version].compactMap { $0 }.joined(separator: " ")
        return CatalogOption(id: id, kind: .package, transport: .stdio, command: command, leadingArguments: leading,
                             trailingArguments: trailing, passesEnvironmentByFlag: byFlag, parameters: parameters,
                             unsupported: unsupported, label: "Local · \(shown)")
    }

    /// Command-line words of registry arguments. A required argument without a value becomes a
    /// `{hint}` word the user has to replace; an optional one without a value is left out.
    private static func tokens(_ arguments: [Lossy<RawArgument>]?) -> [String] {
        (arguments ?? []).compactMap(\.value).flatMap { argument -> [String] in
            let value = argument.value?.text ?? argument.default?.text
            let required = argument.isRequired ?? false
            let hint = text(argument.valueHint)
            if argument.type?.lowercased() == "named" {
                guard let name = text(argument.name) else { return [] }
                if let value { return [name, value] }
                guard required else { return [] }
                return hint.map { [name, "{\($0)}"] } ?? [name]
            }
            if let value { return [value] }
            return required ? ["{\(hint ?? text(argument.name) ?? "value")}"] : []
        }
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

private struct RawEntry: Decodable {
    let server: RawServer
    let meta: Meta?

    enum CodingKeys: String, CodingKey { case server, meta = "_meta" }

    struct Meta: Decodable {
        let official: Official?
        let directory: Directory?

        enum CodingKeys: String, CodingKey {
            case official = "io.modelcontextprotocol.registry/official"
            case directory = "com.anthropic.api/mcp-registry"
        }
    }

    struct Official: Decodable { let status: String? }

    struct Directory: Decodable {
        let displayName: String?
        let oneLiner: String?
        let documentation: String?
        let slug: String?
        let isAuthless: Bool?
        let worksWith: [String]?
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

    struct Repository: Decodable { let url: String? }
}

private struct RawRemote: Decodable {
    let type: String?
    let url: String?
    let headers: [Lossy<RawInput>]?
    let variables: [String: Lossy<RawVariable>]?
}

private struct RawVariable: Decodable {
    let description: String?
    let `default`: LooseText?
    let choices: [String]?
}

private struct RawInput: Decodable {
    let name: String?
    let description: String?
    let value: LooseText?
    let `default`: LooseText?
    let isRequired: Bool?
    let isSecret: Bool?
    let choices: [String]?
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

    struct Transport: Decodable { let type: String? }
}

private struct RawArgument: Decodable {
    let type: String?
    let name: String?
    let value: LooseText?
    let `default`: LooseText?
    let valueHint: String?
    let isRequired: Bool?
}
