import AKitFoundation
import AKitHarnesses
import Foundation
import Yams

/// What of the user's Pi set-up a review can use (`docs/design/review.md`, "Pi steps"): the
/// subagents of pi-subagents, the prompt templates and the skills. AKit only reads their files:
/// a step runs one as AKit's own pass, with the review's reading tools and checks, never the
/// package's code. Project files (`.pi/` in the reviewed repository) are never read: the
/// merge request could bring them.
public struct ReviewPiLibrary: Sendable {
    public struct Item: Sendable, Hashable, Identifiable {
        public enum Kind: String, Codable, Sendable { case agent, template, skill }

        public var kind: Kind
        public var name: String
        public var description: String
        /// `user`, or the package (`npm:pi-subagents`).
        public var origin: String
        public var file: URL
        /// The text after the frontmatter: the agent's system prompt, the template, the skill.
        public var body: String
        /// An agent's frontmatter `model` and `thinking`.
        public var model: String?
        public var thinking: String?
        /// An agent's frontmatter `tools`.
        public var tools: [String]
        /// A template's `argument-hint`.
        public var argumentHint: String?

        public var id: String { "\(kind.rawValue):\(name)" }
        /// What a user types for it: `/run reviewer`, `/review`, `/skill:pdf-tools`.
        public var command: String {
            switch kind {
            case .agent: "/run \(name)"
            case .template: "/\(name)"
            case .skill: "/skill:\(name)"
            }
        }
    }

    /// `subagents` of Pi's settings.json: what pi-subagents gives agents without their own model.
    public struct SubagentDefaults: Sendable, Hashable {
        public var defaultModel: String?
        public var defaultThinking: String?
        public var models: [String: String] = [:]
        public var thinking: [String: String] = [:]

        public init(defaultModel: String? = nil, defaultThinking: String? = nil) {
            self.defaultModel = defaultModel
            self.defaultThinking = defaultThinking
        }
    }

    public var items: [Item]
    public var subagents: SubagentDefaults
    public var problems: [String]

    public init(items: [Item] = [], subagents: SubagentDefaults = SubagentDefaults(), problems: [String] = []) {
        self.items = items
        self.subagents = subagents
        self.problems = problems
    }

    static let thinkingLevels: Set<String> = ["off", "minimal", "low", "medium", "high", "xhigh", "max"]

    public func item(_ kind: Item.Kind, _ name: String) -> Item? { items.first { $0.kind == kind && $0.name == name } }

    /// The model and thinking an agent runs with, in pi-subagents' order: its frontmatter, the
    /// settings' `agentOverrides`, `subagents.defaultModel`, else the passes' model.
    /// `inherit` means the passes' model.
    public func model(of agent: Item, passes: ReviewModelChoice) -> ReviewModelChoice {
        func given(_ value: String?) -> String? { value.flatMap { $0.isEmpty || $0 == "inherit" ? nil : $0 } }
        // pi-subagents puts `agentOverrides` over a builtin's own frontmatter, and under a custom agent's.
        let builtin = agent.origin == "npm:pi-subagents"
        let ownModel = builtin ? given(subagents.models[agent.name]) ?? given(agent.model) : given(agent.model) ?? given(subagents.models[agent.name])
        let ownThinking = builtin ? given(subagents.thinking[agent.name]) ?? given(agent.thinking)
            : given(agent.thinking) ?? given(subagents.thinking[agent.name])
        var model = ownModel ?? given(subagents.defaultModel) ?? passes.model
        var thinking = ownThinking ?? given(subagents.defaultThinking) ?? passes.thinking
        // `provider/model:high` carries the thinking level.
        if let colon = model.lastIndex(of: ":"), Self.thinkingLevels.contains(String(model[model.index(after: colon)...])) {
            thinking = String(model[model.index(after: colon)...])
            model = String(model[..<colon])
        }
        return ReviewModelChoice(model: model, thinking: thinking == "false" ? "off" : thinking)
    }

