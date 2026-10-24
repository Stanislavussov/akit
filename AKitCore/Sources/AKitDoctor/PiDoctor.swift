import AKitFoundation
import AKitHarnesses
import AKitInstructions
import AKitModel
import AKitSkills
import Foundation

/// `akit doctor pi` and the Overview's Check Pi… sheet: a read-only check of Pi's setup, in the
/// shape of Claude Code's `claude doctor` / `/doctor` (install, settings, environment, MCP,
/// context size; each problem with what to do). Facts come from the docs shipped in Pi 1.0.x
/// (`docs/settings.md`, `configuration.md`, `environment-variables.md`, `mcp.md`, `packages.md`,
/// `extensions.md`, `skills.md`, `keybindings.md`, `models.md`, `cli.md`); a few from its
/// `dist/` where the docs are silent, each marked where it is used.
///
/// Offline by default. The live part (`live: true`) runs `pi mcp list --json` and
/// `pi auth check --provider <defaultProvider> --json --no-refresh`, never `--credentials`.
/// Never a secret: auth.json, models-store.json and mcp-auth.json are not read, models.json is
/// only parsed, MCP `env` and `headers` show only their key names, and the text goes through
/// `SecretFilter.masked`.
public enum PiDoctor {
    public enum Level: String, Codable, Sendable {
        case ok, warning, problem
    }

    public struct Line: Codable, Hashable, Sendable {
        public let level: Level
        public let text: String
        /// What to do; nil for an ok line.
        public let fix: String?

        public init(_ level: Level, _ text: String, fix: String? = nil) {
            self.level = level
            self.text = text
            self.fix = fix
        }
    }

    public struct Section: Codable, Hashable, Sendable, Identifiable {
        public let title: String
        public var lines: [Line]
        public var id: String { title }
    }

    public struct Report: Codable, Sendable {
        public let sections: [Section]
        /// The live part ran (Servers and Sign-In).
        public let live: Bool

        public var problems: Int { sections.reduce(0) { $0 + $1.lines.filter { $0.level == .problem }.count } }
        public var warnings: Int { sections.reduce(0) { $0 + $1.lines.filter { $0.level == .warning }.count } }

        /// Plain text like `akit doctor`: `!` starts a problem, `?` a warning, `→` what to do.
        public var text: String {
            var lines = ["Pi doctor (lines starting with ! are problems, ? warnings; → what to do)"]
            for section in sections {
                lines += ["", section.title]
                for line in section.lines {
                    let mark = switch line.level { case .ok: " "; case .warning: "?"; case .problem: "!" }
                    lines.append("\(mark) \(line.text)")
                    if let fix = line.fix { lines.append("    → \(fix)") }
                }
            }
            lines.append("")
            let warned = warnings == 0 ? "" : " \(warnings) warning\(warnings == 1 ? "" : "s")."
            lines.append(problems == 0 ? "No problems found.\(warned)"
                         : "\(problems) problem\(problems == 1 ? "" : "s") found.\(warned)")
            return SecretFilter.masked(lines.joined(separator: "\n"))
        }

        /// One line for `akit doctor`'s Tools section.
        public var summary: String {
            problems == 0 && warnings == 0 ? "no problems"
                : "\(problems) problem\(problems == 1 ? "" : "s"), \(warnings) warning\(warnings == 1 ? "" : "s")"
        }
    }

    /// What a program printed (stdout and stderr together) and how it ended.
    public struct RunOutput: Sendable {
        public let status: Int32
        public let timedOut: Bool
        public let output: String

        public init(status: Int32, timedOut: Bool = false, output: String) {
            self.status = status
            self.timedOut = timedOut
            self.output = output
        }
    }

    /// Runs `pi` (tests inject a fake). nil: it couldn't be started.
    public typealias Runner = @Sendable (_ executable: URL, _ arguments: [String], _ directory: URL,
                                         _ timeout: TimeInterval) async -> RunOutput?

    /// The real one: ProcessRunner with the PATH a mise shim needs.
    public static func processRunner(env: HarnessEnvironment) -> Runner {
        { executable, arguments, directory, timeout in
            var variables = env.variables
            variables["PATH"] = env.pathForChildProcesses
            variables["NO_COLOR"] = "1"
            guard let result = await ProcessRunner.run(executable, arguments: arguments, directory: directory,
                                                       environment: variables, timeout: timeout) else { return nil }
            return RunOutput(status: result.status, timedOut: result.timedOut, output: result.output)
        }
    }

    /// The whole check. `projects`: folders whose `.pi/settings.json`, `.pi/mcp.json` and
    /// packages are checked too; nil: the projects Pi knows (its session headers).
    public static func check(env: HarnessEnvironment, projects: [URL]? = nil, live: Bool = false,
                             runner: Runner? = nil) async -> Report {
        let run = runner ?? processRunner(env: env)
        var check = Check(env: env)
        let executable = env.findExecutable("pi")
        let configRoot = env.piAgentDirectory
        await check.install(executable: executable, run: run)
        guard executable != nil || FileWalk.isDirectory(configRoot) else {
            return Report(sections: check.sections, live: false)
        }
        let projects = projects ?? PiDoctor.knownProjects(env: env)
        let settings = check.settings(projects: projects)
        check.environment()
        check.mcp(projects: projects)
        check.packages(settings: settings, projects: projects)
        check.skills()
        check.context()
        check.keybindings()
        if live {
            await check.live(executable: executable, provider: settings?["defaultProvider"] as? String, run: run)
        }
        return Report(sections: check.sections, live: live)
    }

