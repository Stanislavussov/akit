import Foundation

/// Facts from Pi session lines (see PiSessions for the format).
/// - the `session` header → the session (id, cwd, `started`: copied fork entries are older
///   than the fork, so only the header dates its start);
/// - an assistant message with `usage` → request; `toolCall` blocks → tool calls,
///   `toolResult` messages → their output size and error;
/// - a `read` of `<root>/<skill>/SKILL.md` for an installed skill root → model call of that skill;
/// - a user message starting `<skill name="x"` → user call, and a manual-call example (the text
///   after `</skill>` and the user's prompt before it). Pi records no skill listing.
/// Event keys are `<entry id>@<entry timestamp>` (+ `#<block index>`): a fork copies entries
/// with both, so copies dedupe, while an unrelated session reusing an 8-hex id doesn't collide.
struct PiFacts {
    /// Bump when the facts read from a line change; files that still exist are re-read.
    /// 2: `started` only from the header, user calls say `extra.kind`, nested SKILL.md reads don't count.
    static let parserVersion = 2

    private(set) var sessionKey: String
    private(set) var session: Fact.Session?
    private var skillPaths: PiSkillPaths
    /// The user's last prompt that wasn't a skill call, for manual-call examples.
    private var lastPrompt: String?

    /// `sessionKey` / `cwd`: what an earlier run read from the header, for reads from an offset.
    init(file: URL, sessionKey: String?, cwd: String?, env: HarnessEnvironment) {
        self.sessionKey = sessionKey ?? "pi:" + file.deletingPathExtension().lastPathComponent
        skillPaths = PiSkillPaths(env: env, cwd: cwd.map { URL(filePath: $0, directoryHint: .isDirectory) })
    }

    var sessionFact: Fact? { session.map(Fact.session) }

    mutating func facts(from entry: JSONLines.Object, offset: UInt64) -> [Fact] {
        let stamp = entry["timestamp"] as? String
        let ts = JSONLines.date(stamp)
        if entry["type"] as? String == "session" {
            let id = entry["id"] as? String ?? String(sessionKey.dropFirst("pi:".count))
            sessionKey = "pi:" + id
            let cwd = entry["cwd"] as? String
            session = Fact.Session(nativeID: id, cwd: cwd, started: ts, lastActivity: ts)
            skillPaths.cwd = cwd.map { URL(filePath: $0, directoryHint: .isDirectory) }
            return []
        }
        note(ts)
        guard entry["type"] as? String == "message", let message = entry["message"] as? JSONLines.Object else { return [] }
        // Old files without entry ids fall back to the line's place in the file.
        let key = (entry["id"] as? String).map { "\($0)@\(stamp ?? "")" } ?? "\(sessionKey)@\(offset)"
        let time = ts ?? JSONLines.date(message["timestamp"])
        switch message["role"] as? String {
        case "user":
            let text = JSONLines.text(of: message["content"]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard let skill = PiLogFormat.skillPrefixName(text) else {
                if !text.isEmpty { lastPrompt = text }
                return []
            }
            let args = PiLogFormat.promptTitle(text) == text ? "" : PiLogFormat.promptTitle(text)
            return [.skillCall(.init(key: key, ts: time, skill: skill, by: .user, isSubagent: false, hasArgs: !args.isEmpty)),
                    .manualCallExample(.init(key: key, ts: time, skill: skill, args: args, request: lastPrompt))]
        case "assistant":
            return assistantFacts(message, key: key, at: time)
        case "toolResult":
            guard let callID = message["toolCallId"] as? String else { return [] }
            return [.toolResult(callID: callID, bytes: JSONLines.text(of: message["content"]).utf8.count,
                                isError: message["isError"] as? Bool == true)]
        default:
            return []
        }
    }

    private mutating func note(_ ts: Date?) {
        guard let ts else { return }
        var info = session ?? Fact.Session(nativeID: String(sessionKey.dropFirst("pi:".count)))
        info.lastActivity = max(info.lastActivity ?? ts, ts)
        session = info
    }

    private func assistantFacts(_ message: JSONLines.Object, key: String, at ts: Date?) -> [Fact] {
        var facts: [Fact] = []
        // Same rule as SessionUsage: responses without a model are no requests.
        if let usage = message["usage"] as? JSONLines.Object, let model = message["model"] as? String,
           !model.isEmpty, model != "<synthetic>" {
            facts.append(.request(.init(key: key, ts: ts, model: model, tokens: PiLogFormat.tokens(fromPiUsage: usage),
                                        cost: PiLogFormat.cost(fromPiUsage: usage), isSubagent: false)))
        }
        for (index, block) in (message["content"] as? [JSONLines.Object] ?? []).enumerated()
        where block["type"] as? String == "toolCall" {
            let callKey = "\(key)#\(index)"
            let name = block["name"] as? String ?? "tool"
            let arguments = block["arguments"] as? JSONLines.Object
            let path = name == "read" ? (arguments?["path"] ?? arguments?["file_path"]) as? String : nil
            facts.append(.toolCall(.init(key: callKey, callID: block["id"] as? String ?? callKey, ts: ts, name: name,
                                         inputBytes: Fact.jsonBytes(block["arguments"]), isSubagent: false,
                                         pathHash: path.map(Fact.sha256))))
            if let path, let skill = skillPaths.skill(readAt: path) {
                facts.append(.skillCall(.init(key: callKey, ts: ts, skill: skill, by: .model, isSubagent: false, hasArgs: false)))
            }
        }
        return facts
    }
}

/// Where Pi's installed skills live, to tell using a skill (reading its SKILL.md) from editing one.
/// A path counts when it is under a root as written (`~` expanded, relative to the session's
/// cwd), or when its real path is under a root's real path (`~/.pi/agent/skills` is often a
/// link to `~/.agents/skills`). Never under `~/.akit/` (the brain: editing) or temp folders.
struct PiSkillPaths {
    let env: HarnessEnvironment
    var cwd: URL? {
        didSet { roots = Self.roots(env: env, cwd: cwd) }
    }
    private var roots: [(written: String, real: String)]
    private let excluded: [String]