    /// Reads the user's agents, templates and skills and those of the installed packages of
    /// `<Pi dir>/settings.json`. A user item wins over a package's with the same name.
    public static func load(env: HarnessEnvironment) -> ReviewPiLibrary {
        let root = env.piAgentDirectory
        var library = ReviewPiLibrary()
        var settings: [String: Any] = [:]
        if let data = try? Data(contentsOf: root.appending(path: "settings.json")) {
            settings = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        }
        if let block = settings["subagents"] as? [String: Any] {
            library.subagents.defaultModel = block["defaultModel"] as? String
            library.subagents.defaultThinking = (block["defaultThinking"] as? String) ?? ((block["defaultThinking"] as? Bool) == false ? "off" : nil)
            for (name, value) in block["agentOverrides"] as? [String: Any] ?? [:] {
                guard let override = value as? [String: Any] else { continue }
                if let model = override["model"] as? String { library.subagents.models[name] = model }
                if let thinking = override["thinking"] as? String { library.subagents.thinking[name] = thinking }
                else if (override["thinking"] as? Bool) == false { library.subagents.thinking[name] = "off" }
            }
        }
        var found: [Item] = []
        found += markdown(in: root.appending(path: "agents"), recursive: true).compactMap { agent($0, origin: "user") }
        found += markdown(in: root.appending(path: "prompts"), recursive: false).compactMap { template($0, origin: "user") }
        for folder in [root.appending(path: "skills"), env.homeDirectory.appending(path: ".agents/skills")] {
            found += FileWalk.children(of: folder).compactMap { skill($0.appending(path: "SKILL.md"), origin: "user") }
        }
        let packages = PiPackages.list(configRoot: root, projects: [], in: env)
        library.problems += packages.notes
        for package in packages.packages {
            guard let folder = package.folder else { continue }
            found += package.prompts.compactMap { template($0, origin: package.source) }
            found += package.skills.compactMap { url in
                skill(url.lastPathComponent == "SKILL.md" ? url : url.appending(path: "SKILL.md"), origin: package.source)
            }
            for agents in agentFolders(of: folder, name: package.name) {
                found += markdown(in: agents, recursive: true).compactMap { agent($0, origin: package.source) }
            }
        }
        var seen = Set<String>()
        library.items = found.filter { seen.insert($0.id).inserted }
            .sorted { ($0.kind.rawValue, $0.name) < ($1.kind.rawValue, $1.name) }
        return library
    }

    /// pi-subagents' own builtins (`agents/`) and the folders a package names in
    /// `pi-subagents.agents` or `pi.subagents.agents`.
    static func agentFolders(of folder: URL, name: String) -> [URL] {
        var folders: [URL] = name == "pi-subagents" ? [folder.appending(path: "agents")] : []
        guard let data = try? Data(contentsOf: folder.appending(path: "package.json")),
              let manifest = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return folders }
        let entries = ((manifest["pi-subagents"] as? [String: Any])?["agents"] as? [String] ?? [])
            + ((((manifest["pi"] as? [String: Any])?["subagents"]) as? [String: Any])?["agents"] as? [String] ?? [])
        for entry in entries {
            let url = folder.appending(path: entry).standardizedFileURL
            // Only folders inside the package.
            if url.path.hasPrefix(folder.standardizedFileURL.path + "/"), !folders.contains(url) { folders.append(url) }
        }
        return folders
    }

    static func markdown(in folder: URL, recursive: Bool, depth: Int = 0) -> [URL] {
        var files: [URL] = []
        for url in FileWalk.children(of: folder).sorted(by: { $0.path < $1.path }) {
            if url.pathExtension == "md" { files.append(url) }
            else if recursive, depth < 3, (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                files += markdown(in: url, recursive: true, depth: depth + 1)
            }
        }
        return files
    }

    /// Frontmatter and body of a markdown file; nil when it can't be read or is too big.
    static func read(_ file: URL) -> (map: [String: Any], body: String)? {
        guard let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize, size < 200_000,
              let text = try? String(contentsOf: file, encoding: .utf8) else { return nil }
        let map = ReviewYAML.frontmatter(text).flatMap { try? Yams.load(yaml: $0) as? [String: Any] } ?? [:]
        return (map, ReviewYAML.body(text))
    }

    static func oneLine(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: " ")
    }

    static func agent(_ file: URL, origin: String) -> Item? {
        guard let (map, body) = read(file), let name = map["name"] as? String, !name.isEmpty, !body.isEmpty else { return nil }
        let tools = (map["tools"] as? String).map { $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } }
            ?? ReviewYAML.strings(map["tools"])
        return Item(kind: .agent, name: name, description: oneLine(map["description"] as? String ?? ""), origin: origin, file: file, body: body,
                    model: map["model"] as? String, thinking: (map["thinking"] as? String) ?? ((map["thinking"] as? Bool) == false ? "off" : nil),
                    tools: tools.filter { !$0.isEmpty }, argumentHint: nil)
    }

    static func template(_ file: URL, origin: String) -> Item? {
        guard file.pathExtension == "md", let (map, body) = read(file), !body.isEmpty else { return nil }
        let name = file.deletingPathExtension().lastPathComponent
        let first = body.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        return Item(kind: .template, name: name, description: oneLine(map["description"] as? String ?? String(first.prefix(120))), origin: origin,
                    file: file, body: body, model: nil, thinking: nil, tools: [], argumentHint: map["argument-hint"] as? String)
    }

    static func skill(_ file: URL, origin: String) -> Item? {
        guard let (map, body) = read(file), !body.isEmpty else { return nil }
        let name = map["name"] as? String ?? file.deletingLastPathComponent().lastPathComponent
        return Item(kind: .skill, name: name, description: oneLine(map["description"] as? String ?? ""), origin: origin, file: file, body: body,
                    model: nil, thinking: nil, tools: [], argumentHint: nil)
    }
}

