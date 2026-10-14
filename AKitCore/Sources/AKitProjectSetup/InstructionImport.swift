import AKitBrain
import AKitFoundation
import AKitInstructions
import Foundation

/// Import to Brain… on the Instructions screen (docs/design/instructions.md, step 4): one `##`
/// section of an instruction file becomes part of a layer's AGENTS.md text (the text Edit
/// Layer… changes), in one brain commit. It reaches files at the layer's next render: Update
/// Home Folder for core, Set Up Project for a project's layers. "Also remove it here" takes the
/// section out of the file in the same step (`InstructionEdit`); off by default, since the
/// sessions in between would miss it. After the render the screen shows the two copies, and
/// Remove This Copy… takes the old one out.
public enum InstructionImport {
    public struct Failure: Error, LocalizedError {
        public let message: String
        public var errorDescription: String? { message }
    }

    public struct Plan: Sendable {
        public let layer: String
        public let heading: String?
        /// The layer's AGENTS.md text before and after.
        public let before: String
        public let after: String
        /// The section as it is added (LF, trimmed).
        let piece: String
        /// The file without the section, when it should leave the file too.
        public let removal: InstructionEdit.Plan?
        public let notes: [String]

        public var diff: [TextDiff.Line] { TextDiff.lines(from: before, to: after) }
    }

    /// The layer an import from this file starts with: core for a global file or one above the
    /// project; for a project's file the first layer the brain's record of it picks, else core.
    public static func suggestedLayer(for level: InstructionLevel, project: URL?, brain: Brain, projects: [String: URL]) -> String {
        guard level == .project, let project,
              let id = projects.first(where: { $0.value.standardizedFileURL.path == project.standardizedFileURL.path })?.key,
              let record = brain.projects.first(where: { $0.id == id }),
              let first = brain.layers(of: record).first(where: { $0 != "core" }) else {
            return brain.layers.contains { $0.name == "core" } ? "core" : brain.layers.first?.name ?? "core"
        }
        return first
    }

    /// What importing would change. Only reads (`git ls-files` for the removal's note).
    public static func plan(_ section: InstructionSection, from file: URL, into layerName: String, removeHere: Bool,
                            brain: Brain, rendered: Set<String>, env: HarnessEnvironment) throws(Failure) -> Plan {
        let shown = FileWalk.tilde(file, home: env.homeDirectory)
        if section.isAKitBlock { throw Failure(message: "This is AKit's block of the core layer: it is in the brain already.") }
        guard section.heading != nil else {
            throw Failure(message: "Only a section under a ## heading can go to the brain; the text before the first heading stays in its file.")
        }
        if InstructionEdit.hasOpenFence(section.text) {
            throw Failure(message: "This section opens a code fence that never closes, so AKit can't tell where it ends. Edit the file by hand.")
        }
        guard let text = (try? Data(contentsOf: file)).flatMap({ String(data: $0, encoding: .utf8) }),
              InstructionText.units(text).contains(where: { $0.line == section.line && $0.text == section.text && !$0.isAKitBlock }) else {
            throw Failure(message: "\(shown) changed since the screen read it. Look at the screen again.")
        }
        guard let layer = brain.layers.first(where: { $0.name == layerName }) else {
            throw Failure(message: "The brain has no layer \(layerName).")
        }
        if LayerEditor.agentsFile(of: layer) == nil, layer.files.contains(where: { $0.to == "AGENTS.md" }) {
            throw Failure(message: "The \(layerName) layer sends its AGENTS.md text only under a when: condition. Edit the layer by hand.")
        }
        let before = LayerEditor.details(of: layer).agentsSection
        let own = InstructionText.normalized(section)
        let units = InstructionText.units(before)
        if units.contains(where: { InstructionText.normalized($0) == own }) {
            throw Failure(message: "The \(layerName) layer's AGENTS.md text has this section already.")
        }
        // Templates are LF files; the section's own trailing blank lines don't come along.
        let piece = section.text.replacingOccurrences(of: "\r\n", with: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        let after = before.isEmpty ? piece : before + "\n\n" + piece

        var removal: InstructionEdit.Plan?
        if removeHere {
            do {
                removal = try InstructionEdit.removing(section, from: file, rendered: rendered, env: env)
            } catch {
                throw Failure(message: error.message)
            }
        }
        var notes: [String] = []
        if let heading = section.heading?.lowercased(), units.contains(where: { $0.heading?.lowercased() == heading }) {
            notes.append("The \(layerName) layer has a ## \(section.heading ?? "") with other text already: the model would get both. Edit the layer after this, or pick another one.")
        }
        if piece.contains("{{") {
            notes.append("The section has {{…}}: a layer fills fields with that form when it renders, so the text may change there.")
        }
        if !InstructionText.imports(in: piece).isEmpty {
            notes.append("The section has @… words: Claude Code reads @paths relative to the file, so in the layer's files they may point elsewhere.")
        }
        if layerName == "core" {
            notes.append("It reaches the harnesses' global files at Brain → core → Update Home Folder… (on every Mac after Sync).")
        } else {
            let users = brain.projects(using: layerName).map(\.id)
            notes.append(users.isEmpty
                ? "No project uses the \(layerName) layer yet: pick it in a project's Set Up Project… to bring the section there."
                : "It reaches \(users.joined(separator: ", ")) when Set Up Project… runs there again.")
        }
        notes.append(removeHere
            ? "\(shown) loses the section now; sessions miss it until that render."
            : "\(shown) keeps its copy. After the render, the screen shows both; Remove This Copy… takes this one out.")
        return Plan(layer: layerName, heading: section.heading, before: before, after: after, piece: piece, removal: removal,
                    notes: notes + (removal?.notes ?? []))
    }

    /// The layer's AGENTS.md text gets the section (a brain commit), then the file loses it when
    /// asked. Refused when the layer's text changed since the plan.
    public static func apply(_ plan: Plan, brain: Brain, env: HarnessEnvironment) async throws(Failure) {
        // The file first: when it changed since the preview, nothing is written at all.
        if let removal = plan.removal, (try? Data(contentsOf: removal.file)) != removal.before {
            throw Failure(message: "\(FileWalk.tilde(removal.file, home: env.homeDirectory)) changed since the preview. Look at the preview again.")
        }
        do {
            try await LayerEditor.appendToAgentsSection(plan.piece, inLayer: plan.layer, expected: plan.before, in: brain, env: env)
        } catch {
            throw Failure(message: error.message)
        }
        guard let removal = plan.removal else { return }
        do {
            try InstructionEdit.apply(removal, env: env)
        } catch {
            throw Failure(message: "The \(plan.layer) layer has the section (committed in the brain), but \(FileWalk.tilde(removal.file, home: env.homeDirectory)) still has it: \(error.message) After the layer's next render the screen shows both copies, and Remove This Copy… takes this one out.")
        }
    }
}
