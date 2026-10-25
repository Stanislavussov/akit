import AKitFoundation
import AKitKnowledge
import Foundation

/// `akit notebook`: the notebook of the knowledge base (docs/design/notebook.md, NB8), what the
/// Notebook screen shows. Agents run `tabs` and `show`, and `add` and `done` only when the user
/// asked for them in the session.
extension AKitCLI {
    static let notebookUsage = """
    akit notebook: short notes, plans and to-dos in the knowledge base (docs/design/notebook.md):
    one Markdown file per tab in the base's notebook/ folder, the Notebook screen in AKit. Obsidian
    reads the same files. Search, lint and akit kb context leave the notebook out.

      akit notebook tabs [--json] [--base PATH|WORLD]
                                        The tabs in their order, with their open tasks. A notebook
                                        without tabs shows Inbox, written by the first add.
                                        --json: {base, tabs: [{name, path, open}]}
      akit notebook show TAB [--open] [--json] [--base PATH|WORLD]
                                        A tab's Markdown; --open: only its open tasks (- [ ] …).
                                        --json: {base, tab, path, text, open}
      akit notebook add TAB TEXT [--task] [--today] [--json] [--base PATH|WORLD]
                                        Only when the user asked. One line at the top of the tab
                                        (after a # Title): --task makes it "- [ ] TEXT", --today
                                        puts it under today's heading "## YYYY-MM-DD" (made at the
                                        top when missing). Committed at once; AKit's open tab asks
                                        Reload / Keep Mine. --json: {base, tab, path, line}
      akit notebook done TAB TEXT [--json] [--base PATH|WORLD]
                                        Only when the user asked. Ticks the first open task whose
                                        text contains TEXT (case ignored), committed at once.
                                        --json: {base, tab, path, line}

    Tab names match without regard to case. Which base: as for akit kb (akit kb --help).
    """

    struct NotebookTabsAnswer: Encodable {
        struct Tab: Encodable {
            let name: String
            let path: String
            let open: Int
        }
        let base: String
        let tabs: [Tab]
    }

    struct NotebookShowAnswer: Encodable {
        let base: String
        let tab: String
        let path: String
        let text: String
        let open: [String]
    }

    struct NotebookChangeAnswer: Encodable {
        let base: String
        let tab: String
        let path: String
        let line: String
    }

    static func notebook(_ arguments: [String], env: HarnessEnvironment, cwd: URL, projectsRoot: URL,
                         out: (String) -> Void, today: Date = .now) async throws -> Int32 {
        var args = Arguments(arguments)
        if args.flag("--help") || args.flag("-h") || args.isEmpty {
            out(notebookUsage)
            return 0
        }
        let json = args.flag("--json")
        let baseOption = args.value("--base")
        let command = args.positional()
        func chosen() async throws -> KnowledgeBase? {
            do {
                return try await KnowledgeBase.choose(option: baseOption, folder: cwd, env: env, projectsRoot: projectsRoot, forReading: true)
            } catch {
                throw Failure(message: error.message)
            }
        }
        do {
            switch command {
            case "tabs":
                try args.finish()
                guard let base = try await chosen() else { return noBase(json: json, out: out) }
                let book = KnowledgeNotebook(base: base)
                let names = book.tabs().isEmpty ? [KnowledgeNotebook.firstTab] : book.tabs()
                let tabs = try names.map { name in
                    NotebookTabsAnswer.Tab(name: name, path: book.path(name), open: KnowledgeNotebook.openTasks(in: try book.text(name)).count)
                }
                if json {
                    out(encode(NotebookTabsAnswer(base: base.root.path, tabs: tabs)))
                } else {
                    out(tabs.map { "\($0.name)  \($0.path)  \(count($0.open, "open task"))" }.joined(separator: "\n"))
                }
            case "show":
                let open = args.flag("--open")
                guard let name = args.positional() else { throw Failure(message: "Use: akit notebook show TAB [--open] [--json] [--base PATH|WORLD]") }
                try args.finish()
                guard let base = try await chosen() else { return noBase(json: json, out: out) }
                let book = KnowledgeNotebook(base: base)
                let tab = book.tabs().isEmpty && name.lowercased() == KnowledgeNotebook.firstTab.lowercased()
                    ? KnowledgeNotebook.firstTab : try book.tab(name)
                let text = try book.text(tab)
                let tasks = KnowledgeNotebook.openTasks(in: text)
                if json {
                    out(encode(NotebookShowAnswer(base: base.root.path, tab: tab, path: book.path(tab), text: text, open: tasks)))
                } else if open {
                    out(tasks.isEmpty ? "No open tasks in \(tab)." : tasks.map { "- [ ] \($0)" }.joined(separator: "\n"))
                } else {
                    out(text.isEmpty ? "\(tab) is empty." : text)
                }
            case "add", "done":
                let task = command == "add" && args.flag("--task"), onToday = command == "add" && args.flag("--today")
                guard let name = args.positional(), let text = args.positional() else {
                    throw Failure(message: command == "add" ? "Use: akit notebook add TAB TEXT [--task] [--today] [--json] [--base PATH|WORLD]"
                        : "Use: akit notebook done TAB TEXT [--json] [--base PATH|WORLD]")
                }
                try args.finish()
                let base = try await writable(chosen)
                let book = KnowledgeNotebook(base: base)
                let tab: String, line: String
                if command == "add" {
                    let day = onToday ? dayFormatter.string(from: today) : nil
                    tab = try await book.append(text, to: name, task: task, today: day, env: env)
                    line = task ? "- [ ] \(text.trimmingCharacters(in: .whitespaces))" : text.trimmingCharacters(in: .whitespaces)
                } else {
                    tab = try book.tab(name)
                    line = try await book.tick(text, in: tab, env: env)
                }
                if json {
                    out(encode(NotebookChangeAnswer(base: base.root.path, tab: tab, path: book.path(tab), line: line)))
                } else {
                    out((command == "add" ? "Added to \(tab)" : "Ticked in \(tab)") + ": \(line), committed.")
                }
            default:
                throw Failure(message: "Unknown command akit notebook \(command ?? ""). akit notebook --help lists them.")
            }
        } catch let error as KnowledgeBase.Failure {
            throw Failure(message: error.message)
        }
        return 0
    }

    static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}