/// One Pi step as configured (`pi: steps:` of `review.yaml`, a profile or a run): a subagent, a
/// prompt template or skill, or a plain instruction, run after the roles.
public struct ReviewStepConfig: Codable, Sendable, Hashable {
    /// What the user wrote: `/run reviewer check the retries`, `/review-api orders`,
    /// `/skill:security-audit`, or plain text.
    public var command: String
    public var maxFindings: Int?
    public var minSeverity: ReviewSeverity?

    public init(command: String, maxFindings: Int? = nil, minSeverity: ReviewSeverity? = nil) {
        self.command = command
        self.maxFindings = maxFindings
        self.minSeverity = minSeverity
    }

    /// The parts of the command: what kind, the name, and the arguments after it.
    public var parsed: (kind: ReviewPiLibrary.Item.Kind?, name: String, arguments: String) {
        let text = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.hasPrefix("/") else { return (nil, "", text) }
        let words = text.dropFirst().split(maxSplits: 1, whereSeparator: \.isWhitespace).map(String.init)
        let head = words.first ?? ""
        let rest = words.count > 1 ? words[1] : ""
        if head == "run" {
            let parts = rest.split(maxSplits: 1, whereSeparator: \.isWhitespace).map(String.init)
            return (.agent, parts.first ?? "", parts.count > 1 ? parts[1] : "")
        }
        if head.hasPrefix("skill:") { return (.skill, String(head.dropFirst("skill:".count)), rest) }
        return (.template, head, rest)
    }
}

/// The `pi:` block of `review.yaml`, a profile or a run: extra flags for the review passes and
/// the steps after the roles. Each level adds to the one below.
public struct ReviewPiExtras: Sendable, Hashable {
    public var flags: [String]
    public var steps: [ReviewStepConfig]

    public init(flags: [String] = [], steps: [ReviewStepConfig] = []) {
        self.flags = flags
        self.steps = steps
    }

    public var isEmpty: Bool { flags.isEmpty && steps.isEmpty }

