import AKitBrain
import AKitFoundation
import Foundation

/// Turns a `ProjectBundle` into harness files: skills in `.agents/skills`, glued Markdown
/// files, the CLAUDE.md shim and the `.claude/skills` link. Pure: writes nothing.
public enum Render {
    /// `forHome`: rendering the core layer into the home folder, where no harness reads
    /// ~/AGENTS.md, so there is no CLAUDE.md shim (the .claude/skills link still applies).
    public static func render(_ bundle: ProjectBundle, forHome: Bool = false) -> RenderResult {
        var errors = bundle.errors
        var warnings = bundle.warnings

        // 3. Skills, each in its own folder; manual ones get the header that stops models from starting them.
        var outputs: [RenderedFile] = []
        for skill in bundle.skills {
            for (relative, var data) in skill.files.sorted(by: { $0.key < $1.key }) {
                if relative == "SKILL.md", skill.mode == .manual, let text = String(data: data, encoding: .utf8) {
                    guard let manual = manualOnly(text) else {
                        errors.append("skills/\(skill.name)/SKILL.md has no --- header, so it can't be made manual.")
                        continue
                    }
                    data = Data(manual.utf8)
                }
                outputs.append(RenderedFile(path: "\(ProjectBundle.skillsFolder)/\(skill.name)/\(relative)", content: .data(data), layers: [skill.source]))
            }
        }

        // 4. Files from templates. Markdown targets are glued in layer order; other
        //    files from two layers clash unless the later one overrides.
        var pieces: [String: [ProjectBundle.File]] = [:]
        var targetsInOrder: [String] = []
        for file in bundle.files {
            if pieces[file.to] == nil { targetsInOrder.append(file.to) }
            pieces[file.to, default: []].append(file)
        }
        for path in targetsInOrder {
            let parts = pieces[path] ?? []
            if ProjectBundle.isJSON(path) {
                let layers = parts.map(\.layer).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
                // Not merged into the home folder yet (~/.claude/settings.json is the user's).
                guard !forHome else {
                    warnings.append("\(path) (\(layers.joined(separator: ", "))): JSON files are not rendered into the home folder yet; skipped.")
                    continue
                }
                let merged = mergeJSON(parts, path: path, errors: &errors)
                outputs.append(RenderedFile(path: path, content: .data(Data(merged.pretty.utf8)), layers: layers, mergesJSON: true))
            } else if isMarkdown(path) {
                // An empty section (cleared in Edit Layer) adds nothing; an AGENTS.md of
                // only empty sections is not written. Other empty Markdown files stay.
                let all = parts.map { (layer: $0.layer, text: String(decoding: $0.data, as: UTF8.self).trimmingCharacters(in: .newlines)) }
                let filled = all.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                let sections = filled.isEmpty && path != "AGENTS.md" ? all : filled
                guard !sections.isEmpty else { continue }
                outputs.append(RenderedFile(path: path, content: .data(Data((sections.map(\.text).joined(separator: "\n\n") + "\n").utf8)),
                                            layers: sections.map(\.layer)))
            } else if let winner = parts.last(where: \.override) ?? parts.last {
                if parts.count > 1, !parts.contains(where: \.override) {
                    errors.append("\(path) comes from \(parts.map(\.layer).joined(separator: " and ")). Set override: true in the layer that should win.")
                }
                outputs.append(RenderedFile(path: path, content: .data(winner.data), layers: [winner.layer]))
            }
        }

        // 5. Claude reads CLAUDE.md and .claude/skills; point them at the shared files.
        let paths = Set(outputs.map(\.path))
        if bundle.targets.contains("claude") {
            if !forHome, paths.contains("AGENTS.md"), !paths.contains("CLAUDE.md") {
                outputs.append(RenderedFile(path: "CLAUDE.md", content: .data(Data("@AGENTS.md\n".utf8)), layers: []))
            }
            if !bundle.skills.isEmpty {
                if paths.contains(where: { $0.hasPrefix(".claude/skills/") }) {
                    errors.append("A layer writes into .claude/skills, so it can't link to .agents/skills.")
                } else {
                    outputs.append(RenderedFile(path: ".claude/skills", content: .link("../.agents/skills"), layers: []))
                }
            }
        }

        // Every path once, and never inside .git (a layer could plant a hook).
        var seen: Set<String> = []
        for output in outputs where !seen.insert(output.path).inserted {
            errors.append("\(output.path) is written twice (a template and a skill or the Claude link). Rename one.")
        }
        for output in outputs where output.path.split(separator: "/").contains(".git") {
            errors.append("\(output.path) is inside .git; layers can't write there.")
        }

        return RenderResult(layers: bundle.layers, outputs: outputs.sorted { $0.path < $1.path }, errors: errors,
                            warnings: warnings, skills: bundle.skills.map { .init(name: $0.name, mode: $0.mode, source: $0.source) })
    }

