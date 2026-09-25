import Foundation

/// A place a new MCP server can be written to. One file read by several harnesses
/// (a project `.mcp.json`) is one target.
public struct MCPWriteTarget: Identifiable, Hashable, Sendable {
    public var id: String { "\(file.path)|\(keyPath.joined(separator: "/"))" }
    public let file: URL
    public let keyPath: [String]
    public let dialect: MCPSource.Dialect
    public let scope: SkillScope
    public let layer: String
    public let harnesses: [HarnessID]
    /// Claude's `~/.claude.json` is changed with `claude mcp add-json --scope <this>`, never by AKit.
    public let claudeScope: String?
    /// Meant to be committed and shared with a team: secrets stay `${VAR}` references by default.
    public let isShared: Bool
    /// Why AKit can't write here (e.g. a JSONC file with comments). nil = writable.
    public let blockedReason: String?

    public static func == (a: Self, b: Self) -> Bool { a.id == b.id }
    public func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

extension MCPSource.Dialect: Hashable {}

/// How a secret reaches the server.
public enum MCPSecretMode: String, CaseIterable, Hashable, Sendable {
    /// The config runs `security find-generic-password` itself. Works however the harness
    /// was started, but only on a Mac with this Keychain item.
    case keychainLookup
    /// The config gets `${VAR}`; `~/.akit/env.sh` exports VAR from the Keychain for shells
    /// that source it. Keeps a shared file portable.
    case environment
}

/// What Apply will do. Holds secret values until Apply; never shown.
public struct MCPWritePlan: Sendable {
    public let target: MCPWriteTarget
    public let name: String
    /// The server entry as written (no secret values in it).
    public let entryJSON: String
    /// Masked diff of the file for the preview; empty for Claude's own file.
    public let diff: [TextDiff.Line]
    /// An entry with this name exists and is replaced.
    public let replaces: Bool
    public let notes: [String]
    let secrets: [(account: String, value: String)]
    /// File text the diff was made from; Apply refuses if the file changed since.
    let before: String?
    let after: String?
    /// The entry as compact JSON, for `claude mcp add-json`.
    let entryCompact: String
    public let secretMode: MCPSecretMode
    public var secretNames: [String] { secrets.map(\.account) }
}

public enum MCPWriter {
    public static let envFileName = ".akit/env.sh"

    /// Writable places from the harnesses' MCP sources: JSON files AKit edits itself, plus
    /// Claude's user/local scopes through its CLI. Read-only (plugins) and TOML sources are left out.
    public static func targets(installations: [HarnessInstallation], projects: [URL],
                               adapters: [any HarnessAdapter] = HarnessCatalog.adapters,
                               in env: HarnessEnvironment) -> [MCPWriteTarget] {
        let installed = Set(installations.map(\.id))
        let sources = adapters.filter { installed.contains($0.id) }.flatMap { $0.mcpSources(in: env, projects: projects) }
        return targets(from: sources, env: env)
    }

    static func targets(from sources: [MCPSource], env: HarnessEnvironment) -> [MCPWriteTarget] {
        let claudeState = ClaudeCodeAdapter().stateFile(in: env).standardizedFileURL.path
        var order: [String] = []
        var grouped: [String: [MCPSource]] = [:]
        for source in sources where !source.isReadOnly && source.format != .toml && source.inactiveReason == nil {
            let key = "\(source.file.path)|\(source.keyPath.joined(separator: "/"))"
            if grouped[key] == nil { order.append(key) }
            grouped[key, default: []].append(source)
        }
        return order.compactMap { key in
            guard let group = grouped[key], let first = group.first else { return nil }
            let isClaudeState = first.harness == .claudeCode && first.file.standardizedFileURL.path == claudeState
            var blocked: String?
            if first.format == .jsonc, let text = try? String(contentsOf: first.file, encoding: .utf8),
               ConfigText.stripJSONC(text) != text {
                blocked = "Has comments; AKit would lose them. Add the server by hand."
            }
            var shared = false
            if case .project = first.scope, !isClaudeState, !first.file.path.contains("/.pi/") { shared = true }
            return MCPWriteTarget(file: first.file, keyPath: first.keyPath, dialect: first.dialect, scope: first.scope,
                                  layer: first.layer, harnesses: group.map(\.harness).sorted(),
                                  claudeScope: isClaudeState ? (first.keyPath.first == "projects" ? "local" : "user") : nil,
                                  isShared: shared, blockedReason: blocked)
        }
    }