    /// `pi: { flags: ["--provider", "x"], steps: ["/run reviewer", {run: "/review-api", max_findings: 5}] }`.
    public static func parse(_ value: Any?, where where_: String) throws -> ReviewPiExtras {
        guard let map = value as? [String: Any] else { return ReviewPiExtras() }
        var extras = ReviewPiExtras()
        // A string of flags splits like a shell line; a list keeps each entry whole.
        if let line = map["flags"] as? String { extras.flags = ReviewPiFlags.split(line) } else { extras.flags = ReviewYAML.strings(map["flags"]) }
        if let problem = ReviewPiFlags.problem(extras.flags) { throw ReviewRole.Failure(message: "\(where_): pi flags: \(problem)") }
        for entry in map["steps"] as? [Any] ?? [] {
            if let text = entry as? String {
                extras.steps.append(ReviewStepConfig(command: text))
            } else if let step = entry as? [String: Any], let text = step["run"] as? String {
                var config = ReviewStepConfig(command: text, maxFindings: step["max_findings"] as? Int)
                if let severity = step["min_severity"] as? String {
                    guard let value = ReviewSeverity(rawValue: severity) else {
                        throw ReviewRole.Failure(message: "\(where_): pi steps: min_severity \(severity) is not a severity.")
                    }
                    config.minSeverity = value
                }
                if let max = config.maxFindings, !(1...20).contains(max) {
                    throw ReviewRole.Failure(message: "\(where_): pi steps: max_findings must be 1–20.")
                }
                extras.steps.append(config)
            } else {
                throw ReviewRole.Failure(message: "\(where_): each pi step is a command (\"/run reviewer\") or { run: …, max_findings: … }.")
            }
        }
        return extras
    }
}

/// Extra Pi flags of the review passes: only flags that change nothing AKit's guarantees rest
/// on (what a pass may read or run, where it sends the merge request, its session). Anything else
/// is refused, a flag's value included: Pi takes the next argument as a value even when it
/// starts with `-`, and a loose `@file` would put any file into the prompt.
public enum ReviewPiFlags {
    /// Allowed flags and whether each takes a value. `--provider` and `--models` are not here:
    /// they change where the merge request goes, which the sending policy checks from the model
    /// (`provider/model`).
    public static let allowed: [String: Bool] = [
        "--name": true, "-n": true, "--exclude-tools": true, "-xt": true, "--no-approve": false, "-na": false, "--verbose": false,
    ]

    /// Why the flags can't be used, or nil. Checks the whole list: every item is an allowed
    /// flag or the value right after one.
    public static func problem(_ flags: [String]) -> String? {
        var index = 0
        while index < flags.count {
            let flag = flags[index]
            guard flag.hasPrefix("-") else { return "\(flag) is not a flag; flags start with -." }
            guard let takesValue = allowed[flag] else {
                return "\(flag) can't be used in a review pass. Allowed: \(allowed.keys.filter { $0.hasPrefix("--") }.sorted().joined(separator: ", "))."
                    + (flag == "--provider" || flag == "--models" ? " Choose the model as provider/model instead." : "")
            }
            if takesValue {
                guard index + 1 < flags.count else { return "\(flag) needs a value." }
                let value = flags[index + 1]
                if value.isEmpty || value.hasPrefix("-") || value.hasPrefix("@") { return "\(value) is not a value for \(flag)." }
                if flag == "--exclude-tools" || flag == "-xt",
                   value.split(separator: ",").contains(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("akit") || $0.contains("*") }) {
                    return "--exclude-tools can't take AKit's own tools away or use patterns."
                }
                index += 1
            }
            index += 1
        }
        if flags.contains(where: { SecretFilter.masked($0) != $0 }) { return "a flag value looks like a secret." }
        return nil
    }

    /// `--provider x --exclude-tools "find,ls"` → its words, with shell-like quotes.
    public static func split(_ line: String) -> [String] { ReviewPiTemplate.words(line) }

    /// The flags of `pi --help` a review pass may take, with their help text.
    public static func suggestions(help: String) -> [(flag: String, help: String)] {
        // `  --exclude-tools, -xt <tools>   Comma-separated …`
        guard let regex = try? NSRegularExpression(pattern: #"^\s+(-{1,2}[\w-]+(?:,\s*-{1,2}[\w-]+)*)\s*(<[^>]*>)?\s{2,}(\S.*)$"#) else { return [] }
        var result: [(String, String)] = []
        for line in help.split(whereSeparator: \.isNewline).map(String.init) {
            guard let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) else { continue }
            func group(_ index: Int) -> String { Range(match.range(at: index), in: line).map { String(line[$0]) } ?? "" }
            let names = group(1).split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            guard let name = names.first(where: { $0.hasPrefix("--") }) ?? names.first, name != "--",
                  names.allSatisfy({ allowed[$0] != nil }),
                  !result.contains(where: { $0.0.hasPrefix(name) }) else { continue }
            let argument = group(2)
            result.append((argument.isEmpty ? name : "\(name) \(argument)", group(3)))
        }
        return result
    }
}