    init(env: HarnessEnvironment, cwd: URL?) {
        self.env = env
        self.cwd = cwd
        roots = Self.roots(env: env, cwd: cwd)
        let home = env.homeDirectory.standardizedFileURL
        let temp = env.variables["TMPDIR"].flatMap { $0.isEmpty ? nil : URL(filePath: $0).standardizedFileURL.path }
        let candidates = [home.appending(path: ".akit").path, "/tmp", "/private/tmp", "/var/folders", "/private/var/folders"]
            + (temp.map { [$0, Self.realPath($0)] } ?? [])
        // An exclusion holding the home folder itself (a test home in a temp folder) would hide everything.
        let homePaths = [home.path, Self.realPath(home.path)]
        excluded = candidates.filter { folder in !homePaths.contains { Self.isInside($0, folder) || $0 == folder } }
    }

    /// The skill's folder name, or nil when this read is not a use of an installed skill: only
    /// `<root>/<skill>/SKILL.md` counts, not a SKILL.md deeper inside a skill (examples, vendored copies).
    func skill(readAt raw: String) -> String? {
        guard !raw.isEmpty, let file = written(raw), file.lastPathComponent == "SKILL.md" else { return nil }
        let folder = file.deletingLastPathComponent().path
        guard !excluded.contains(where: { Self.isInside(folder, $0) || folder == $0 }) else { return nil }
        let real = Self.realPath(folder)
        func parent(_ path: String) -> String { (path as NSString).deletingLastPathComponent }
        guard roots.contains(where: { parent(folder) == $0.written || parent(real) == $0.real }) else { return nil }
        return file.deletingLastPathComponent().lastPathComponent
    }

    /// `~` expanded against the (fake) home, relative paths against the session's cwd.
    private func written(_ path: String) -> URL? {
        if path == "~" || path.hasPrefix("~/") { return env.expand(path).standardizedFileURL }
        if path.hasPrefix("/") { return URL(filePath: path).standardizedFileURL }
        return cwd?.appending(path: path).standardizedFileURL
    }

    private static func roots(env: HarnessEnvironment, cwd: URL?) -> [(written: String, real: String)] {
        let home = env.homeDirectory
        var urls = PiAdapter().skillRoots(in: env, projects: cwd.map { [$0] } ?? []).map(\.url)
        urls += [".agents/skills", ".pi/agent/skills", ".pi/skills"].map { home.appending(path: $0) }
        for folder in cwd.map({ ancestors(of: $0.standardizedFileURL.path) }) ?? [] {
            let url = URL(filePath: folder, directoryHint: .isDirectory)
            urls += [url.appending(path: ".agents/skills"), url.appending(path: ".pi/skills")]
        }
        var seen = Set<String>()
        return urls.map { $0.standardizedFileURL.path }.filter { seen.insert($0).inserted }.map { ($0, realPath($0)) }
    }

    /// The path with every link resolved (like realpath(3)); missing parts are kept as written.
    static func realPath(_ path: String) -> String {
        var missing: [String] = []
        for folder in ancestors(of: URL(filePath: path).standardizedFileURL.path) {
            if let resolved = realpath(folder, nil) {
                defer { free(resolved) }
                return missing.reduce(URL(filePath: String(cString: resolved))) { $0.appending(path: $1) }.path
            }
            missing.insert((folder as NSString).lastPathComponent, at: 0)
        }
        return path
    }

    /// The folder and each parent up to `/`, as strings: URL's parent of `/` is `/..`, which
    /// never ends a walk. Bounded, so a strange path can't loop.
    static func ancestors(of path: String) -> [String] {
        var result: [String] = []
        var current = path
        while result.count < 256 {
            result.append(current)
            let parent = (current as NSString).deletingLastPathComponent
            if parent == current || parent.isEmpty { break }
            current = parent
        }
        return result
    }

    static func isInside(_ path: String, _ folder: String) -> Bool {
        path.hasPrefix(folder.hasSuffix("/") ? folder : folder + "/")
    }
}
