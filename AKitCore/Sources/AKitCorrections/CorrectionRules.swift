import AKitBrain
import AKitFoundation
import AKitInsights
import AKitProjectSetup
import Foundation

/// Apply… and Remove Rule… (`docs/design/corrections.md`, parts 3 and 4): a pattern's rule as one
/// bullet under one `##` heading of Global Instructions (the core layer) or of a project's own
/// instruction file, with a diff first and a backup; never a commit in a project.
public enum CorrectionRules {
    public static let globalTarget = "global"
    public static let heading = "Rules from corrections"

    public struct Failure: Error, LocalizedError {
        public let message: String
        public var errorDescription: String? { message }
    }

    public enum Target: Hashable, Sendable {
        /// Brain → Global Instructions: every session on this Mac.
        case global
        /// A project's own instruction file, in its main checkout.
        case project(id: String, folder: URL)

        public var scope: String? {
            if case .project(let id, _) = self { return id }
            return nil
        }
    }

    /// What Apply… or Remove Rule… would write.
    public struct Plan: Sendable {
        public let ruleID: String
        public let target: Target
        /// `Global Instructions (core layer)` or the file's `~/…` path.
        public let shown: String
        public let lines: [TextDiff.Line]
        public let notes: [String]
        let global: GlobalInstructions.EditPlan?
        let file: InstructionEdit.Plan?
    }

    // MARK: - Text

    /// The rule as one bullet: the first line after `- `, the others indented under it.
    public static func bullet(_ rule: [String]) -> String {
        "- " + rule.joined(separator: "\n  ")
    }