/// Pi's prompt template arguments: `$1`, `$@`, `$ARGUMENTS`, `${1:-default}`, `${@:-default}`,
/// `${@:N}`, `${@:N:L}`; arguments split like a shell line.
public enum ReviewPiTemplate {
    public static func expand(_ template: String, arguments: String) -> String {
        let args = commandArguments(arguments)
        let all = args.joined(separator: " ")
        // Pi's own expression (`substituteArgs` in Pi's prompt-templates), in one pass.
        let pattern = #"\$\{(\d+|ARGUMENTS|@):-([^}]*)\}|\$\{@:(\d+)(?::(\d+))?\}|\$(ARGUMENTS|@|\d+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return template }
        func argument(_ text: String) -> String? {
            guard let position = Int(text), position >= 1, position <= args.count else { return nil }
            return args[position - 1]
        }
        var result = ""
        var last = template.startIndex
        for match in regex.matches(in: template, range: NSRange(template.startIndex..., in: template)) {
            guard let range = Range(match.range, in: template) else { continue }
            func group(_ index: Int) -> String? { Range(match.range(at: index), in: template).map { String(template[$0]) } }
            let value: String
            if let target = group(1) {
                let given = target == "@" || target == "ARGUMENTS" ? all : argument(target) ?? ""
                value = given.isEmpty ? group(2) ?? "" : given
            } else if let startText = group(3) {
                // Clamped: a huge number in a template never overflows.
                let start = min(args.count, max(0, (Int(startText) ?? 1) - 1))
                let length = group(4).map { min(args.count - start, max(0, Int($0) ?? 0)) } ?? (args.count - start)
                value = args[start..<(start + length)].joined(separator: " ")
            } else if let simple = group(5) {
                value = simple == "ARGUMENTS" || simple == "@" ? all : argument(simple) ?? ""
            } else {
                value = ""
            }
            result += template[last..<range.lowerBound] + value
            last = range.upperBound
        }
        return result + template[last...]
    }

    /// Pi's split of a command's arguments (`parseCommandArgs`): spaces separate, "…" and '…'
    /// group, no escapes, empty words dropped.
    static func commandArguments(_ line: String) -> [String] {
        var args: [String] = []
        var current = ""
        var quote: Character?
        for character in line {
            if let open = quote {
                if character == open { quote = nil } else { current.append(character) }
            } else if character == "\"" || character == "'" {
                quote = character
            } else if character.isWhitespace {
                if !current.isEmpty { args.append(current); current = "" }
            } else {
                current.append(character)
            }
        }
        if !current.isEmpty { args.append(current) }
        return args
    }

    /// A shell-like split: spaces separate, "…" and '…' group, \ escapes.
    public static func words(_ line: String) -> [String] {
        var words: [String] = []
        var current = ""
        var quote: Character?
        var escaped = false
        var started = false
        for character in line {
            if escaped { current.append(character); escaped = false; continue }
            if character == "\\", quote != "'" { escaped = true; started = true; continue }
            if let open = quote {
                if character == open { quote = nil } else { current.append(character) }
                continue
            }
            if character == "\"" || character == "'" { quote = character; started = true; continue }
            if character.isWhitespace {
                if started { words.append(current); current = ""; started = false }
                continue
            }
            current.append(character)
            started = true
        }
        if started { words.append(current) }
        return words
    }
}

public enum ReviewPiCommands {
    /// `pi --help` as a review pass sees it: without extensions (their flags don't apply there).
    public static func help(pi: URL, env: HarnessEnvironment) async -> String? {
        guard let result = await ProcessRunner.run(pi, arguments: ["--no-extensions", "--offline", "--help"],
                                                   environment: env.variables.merging(["PATH": env.pathForChildProcesses, "NO_COLOR": "1"]) { $1 },
                                                   timeout: 30), result.succeeded else { return nil }
        return result.output
    }
}