    // MARK: - Plan

    public static func plan(_ draft: MCPDraft, into target: MCPWriteTarget, secretMode: MCPSecretMode,
                            home: URL) throws -> MCPWritePlan {
        if let reason = target.blockedReason { throw ConfigTextError(reason) }
        if let problem = draft.problems.first { throw ConfigTextError(problem) }
        let name = draft.name.trimmingCharacters(in: .whitespaces)
        var notes: [String] = []
        let (entry, secrets) = entry(for: draft, target: target, mode: secretMode, notes: &notes)
        let entryJSON = try text(redacted(entry))

        if target.claudeScope != nil {
            let existing = try? read(target.file, jsonc: false)
            let replaces = (table(in: existing ?? [:], at: target.keyPath))?[name] != nil
            return MCPWritePlan(target: target, name: name, entryJSON: entryJSON, diff: [], replaces: replaces,
                                notes: notes + ["Claude writes this itself (`claude mcp add-json --scope \(target.claudeScope!)`); AKit keeps a backup of \(SkillScanner.tilde(target.file, home: home))."],
                                secrets: secrets, before: nil, after: nil, entryCompact: try text(entry, pretty: false),
                                secretMode: secretMode)
        }

        let before = (try? String(contentsOf: target.file, encoding: .utf8))
        var object = try before.map { try ConfigText.jsonObject(Data($0.utf8), jsonc: target.dialect == .openCode) } ?? [:]
        let replaces = table(in: object, at: target.keyPath)?[name] != nil
        set(entry, named: name, at: target.keyPath[...], in: &object)
        if before == nil, target.dialect == .openCode { object["$schema"] = "https://opencode.ai/config.json" }
        let after = try text(object) + "\n"

        let original = try before.map { try ConfigText.jsonObject(Data($0.utf8), jsonc: target.dialect == .openCode) }
        if let before, let original, try text(original) + "\n" != before {
            notes.append("AKit rewrites the file with sorted keys and 2-space indentation.")
        }
        let diff = TextDiff.lines(from: try original.map { try text(redacted($0)) + "\n" } ?? "",
                                  to: try text(redacted(object)) + "\n")
        return MCPWritePlan(target: target, name: name, entryJSON: entryJSON, diff: diff,
                            replaces: replaces, notes: notes, secrets: secrets, before: before ?? "", after: after,
                            entryCompact: try text(entry, pretty: false), secretMode: secretMode)
    }