    // MARK: - Pieces

    /// SKILL.md with `disable-model-invocation: true` in its header; nil without a header.
    static func manualOnly(_ text: String) -> String? {
        let newline = text.contains("\r\n") ? "\r\n" : "\n"
        let bom = text.hasPrefix("\u{FEFF}")
        var lines = String(text.dropFirst(bom ? 1 : 0)).components(separatedBy: newline)
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---",
              let end = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }) else { return nil }
        let line = "disable-model-invocation: true"
        // The key as written: bare or quoted, with or without a space before the colon.
        let existing = lines[1..<end].firstIndex { raw in
            let key = raw.split(separator: ":", maxSplits: 1).first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
            return !raw.hasPrefix(" ") && key.trimmingCharacters(in: CharacterSet(charactersIn: "\"'")) == "disable-model-invocation"
        }
        if let existing { lines[existing] = line } else { lines.insert(line, at: end) }
        return (bom ? "\u{FEFF}" : "") + lines.joined(separator: newline)
    }

    /// The layers' JSON for one file, merged key by key in layer order. Objects merge; arrays
    /// and other values are leaves. Two layers giving one leaf different values is an error,
    /// unless one sets `override: true` (that one wins; the later one when both do).
    static func mergeJSON(_ parts: [ProjectBundle.File], path: String, errors: inout [String]) -> JSONValue {
        var leaves: [(path: [String], value: JSONValue, layer: String, override: Bool)] = []
        var reported: Set<[String]> = []
        func overlaps(_ a: [String], _ b: [String]) -> Bool { a.count <= b.count ? Array(b.prefix(a.count)) == a : Array(a.prefix(b.count)) == b }
        for part in parts {
            // The bundle has checked that every part is a JSON object.
            guard let tree = try? JSONValue.parse(part.data) else { continue }
            for leaf in tree.leaves {
                let clashes = leaves.indices.filter { overlaps(leaves[$0].path, leaf.path) }
                if clashes.count == 1, leaves[clashes[0]].path == leaf.path, leaves[clashes[0]].value == leaf.value { continue }
                if !clashes.isEmpty {
                    if !part.override {
                        let owners = clashes.map { leaves[$0] }
                        if !owners.contains(where: \.override), reported.insert(leaf.path).inserted {
                            let others = owners.map(\.layer).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
                            errors.append("\(path): \(JSONValue.display(leaf.path)) is set differently by \(others.joined(separator: " and ")) and \(part.layer). Set override: true in the layer that should win.")
                        }
                        continue
                    }
                    for index in clashes.reversed() { leaves.remove(at: index) }
                }
                leaves.append((leaf.path, leaf.value, part.layer, part.override))
            }
        }
        var merged = JSONValue.object([:])
        for leaf in leaves { merged.set(leaf.value, at: leaf.path) }
        return merged
    }

    private static func isMarkdown(_ path: String) -> Bool { path.lowercased().hasSuffix(".md") }
}
