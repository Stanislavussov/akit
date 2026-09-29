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
    /// Why the harness doesn't load this file now (e.g. pi-mcp-adapter missing). Still editable.
    public let inactiveReason: String?

    public static func == (a: Self, b: Self) -> Bool { a.id == b.id }
    public func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

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
    /// Editing: the entry's name before; it is removed when the name changed.
    public let originalName: String?
    /// Deletes `name` instead of writing it.
    public let isRemoval: Bool
    /// The server entry as written, masked.
    public let entryJSON: String
    /// Masked diff of the file for the preview; empty for Claude's own file.
    public let diff: [TextDiff.Line]
    /// An entry with this name exists and is replaced.
    public let replaces: Bool
    public let notes: [String]
    /// Things to read before Apply, e.g. a Keychain item another server may use gets replaced.
    public let warnings: [String]
    let secrets: [(account: String, value: String)]
    /// Variables `~/.akit/env.sh` must export for this entry (new and kept ones).
    let envVariables: [String]
    /// File text the plan was made from; Apply refuses if the file changed since.
    let before: String?
    let after: String?
    /// The entry as compact JSON, for `claude mcp add-json`.
    let entryCompact: String
    /// Claude replace: the entry as it was, re-added if `add-json` fails after `remove`.
    let originalCompact: String?
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
        return targets(from: sources)
    }

    static func targets(from sources: [MCPSource]) -> [MCPWriteTarget] {
        var order: [String] = []
        var grouped: [String: [MCPSource]] = [:]
        for source in sources where !source.isReadOnly && source.format != .toml {
            let key = "\(source.file.path)|\(source.keyPath.joined(separator: "/"))"
            if grouped[key] == nil { order.append(key) }
            grouped[key, default: []].append(source)
        }
        return order.compactMap { key in
            guard let group = grouped[key], let first = group.first else { return nil }
            let isClaudeState = first.writesThroughClaudeCLI
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
                                  isShared: shared, blockedReason: blocked, inactiveReason: first.inactiveReason)
        }
    }

    /// The writable target a listed server lives in; nil for plugins, TOML and blocked files.
    public static func target(of server: MCPServer, in targets: [MCPWriteTarget]) -> MCPWriteTarget? {
        let id = "\(server.file.path)|\(server.keyPath.joined(separator: "/"))"
        return targets.first { $0.id == id }
    }

    /// The raw entry of a listed server and the file text it came from, for the edit form.
    /// Values stay in memory only.
    public static func rawEntry(of server: MCPServer, target: MCPWriteTarget) -> (entry: [String: Any], fileText: String)? {
        guard let text = try? String(contentsOf: target.file, encoding: .utf8),
              let object = try? ConfigText.jsonObject(Data(text.utf8), jsonc: target.dialect == .openCode),
              let entry = table(in: object, at: target.keyPath)?[server.name] as? [String: Any] else { return nil }
        return (entry, text)
    }

    static func hasComments(_ text: String) -> Bool {
        ConfigText.stripJSONC(text) != ConfigText.normalized(text)
    }

    // MARK: - Plan

    /// `replacing`: the name of the entry being edited (nil = a new server).
    /// `openedText`: the file text the edit form was filled from; the plan refuses if it changed.
    /// `keychain`: to warn when a secret would replace an existing Keychain item.
    public static func plan(_ draft: MCPDraft, into target: MCPWriteTarget, secretMode: MCPSecretMode,
                            replacing originalName: String? = nil, openedText: String? = nil,
                            keychain: SecretStore, home: URL) throws -> MCPWritePlan {
        if let reason = target.blockedReason { throw ConfigTextError(reason) }
        if let problem = draft.problems.first { throw ConfigTextError(problem) }
        let name = draft.name.trimmingCharacters(in: .whitespaces)
        let where_ = FileWalk.tilde(target.file, home: home)
        var notes: [String] = []
        let built = try entry(for: draft, target: target, mode: secretMode, notes: &notes)
        let entryJSON = try text(redacted(built.entry))
        let entryCompact = try text(built.entry, pretty: false)

        let before = try? String(contentsOf: target.file, encoding: .utf8)
        if target.dialect == .openCode, let before, hasComments(before) {
            throw ConfigTextError("\(where_) has comments; AKit would lose them. Change it by hand.")
        }
        let jsonc = target.dialect == .openCode
        let original = try before.map { try ConfigText.jsonObject(Data($0.utf8), jsonc: jsonc) }
        let current = original.flatMap { table(in: $0, at: target.keyPath) } ?? [:]
        if let openedText {
            // Claude rewrites its own file all the time: there only the entry itself must be unchanged.
            let changed: Bool
            if target.claudeScope != nil, let originalName {
                let opened = (try? ConfigText.jsonObject(Data(openedText.utf8), jsonc: false))
                    .flatMap { table(in: $0, at: target.keyPath)?[originalName] }
                changed = try opened.map { try text($0) } != current[originalName].map { try text($0) }
            } else {
                changed = before != openedText
            }
            if changed { throw ConfigTextError("\(where_) changed after the form was opened. Close it and edit again.") }
        }
        if name != originalName, current[name] != nil {
            throw ConfigTextError("A server named “\(name)” already exists here. Pick another name or edit that one.")
        }
        let replaces = current[name] != nil

        var warnings: [String] = []
        for secret in built.secrets where keychain.contains(secret.account) && !built.keptAccounts.contains(secret.account) {
            warnings.append("The Keychain already has \(secret.account); Apply replaces it. Another server that uses \(secret.account) gets this value too.")
        }
        if target.claudeScope != nil, draft.activeValues.contains(where: { !$0.isSecret && $0.value.isEmpty && $0.hasHiddenValue }) {
            notes.append("Values kept in \(where_) are passed to `claude mcp add-json` as a command argument while saving.")
        }

        if let scope = target.claudeScope {
            var originalCompact: String?
            if replaces, let entry = current[name] { originalCompact = try text(entry, pretty: false) }
            return MCPWritePlan(target: target, name: name, originalName: originalName, isRemoval: false,
                                entryJSON: entryJSON, diff: [], replaces: replaces,
                                notes: notes + ["Claude writes this itself (`claude mcp add-json --scope \(scope)`); AKit keeps a backup of \(where_)."],
                                warnings: warnings, secrets: built.secrets, envVariables: built.envVariables,
                                before: before ?? "", after: nil, entryCompact: entryCompact,
                                originalCompact: originalCompact, secretMode: secretMode)
        }

        var object = original ?? [:]
        if let originalName, originalName != name { set(nil, named: originalName, at: target.keyPath[...], in: &object) }
        set(built.entry, named: name, at: target.keyPath[...], in: &object)
        if before == nil, target.dialect == .openCode { object["$schema"] = "https://opencode.ai/config.json" }
        let after = try text(object) + "\n"
        if let before, let original, try text(original) + "\n" != before {
            notes.append("AKit rewrites the file with sorted keys and 2-space indentation.")
        }
        let diff = TextDiff.lines(from: try original.map { try text(redacted($0)) + "\n" } ?? "",
                                  to: try text(redacted(object)) + "\n")
        return MCPWritePlan(target: target, name: name, originalName: originalName, isRemoval: false,
                            entryJSON: entryJSON, diff: diff, replaces: replaces, notes: notes, warnings: warnings,
                            secrets: built.secrets, envVariables: built.envVariables, before: before ?? "",
                            after: after, entryCompact: entryCompact, originalCompact: nil, secretMode: secretMode)
    }

    /// Deleting `name` from the target. Keychain items are left alone: another server may use them.
    public static func removalPlan(_ name: String, from target: MCPWriteTarget, home: URL) throws -> MCPWritePlan {
        let where_ = FileWalk.tilde(target.file, home: home)
        guard let before = try? String(contentsOf: target.file, encoding: .utf8) else {
            throw ConfigTextError("\(where_) doesn't exist.")
        }
        let jsonc = target.dialect == .openCode
        if jsonc, hasComments(before) { throw ConfigTextError("\(where_) has comments; AKit would lose them. Change it by hand.") }
        let original = try ConfigText.jsonObject(Data(before.utf8), jsonc: jsonc)
        guard let entry = table(in: original, at: target.keyPath)?[name] else {
            throw ConfigTextError("“\(name)” is no longer in \(where_).")
        }
        if let scope = target.claudeScope {
            // Show what goes away: the entry, masked.
            return MCPWritePlan(target: target, name: name, originalName: nil, isRemoval: true,
                                entryJSON: try text(redacted([name: entry])), diff: [], replaces: true,
                                notes: ["Claude removes it itself (`claude mcp remove --scope \(scope)`); AKit keeps a backup of \(where_)."],
                                warnings: [], secrets: [], envVariables: [], before: before, after: nil,
                                entryCompact: "", originalCompact: nil, secretMode: .environment)
        }
        var object = original
        set(nil, named: name, at: target.keyPath[...], in: &object)
        var notes: [String] = []
        if try text(original) + "\n" != before { notes.append("AKit rewrites the file with sorted keys and 2-space indentation.") }
        let diff = TextDiff.lines(from: try text(redacted(original)) + "\n", to: try text(redacted(object)) + "\n")
        return MCPWritePlan(target: target, name: name, originalName: nil, isRemoval: true, entryJSON: "", diff: diff,
                            replaces: true, notes: notes, warnings: [], secrets: [], envVariables: [], before: before,
                            after: try text(object) + "\n", entryCompact: "", originalCompact: nil, secretMode: .environment)
    }

    struct BuiltEntry {
        var entry: [String: Any]
        var secrets: [(account: String, value: String)]
        /// Keychain items the entry keeps using unchanged.
        var keptAccounts: Set<String>
        var envVariables: [String]
    }

    /// The entry in the target's dialect and the secrets to store. Only the list of the chosen
    /// transport is used (env for stdio, headers for remote servers).
    static func entry(for draft: MCPDraft, target: MCPWriteTarget, mode: MCPSecretMode,
                      notes: inout [String]) throws -> BuiltEntry {
        var result = BuiltEntry(entry: [:], secrets: [], keptAccounts: [], envVariables: [])
        let piOnly = target.harnesses == [.pi]
        let claudeOnly = target.harnesses == [.claudeCode]
        let openCode = target.dialect == .openCode
        let stdio = draft.transport == .stdio
        func reference(_ variable: String) -> String {
            if mode == .environment || !stdio { result.envVariables.append(variable) }
            return openCode ? "{env:\(variable)}" : "${\(variable)}"
        }
        /// Stores a new value, moves a hidden literal into the Keychain, or keeps the item.
        func secret(_ value: MCPDraft.Value, _ variable: String) throws {
            guard KeychainSecretStore.isVariableName(variable) else {
                throw ConfigTextError("“\(variable)” can't be a Keychain name (letters, digits, _).")
            }
            if !value.value.isEmpty { result.secrets.append((variable, value.value)) }
            else if let literal = value.existingLiteral { result.secrets.append((variable, literal)) }
            else { result.keptAccounts.insert(variable) }
        }
        /// The value to write as is: typed text, or the file's own value (type kept).
        func plain(_ value: MCPDraft.Value) -> Any {
            guard value.value.isEmpty else { return value.value }
            if let json = value.existingJSON,
               let original = try? JSONSerialization.jsonObject(with: Data(json.utf8), options: [.fragmentsAllowed]) {
                return original
            }
            return value.existingLiteral ?? ""
        }

        // A headersHelper that isn't AKit's own stays; secret headers then go through ${VAR}.
        let foreignHelper = draft.preservedJSON
            .flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }?["headersHelper"] != nil
        var plainValues: [String: Any] = [:]
        var wrapped: [(key: String, account: String)] = []
        var helperHeaders: [(String, String)] = []
        for value in draft.activeValues {
            let key = value.key.trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { continue }
            guard value.isSecret else { plainValues[key] = plain(value); continue }
            if stdio {
                let variable = draft.variable(for: value, isHeader: false, lookup: mode == .keychainLookup)
                try secret(value, variable)
                switch mode {
                case .environment: plainValues[key] = reference(variable)
                case .keychainLookup where piOnly: plainValues[key] = "!" + KeychainSecretStore.lookupCommand(variable)
                case .keychainLookup: wrapped.append((key, variable))
                }
            } else {
                let variable = draft.variable(for: value, isHeader: true)
                try secret(value, variable)
                if mode == .keychainLookup, piOnly {
                    plainValues[key] = "!" + KeychainSecretStore.lookupCommand(variable)
                } else if mode == .keychainLookup, claudeOnly, !foreignHelper {
                    // printf puts the value into JSON unescaped.
                    let typed = value.value.isEmpty ? value.existingLiteral ?? "" : value.value
                    if typed.contains(where: { $0 == "\"" || $0 == "\\" || $0.isNewline }) {
                        throw ConfigTextError("Header \(key): a value with quotes or backslashes can't go through a Keychain lookup. Use the ${VAR} option.")
                    }
                    helperHeaders.append((key, variable))
                } else {
                    if mode == .keychainLookup, foreignHelper, claudeOnly {
                        notes.append("Header \(key): the entry has its own headersHelper, which AKit keeps, so the header reads ${\(variable)} from the environment.")
                    } else if mode == .keychainLookup {
                        notes.append("Header \(key): \(target.harnesses.map(\.displayName).joined(separator: " and ")) can't run a command for it, so it reads ${\(variable)} from the environment.")
                    }
                    plainValues[key] = reference(variable)
                }
            }
        }

        var command = draft.command.trimmingCharacters(in: .whitespaces)
        var arguments = draft.arguments
        if !wrapped.isEmpty {
            // sh -c 'KEY="$(security …)" && export KEY && exec "$0" "$@"' command args…
            arguments = ["-c", KeychainSecretStore.wrapperScript(wrapped), command] + arguments
            command = "/bin/sh"
        }

        var entry: [String: Any] = [:]
        if let preserved = draft.preservedJSON,
           let fields = try? JSONSerialization.jsonObject(with: Data(preserved.utf8)) as? [String: Any] {
            entry = fields
        }
        if openCode {
            if stdio {
                entry["type"] = "local"
                entry["command"] = [command] + arguments
                if !plainValues.isEmpty { entry["environment"] = plainValues }
            } else {
                entry["type"] = "remote"
                entry["url"] = draft.url.trimmingCharacters(in: .whitespaces)
                if !plainValues.isEmpty { entry["headers"] = plainValues }
            }
        } else {
            if !stdio || draft.writesStdioType { entry[draft.usesTransportKey ? "transport" : "type"] = draft.transport.rawValue }
            if stdio {
                entry["command"] = command
                if !arguments.isEmpty { entry["args"] = arguments }
                if !plainValues.isEmpty { entry["env"] = plainValues }
            } else {
                entry["url"] = draft.url.trimmingCharacters(in: .whitespaces)
                if !plainValues.isEmpty { entry["headers"] = plainValues }
                // Claude runs this and merges the printed JSON object into the headers.
                if !helperHeaders.isEmpty { entry["headersHelper"] = try KeychainSecretStore.helperCommand(helperHeaders) }
            }
        }
        result.entry = entry
        result.envVariables = Array(Set(result.envVariables)).sorted()
        return result
    }

    // MARK: - Apply

    public struct Outcome: Sendable {
        public let backup: URL?
        public let notes: [String]
    }

    /// Backs the file up, writes it (or asks Claude's CLI to), then stores the secrets, so a
    /// failed write never leaves another server's Keychain item changed.
    /// `runClaude` runs `claude` with arguments in a folder and throws when it fails.
    public static func apply(_ plan: MCPWritePlan, secrets store: SecretStore, home: URL,
                             runClaude: @Sendable (_ arguments: [String], _ directory: URL?) async throws -> Void)
        async throws -> Outcome {
        let target = plan.target
        let where_ = FileWalk.tilde(target.file, home: home)
        if let before = plan.before {
            let now = (try? String(contentsOf: target.file, encoding: .utf8)) ?? ""
            guard now == before || target.claudeScope != nil else {
                throw ConfigTextError("\(where_) changed after the preview. Check the diff again.")
            }
        }
        let backup = try backUp(target.file, home: home)
        let backupNote = backup.map { " A backup is in \(FileWalk.tilde($0, home: home))." } ?? ""

        /// Secrets are stored once the entry that uses them is written.
        func saveSecrets() throws {
            do {
                for secret in plan.secrets { try store.save(secret.value, for: secret.account) }
            } catch {
                throw ConfigTextError("The config was saved, but the Keychain wasn't: \(error.localizedDescription) Use “Set in Keychain…” on the server.\(backupNote)")
            }
        }
        func failed(_ error: Error, _ extra: String = "") -> ConfigTextError {
            ConfigTextError("\(error.localizedDescription)\(extra)\(backupNote)")
        }

        if let scope = target.claudeScope {
            var directory: URL?
            if case .project(let url) = target.scope { directory = url }
            if plan.isRemoval {
                do { try await runClaude(["mcp", "remove", "--scope", scope, plan.name], directory) } catch { throw failed(error) }
            } else if let original = plan.originalName, original != plan.name {
                // Rename: add the new entry first, so a failure loses nothing.
                do { try await runClaude(["mcp", "add-json", "--scope", scope, plan.name, plan.entryCompact], directory) }
                catch { throw failed(error) }
                try saveSecrets()
                do { try await runClaude(["mcp", "remove", "--scope", scope, original], directory) }
                catch { throw failed(error, " “\(plan.name)” was added, but the old “\(original)” is still there.") }
            } else {
                if plan.replaces {
                    do { try await runClaude(["mcp", "remove", "--scope", scope, plan.name], directory) } catch { throw failed(error) }
                }
                do {
                    try await runClaude(["mcp", "add-json", "--scope", scope, plan.name, plan.entryCompact], directory)
                } catch {
                    // Put the old entry back so the server isn't lost.
                    guard let original = plan.originalCompact else { throw failed(error) }
                    let restored = (try? await runClaude(["mcp", "add-json", "--scope", scope, plan.name, original], directory)) != nil
                    throw failed(error, restored ? " The old entry was put back."
                                                 : " Putting the old entry back failed too; restore it from the backup.")
                }
                try saveSecrets()
            }
        } else if let after = plan.after {
            try write(after, to: target.file)
            try saveSecrets()
        }

        var notes: [String] = []
        if !plan.envVariables.isEmpty {
            try updateEnvFile(adding: plan.envVariables, home: home)
            if !isEnvFileSourced(home: home) { notes.append(sourceHint) }
        }
        return Outcome(backup: backup, notes: notes)
    }

    /// `apply` with the real `claude` CLI of `claude` (Claude Code's installation), run with
    /// `env`'s variables and PATH. A failure shows the CLI's output with secrets masked.
    public static func apply(_ plan: MCPWritePlan, claude: HarnessInstallation?, secrets store: SecretStore,
                             env: HarnessEnvironment) async throws -> Outcome {
        let claude = claude?.executableURL
        return try await apply(plan, secrets: store, home: env.homeDirectory) { arguments, directory in
            guard let claude else { throw NSError(domain: "AKit", code: 3, userInfo: [NSLocalizedDescriptionKey: "The claude command was not found."]) }
            var environment = env.variables
            environment["PATH"] = env.pathForChildProcesses
            guard let result = await ProcessRunner.run(claude, arguments: arguments, directory: directory,
                                                       environment: environment, timeout: 30) else {
                throw NSError(domain: "AKit", code: 3, userInfo: [NSLocalizedDescriptionKey: "claude couldn't be started."])
            }
            guard result.succeeded else {
                let output = SecretFilter.masked(result.output.trimmingCharacters(in: .whitespacesAndNewlines))
                throw NSError(domain: "AKit", code: 3, userInfo: [NSLocalizedDescriptionKey:
                    "claude \(arguments.prefix(2).joined(separator: " ")) failed: \(output)"])
            }
        }
    }

    /// Writes through a symlink to the real file and keeps its permissions (a 0600 config stays 0600).
    static func write(_ text: String, to file: URL) throws {
        let real = file.resolvingSymlinksInPath()
        let fm = FileManager.default
        let permissions = (try? fm.attributesOfItem(atPath: real.path))?[.posixPermissions]
        try fm.createDirectory(at: real.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: real, options: .atomic)
        if let permissions { try fm.setAttributes([.posixPermissions: permissions], ofItemAtPath: real.path) }
    }

    /// Saves one secret (the "Set in Keychain" button) and exports it from `~/.akit/env.sh`.
    /// Returns hints for the user.
    public static func storeSecret(_ value: String, for account: String, in store: SecretStore, home: URL) throws -> [String] {
        guard KeychainSecretStore.isVariableName(account) else {
            throw ConfigTextError("\(account) is not a valid variable name.")
        }
        guard !value.isEmpty else { throw ConfigTextError("The value is empty.") }
        try store.save(value, for: account)
        try updateEnvFile(adding: [account], home: home)
        return isEnvFileSourced(home: home) ? [] : [sourceHint]
    }

    public static let sourceLine = "source ~/\(envFileName)"
    static let sourceHint = "Add `source ~/\(envFileName)` to ~/.zshrc so terminals export it; harnesses started from the Dock don't read ~/.zshrc."

    /// Whether a shell startup file sources AKit's env file.
    public static func isEnvFileSourced(home: URL) -> Bool {
        [".zshrc", ".zprofile", ".zshenv", ".bashrc", ".bash_profile"].contains { name in
            ((try? String(contentsOf: home.appending(path: name), encoding: .utf8)) ?? "").contains("akit/env.sh")
        }
    }

    /// Copies the file to `~/.akit/backups/<time>/<path>`; never overwrites an older backup.
    static func backUp(_ file: URL, home: URL) throws -> URL? {
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        return try Backup.copy(file, into: try Backup.newFolder(home: home), home: home)
    }

    /// `~/.akit/env.sh`: one Keychain lookup per variable, no secret values. Only plain
    /// variable names get in, whatever an older file or a caller holds.
    static func updateEnvFile(adding variables: [String], home: URL) throws {
        let url = home.appending(path: envFileName)
        var known = Set<String>()
        let existing = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        for line in existing.split(separator: "\n") where line.hasPrefix("export ") {
            if let name = line.dropFirst(7).split(separator: "=").first { known.insert(String(name)) }
        }
        known.formUnion(variables)
        let names = known.filter(KeychainSecretStore.isVariableName).sorted()
        let lines = ["# Written by AKit. Exports MCP secrets from the Keychain (service \"\(KeychainSecretStore.service)\").",
                     "# Source it from ~/.zshrc: source ~/\(envFileName)"]
            + names.map { "export \($0)=\"$(\(KeychainSecretStore.lookupCommand($0)) 2>/dev/null)\"" }
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

    /// Sets (or with nil removes) `name` in the table at `path`.
    static func set(_ entry: [String: Any]?, named name: String, at path: ArraySlice<String>, in object: inout [String: Any]) {
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