    /// The text with the bullet at the end of the `## Rules from corrections` section, which is
    /// added at the end when there is none. Every other byte stays.
    public static func adding(_ bullet: String, to text: String) -> String {
        var lines = text.components(separatedBy: "\n")
        let isBlank: (String) -> Bool = { $0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard let start = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "## \(heading)" }) else {
            let body = text.trimmingCharacters(in: .newlines)
            return (body.isEmpty ? "" : body + "\n\n") + "## \(heading)\n\n\(bullet)\n"
        }
        var end = lines[(start + 1)...].firstIndex(where: isHeading) ?? lines.count
        while end > start + 1, isBlank(lines[end - 1]) { end -= 1 }
        var insert = bullet.components(separatedBy: "\n")
        if end == start + 1 { insert.insert("", at: 0) }
        lines.insert(contentsOf: insert, at: end)
        let result = lines.joined(separator: "\n")
        return result.hasSuffix("\n") ? result : result + "\n"
    }

    /// The text without the bullet; the heading goes too when its section is left empty. nil when
    /// the bullet isn't in the section (it was changed or moved by hand).
    public static func removing(_ bullet: String, from text: String) -> String? {
        var lines = text.components(separatedBy: "\n")
        let isBlank: (String) -> Bool = { $0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard let start = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "## \(heading)" }) else { return nil }
        let end = lines[(start + 1)...].firstIndex(where: isHeading) ?? lines.count
        let own = bullet.components(separatedBy: "\n")
        guard let at = (start + 1..<max(start + 1, end - own.count + 1)).first(where: { Array(lines[$0..<($0 + own.count)]) == own }) else {
            return nil
        }
        lines.removeSubrange(at..<(at + own.count))
        let newEnd = end - own.count
        if lines[(start + 1)..<newEnd].allSatisfy(isBlank) {
            lines.removeSubrange(start..<newEnd)
            // One blank line between the parts around it, none at the start.
            while start < lines.count, start > 0, isBlank(lines[start]), isBlank(lines[start - 1]) { lines.remove(at: start) }
            while let first = lines.first, isBlank(first), lines.count > 1 { lines.removeFirst() }
        }
        var result = lines.joined(separator: "\n")
        while result.hasSuffix("\n\n") { result.removeLast() }
        return result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "" : result
    }

    static func isHeading(_ line: String) -> Bool {
        line.hasPrefix("# ") || line.hasPrefix("## ")
    }

    // MARK: - Targets

    /// AKit's proposal (part 3): reactions from one project → that project, else global.
    public static func proposedTarget(_ pattern: CorrectionPattern, projectFolders: [String: URL]) -> Target {
        if let scope = pattern.scope, let folder = projectFolders[scope] { return .project(id: scope, folder: folder) }
        return .global
    }

    /// The instruction file the scope's harnesses read in a project (Claude Code reads AGENTS.md
    /// only when there is no CLAUDE.md; Pi reads AGENTS.md first, else CLAUDE.md).
    public static func projectFile(in folder: URL, harnesses: Set<String>) -> URL {
        let agents = folder.appending(path: "AGENTS.md"), claude = folder.appending(path: "CLAUDE.md")
        let fm = FileManager.default
        switch (fm.fileExists(atPath: agents.path), fm.fileExists(atPath: claude.path)) {
        case (true, false): return agents
        case (false, true): return claude
        default: return harnesses.contains("claude") || harnesses.isEmpty ? claude : agents
        }
    }

    // MARK: - Plans

    public static func planApply(_ pattern: CorrectionPattern, to target: Target, brain: Brain?, rendered: Set<String>,
                                 env: HarnessEnvironment) throws(Failure) -> Plan {
        try plan(id: pattern.id, target: target, brain: brain, rendered: rendered, env: env,
                 harnesses: Set(pattern.reactions.map { String($0.sessionKey.prefix { $0 != ":" }) })) { text throws(Failure) in
            adding(bullet(pattern.rule), to: text)
        }
    }

    public static func planRemove(_ rule: CorrectionRule, brain: Brain?, rendered: Set<String>, env: HarnessEnvironment) throws(Failure) -> Plan {
        let target: Target
        if rule.isGlobal {
            target = .global
        } else {
            guard let scope = rule.scope else { throw Failure(message: "The rule's project is not recorded.") }
            target = .project(id: scope, folder: URL(filePath: rule.target).deletingLastPathComponent())
        }
        return try plan(id: rule.id, target: target, brain: brain, rendered: rendered, env: env, harnesses: [],
                        file: rule.isGlobal ? nil : URL(filePath: rule.target)) { text throws(Failure) in
            guard let after = removing(bullet(rule.rule), from: text) else {
                throw Failure(message: "The rule's bullet is no longer under “## \(heading)” as written; it was changed by hand. Remove it there.")
            }
            return after
        }
    }

    static func plan(id: String, target: Target, brain: Brain?, rendered: Set<String>, env: HarnessEnvironment, harnesses: Set<String>,
                     file chosen: URL? = nil, change: (String) throws(Failure) -> String) throws(Failure) -> Plan {
        switch target {
        case .global:
            guard let brain else { throw Failure(message: "No brain: Global Instructions live in the brain's core layer. Create one with akit init.") }
            guard let core = brain.layers.first(where: { $0.name == "core" }) else { throw Failure(message: "The brain has no core layer.") }
            let before = LayerEditor.details(of: core).agentsSection
            let edit: GlobalInstructions.EditPlan
            do { edit = try GlobalInstructions.editing(to: try change(before), brain: brain) } catch let error as Failure {
                throw error
            } catch {
                throw Failure(message: (error as? GlobalInstructions.Failure)?.message ?? error.localizedDescription)
            }
            return Plan(ruleID: id, target: target, shown: "Global Instructions (the core layer's AGENTS.md)", lines: edit.lines,
                        notes: ["Committed to the brain, then written into the global files (a backup first)."], global: edit, file: nil)
        case .project(_, let folder):
            let file = chosen ?? projectFile(in: folder, harnesses: harnesses)
            let original = try? Data(contentsOf: file)
            guard let text = original.map({ String(decoding: $0, as: UTF8.self) }) ?? "" as String? else {
                throw Failure(message: "\(file.path) can't be read.")
            }
            let edit: InstructionEdit.Plan
            do { edit = try InstructionEdit.editing(file, original: original, to: try change(text), rendered: rendered, env: env) } catch let error as Failure {
                throw error
            } catch {
                throw Failure(message: (error as? InstructionEdit.Failure)?.message ?? error.localizedDescription)
            }
            return Plan(ruleID: id, target: target, shown: FileWalk.tilde(file, home: env.homeDirectory), lines: edit.diff,
                        notes: edit.notes, global: nil, file: edit)
        }
    }

    // MARK: - Writing

    /// Writes the plan, marks the moment in the spool and records the rule. Returns lines of what
    /// was written. `context` writes Global Instructions into the global files.
    @discardableResult
    public static func apply(_ plan: Plan, pattern: CorrectionPattern, brain: Brain?, context: SkillMove.Context?, env: HarnessEnvironment,
                             now: Date = Date()) async throws(Failure) -> [String] {
        var state: CorrectionsState
        do { state = try CorrectionsState.load(env: env) } catch { throw Failure(message: error.message) }
        let written = try await write(plan, brain: brain, context: context, env: env)
        let note = "Rule from corrections \(pattern.id): \(pattern.title)"
        do { try Spool.mark(String(note.prefix(Spool.maxNoteLength)), at: now, home: env.homeDirectory, now: now) } catch {
            throw Failure(message: "The rule was written, but its mark wasn't: \(error.message)")
        }
        state.rules.removeAll { $0.id == pattern.id }
        state.rules.append(CorrectionRule(id: pattern.id, title: pattern.title, rule: pattern.rule, scope: plan.target.scope,
                                          target: plan.file?.file.path ?? globalTarget, applied: now,
                                          places: pattern.places.sorted()))
        do { try state.save(env: env) } catch { throw Failure(message: error.message) }
        return written
    }

    /// Takes the rule out and records when; its verdict stops.
    @discardableResult
    public static func remove(_ plan: Plan, brain: Brain?, context: SkillMove.Context?, env: HarnessEnvironment,
                              now: Date = Date()) async throws(Failure) -> [String] {
        var state: CorrectionsState
        do { state = try CorrectionsState.load(env: env) } catch { throw Failure(message: error.message) }
        guard let index = state.rules.firstIndex(where: { $0.id == plan.ruleID && $0.removed == nil }) else {
            throw Failure(message: "No applied rule \(plan.ruleID).")
        }
        let written = try await write(plan, brain: brain, context: context, env: env)
        state.rules[index].removed = now
        do { try state.save(env: env) } catch { throw Failure(message: error.message) }
        return written
    }

    static func write(_ plan: Plan, brain: Brain?, context: SkillMove.Context?, env: HarnessEnvironment) async throws(Failure) -> [String] {
        if let edit = plan.file {
            do { try InstructionEdit.apply(edit, env: env) } catch { throw Failure(message: error.message) }
            return ["Written into \(plan.shown) (a backup first). AKit doesn't commit it."]
        }
        guard let edit = plan.global, let brain else { return [] }
        do { try await GlobalInstructions.commit(edit, brain: brain, env: env) } catch { throw Failure(message: error.message) }
        var lines = ["Committed to the brain's core layer."]
        guard let context else { return lines + ["Update Home Folder writes it into the global files."] }
        let blocks = GlobalInstructions.homeBlocks(context: context, brainRoot: brain.root)
        if blocks.canApply {
            do { try await GlobalInstructions.applyHome(blocks, context: context) } catch { throw Failure(message: error.message) }
            lines.append("Written into " + blocks.diffs.map(\.path).joined(separator: ", ") + " (a backup first).")
        } else {
            lines.append("No global file took the block: " + (blocks.warnings.isEmpty ? "nothing to change." : blocks.warnings.joined(separator: " ")))
        }
        return lines
    }
}
