import AKitBrain
import AKitErrorAnalysis
import AKitLab
import AKitFoundation
import AKitHarnesses
import AKitInstructions
import AKitModel
import AKitProjectSetup
import Foundation

/// `akit instructions [FOLDER] [--harness NAME]`: the instruction files each harness loads for a
/// session in the folder, in order, with the skipped ones and why, and the sections the model gets
/// twice or in two versions (docs/design/instructions.md).
extension AKitCLI {
    static let instructionsUsage = "Use: akit instructions [FOLDER] [--harness claude|pi|codex|opencode] [--global]"

    static func instructions(_ args: inout Arguments, env: HarnessEnvironment, cwd: URL,
                             out: (String) -> Void) throws -> Int32 {
        let harnessName = args.value("--harness"), global = args.flag("--global")
        let folder = args.positional()
        try args.finish()
        if global, folder != nil { throw Failure(message: "--global and a folder don't go together. " + instructionsUsage) }
        let names: [String: HarnessID] = ["claude": .claudeCode, "claude-code": .claudeCode, "pi": .pi, "codex": .codex, "opencode": .openCode]
        let harnesses: [HarnessID]
        if let harnessName {
            guard let harness = names[harnessName.lowercased()] else { throw Failure(message: "Unknown harness \(harnessName). " + instructionsUsage) }
            harnesses = [harness]
        } else {
            let installed = Set(HarnessCatalog.detectAll(in: env).map(\.id))
            harnesses = InstructionScanner.harnesses.filter(installed.contains)
            if harnesses.isEmpty { throw Failure(message: "None of Claude Code, Pi, Codex or OpenCode is installed. Name one with --harness.") }
        }
        let project = global ? nil : resolve(folder ?? ".", cwd: cwd, env: env)
        if let project, !FileWalk.isDirectory(project) { throw Failure(message: "No folder at \(project.path).") }
        out(harnesses.map { instructionsText(InstructionScanner.view(harness: $0, project: project, env: env), home: env.homeDirectory) }
            .joined(separator: "\n\n"))
        return 0
    }

    static let instructionsRemoveUsage = "Use: akit instructions remove FILE (--line N | --section HEADING) [--yes]"

