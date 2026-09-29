import AKitBrain
import AKitFoundation
import Darwin
import Foundation

/// `akit record-session --harness H`, run by the akit Claude plugin's SessionStart hook and by
/// the Pi extension. Reads the hook's JSON (`session_id`, `cwd`, `transcript_path`, `source`)
/// from stdin and appends one `session_start` line to the spool, with the repository the
/// folder belongs to, read from `.git` files as text. Prints nothing (SessionStart output
/// would land in the agent's context), starts no process, never fails.
public enum RecordSession {
    /// The `akit` binary's entry for `record-session`, before anything else runs. The caller
    /// exits 0 afterwards, whatever happened.
    public static func main(arguments: [String]) {
        guard getuid() != 0 else { return }
        // Run by hand in a terminal there is no hook input; don't wait for one.
        let input = isatty(0) != 0 ? Data() : readStandardInput()
        run(harness: harness(in: arguments), stdin: input, env: .current)
    }

    /// `--harness H`; Claude when missing.
    public static func harness(in arguments: [String]) -> String {
        guard let index = arguments.firstIndex(of: "--harness"), index + 1 < arguments.count else { return "claude" }
        return arguments[index + 1]
    }

    /// Stdin up to `limit` bytes (hook input is a few hundred).
    static func readStandardInput(limit: Int = 1 << 20) -> Data {
        var data = Data()
        while data.count < limit, let chunk = try? FileHandle.standardInput.read(upToCount: 64 << 10), !chunk.isEmpty {
            data.append(chunk)
        }
        return data
    }

    /// Appends the line for this hook input; garbage input writes nothing.
    public static func run(harness: String, stdin: Data, env: HarnessEnvironment, now: Date = Date()) {
        guard let line = line(harness: harness, stdin: stdin, now: now) else { return }
        Spool.append(line, home: env.homeDirectory, now: now)
    }

    static func line(harness rawHarness: String, stdin: Data, now: Date) -> [String: Any]? {
        guard let input = (try? JSONSerialization.jsonObject(with: stdin)) as? [String: Any] else { return nil }
        let harness = String(rawHarness.lowercased().filter { $0.isLetter || $0.isNumber || $0 == "-" }.prefix(32))
        func text(_ key: String) -> String? {
            (input[key] as? String).flatMap { $0.isEmpty ? nil : $0 }
        }
        let transcript = text("transcript_path")
        // Pi names its logs `<time>_<session id>.jsonl`; used when the id itself is missing.
        let fromFile = transcript.flatMap { path -> String? in
            let name = URL(filePath: path).deletingPathExtension().lastPathComponent
            return name.split(separator: "_").last.map(String.init)
        }
        guard !harness.isEmpty, let session = text("session_id") ?? (harness == "pi" ? fromFile : nil),
              session.count <= 256 else { return nil }
        var line: [String: Any] = ["v": Spool.lineVersion, "kind": "session_start", "harness": harness,
                                   "session_id": session, "ts": Spool.milliseconds(now)]
        line["source"] = text("source")
        line["transcript"] = transcript
        if let cwd = text("cwd") {
            line["cwd"] = cwd
            if let repository = repository(containing: cwd) {
                line["gitdir"] = repository.gitdir
                line["common_dir"] = repository.commonDir
                line["remote_id"] = repository.remoteID
                line["branch"] = repository.branch
            }
        }
        return line
    }

    // MARK: - Repository

    struct Repository: Equatable {
        /// The folder git keeps this checkout's state in (`.git`, or `<main>/.git/worktrees/<name>`).
        let gitdir: String
        /// The main repository's `.git`, shared by all its worktrees.
        let commonDir: String
        /// `github.com/owner/repo` from the main repository's `origin`.
        let remoteID: String?
        let branch: String?
    }

    /// Nearest `.git` at or above `cwd`. A `.git` file (a worktree) points to its gitdir, whose
    /// `commondir` points to the main repository; the remote comes from there.
    static func repository(containing cwd: String) -> Repository? {
        guard cwd.hasPrefix("/") else { return nil }
        var folder = (cwd as NSString).standardizingPath
        // Bounded: every step drops one path component, and "/" ends the walk.
        for _ in 0..<512 {
            let dotGit = (folder as NSString).appendingPathComponent(".git")
            var info = stat()
            if stat(dotGit, &info) == 0 {
                switch info.st_mode & S_IFMT {
                case S_IFDIR:
                    return repository(gitdir: dotGit)
                case S_IFREG:
                    if let target = gitdirPointer(in: dotGit) {
                        let gitdir = target.hasPrefix("/") ? target : (folder as NSString).appendingPathComponent(target)
                        return repository(gitdir: (gitdir as NSString).standardizingPath)
                    }
                default:
                    break
                }
            }
            let parent = (folder as NSString).deletingLastPathComponent
            guard !parent.isEmpty, parent != folder else { return nil }
            folder = parent
        }
        return nil
    }

    private static func repository(gitdir: String) -> Repository {
        var common = gitdir
        if let pointer = small(gitdir + "/commondir")?.trimmingCharacters(in: .whitespacesAndNewlines), !pointer.isEmpty {
            common = ((pointer.hasPrefix("/") ? pointer : gitdir + "/" + pointer) as NSString).standardizingPath
        }
        let remote = small(common + "/config").flatMap(originURL).flatMap(ProjectRecords.normalizedRemote)
        var branch: String?
        if let head = small(gitdir + "/HEAD")?.trimmingCharacters(in: .whitespacesAndNewlines), head.hasPrefix("ref: refs/heads/") {
            branch = String(head.dropFirst("ref: refs/heads/".count))
        }
        return Repository(gitdir: gitdir, commonDir: common, remoteID: remote, branch: branch)
    }

    /// `gitdir: <path>` of a worktree's `.git` file.
    private static func gitdirPointer(in file: String) -> String? {
        small(file)?.split(whereSeparator: \.isNewline)
            .first { $0.hasPrefix("gitdir:") }
            .map { $0.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces) }
            .flatMap { $0.isEmpty ? nil : $0 }
    }

    /// `url` of `[remote "origin"]` in a git config file.
    static func originURL(_ config: String) -> String? {
        var inOrigin = false
        for raw in config.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") {
                let header = line.filter { !$0.isWhitespace }
                inOrigin = header.hasPrefix("[remote\"origin\"]")
                continue
            }
            guard inOrigin, let equals = line.firstIndex(of: "=") else { continue }
            guard line[..<equals].trimmingCharacters(in: .whitespaces).lowercased() == "url" else { continue }
            var value = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") { value = String(value.dropFirst().dropLast()) }
            return value.isEmpty ? nil : value
        }
        return nil
    }

    /// A small text file (git metadata), or nil.
    static func small(_ path: String, limit: Int = 256 << 10) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        return (try? handle.read(upToCount: limit)).map { String(decoding: $0, as: UTF8.self) }
    }
}
