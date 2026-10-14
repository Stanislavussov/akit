import AKitFoundation
import AKitHarnesses
import AKitInstructions
import AKitModel
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
}