    /// The entry in the target's dialect and the secrets to store.
    static func entry(for draft: MCPDraft, target: MCPWriteTarget, mode: MCPSecretMode,
                      notes: inout [String]) -> ([String: Any], [(account: String, value: String)]) {
        var secrets: [(account: String, value: String)] = []
        let piOnly = target.harnesses == [.pi]
        let claudeOnly = target.harnesses == [.claudeCode]
        let openCode = target.dialect == .openCode
        func reference(_ variable: String) -> String { openCode ? "{env:\(variable)}" : "${\(variable)}" }

        var plainEnv: [String: Any] = [:]
        var wrapped: [String] = [] // env variables the shell wrapper exports
        for value in draft.environment {
            let key = value.key.trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { continue }
            guard value.isSecret else { plainEnv[key] = value.value; continue }
            let variable = draft.variable(for: value, isHeader: false)
            secrets.append((variable, value.value))
            switch mode {
            case .environment: plainEnv[key] = reference(variable)
            case .keychainLookup where piOnly: plainEnv[key] = "!" + KeychainSecretStore.lookupCommand(variable)
            case .keychainLookup: wrapped.append(variable)
            }
        }

        var plainHeaders: [String: Any] = [:]
        var helperHeaders: [(String, String)] = []
        for value in draft.headers {
            let key = value.key.trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { continue }
            guard value.isSecret else { plainHeaders[key] = value.value; continue }
            let variable = draft.variable(for: value, isHeader: true)
            secrets.append((variable, value.value))
            if mode == .keychainLookup, piOnly {
                plainHeaders[key] = "!" + KeychainSecretStore.lookupCommand(variable)
            } else if mode == .keychainLookup, claudeOnly {
                helperHeaders.append((key, variable))
            } else {
                if mode == .keychainLookup {
                    notes.append("Header \(key): \(target.harnesses.map(\.displayName).joined(separator: " and ")) can't run a command for it, so it reads ${\(variable)} from the environment.")
                }
                plainHeaders[key] = reference(variable)
            }
        }

        var command = draft.command.trimmingCharacters(in: .whitespaces)
        var arguments = draft.arguments.filter { !$0.isEmpty }
        if !wrapped.isEmpty {
            // sh -c 'VAR="$(security …)" && export VAR && exec "$0" "$@"' command args…
            let exports = wrapped.map { "\($0)=\"$(\(KeychainSecretStore.lookupCommand($0)))\" && export \($0)" }
            arguments = ["-c", (exports + ["exec \"$0\" \"$@\""]).joined(separator: " && "), command] + arguments
            command = "/bin/sh"
        }

        var entry: [String: Any] = [:]
        if openCode {
            if draft.transport == .stdio {
                entry["type"] = "local"
                entry["command"] = [command] + arguments
                if !plainEnv.isEmpty { entry["environment"] = plainEnv }
            } else {
                entry["type"] = "remote"
                entry["url"] = draft.url.trimmingCharacters(in: .whitespaces)
                if !plainHeaders.isEmpty { entry["headers"] = plainHeaders }
            }
            return (entry, secrets)
        }
        entry["type"] = draft.transport.rawValue
        if draft.transport == .stdio {
            entry["command"] = command
            if !arguments.isEmpty { entry["args"] = arguments }
            if !plainEnv.isEmpty { entry["env"] = plainEnv }
        } else {
            entry["url"] = draft.url.trimmingCharacters(in: .whitespaces)
            if !plainHeaders.isEmpty { entry["headers"] = plainHeaders }
            if !helperHeaders.isEmpty {
                // Claude runs this and merges the printed JSON object into the headers.
                let format = "{" + helperHeaders.map { "\"\($0.0)\":\"%s\"" }.joined(separator: ",") + "}"
                let values = helperHeaders.map { "\"$(\(KeychainSecretStore.lookupCommand($0.1)))\"" }.joined(separator: " ")
                entry["headersHelper"] = "printf '\(format)' \(values)"
            }
        }
        return (entry, secrets)
    }

    // MARK: - Apply

    public struct Outcome: Sendable {
        public let backup: URL?
        public let notes: [String]
    }

    /// Stores the secrets, backs the file up, then writes it (or asks Claude's CLI to).
    /// `runClaude` runs `claude` with arguments in a folder and returns its output or throws.
    public static func apply(_ plan: MCPWritePlan, secrets store: SecretStore, home: URL,
                             runClaude: @Sendable (_ arguments: [String], _ directory: URL?) async throws -> Void)
        async throws -> Outcome {
        let target = plan.target
        if let before = plan.before {
            let now = (try? String(contentsOf: target.file, encoding: .utf8)) ?? ""
            guard now == before else {
                throw ConfigTextError("\(SkillScanner.tilde(target.file, home: home)) changed after the preview. Check the diff again.")
            }
        }
        for secret in plan.secrets { try store.save(secret.value, for: secret.account) }
        let backup = try backUp(target.file, home: home)

        if let scope = target.claudeScope {
            var directory: URL?
            if case .project(let url) = target.scope { directory = url }
            if plan.replaces { try await runClaude(["mcp", "remove", "--scope", scope, plan.name], directory) }
            try await runClaude(["mcp", "add-json", "--scope", scope, plan.name, plan.entryCompact], directory)
        } else if let after = plan.after {
            try FileManager.default.createDirectory(at: target.file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(after.utf8).write(to: target.file, options: .atomic)
        }

        var notes: [String] = []
        if plan.secretMode == .environment, !plan.secrets.isEmpty {
            try updateEnvFile(adding: plan.secrets.map(\.account), home: home)
            let zshrc = (try? String(contentsOf: home.appending(path: ".zshrc"), encoding: .utf8)) ?? ""
            if !zshrc.contains("akit/env.sh") {
                notes.append("Add `source ~/\(envFileName)` to ~/.zshrc so terminals export \(plan.secrets.map(\.account).joined(separator: ", ")) from the Keychain.")
            }
        }
        return Outcome(backup: backup, notes: notes)
    }

    /// Copies the file to `~/.akit/backups/<time>/<path>`. nil when there is nothing to back up.
    static func backUp(_ file: URL, home: URL) throws -> URL? {
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        let stamp = ISO8601DateFormatter.string(from: .now, timeZone: .current,
                                                formatOptions: [.withFullDate, .withTime, .withColonSeparatorInTime])
            .replacingOccurrences(of: ":", with: "")
        var relative = file.standardizedFileURL.path
        if relative.hasPrefix(home.standardizedFileURL.path + "/") { relative = String(relative.dropFirst(home.standardizedFileURL.path.count + 1)) }
        let backup = home.appending(path: ".akit/backups/\(stamp)").appending(path: relative)
        try FileManager.default.createDirectory(at: backup.deletingLastPathComponent(), withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: backup.path) { try FileManager.default.removeItem(at: backup) }
        try FileManager.default.copyItem(at: file, to: backup)
        return backup
    }

    /// `~/.akit/env.sh`: one Keychain lookup per variable, no secret values.
    static func updateEnvFile(adding variables: [String], home: URL) throws {
        let url = home.appending(path: envFileName)
        var known = Set<String>()
        let existing = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        for line in existing.split(separator: "\n") where line.hasPrefix("export ") {
            if let name = line.dropFirst(7).split(separator: "=").first { known.insert(String(name)) }
        }
        known.formUnion(variables)
        let lines = ["# Written by AKit. Exports MCP secrets from the Keychain (service \"\(KeychainSecretStore.service)\").",
                     "# Source it from ~/.zshrc: source ~/\(envFileName)"]
            + known.sorted().map { "export \($0)=\"$(\(KeychainSecretStore.lookupCommand($0)) 2>/dev/null)\"" }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: url, options: .atomic)
    }