    /// Project folders Pi has sessions for.
    static func knownProjects(env: HarnessEnvironment) -> [URL] {
        guard let adapter = HarnessCatalog.adapter(for: .pi), let pi = adapter.detect(in: env) else { return [] }
        return SkillScanner.projects(installations: [pi], adapters: [adapter], in: env)
    }

    // MARK: - Facts from Pi's docs

    /// Every setting in `docs/settings.md` (nested ones dotted). An object-valued setting whose
    /// keys are the user's own (`modelThinkingLevels`, …) is one entry.
    static let documentedSettings: Set<String> = [
        "defaultProvider", "defaultModel", "defaultThinkingLevel", "modelThinkingLevels", "thinkingBudgets",
        "enabledModels", "hideThinkingBlock", "showCacheMissNotices", "cacheWarming",
        "steeringMode", "followUpMode", "externalEditor", "doubleEscapeAction", "treeFilterMode", "defaultProjectTrust",
        "defaultTools", "codemode.mode", "codemode.inlineBudget",
        "sessionDir", "compaction.enabled", "compaction.reserveTokens", "compaction.keepRecentTokens",
        "compaction.modelOverrides", "branchSummary.reserveTokens", "branchSummary.skipPrompt",
        "theme", "quietStartup", "tuiMode", "fullscreenExitOutput", "fullscreenScrollbar", "fullscreenCopyOnSelect",
        "fullscreenWheelScrollLines", "editorPaddingX", "outputPad", "autocompleteMaxVisible", "showHardwareCursor",
        "terminal.showImages", "terminal.imageWidthCells", "terminal.clearOnShrink", "terminal.showTerminalProgress",
        "terminal.hyperlinks", "terminal.images", "terminal.trueColor", "images.autoResize", "images.blockImages",
        "markdown.codeBlockIndent", "markdown.mermaid",
        "transport", "httpProxy", "httpIdleTimeoutMs", "websocketConnectTimeoutMs", "retry.enabled", "retry.maxRetries",
        "retry.baseDelayMs", "retry.maxAgentDelayMs", "retry.provider.timeoutMs", "retry.provider.maxRetries",
        "retry.provider.maxRetryDelayMs",
        "shellPath", "shellCommandPrefix", "npmCommand",
        "packages", "extensions", "skills", "prompts", "themes", "enableSkillCommands",
        "collapseChangelog", "enableInstallTelemetry", "enableAnalytics", "warnings.anthropicExtraUsage",
    ]

    /// Keys Pi writes itself, not in settings.md (the `Settings` type in `dist/core/settings-manager.d.ts`, 1.0.4).
    static let piWrittenSettings: Set<String> = ["lastChangelogVersion", "trackingId", "deviceId"]

    /// settings.md: "Can only be set in agent-directory settings" / "Global setting only".
    static let globalOnlySettings: Set<String> = ["defaultProjectTrust", "httpProxy", "cacheWarming"]

    /// What a setting with a fixed set of values may hold (settings.md's type column).
    struct Allowed {
        var strings: Set<String> = []
        var bool = false
        var numbers: ClosedRange<Int>?

        func accepts(_ value: Any) -> Bool {
            if isBool(value) { return bool }
            if let text = value as? String { return strings.contains(text) }
            if let number = value as? NSNumber, let numbers {
                let double = number.doubleValue
                return double == double.rounded() && numbers.contains(Int(double))
            }
            return false
        }

        var description: String {
            var parts = strings.sorted().map { "\"\($0)\"" }
            if bool { parts += ["true", "false"] }
            if let numbers { parts.append(numbers.lowerBound == numbers.upperBound ? "\(numbers.lowerBound)" : "\(numbers.lowerBound)–\(numbers.upperBound)") }
            return parts.joined(separator: ", ")
        }
    }

    static let thinkingLevels: Set<String> = ["off", "minimal", "low", "medium", "high", "xhigh", "max"]

    static let allowedSettings: [String: Allowed] = [
        "defaultThinkingLevel": Allowed(strings: thinkingLevels),
        "cacheWarming": Allowed(strings: ["off", "streaming", "idle"]),
        "steeringMode": Allowed(strings: ["all", "one-at-a-time"]),
        "followUpMode": Allowed(strings: ["all", "one-at-a-time"]),
        "doubleEscapeAction": Allowed(strings: ["tree", "fork", "none"]),
        "treeFilterMode": Allowed(strings: ["default", "no-tools", "user-only", "labeled-only", "all"]),
        "defaultProjectTrust": Allowed(strings: ["ask", "always", "never"]),
        "codemode.mode": Allowed(strings: ["on", "only"]),
        "quietStartup": Allowed(strings: ["header"], bool: true),
        "tuiMode": Allowed(strings: ["regular", "fullscreen"]),
        "fullscreenExitOutput": Allowed(strings: ["transcript", "resume-hint"]),
        "fullscreenScrollbar": Allowed(strings: ["auto", "always", "hidden"]),
        "fullscreenWheelScrollLines": Allowed(strings: ["auto"], numbers: 1...100),
        "editorPaddingX": Allowed(numbers: 0...3),
        "outputPad": Allowed(numbers: 0...1),
        "autocompleteMaxVisible": Allowed(numbers: 3...20),
        "terminal.hyperlinks": Allowed(strings: ["auto"], bool: true),
        "terminal.trueColor": Allowed(strings: ["auto"], bool: true),
        // `"kitty" | "iterm2" | "auto" | false`: true isn't listed, but a bool is the closest check.
        "terminal.images": Allowed(strings: ["kitty", "iterm2", "auto"], bool: true),
        "markdown.mermaid": Allowed(strings: ["off", "final", "streaming"]),
        "transport": Allowed(strings: ["auto", "sse", "websocket", "websocket-cached"]),
    ]

