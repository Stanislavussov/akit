import Foundation

/// Where a catalog entry is listed.
public enum CatalogSource: String, Codable, Hashable, Sendable {
    /// Anthropic's connector directory: a few hundred reviewed remote servers.
    case directory
    /// The official MCP Registry: anyone can publish there, nothing is reviewed.
    case registry

    public var title: String {
        switch self {
        case .directory: "Anthropic directory"
        case .registry: "MCP Registry"
        }
    }
}

/// One MCP server of a catalog, with the ways to connect to it.
public struct CatalogServer: Identifiable, Hashable, Sendable, Codable {
    public var id: String { "\(source.rawValue)|\(name)" }

    /// Registry name, `namespace/server`, e.g. `io.github.upstash/context7`.
    public let name: String
    public let title: String
    public let summary: String
    public let version: String?
    public let source: CatalogSource
    public let repositoryURL: URL?
    public let websiteURL: URL?
    public let documentationURL: URL?
    public let isDeprecated: Bool
    /// Directory entries: whether the entry names Claude Code among the clients it works with.
    public let listsClaudeCode: Bool?
    /// Directory entries: the server asks the user to sign in (OAuth) on first use.
    public let needsSignIn: Bool?
    /// The name the server gets in a config file, e.g. `context7`.
    public let configName: String
    public let options: [CatalogOption]

    public init(name: String, title: String, summary: String, version: String? = nil, source: CatalogSource,
                repositoryURL: URL? = nil, websiteURL: URL? = nil, documentationURL: URL? = nil,
                isDeprecated: Bool = false, listsClaudeCode: Bool? = nil, needsSignIn: Bool? = nil,
                configName: String, options: [CatalogOption]) {
        self.name = name
        self.title = title
        self.summary = summary
        self.version = version
        self.source = source
        self.repositoryURL = repositoryURL
        self.websiteURL = websiteURL
        self.documentationURL = documentationURL
        self.isDeprecated = isDeprecated
        self.listsClaudeCode = listsClaudeCode
        self.needsSignIn = needsSignIn
        self.configName = configName
        self.options = options
    }

    /// The publisher's namespace, e.g. `io.github.upstash`. The registry checks who owns it.
    public var namespace: String { String(name.split(separator: "/").first ?? "") }

    /// A config name from a registry name: the last part without `mcp`/`server` filler, or the
    /// publisher's own label when nothing else is left (`com.notion/mcp` → `notion`).
    static func configName(for name: String) -> String {
        let parts = name.split(separator: "/", maxSplits: 1).map(String.init)
        var last = (parts.count > 1 ? parts[1] : parts.first ?? "").lowercased()
        for suffix in ["-mcp-server", "_mcp_server", "-mcp", "_mcp", "-server"] where last.hasSuffix(suffix) {
            last.removeLast(suffix.count)
            break
        }
        for prefix in ["mcp-server-", "mcp-", "mcp_"] where last.hasPrefix(prefix) {
            last.removeFirst(prefix.count)
            break
        }
        let filler: Set<String> = ["", "mcp", "server", "mcp-server", "remote", "remote-mcp-server", "api", "app"]
        if filler.contains(last), parts.count > 1 {
            // Reverse-DNS namespace: skip the top-level label and filler (`com.cloudflare.mcp` → `cloudflare`).
            let labels = parts[0].lowercased().split(separator: ".").map(String.init)
            let ignored: Set<String> = ["mcp", "api", "app", "www", "github", "gitlab"]
            last = labels.dropFirst().first { !ignored.contains($0) } ?? labels.last ?? last
        }
        let cleaned = String(last.map { $0.isASCII && ($0.isLetter || $0.isNumber || "-_.".contains($0)) ? $0 : "-" })
        return cleaned.trimmingCharacters(in: CharacterSet(charactersIn: "-_."))
    }
}

/// One way to connect to a server: its public URL, or a package started on this Mac.
public struct CatalogOption: Identifiable, Hashable, Sendable, Codable {
    public enum Kind: String, Codable, Hashable, Sendable { case remote, package }
    public enum Transport: String, Codable, Hashable, Sendable { case stdio, http, sse }

    /// Place in the server's entry, e.g. `remote:0`, `package:1`.
    public let id: String
    public let kind: Kind
    public let transport: Transport
    /// Remote: the URL, possibly with `{variable}` parts.
    public let url: String
    /// Package: the program that starts it (`npx`, `uvx`, `docker`).
    public let command: String
    /// Package: arguments before the environment flags (docker's `run -i --rm`).
    public let leadingArguments: [String]
    /// Package: the package itself and what follows it.
    public let trailingArguments: [String]
    /// Docker: every environment variable is also named with `-e NAME`, so it reaches the container.
    public let passesEnvironmentByFlag: Bool
    public let parameters: [CatalogParameter]
    /// Why AKit can't fill the form for this option; nil when it can.
    public let unsupported: String?
    /// One line for a picker, e.g. `Remote · mcp.context7.com` or `Local · npx @upstash/context7-mcp 4.1.1`.
    public let label: String

    public init(id: String, kind: Kind, transport: Transport, url: String = "", command: String = "",
                leadingArguments: [String] = [], trailingArguments: [String] = [], passesEnvironmentByFlag: Bool = false,
                parameters: [CatalogParameter] = [], unsupported: String? = nil, label: String) {
        self.id = id
        self.kind = kind
        self.transport = transport
        self.url = url
        self.command = command
        self.leadingArguments = leadingArguments
        self.trailingArguments = trailingArguments
        self.passesEnvironmentByFlag = passesEnvironmentByFlag
        self.parameters = parameters
        self.unsupported = unsupported
        self.label = label
    }
}

/// A value the server takes: an environment variable, a header, or a part of the URL.
public struct CatalogParameter: Identifiable, Hashable, Sendable, Codable {
    public enum Place: String, Codable, Hashable, Sendable { case environment, header, url }

    public var id: String { "\(place.rawValue):\(name)" }
    public let place: Place
    public let name: String
    public let details: String
    public let isRequired: Bool
    public let isSecret: Bool
    public let defaultValue: String?
    public let choices: [String]
    /// Header: the shape of the value, e.g. `Bearer {token}`.
    public let template: String?

    public init(place: Place, name: String, details: String = "", isRequired: Bool = false, isSecret: Bool = false,
                defaultValue: String? = nil, choices: [String] = [], template: String? = nil) {
        self.place = place
        self.name = name
        self.details = details
        self.isRequired = isRequired
        self.isSecret = isSecret
        self.defaultValue = defaultValue
        self.choices = choices
        self.template = template
    }
}