    // MARK: - JSON helpers

    static func read(_ url: URL, jsonc: Bool) throws -> [String: Any] {
        try ConfigText.jsonObject(try Data(contentsOf: url), jsonc: jsonc)
    }

    static func table(in object: [String: Any], at path: [String]) -> [String: Any]? {
        var current: Any? = object
        for key in path { current = (current as? [String: Any])?[key] }
        return current as? [String: Any]
    }

    static func set(_ entry: [String: Any], named name: String, at path: ArraySlice<String>, in object: inout [String: Any]) {
        guard let first = path.first else { object[name] = entry; return }
        var child = object[first] as? [String: Any] ?? [:]
        set(entry, named: name, at: path.dropFirst(), in: &child)
        object[first] = child
    }

    static func text(_ object: Any, pretty: Bool = true) throws -> String {
        var options: JSONSerialization.WritingOptions = [.sortedKeys, .withoutEscapingSlashes]
        if pretty { options.insert(.prettyPrinted) }
        return String(decoding: try JSONSerialization.data(withJSONObject: object, options: options), as: UTF8.self)
    }

    /// A copy safe to show: env/header values and secret-looking keys hidden, the rest masked.
    static func redacted(_ value: Any, key: String? = nil, parentIsSecretTable: Bool = false) -> Any {
        if let dict = value as? [String: Any] {
            let secretTable = ["env", "environment", "headers", "http_headers"].contains(key ?? "")
            return dict.reduce(into: [String: Any]()) { result, pair in
                result[pair.key] = redacted(pair.value, key: pair.key, parentIsSecretTable: secretTable)
            }
        }
        if let list = value as? [Any] {
            let strings = list.compactMap { $0 as? String }
            if strings.count == list.count { return key == "args" || key == "command" ? MCPValues.maskedArguments(strings) : strings.map(SecretFilter.masked) }
            return list.map { redacted($0, key: key) }
        }
        guard let text = value as? String else { return value }
        if parentIsSecretTable || MCPValues.looksSecret(name: key ?? "") {
            if text.hasPrefix("!") { return "!" + SecretFilter.masked(String(text.dropFirst())) }
            let rest = MCPValues.withoutReferences(text).trimmingCharacters(in: .whitespaces)
            return MCPValues.hasReference(text) && rest.count <= 12 ? text : "[hidden]"
        }
        if key == "url" { return MCPValues.maskedURL(text) }
        return SecretFilter.masked(text)
    }
}