    /// environment-variables.md: variables Pi reads whose valid values the docs list.
    static let allowedVariables: [String: Set<String>] = [
        "PI_TELEMETRY": ["1", "true", "yes", "0", "false", "no"],
        "PI_CACHE_RETENTION": ["long"],
        "PI_HARDWARE_CURSOR": ["1"],
        "PI_HYPERLINKS": ["1", "0", "auto"],
        "PI_IMAGE_PROTOCOL": ["kitty", "iterm2", "none", "auto"],
        "PI_TRUE_COLOR": ["1", "0", "auto"],
    ]

    /// environment-variables.md: the other variables Pi itself reads; shown when set.
    static let otherVariables = ["PI_OFFLINE", "PI_SKIP_VERSION_CHECK", "PI_PACKAGE_DIR", "PI_SHARE_VIEWER_URL",
                                 "PI_RADIUS_GATEWAY", "PI_TUI_ESC_TIMEOUT"]

    /// Claude Code's `/doctor` warns about a CLAUDE.md over 40,000 characters ("Large CLAUDE.md
    /// will impact performance"); Pi has no such check, so AKit uses the same line.
    static let largeInstructions = 40_000

    /// mcp.md: server names use letters, digits, `_` and `-`.
    static func isServerName(_ name: String) -> Bool {
        !name.isEmpty && name.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }
    }
    /// mcp.md "Control tool exposure" (`codemode-deferred` is an alias of `codemode`).
    static let exposures: Set<String> = ["codemode", "deferred", "direct", "hidden", "codemode-deferred"]
    /// A project entry without command, url or type changes only these keys of the global server
    /// (mcp.md; the list is `OVERRIDE_KEYS` in `dist/extensions/mcp/config.js`).
    static let overrideKeys: Set<String> = ["enabled", "exposure", "toolExposure"]

    /// keybindings.md "Key syntax".
    static let modifiers: Set<String> = ["ctrl", "shift", "alt", "super"]
    static let keys: Set<String> = {
        var keys = Set("abcdefghijklmnopqrstuvwxyz0123456789".map(String.init))
        keys.formUnion(["escape", "esc", "enter", "return", "tab", "space", "backspace", "delete", "insert", "clear",
                        "home", "end", "pageup", "pagedown", "up", "down", "left", "right"])
        keys.formUnion((1...12).map { "f\($0)" })
        keys.formUnion("`-=[]\\;',./!@#$%^&*()_+|~{}:<>?".map(String.init))
        return keys
    }()

    /// Whether a key string follows keybindings.md's syntax (`ctrl+shift+x`, `ctrl++`).
    static func isValidKey(_ text: String) -> Bool {
        var mods: [Substring]
        let key: String
        if text.hasSuffix("++") || text == "+" {
            key = "+"
            mods = text.dropLast(text == "+" ? 1 : 2).split(separator: "+", omittingEmptySubsequences: false)
            if mods == [""] { mods = [] }
        } else {
            let parts = text.split(separator: "+", omittingEmptySubsequences: false)
            guard let last = parts.last else { return false }
            key = String(last)
            mods = Array(parts.dropLast())
        }
        return keys.contains(key.lowercased()) && mods.allSatisfy { modifiers.contains($0.lowercased()) }
    }

    static func isBool(_ value: Any) -> Bool {
        guard let number = value as? NSNumber else { return false }
        return CFGetTypeID(number) == CFBooleanGetTypeID()
    }

    // MARK: - The checks

    struct Check {
        let env: HarnessEnvironment
        var sections: [Section] = []

        var home: URL { env.homeDirectory }
        var configRoot: URL { env.piAgentDirectory }
        func tilde(_ url: URL) -> String { FileWalk.tilde(url.standardizedFileURL, home: home.standardizedFileURL) }

        mutating func add(_ title: String, _ lines: [Line]) {
            sections.append(Section(title: title, lines: lines))
        }

        /// A JSON file: nil when it doesn't exist; the error text when it can't be parsed.
        func readJSON(_ url: URL, jsonc: Bool = false) -> Result<[String: Any], ConfigTextError>? {
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            guard FileWalk.isRegularFile(url) else { return .failure(ConfigTextError("not a regular file")) }
            guard let data = FileWalk.head(of: url, limit: (8 << 20) + 1), data.count <= 8 << 20 else {
                return .failure(ConfigTextError("larger than 8 MB"))
            }
            do {
                return .success(try ConfigText.jsonObject(data, jsonc: jsonc))
            } catch let error as ConfigTextError {
                return .failure(error)
            } catch {
                // JSONSerialization's own text names the line; it never holds the file's values.
                let text = (error as NSError).userInfo[NSDebugDescriptionErrorKey] as? String ?? "not valid JSON"
                return .failure(ConfigTextError(text))
            }
        }

        // MARK: Install

        mutating func install(executable: URL?, run: Runner) async {
            var lines: [Line] = []
            let fm = FileManager.default
            if let executable {
                let version = await run(executable, ["--version"], home, 10).flatMap { result -> String? in
                    guard result.status == 0, !result.timedOut else { return nil }
                    return result.output.split(whereSeparator: \.isNewline)
                        .map { $0.trimmingCharacters(in: .whitespaces) }
                        .first { !$0.isEmpty && $0.contains(where: \.isNumber) }
                }
                if let version {
                    lines.append(Line(.ok, "pi: \(tilde(executable)), version \(version)"))
                } else {
                    lines.append(Line(.problem, "pi: \(tilde(executable)) doesn't answer pi --version",
                                      fix: "Run pi --version in a terminal; reinstall Pi if it fails (npm install -g @earendil-works/pi-coding-agent)."))
                }
            } else {
                lines.append(Line(.problem, "pi isn't on PATH",
                                  fix: "Install Pi (npm install -g @earendil-works/pi-coding-agent) or add its folder to PATH."))
            }
            // Every pi on PATH, like `which -a pi`. A version manager's shim (a `shims` folder:
            // mise, asdf) starts the version it picks, so it isn't an installation of its own.
            var seen: Set<String> = []
            var targets: [String: [URL]] = [:]
            var all: [URL] = []
            for folder in env.executableSearchPaths {
                let candidate = folder.appending(path: "pi")
                guard fm.isExecutableFile(atPath: candidate.path), seen.insert(candidate.standardizedFileURL.path).inserted else { continue }
                all.append(candidate)
                if folder.lastPathComponent == "shims" { continue }
                targets[FileWalk.realPath(candidate) ?? candidate.path, default: []].append(candidate)
            }
            if all.count > 1 {
                lines.append(Line(.ok, "on PATH, in order: \(all.map { tilde($0) + ($0.deletingLastPathComponent().lastPathComponent == "shims" ? " (shim)" : "") }.joined(separator: ", "))"))
            }
            if targets.count > 1 {
                let list = targets.keys.sorted().map { tilde(URL(filePath: $0)) }.joined(separator: ", ")
                lines.append(Line(.warning, "\(targets.count) different Pi installations: \(list)",
                                  fix: "The first one on PATH runs. Remove the ones you don't use, so updates reach the one that runs."))
            }
            for name in ["PI_CODING_AGENT_DIR", "PI_CODING_AGENT_SESSION_DIR"] {
                guard let value = env.variables[name], !value.isEmpty else { continue }
                let url = env.expand(value)
                if FileWalk.isDirectory(url) {
                    lines.append(Line(.ok, "\(name)=\(tilde(url))"))
                } else {
                    lines.append(Line(.warning, "\(name)=\(tilde(url)), which doesn't exist",
                                      fix: "Fix the variable in your shell profile, or remove it to use Pi's default folder."))
                }
            }
            if FileWalk.isDirectory(configRoot) {
                lines.append(Line(.ok, "config folder: \(tilde(configRoot))"))
            } else if executable != nil {
                lines.append(Line(.warning, "config folder \(tilde(configRoot)) doesn't exist yet",
                                  fix: "Start pi once; it creates the folder."))
            }
            add("Install", lines)
        }

        // MARK: Settings

        /// Returns the global settings (nil when missing or broken).
        mutating func settings(projects: [URL]) -> [String: Any]? {
            var lines: [Line] = []
            let file = configRoot.appending(path: "settings.json")
            let global = settingsLines(file, global: true, into: &lines)
            if global == nil, !FileManager.default.fileExists(atPath: file.path) {
                lines.append(Line(.ok, "\(tilde(file)): none, Pi uses its defaults"))
            }
            if let global {
                let provider = global["defaultProvider"] as? String, model = global["defaultModel"] as? String
                if provider == nil && model == nil {
                    lines.append(Line(.ok, "default model: not set, Pi picks one at start"))
                } else {
                    lines.append(Line(.ok, "default model: \([provider, model].compactMap(\.self).joined(separator: "/"))"))
                }
            }
            for project in projects {
                _ = settingsLines(project.appending(path: ".pi/settings.json"), global: false, into: &lines)
            }
            // models.md: endpoints and models; Pi reads it with comments allowed (dist/core/model-config.js).
            // Only parsed: it may hold API keys.
            let models = configRoot.appending(path: "models.json")
            switch readJSON(models, jsonc: true) {
            case nil: break
            case .success: lines.append(Line(.ok, "\(tilde(models)): readable"))
            case .failure(let error):
                lines.append(Line(.problem, "\(tilde(models)) can't be read: \(error.errorDescription ?? "not valid JSON")",
                                  fix: "Fix the JSON; Pi can't load your custom models and endpoints until then."))
            }
            add("Settings", lines)
            return global
        }

        func settingsLines(_ file: URL, global: Bool, into lines: inout [Line]) -> [String: Any]? {
            guard let read = readJSON(file) else { return nil }
            let name = tilde(file)
            switch read {
            case .failure(let error):
                lines.append(Line(.problem, "\(name) can't be read: \(error.errorDescription ?? "not valid JSON")",
                                  fix: "Fix the JSON. Pi reports a broken settings file at start and doesn't use it."))
                return nil
            case .success(let settings):
                var found: [Line] = []
                walk(settings, prefix: "", file: name, global: global, into: &found)
                if let levels = settings["modelThinkingLevels"] as? [String: Any] {
                    for (model, level) in levels.sorted(by: { $0.key < $1.key }) where !((level as? String).map(thinkingLevels.contains) ?? false) {
                        found.append(Line(.problem, "\(name): modelThinkingLevels[\"\(model)\"] is not a thinking level",
                                          fix: "Use one of \(thinkingLevels.sorted().joined(separator: ", ")) (settings.md)."))
                    }
                }
                lines.append(contentsOf: found.isEmpty ? [Line(.ok, "\(name): \(settings.count) setting\(settings.count == 1 ? "" : "s"), all known")] : found)
                return settings
            }
        }

        /// Unknown keys, values outside the documented ones, global-only keys in a project.
        func walk(_ object: [String: Any], prefix: String, file: String, global: Bool, into lines: inout [Line]) {
            for key in object.keys.sorted() {
                let path = prefix + key
                let value = object[key]!
                if prefix.isEmpty, PiDoctor.piWrittenSettings.contains(key) { continue }
                if PiDoctor.documentedSettings.contains(path) {
                    if let allowed = PiDoctor.allowedSettings[path], !allowed.accepts(value) {
                        lines.append(Line(.problem, "\(file): \(path) has a value Pi doesn't know",
                                          fix: "Use one of \(allowed.description) (settings.md)."))
                    }
                    if !global, PiDoctor.globalOnlySettings.contains(path) {
                        lines.append(Line(.warning, "\(file): \(path) works only in \(tilde(configRoot.appending(path: "settings.json")))",
                                          fix: "Move it to the global settings; Pi ignores it in a project."))
                    }
                } else if let nested = value as? [String: Any],
                          PiDoctor.documentedSettings.contains(where: { $0.hasPrefix(path + ".") }) {
                    walk(nested, prefix: path + ".", file: file, global: global, into: &lines)
                } else {
                    lines.append(Line(.warning, "\(file): unknown key \(path)",
                                      fix: "Not in Pi's settings reference (settings.md): check the spelling, or remove it."))
                }
            }
        }

        // MARK: Environment

        mutating func environment() {
            var lines: [Line] = []
            for (name, allowed) in PiDoctor.allowedVariables.sorted(by: { $0.key < $1.key }) {
                guard let value = env.variables[name] else { continue }
                if allowed.contains(value) {
                    lines.append(Line(.ok, "\(name)=\(value)"))
                } else {
                    lines.append(Line(.problem, "\(name) has a value Pi doesn't know",
                                      fix: "Use \(allowed.sorted().joined(separator: ", ")) (environment-variables.md), or unset it."))
                }
            }
            for name in PiDoctor.otherVariables {
                guard let value = env.variables[name] else { continue }
                if name == "PI_TUI_ESC_TIMEOUT", Int(value).map({ $0 < 0 }) ?? true {
                    lines.append(Line(.problem, "PI_TUI_ESC_TIMEOUT is not a number of milliseconds",
                                      fix: "Set it to a whole number like 50, or unset it (environment-variables.md)."))
                } else {
                    // URLs may carry a user and password: only that it is set.
                    lines.append(Line(.ok, name.hasSuffix("_URL") || name == "PI_RADIUS_GATEWAY" ? "\(name) is set" : "\(name)=\(value)"))
                }
            }
            if lines.isEmpty { lines.append(Line(.ok, "none of Pi's variables with fixed values is set")) }
            lines.append(Line(.ok, "only this process's environment: an app started from Finder doesn't see your shell's variables"))
            add("Environment", lines)
        }

        // MARK: MCP

        mutating func mcp(projects: [URL]) {
            var lines: [Line] = []
            let globalFile = configRoot.appending(path: "mcp.json")
            let globalNames = mcpFile(globalFile, project: false, globalNames: [], into: &lines)
            for project in projects {
                _ = mcpFile(project.appending(path: ".pi/mcp.json"), project: true, globalNames: globalNames, into: &lines)
            }
            add("MCP servers", lines)
        }

        /// The servers of one mcp.json, checked the way Pi 1.0.4 checks them (mcp.md "Configuration
        /// rules"; `validateMcpServerConfig` in dist/core/mcp-servers.js). Returns the server names.
        func mcpFile(_ file: URL, project: Bool, globalNames: Set<String>, into lines: inout [Line]) -> Set<String> {
            let name = tilde(file)
            guard let read = readJSON(file) else {
                if !project { lines.append(Line(.ok, "\(name): none")) }
                return []
            }
            guard case .success(let root) = read else {
                if case .failure(let error) = read {
                    lines.append(Line(.problem, "\(name) can't be read: \(error.errorDescription ?? "not valid JSON")",
                                      fix: "Fix the JSON; Pi connects none of its servers until then."))
                }
                return []
            }
            let rawServers = root["mcpServers"]
            if rawServers != nil, !(rawServers is [String: Any]) {
                lines.append(Line(.problem, "\(name): mcpServers is not an object",
                                  fix: "Write it as {\"mcpServers\": {\"name\": {…}}} (mcp.md)."))
                return []
            }
            if let auto = root["autoEnableCodemode"], !isBool(auto) {
                lines.append(Line(.problem, "\(name): autoEnableCodemode must be true or false"))
            }
            let servers = rawServers as? [String: Any] ?? [:]
            if servers.isEmpty {
                lines.append(Line(.ok, "\(name): no servers"))
                return []
            }
            var namespaces: [String: String] = [:]
            for server in servers.keys.sorted() {
                let before = lines.count
                let fix = "Fix the entry in \(name); Pi skips it and connects the others (mcp.md)."
                func problem(_ text: String, _ what: String? = nil) {
                    lines.append(Line(.problem, "\(name): server \"\(server)\" \(text)", fix: what ?? fix))
                }
                guard PiDoctor.isServerName(server) else {
                    problem("has an invalid name", "Use only letters, digits, _ and - in server names (mcp.md).")
                    continue
                }
                guard let entry = servers[server] as? [String: Any] else { problem("is not an object"); continue }
                // Names that differ only in - and _ share one tool namespace.
                let namespace = server.replacingOccurrences(of: "-", with: "_")
                if let other = namespaces[namespace] {
                    problem("clashes with \"\(other)\": names that differ only in - and _ count as one server",
                            "Rename one of them.")
                    continue
                }
                namespaces[namespace] = server
                let isOverride = entry["command"] == nil && entry["url"] == nil && entry["type"] == nil
                if project, isOverride {
                    let extra = Set(entry.keys).subtracting(PiDoctor.overrideKeys)
                    if !globalNames.contains(server) {
                        problem("has no command or url and there is no global server of that name to change")
                    } else if !extra.isEmpty {
                        problem("changes a global server but also sets \(extra.sorted().joined(separator: ", "))",
                                "An entry without command or url may only set enabled, exposure and toolExposure (mcp.md).")
                    }
                    continue
                }
                if let exposure = entry["exposure"], !((exposure as? String).map(PiDoctor.exposures.contains) ?? false) {
                    problem("has an unknown exposure", "Use codemode, deferred, direct or hidden (mcp.md).")
                }
                if let enabled = entry["enabled"], !isBool(enabled) { problem("has enabled that isn't true or false") }
                if let timeout = entry["timeout"], isBool(timeout) || !((timeout as? NSNumber).map { $0.doubleValue > 0 } ?? false) {
                    problem("has a timeout that isn't a positive number of seconds")
                }
                let type = entry["type"] as? String
                if type == "sse" {
                    problem("uses the SSE transport, which Pi doesn't support",
                            "Use the server's streamable HTTP URL (often /mcp instead of /sse).")
                    continue
                }
                if let type, !["stdio", "http", "streamable-http"].contains(type) {
                    problem("has an unknown type", "Use stdio, http or streamable-http, or leave type out (mcp.md).")
                    continue
                }
                let keys = { (key: String) -> String in
                    let names = (entry[key] as? [String: Any])?.keys.sorted() ?? []
                    return names.isEmpty ? "" : ", \(key): \(names.joined(separator: ", "))"
                }
                if let url = entry["url"] as? String, type == nil || type != "stdio" {
                    let scheme = URL(string: url)?.scheme?.lowercased()
                    if scheme != "http" && scheme != "https" { problem("has a url that isn't http or https") }
                    if let headers = entry["headers"], !((headers as? [String: Any])?.values.allSatisfy { $0 is String } ?? false) {
                        problem("has headers that aren't names with text values")
                    }
                    if lines.count == before {
                        let host = URL(string: url)?.host ?? "?"
                        lines.append(Line(.ok, "\(server): HTTP, \(host)\(keys("headers"))\(entry["enabled"] as? Bool == false ? ", off" : "")"))
                    }
                } else if let command = entry["command"] as? String {
                    if let args = entry["args"], !((args as? [Any])?.allSatisfy { $0 is String } ?? false) {
                        problem("has args that aren't a list of strings")
                    }
                    if let variables = entry["env"], !((variables as? [String: Any])?.values.allSatisfy { $0 is String } ?? false) {
                        problem("has env that isn't names with text values")
                    }
                    if entry["enabled"] as? Bool != false, !commandExists(command) {
                        let shellLine = command.contains(" ")
                        problem("runs \(command.split(separator: " ").first.map(String.init) ?? command), which isn't found\(shellLine ? " (command is one program, not a shell line)" : "")",
                                shellLine ? "Put the program in command and its arguments in args (mcp.md)."
                                    : "Install it, or give its full path in command. Pi starts it with your PATH.")
                    }
                    if lines.count == before {
                        lines.append(Line(.ok, "\(server): stdio, \(command)\(keys("env"))\(entry["enabled"] as? Bool == false ? ", off" : "")"))
                    }
                } else {
                    problem("needs either command (stdio) or url (streamable HTTP)")
                }
            }
            return Set(servers.keys)
        }

        /// A stdio command Pi can start: a path (a leading `~/` is home, mcp.md) or a program on PATH.
        func commandExists(_ command: String) -> Bool {
            if command.hasPrefix("~/") || command.contains("/") {
                return FileManager.default.isExecutableFile(atPath: env.expand(command).path)
            }
            return env.findExecutable(command) != nil
        }

        // MARK: Packages and extensions

        mutating func packages(settings: [String: Any]?, projects: [URL]) {
            var lines: [Line] = []
            let listing = PiPackages.list(configRoot: configRoot, projects: projects, in: env)
            for package in listing.packages {
                let place = package.scope == .global ? "" : " (\(tilde(package.settingsFile)))"
                if package.isInstalled {
                    lines.append(Line(.ok, "\(package.source): \(package.name)\(package.version.map { " \($0)" } ?? "")\(place)"))
                } else if package.kind == .local {
                    lines.append(Line(.problem, "\(package.source)\(place): the folder doesn't exist",
                                      fix: "Fix the path in packages, or remove the entry (pi remove \(package.source))."))
                } else {
                    lines.append(Line(.problem, "\(package.source)\(place) isn't installed",
                                      fix: "Run pi update --extensions to install the packages in settings (packages.md)."))
                }
            }
            if listing.packages.isEmpty { lines.append(Line(.ok, "no packages")) }
            lines += listing.notes.map { Line(.warning, $0) }
            // settings.md: `extensions` lists files or folders, resolved from the agent folder;
            // `!pattern`, `+path`, `-path` and globs filter; `builtin:<name>` are Pi's own.
            for entry in settings?["extensions"] as? [String] ?? [] {
                var path = entry
                if path.hasPrefix("+") { path.removeFirst() }
                if path.hasPrefix("-") || path.hasPrefix("!") || path.hasPrefix("builtin:")
                    || path.contains(where: { "*?[{".contains($0) }) { continue }
                let url = path.hasPrefix("~") || path.hasPrefix("/") ? env.expand(path) : configRoot.appending(path: path)
                if !FileManager.default.fileExists(atPath: url.path) {
                    lines.append(Line(.problem, "extensions entry \(entry): \(tilde(url)) doesn't exist",
                                      fix: "Fix or remove the entry in \(tilde(configRoot.appending(path: "settings.json")))."))
                }
            }
            // extensions.md / dist/core/extensions/loader.js: .ts and .js files, and folders with
            // a package.json whose pi.extensions exist, or an index.ts / index.js.
            let folder = configRoot.appending(path: "extensions")
            var loaded = 0
            for item in FileWalk.children(of: folder).sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                let name = item.lastPathComponent
                if name.hasPrefix(".") { continue }
                if FileWalk.isDirectory(item) {
                    if extensionEntries(in: item) {
                        loaded += 1
                    } else {
                        lines.append(Line(.warning, "extensions/\(name)/ has no index.ts, index.js or package.json with pi.extensions: Pi loads nothing from it",
                                          fix: "Fine when a package keeps its own files there; otherwise add the entry point or move it out."))
                    }
                } else if name.hasSuffix(".ts") || name.hasSuffix(".js") {
                    loaded += 1
                } else {
                    lines.append(Line(.warning, "extensions/\(name): not a .ts or .js file, Pi doesn't load it"))
                }
            }
            if FileWalk.isDirectory(folder) {
                lines.append(Line(.ok, "\(tilde(folder)): \(loaded) extension\(loaded == 1 ? "" : "s") Pi loads"))
            }
            add("Packages and extensions", lines)
        }

        func extensionEntries(in folder: URL) -> Bool {
            if let manifest = FileWalk.jsonObject(folder.appending(path: "package.json")),
               let declared = (manifest["pi"] as? [String: Any])?["extensions"] as? [String],
               declared.contains(where: { FileManager.default.fileExists(atPath: folder.appending(path: $0).path) }) {
                return true
            }
            return ["index.ts", "index.js"].contains { FileWalk.isRegularFile(folder.appending(path: $0)) }
        }

        // MARK: Skills

        /// What AKit's skill scanner finds for Pi in the global skills (a session adds one project's).
        mutating func skills() {
            var lines: [Line] = []
            guard let adapter = HarnessCatalog.adapter(for: .pi), let pi = adapter.detect(in: env) else { return }
            let skills = SkillScanner.scan(installations: [pi], adapters: [adapter], projects: [], in: env)
                .filter { $0.places[.pi] != nil }
            var listing = 0
            for skill in skills {
                let where_ = tilde(skill.file)
                if skill.visibleTo.contains(.pi) { listing += skill.name.count + skill.description.count }
                for warning in skill.warnings where warning.hasPrefix("Pi") {
                    let ignored = warning.hasPrefix("Pi ignores")
                    lines.append(Line(ignored ? .problem : .warning, "\(skill.name) (\(where_)): \(warning)",
                                      fix: ignored ? "Add a description to the frontmatter (skills.md)."
                                          : warning.contains("collides") ? "Pi keeps the first one it finds; rename or remove the other."
                                          : warning.contains("description") ? "Shorten the description to 1024 characters (skills.md)."
                                          : "Use lowercase letters, digits and single hyphens, at most 64 characters (skills.md)."))
                }
                // skills.md: Pi doesn't mind, but other Agent Skills tools may.
                if !skill.isSingleFile, let place = skill.places[.pi], place.folderName != skill.name {
                    lines.append(Line(.warning, "\(skill.name) (\(where_)): name differs from its folder \(place.folderName)",
                                      fix: "Pi doesn't mind; other Agent Skills tools want them equal (skills.md)."))
                }
            }
            let visible = skills.filter { $0.visibleTo.contains(.pi) }.count
            lines.insert(Line(.ok, "\(visible) global skill\(visible == 1 ? "" : "s"); names and descriptions ≈ \(listing) characters in every prompt (Pi sends them all)"), at: 0)
            add("Skills", lines)
        }

        // MARK: Context

        mutating func context() {
            var lines: [Line] = []
            let view = InstructionScanner.view(harness: .pi, project: nil, env: env)
            for entry in view.entries {
                let characters = entry.text.count
                if entry.status.isLoaded {
                    if characters > PiDoctor.largeInstructions {
                        lines.append(Line(.warning, "\(tilde(entry.file)): \(characters) characters, over \(PiDoctor.largeInstructions)",
                                          fix: "Every Pi session pays for it. Move rarely needed parts into skills (Instructions screen)."))
                    } else {
                        lines.append(Line(.ok, "\(tilde(entry.file)): \(characters) characters"))
                    }
                } else if case .skipped(let reason) = entry.status {
                    lines.append(Line(.ok, "\(tilde(entry.file)): skipped, \(reason)"))
                }
            }
            if view.entries.isEmpty { lines.append(Line(.ok, "no global AGENTS.md or CLAUDE.md")) }
            // configuration.md: SYSTEM.md replaces Pi's prompt, APPEND_SYSTEM.md adds to it.
            for (name, what) in [("SYSTEM.md", "replaces Pi's default system prompt"), ("APPEND_SYSTEM.md", "is added to Pi's system prompt")] {
                let file = configRoot.appending(path: name)
                if FileWalk.isRegularFile(file) { lines.append(Line(.ok, "\(tilde(file)) \(what)")) }
            }
            add("Context", lines)
        }

        // MARK: Keybindings

        mutating func keybindings() {
            let file = configRoot.appending(path: "keybindings.json")
            let name = tilde(file)
            guard let read = readJSON(file) else { return }
            var lines: [Line] = []
            switch read {
            case .failure(let error):
                lines.append(Line(.problem, "\(name) can't be read: \(error.errorDescription ?? "not valid JSON")",
                                  fix: "Fix the JSON; Pi uses its default keys until then."))
            case .success(let bindings):
                for action in bindings.keys.sorted() {
                    let value = bindings[action]!
                    let keys = (value as? String).map { [$0] } ?? (value as? [Any])?.compactMap { $0 as? String }
                    guard let keys, (value as? [Any])?.count ?? 1 == keys.count else {
                        lines.append(Line(.problem, "\(name): \(action) must be a key or a list of keys",
                                          fix: "Write \"ctrl+x\" or [\"ctrl+x\", \"alt+x\"] (keybindings.md)."))
                        continue
                    }
                    for key in keys where !PiDoctor.isValidKey(key) {
                        lines.append(Line(.warning, "\(name): \(action): \(key) isn't a key Pi knows",
                                          fix: "Write modifiers (ctrl, shift, alt, super) and one key, joined by + (keybindings.md)."))
                    }
                }
                if lines.isEmpty { lines.append(Line(.ok, "\(name): \(bindings.count) binding\(bindings.count == 1 ? "" : "s")")) }
            }
            add("Keybindings", lines)
        }

        // MARK: Live

        mutating func live(executable: URL?, provider: String?, run: Runner) async {
            var lines: [Line] = []
            guard let executable else {
                add("Servers and sign-in", [Line(.problem, "can't check: pi isn't on PATH")])
                return
            }
            // cli.md: `pi mcp list [--json]` connects to every enabled server; from home, so no project's .pi/mcp.json.
            let timeout: TimeInterval = 90
            if let result = await run(executable, ["mcp", "list", "--json"], home, timeout) {
                if result.timedOut {
                    lines.append(Line(.problem, "pi mcp list didn't finish in \(Int(timeout)) s",
                                      fix: "Run pi mcp list in a terminal to see which server hangs."))
                } else if let json = PiDoctor.jsonObject(in: result.output) {
                    lines += mcpListLines(json)
                } else {
                    lines.append(Line(.problem, "pi mcp list gave no JSON: \(PiDoctor.firstLine(result.output))",
                                      fix: "Run pi mcp list in a terminal."))
                }
            } else {
                lines.append(Line(.problem, "pi mcp list couldn't be started"))
            }
            // cli.md: `pi auth check` prints ready, not_ready or invalid. Never --credentials.
            if let provider, !provider.isEmpty {
                if let result = await run(executable, ["auth", "check", "--provider", provider, "--json", "--no-refresh"], home, 30) {
                    let status = PiDoctor.jsonObject(in: result.output)?["status"] as? String
                    switch status {
                    case "ready": lines.append(Line(.ok, "sign-in for \(provider): ready"))
                    case "not_ready":
                        lines.append(Line(.problem, "sign-in for \(provider): no usable credentials",
                                          fix: "Run pi and /login, or set the provider's API key variable (providers.md)."))
                    case "invalid":
                        lines.append(Line(.problem, "sign-in for \(provider): the credentials are invalid or expired",
                                          fix: "Run pi and /login again (an expired sign-in also refreshes when Pi starts)."))
                    default:
                        lines.append(Line(.problem, result.timedOut ? "pi auth check didn't finish in 30 s"
                                          : "pi auth check: \(PiDoctor.firstLine(result.output))",
                                          fix: "Run pi auth check --provider \(provider) in a terminal."))
                    }
                } else {
                    lines.append(Line(.problem, "pi auth check couldn't be started"))
                }
            } else {
                lines.append(Line(.ok, "sign-in not checked: no defaultProvider in settings"))
            }
            add("Servers and sign-in", lines)
        }

        /// `{servers: [{name, scope, enabled, state, tools: [names], error?}], errors: [text]}`
        /// (`list` in dist/extensions/mcp/cli.js, 1.0.4), read leniently.
        func mcpListLines(_ json: [String: Any]) -> [Line] {
            var lines: [Line] = []
            for server in json["servers"] as? [[String: Any]] ?? [] {
                let name = server["name"] as? String ?? "?"
                let state = server["state"] as? String ?? "unknown"
                let tools = (server["tools"] as? [Any])?.count ?? 0
                let scope = (server["scope"] as? String).map { $0 == "global" ? "" : " (\($0))" } ?? ""
                switch state {
                case "connected": lines.append(Line(.ok, "\(name)\(scope): connected, \(tools) tool\(tools == 1 ? "" : "s")"))
                case "disabled": lines.append(Line(.ok, "\(name)\(scope): off"))
                case "needs-auth":
                    lines.append(Line(.problem, "\(name)\(scope): needs sign-in", fix: "Run pi mcp login \(name)."))
                default:
                    let error = (server["error"] as? String).map { ": " + PiDoctor.firstLine($0) } ?? ""
                    lines.append(Line(.problem, "\(name)\(scope): \(state)\(error)",
                                      fix: "Run pi mcp list in a terminal; /mcp in Pi shows the server's stderr."))
                }
            }
            for error in json["errors"] as? [String] ?? [] {
                lines.append(Line(.problem, PiDoctor.firstLine(error.replacingOccurrences(of: home.path + "/", with: "~/")),
                                  fix: "Fix the entry; Pi skips it."))
            }
            if lines.isEmpty { lines.append(Line(.ok, "no MCP servers configured")) }
            return lines
        }
    }

    /// The JSON object in a program's output (stderr may be around it).
    static func jsonObject(in output: String) -> [String: Any]? {
        guard let start = output.firstIndex(of: "{"), let end = output.lastIndex(of: "}"), start < end else { return nil }
        return try? JSONSerialization.jsonObject(with: Data(output[start...end].utf8)) as? [String: Any]
    }

    /// The first non-empty line, at most 200 characters.
    static func firstLine(_ text: String) -> String {
        let line = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty } ?? "no output"
        return line.count > 200 ? String(line.prefix(200)) + "…" : line
    }
}
