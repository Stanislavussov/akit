import AKitAttention
import AKitBrain
import AKitFoundation
import AKitHarnesses
import Foundation

/// `akit attention`: what the Attention screen shows (docs/design/attention.md). Reads only; an
/// agent may run it to see what failed or waits before it starts.
extension AKitCLI {
    static let attentionUsage = """
    akit attention: what needs you now, gathered from every screen of AKit (docs/design/attention.md).
    Read from the files those screens keep; nothing is run, no model is called.

      akit attention [--all] [--json] [--brain DIR] [--project PATH]…
                        Problems first (a failed Lab run, review or send, a stopped flow run, an
                        MCP server that doesn't connect, a brain problem), then what needs a look
                        (failed analysis sessions, candidate failure modes, hidden tests that
                        failed), then what is ready to read (code reviews, session reviews, error
                        analysis reports, eval verdicts, knowledge inbox proposals). Runs and
                        checks older than 14 days are left out. Each line ends with an akit://
                        link that opens the place in AKit.
                        --all: also the items dismissed on the Attention screen.
                        --project: a folder whose flow runs to read (repeatable); default every
                        project under ~/Projects.
                        --json: {items: [{id, level: problem|check|ready, source, title, detail,
                        date, link, dismissed}]}; exit 0 either way.
    """

    struct AttentionAnswer: Encodable {
        struct Item: Encodable {
            let id: String
            let level: String
            let source: String
            let title: String
            let detail: String
            let date: Date?
            let link: String
            let dismissed: Bool
        }
        let items: [Item]
    }

    static func attention(_ arguments: [String], env: HarnessEnvironment, cwd: URL, projectsRoot: URL,
                          out: (String) -> Void, now: Date = .now) throws -> Int32 {
        var args = Arguments(arguments)
        if args.flag("--help") || args.flag("-h") {
            out(attentionUsage)
            return 0
        }
        let json = args.flag("--json")
        let all = args.flag("--all")
        let brainFolder = args.value("--brain").map { resolve($0, cwd: cwd, env: env) } ?? Brain.defaultRoot(home: env.homeDirectory)
        let projects = args.values("--project").map { resolve($0, cwd: cwd, env: env) }
        try args.finish()
        let items = Attention.collect(env: env, brain: Brain.load(from: brainFolder),
                                      projects: projects.isEmpty ? ProjectFinder.projects(inRoots: [projectsRoot]) : projects, now: now)
        let dismissals = AttentionDismissals.load(home: env.homeDirectory)
        let shown = all ? items : items.filter { !dismissals.hides($0) }
        if json {
            let answer = AttentionAnswer(items: shown.map {
                .init(id: $0.id, level: $0.level.rawValue, source: $0.source.rawValue, title: $0.title, detail: $0.detail,
                      date: $0.date, link: $0.link.url.absoluteString, dismissed: dismissals.hides($0))
            })
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            encoder.dateEncodingStrategy = .iso8601
            out(SecretFilter.masked(String(decoding: try encoder.encode(answer), as: UTF8.self)))
            return 0
        }
        let hidden = items.count - shown.count
        guard !shown.isEmpty else {
            out("Nothing needs attention." + (hidden > 0 ? " \(count(hidden, "dismissed item")) hidden (--all shows them)." : ""))
            return 0
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        var lines: [String] = []
        for level in AttentionItem.Level.allCases {
            let group = shown.filter { $0.level == level }
            guard !group.isEmpty else { continue }
            if !lines.isEmpty { lines.append("") }
            lines.append("\(level.title) (\(group.count))")
            for item in group {
                let when = item.date.map { " · " + formatter.string(from: $0) } ?? ""
                lines.append("  \(item.title)")
                lines.append("    \(item.source.title)\(when)" + (dismissals.hides(item) ? " · dismissed" : "") + (item.detail.isEmpty ? "" : ". \(item.detail)"))
                lines.append("    \(item.link.url.absoluteString)")
            }
        }
        if hidden > 0 { lines.append("\n\(count(hidden, "dismissed item")) hidden (--all shows them).") }
        out(SecretFilter.masked(lines.joined(separator: "\n")))
        return 0
    }
}