    /// `akit instructions remove FILE`: Remove This Copy… from the command line, the same core
    /// code (`InstructionEdit.removing` and `apply`): the diff first, `--yes` writes after a backup.
    static func instructionsRemove(_ args: inout Arguments, yes: Bool, rendered: Set<String>, env: HarnessEnvironment, cwd: URL,
                                   out: (String) -> Void) throws -> Int32 {
        let lineText = args.value("--line"), heading = args.value("--section")
        guard let path = args.positional() else { throw Failure(message: instructionsRemoveUsage) }
        try args.finish()
        guard (lineText == nil) != (heading == nil) else { throw Failure(message: instructionsRemoveUsage) }
        let file = resolve(path, cwd: cwd, env: env)
        let shown = FileWalk.tilde(file, home: env.homeDirectory)
        guard let data = FileManager.default.contents(atPath: file.path), let text = String(data: data, encoding: .utf8) else {
            throw Failure(message: "\(shown) can't be read as text.")
        }
        let units = InstructionText.units(text)
        let section: InstructionSection
        if let lineText {
            guard let line = Int(lineText), let found = units.first(where: { $0.line == line }) else {
                throw Failure(message: "No section starts at line \(lineText) of \(shown). Sections start at lines \(units.map { String($0.line) }.joined(separator: ", ")).")
            }
            section = found
        } else {
            let wanted = (heading ?? "").trimmingCharacters(in: .whitespaces).lowercased()
            let found = units.filter { $0.heading?.trimmingCharacters(in: .whitespaces).lowercased() == wanted }
            guard let first = found.first else { throw Failure(message: "No section ## \(heading ?? "") in \(shown).") }
            guard found.count == 1 else {
                throw Failure(message: "\(shown) has \(found.count) sections ## \(first.heading ?? ""), at lines \(found.map { String($0.line) }.joined(separator: ", ")). Pick one with --line N.")
            }
            section = first
        }
        let plan: InstructionEdit.Plan
        do { plan = try InstructionEdit.removing(section, from: file, rendered: rendered, env: env) } catch { throw Failure(message: error.message) }
        var lines = ["Remove \(section.heading.map { "## \($0)" } ?? "the text before the first heading") (line \(section.line)) from \(shown):"]
        lines += TextDiff.unified(plan.diff)
        lines += plan.notes
        if !yes {
            lines.append("Run again with --yes to do it.")
            out(lines.joined(separator: "\n"))
            return 0
        }
        let backup: URL?
        do { backup = try InstructionEdit.apply(plan, env: env) } catch { throw Failure(message: error.message) }
        lines.append("Done.\(backup.map { " A backup is in \(FileWalk.tilde($0, home: env.homeDirectory))." } ?? "")")
        out(lines.joined(separator: "\n"))
        return 0
    }

    static func instructionsText(_ view: InstructionView, home: URL) -> String {
        let place = view.project.map { " in \(FileWalk.tilde($0, home: home))" } ?? " (global files only)"
        let loaded = view.loaded
        var lines = ["\(view.harness.displayName)\(place): \(loaded.count) file\(loaded.count == 1 ? "" : "s"), "
                     + "\(byteText(view.loadedBytes)) ≈ \(view.loadedBytes / 4) tokens, in the order the model gets them"]
        for entry in view.entries {
            let path = FileWalk.tilde(entry.file, home: home)
            let level = switch entry.level {
            case .global: "global "
            case .above: "above  "
            case .project: "project"
            }
            switch entry.status {
            case .loaded, .imported:
                let by = if case .imported(let file) = entry.status { " (imported by \(file.lastPathComponent))" } else { "" }
                let sections = entry.sections.count
                lines.append("  \(level)  \(path)\(by)  \(byteText(entry.bytes)), \(sections) section\(sections == 1 ? "" : "s")")
                if let note = entry.note { lines.append("           ! \(note)") }
            case .onDemand(let when):
                lines.append("  later    \(path)  \(byteText(entry.bytes)): \(when)")
            case .skipped(let reason):
                lines.append("  skipped  \(path): \(reason)")
            }
        }
        if view.entries.isEmpty { lines.append("  (no instruction files)") }
        // Sections the model gets twice (same text), or in two versions (same heading).
        for group in view.duplicates {
            let places = group.places.map { "\(FileWalk.tilde($0.file, home: home)):\($0.section.line)" }.joined(separator: ", ")
            let title = group.heading.map { "## \($0)" } ?? "(lead)"
            lines.append(group.kind == .same ? "  twice    \(title): \(places)" : "  differs  \(title): \(places)")
        }
        return lines.joined(separator: "\n")
    }

    private static func byteText(_ bytes: Int) -> String {
        bytes < 1024 ? "\(bytes) B" : String(format: "%.1f KB", Double(bytes) / 1024)
    }

    static let instructionsGlobalUsage = "Use: akit instructions global [--json] | akit instructions global set FILE|- [--yes]"

    /// `akit instructions global`: the core layer's AGENTS.md text and its copies in the global
    /// files (docs/design/global-instructions.md); `set` replaces the text through the brain.
    static func instructionsGlobal(_ args: inout Arguments, json: Bool, yes: Bool, brain: Brain, context: SkillMove.Context,
                                   env: HarnessEnvironment, cwd: URL, input: () -> Data, out: (String) -> Void) async throws -> Int32 {
        if args.peek == "set" {
            _ = args.positional()
            guard let file = args.positional() else { throw Failure(message: instructionsGlobalUsage) }
            try args.finish()
            if json { throw Failure(message: "--json goes only with akit instructions global.") }
            let data: Data
            if file == "-" { data = input() } else {
                let url = resolve(file, cwd: cwd, env: env)
                guard let read = try? Data(contentsOf: url) else { throw Failure(message: "Can't read \(url.path).") }
                data = read
            }
            guard let text = String(data: data, encoding: .utf8) else { throw Failure(message: "The text isn't UTF-8.") }
            let plan: GlobalInstructions.EditPlan
            do { plan = try GlobalInstructions.editing(to: text, brain: brain) } catch { throw Failure(message: error.message) }
            guard plan.isChange else {
                out("The core layer has this text already.")
                return 0
            }
            var lines = ["Core layer's AGENTS.md text (the global instructions):"] + TextDiff.unified(plan.lines)
            guard yes else {
                lines.append("Run again with --yes to commit it to the brain and write it into the global files.")
                out(lines.joined(separator: "\n"))
                return 0
            }
            do { try await GlobalInstructions.commit(plan, brain: brain, env: env) } catch { throw Failure(message: error.message) }
            lines.append("Committed to the brain.")
            let blocks = GlobalInstructions.homeBlocks(context: context, brainRoot: brain.root)
            if blocks.canApply {
                do { try await GlobalInstructions.applyHome(blocks, context: context) } catch { throw Failure(message: error.message) }
                for diff in blocks.diffs { lines += ["\(diff.path) (AKit's block):"] + TextDiff.unified(diff.lines) }
                lines.append("Written into " + blocks.diffs.map(\.path).joined(separator: ", ") + " (a backup first).")
            } else {
                lines.append("No global file took the block: " + (blocks.warnings.isEmpty ? "nothing to change." : blocks.warnings.joined(separator: " ")))
            }
            out(lines.joined(separator: "\n"))
            return 0
        }
        try args.finish()
        let status = GlobalInstructions.status(context: context, brain: brain)
        if json {
            struct Copy: Encodable { let path: String, harnesses: [String], state: String, note: String?, bytes: Int, otherTools: [String: Int], ownSections: [String?] }
            struct Report: Encodable { let text: String, bytes: Int, tokens: Int, copies: [Copy], notes: [String] }
            let copies = status.copies.map { copy -> Copy in
                let (state, note): (String, String?) = switch copy.state {
                case .current: ("current", nil)
                case .outdated(let why): ("outdated", why)
                case .noBlock(let why): ("no-block", why)
                }
                return Copy(path: copy.path, harnesses: copy.harnesses.map(\.rawValue), state: state, note: note, bytes: copy.bytes,
                            otherTools: Dictionary(copy.managed.map { ($0.name, $0.bytes) }, uniquingKeysWith: +),
                            ownSections: copy.own.map(\.heading))
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            out(String(decoding: try encoder.encode(Report(text: status.text, bytes: status.bytes, tokens: status.tokens,
                                                           copies: copies, notes: status.notes)), as: UTF8.self))
            return 0
        }
        guard status.hasCore else { throw Failure(message: "The brain has no core layer.") }
        var lines = [status.text.isEmpty
            ? "Global instructions (core layer's AGENTS.md): none yet. Set them with akit instructions global set FILE."
            : "Global instructions (core layer's AGENTS.md): \(byteText(status.bytes)) ≈ \(status.tokens) tokens"]
        for copy in status.copies {
            let state = switch copy.state {
            case .current: "current"
            case .outdated(let why): "outdated: \(why)"
            case .noBlock(let why): "no block: \(why)"
            }
            lines.append("  \(copy.path) (\(copy.harnesses.map(\.displayName).joined(separator: ", "))): \(state)")
            for block in copy.managed { lines.append("    \(block.name) block, lines \(block.lines.lowerBound)–\(block.lines.upperBound), \(byteText(block.bytes)): another tool's") }
            if !copy.own.isEmpty {
                lines.append("    own text, \(byteText(copy.ownBytes)): " + copy.own.map { $0.heading.map { "## \($0)" } ?? "line \($0.line)" }.joined(separator: ", "))
            }
        }
        lines += status.notes.map { "  ! \($0)" }
        if !status.text.isEmpty { lines += ["", status.text] }
        out(lines.joined(separator: "\n"))
        return 0
    }

    static let instructionsAnalyzeUsage = "Use: akit instructions analyze [--part size|review|sessions] [--days N] [--agent claude-code|pi --model M [--effort E]] [--json]"

    /// `akit instructions analyze`: one part of Analyze… (docs/design/global-instructions.md).
    static func instructionsAnalyze(_ args: inout Arguments, json: Bool, env: HarnessEnvironment, projectsRoot: URL,
                                    out: (String) -> Void) async throws -> Int32 {
        let partName = args.value("--part") ?? "size", daysText = args.value("--days")
        let agentName = args.value("--agent"), modelName = args.value("--model"), effort = args.value("--effort") ?? "high"
        try args.finish()
        guard let part = InstructionAnalysis.Part(rawValue: partName) else { throw Failure(message: instructionsAnalyzeUsage) }
        let days = try daysText.map { text -> Int in
            guard let days = Int(text), (1...365).contains(days) else { throw Failure(message: "--days takes 1 to 365.") }
            return days
        } ?? 30
        var agent: LabAgent?
        if part != .size {
            guard let agentName, let harness = LabHarness(rawValue: agentName), let modelName, !modelName.isEmpty else {
                throw Failure(message: "--part \(partName) needs --agent claude-code|pi and --model. " + instructionsAnalyzeUsage)
            }
            agent = LabAgent(harness: harness, model: modelName, effort: effort)
        }
        let installed = Set(HarnessCatalog.detectAll(in: env).map(\.id))
        let harnesses = InstructionScanner.harnesses.filter(installed.contains)
        let report: InstructionAnalysis.Report
        do {
            report = try await InstructionAnalysis.run(part, days: days, harnesses: harnesses, agent: agent, env: env)
        } catch {
            throw Failure(message: error.localizedDescription)
        }
        if json {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            out(String(decoding: try encoder.encode(report), as: UTF8.self))
            return 0
        }
        var lines = report.notes
        let top = report.costs.sorted { $0.sent > $1.sent }.prefix(8)
        if part == .size, !top.isEmpty {
            lines.append("Most expensive sections, last \(report.days) days:")
            lines += top.map { "  \($0.section) (\($0.file)): ≈ \($0.tokens) tokens × \($0.requests) requests = \($0.sent)" }
        }
        let findings = report.sorted.filter { $0.part == part }
        lines.append(findings.isEmpty ? "No findings." : "Findings:")
        for finding in findings {
            lines.append("  [\(finding.severity.rawValue.uppercased())] \(finding.title)" + (finding.section.map { " · \($0)" } ?? "") + (finding.file.map { " · \($0)" } ?? ""))
            if !finding.why.isEmpty { lines.append("    \(finding.why)") }
            if !finding.places.isEmpty { lines.append("    also: " + finding.places.joined(separator: ", ")) }
            if let suggestion = finding.suggestion { lines.append(suggestion.isEmpty ? "    suggestion: remove it" : "    suggestion:\n" + suggestion.split(separator: "\n", omittingEmptySubsequences: false).map { "      " + $0 }.joined(separator: "\n")) }
        }
        out(lines.joined(separator: "\n"))
        return 0
    }
}
