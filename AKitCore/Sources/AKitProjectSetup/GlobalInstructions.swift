import AKitBrain
import AKitFoundation
import AKitHarnesses
import AKitInstructions
import AKitModel
import Foundation

/// The global instructions (docs/design/global-instructions.md): the core layer's AGENTS.md text,
/// the one source, and its copies as AKit's marked block in each harness's global file. Shows
/// where the text goes and whether each copy is current, and edits it through the brain:
///
/// ```
/// core text ──Edit… (diff, commit)──▶ brain ──home blocks (diff, Apply)──▶ ~/.claude/CLAUDE.md, Pi's AGENTS.md
/// ```
public enum GlobalInstructions {
    public struct Failure: Error, LocalizedError {
        public let message: String
        public var errorDescription: String? { message }
    }

    /// Another tool's marked block in a global file (`<!-- OMC:START -->` … `<!-- OMC:END -->`):
    /// shown and counted, never taken over or edited by AKit.
    public struct ManagedBlock: Hashable, Sendable {
        public let name: String
        /// 1-based lines of the start and end markers.
        public let lines: ClosedRange<Int>
        public let bytes: Int
    }

    /// One global file and AKit's block in it.
    public struct Copy: Identifiable, Hashable, Sendable {
        public enum State: Hashable, Sendable {
            /// The block has the core text as it is now.
            case current
            /// Update Home Folder changes the block (or adds it, or takes it out).
            case outdated(String)
            /// The harness reads this file, but AKit writes no block into it.
            case noBlock(String)
        }

        public let file: URL
        /// `~/…` for display.
        public let path: String
        /// Harnesses that read the file as their global instructions.
        public let harnesses: [HarnessID]
        public let state: State
        /// Update Home Folder writes AKit's block into this file (Claude's CLAUDE.md, Pi's file),
        /// as the home folder's harnesses are set; a file only imported or read by another
        /// harness gets none, so its own text can't leave it.
        public let getsBlock: Bool
        /// The whole file as the harnesses read it.
        public let bytes: Int
        /// Other tools' blocks in it.
        public let managed: [ManagedBlock]
        /// The user's own sections: not AKit's block, not in another tool's block, not blank.
        public let own: [InstructionSection]
        /// Lines of the `own` sections cut out of a section another tool's block shares.
        public let partial: [Int]
        public var id: String { file.path }
        public var ownBytes: Int { own.reduce(0) { $0 + $1.bytes } }
    }

    public struct Status: Sendable {
        /// The core layer's AGENTS.md text, trimmed; empty when core has none.
        public let text: String
        /// The brain has a core layer.
        public let hasCore: Bool
        public let copies: [Copy]
        /// Notes from the home render (warnings, why it can't apply).
        public let notes: [String]

        public var bytes: Int { text.utf8.count }
        /// ≈ tokens as the Instructions screen counts them (bytes / 4).
        public var tokens: Int { bytes / 4 }
        public var outdated: Bool { copies.contains { if case .outdated = $0.state { true } else { false } } }
    }

    // MARK: - Reading

    /// The core text, the global files of the installed harnesses and their blocks. Only reads.
    public static func status(context: SkillMove.Context, brain: Brain) -> Status {
        let env = context.env, home = env.homeDirectory
        guard let core = brain.layers.first(where: { $0.name == "core" }) else {
            return Status(text: "", hasCore: false, copies: [], notes: ["The brain has no core layer."])
        }
        let text = LayerEditor.details(of: core).agentsSection
        let homePlan = plan(context: context, brain: brain)
        let url: (String) -> URL = { $0.hasPrefix("/") ? URL(filePath: $0) : home.appending(path: $0) }
        let blockChanges = homePlan.changes.filter(\.block)
        let targets = blockTargets(homePlan, context: context)

        // Every installed harness's loaded global files, one copy per real file.
        var order: [String] = [], readers: [String: [HarnessID]] = [:], entries: [String: InstructionEntry] = [:]
        for harness in InstructionMove.installed(env) {
            for entry in InstructionScanner.view(harness: harness, project: nil, env: env).loaded where entry.level == .global {
                let key = InstructionEdit.realPath(entry.file)
                if readers[key] == nil { order.append(key); entries[key] = entry }
                readers[key, default: []].append(harness)
            }
        }
        // A block AKit would add to a file no harness reads yet (Pi's new AGENTS.md) is a copy too.
        for change in blockChanges where change.blockAction == .add {
            let key = InstructionEdit.realPath(url(change.path))
            if readers[key] == nil { order.append(key); readers[key] = [] }
        }

        let copies = order.map { key -> Copy in
            let entry = entries[key]
            let file = entry?.file ?? URL(filePath: key)
            let change = blockChanges.first { InstructionEdit.realPath(url($0.path)) == key }
            let fileText = entry?.text ?? ""
            let managed = managedBlocks(in: fileText)
            let parts = ownParts(of: fileText, managed: managed)
            return Copy(file: file, path: FileWalk.tilde(file, home: home), harnesses: readers[key] ?? [],
                        state: homePlan.canApply ? state(of: change, text: fileText, coreIsEmpty: text.isEmpty)
                            : .noBlock("AKit can't render the core text now; the notes below say why."),
                        getsBlock: targets.contains(key), bytes: fileText.utf8.count, managed: managed,
                        own: parts.map(\.section), partial: parts.filter(\.partial).map(\.section.line))
        }
        var notes = homePlan.render.warnings
        if !homePlan.canApply { notes += homePlan.render.errors + homePlan.blockers }
        return Status(text: text, hasCore: true, copies: copies, notes: notes)
    }

    /// The files Update Home Folder writes AKit's block into, by real path.
    static func blockTargets(_ plan: ProjectSetup.Plan, context: SkillMove.Context) -> Set<String> {
        let home = context.env.homeDirectory
        var urls: [URL] = []
        if plan.answers.targets.contains("claude") { urls.append(home.appending(path: InstructionsBlock.claudePath)) }
        if plan.answers.targets.contains("pi"),
           let folder = InstructionsBlock.piDirectory(setting: context.piAgentDirSetting, recorded: plan.previous?.piAgentDir,
                                                      remember: context.rememberPiAgentDir, home: home).url {
            urls.append(InstructionsBlock.piFile(in: folder))
        }
        return Set(urls.map(InstructionEdit.realPath))
    }

    static func state(of change: ProjectSetup.Change?, text: String, coreIsEmpty: Bool) -> Copy.State {
        guard let change else {
            if InstructionText.sections(text).contains(where: \.isAKitBlock) { return .current }
            return .noBlock(coreIsEmpty ? "core has no text yet." : "AKit writes no core block into this file.")
        }
        if change.kind == .same { return .current }
        switch change.blockAction {
        case .add: return .outdated(text.isEmpty ? "Update Home Folder creates it with the core block." : "Update Home Folder adds the core block.")
        case .update: return .outdated(change.blockNote ?? "Update Home Folder brings the new core text.")
        case .takeOut, .trash: return .outdated("Update Home Folder takes the core block out: core has no text.")
        case nil: return .outdated(change.blockNote ?? "Update Home Folder changes it.")
        }
    }

    /// `<!-- NAME:START -->` … `<!-- NAME:END -->` pairs, outside code fences. A start without
    /// its end runs to the end of the file: AKit can't tell where that tool's text stops.
    public static func managedBlocks(in text: String) -> [ManagedBlock] {
        let lines = InstructionText.lines(text)
        var open: (name: String, line: Int)?
        var found: [ManagedBlock] = []
        var fence: Fence?
        let bytes = { (range: ClosedRange<Int>) in lines[(range.lowerBound - 1)...(range.upperBound - 1)].reduce(0) { $0 + $1.utf8.count + 1 } }
        for (index, raw) in lines.enumerated() {
            var line = raw
            if index == 0, line.unicodeScalars.first == "\u{FEFF}" { line.unicodeScalars.removeFirst() }
            line = line.trimmingCharacters(in: .whitespaces.union(CharacterSet(charactersIn: "\r")))
            if let current = fence {
                if current.closes(line) { fence = nil }
                continue
            }
            if let opening = Fence(opening: line) {
                fence = opening
                continue
            }
            guard let marker = marker(line) else { continue }
            if marker.start, open == nil {
                open = (marker.name, index + 1)
            } else if !marker.start, let current = open, current.name == marker.name {
                found.append(ManagedBlock(name: marker.name, lines: current.line...(index + 1), bytes: bytes(current.line...(index + 1))))
                open = nil
            }
        }
        // The split leaves an empty last line after a final newline: not a line of the file.
        let last = lines.last?.isEmpty == true ? lines.count - 1 : lines.count
        if let open, last >= open.line {
            found.append(ManagedBlock(name: open.name, lines: open.line...last, bytes: bytes(open.line...last)))
        }
        return found
    }

    /// Another tool's marker line (`<!-- NAME:START -->` / `<!-- NAME:END -->`), not AKit's.
    static func marker(_ line: String) -> (name: String, start: Bool)? {
        guard line.hasPrefix("<!--"), line.hasSuffix("-->") else { return nil }
        let parts = line.dropFirst(4).dropLast(3).trimmingCharacters(in: .whitespaces).split(separator: ":")
        guard parts.count == 2, let name = parts.first.map(String.init), !name.isEmpty, name.lowercased() != "akit",
              name.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }) else { return nil }
        switch parts[1].uppercased() {
        case "START": return (name, true)
        case "END": return (name, false)
        default: return nil
        }
    }

    /// The text has a block marker of AKit or of another tool on a line of its own.
    static func hasMarkers(_ text: String) -> Bool {
        InstructionText.lines(text).contains { raw in
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            return line == InstructionText.akitStart || line == InstructionText.akitEnd || marker(line) != nil
        }
    }

    /// The file's sections that are the user's: not AKit's block, not blank, and not inside
    /// another tool's block. A section that shares lines with such a block (the user's text
    /// right above its start, or after its end inside one section) keeps only its own lines and
    /// is marked `partial`: AKit can copy that text, but can't take it out of the file.
    static func ownSections(of text: String, managed: [ManagedBlock]) -> [InstructionSection] {
        ownParts(of: text, managed: managed).map(\.section)
    }

    static func ownParts(of text: String, managed: [ManagedBlock]) -> [(section: InstructionSection, partial: Bool)] {
        InstructionText.sections(text).flatMap { section -> [(section: InstructionSection, partial: Bool)] in
            guard !section.isAKitBlock, !section.isBlank else { return [] }
            let lines = InstructionText.lines(section.text)
            let last = section.line + lines.count - 1
            let blocks = managed.filter { $0.lines.lowerBound <= last && $0.lines.upperBound >= section.line }
            guard !blocks.isEmpty else { return [(section, false)] }
            // The section's lines outside every block, in runs.
            var runs: [[(number: Int, text: String)]] = [[]]
            for (offset, line) in lines.enumerated() {
                let number = section.line + offset
                if blocks.contains(where: { $0.lines.contains(number) }) {
                    if !runs[runs.count - 1].isEmpty { runs.append([]) }
                } else {
                    runs[runs.count - 1].append((number, line))
                }
            }
            return runs.compactMap { run -> (section: InstructionSection, partial: Bool)? in
                let kept = run.drop { $0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isComment($0.text) }
                var body = Array(kept)
                while let tail = body.last, tail.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { body.removeLast() }
                guard let first = body.first else { return nil }
                let heading = first.number == section.line ? section.heading : nil
                return (InstructionSection(heading: heading, text: body.map(\.text).joined(separator: "\n") + "\n", isAKitBlock: false, line: first.number), true)
            }
        }
    }

    static func isComment(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasPrefix("<!--") && trimmed.hasSuffix("-->")
    }

    /// The home render with core only, as Update Home Folder would plan it.
    static func plan(context: SkillMove.Context, brain: Brain) -> ProjectSetup.Plan {
        var answers = ProjectRecords.savedAnswers(id: context.homeID, in: context.store) ?? ProjectAnswers(targets: context.targets)
        answers.layers = ["core"]
        return ProjectSetup.plan(project: context.env.homeDirectory, id: context.homeID, answers: answers, brain: brain, store: context.store,
                                 forHome: true, piAgentDirSetting: context.piAgentDirSetting,
                                 rememberPiAgentDir: context.rememberPiAgentDir, env: context.env)
    }

    // MARK: - Editing

    /// Edit…: the core text before and after, as a diff.
    public struct EditPlan: Sendable {
        public let before: String
        public let after: String
        public var lines: [TextDiff.Line] { TextDiff.lines(from: before, to: after) }
        public var isChange: Bool { before != after }
    }

    public static func editing(to text: String, brain: Brain) throws(Failure) -> EditPlan {
        guard let core = brain.layers.first(where: { $0.name == "core" }) else { throw Failure(message: "The brain has no core layer.") }
        if LayerEditor.agentsFile(of: core) == nil, core.files.contains(where: { $0.to == "AGENTS.md" }) {
            throw Failure(message: "The core layer sends its AGENTS.md text only under a when: condition. Edit the layer by hand.")
        }
        let after = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if hasMarkers(after) {
            throw Failure(message: "The text has a block marker line (<!-- …:START --> or <!-- …:END -->, AKit's or another tool's). Take it out: each tool writes its own markers.")
        }
        return EditPlan(before: LayerEditor.details(of: core).agentsSection, after: after)
    }

    /// Step 1: the new text in core (a commit). Refused when core's text changed since the plan.
    public static func commit(_ plan: EditPlan, brain: Brain, env: HarnessEnvironment) async throws(Failure) {
        guard plan.isChange else { return }
        guard let fresh = Brain.load(from: brain.root), let core = fresh.layers.first(where: { $0.name == "core" }) else {
            throw Failure(message: "The brain at \(brain.root.path) can't be read.")
        }
        var details = LayerEditor.details(of: core)
        guard details.agentsSection == plan.before else {
            throw Failure(message: "The core layer's AGENTS.md text changed since the preview. Look at the preview again.")
        }
        details.agentsSection = plan.after
        do {
            try await LayerEditor.update("core", to: details, in: fresh, env: env)
        } catch {
            throw Failure(message: error.message)
        }
    }

    /// Step 2's preview: every change of a core block in the global files, as diffs. Other home
    /// changes (skills) are left for Update Home Folder.
    public struct HomeBlocks: Sendable {
        public struct Diff: Identifiable, Sendable {
            public let path: String
            public let lines: [TextDiff.Line]
            public var id: String { path }
        }

        public let diffs: [Diff]
        public let warnings: [String]
        let home: ProjectSetup.Plan?
        let paths: Set<String>
        let brain: Brain?

        public var canApply: Bool { home != nil && !paths.isEmpty }
    }

    public static func homeBlocks(context: SkillMove.Context, brainRoot: URL) -> HomeBlocks {
        let home = context.env.homeDirectory
        guard let brain = Brain.load(from: brainRoot) else {
            return HomeBlocks(diffs: [], warnings: ["The brain can't be read again."], home: nil, paths: [], brain: nil)
        }
        let homePlan = plan(context: context, brain: brain)
        let changed = homePlan.changes.filter { $0.block && $0.kind != .same }
        let url: (String) -> URL = { $0.hasPrefix("/") ? URL(filePath: $0) : home.appending(path: $0) }
        var warnings = homePlan.render.warnings
        if !homePlan.canApply { warnings += homePlan.render.errors + homePlan.blockers }
        return HomeBlocks(diffs: changed.map { HomeBlocks.Diff(path: FileWalk.tilde(url($0.path), home: home),
                                                               lines: TextDiff.lines(from: $0.oldText ?? "", to: $0.newText ?? "")) },
                          warnings: warnings, home: homePlan.canApply ? homePlan : nil, paths: Set(changed.map(\.path)), brain: brain)
    }

    /// Step 2: the blocks are written (backup first; refused when a file changed since the preview).
    public static func applyHome(_ blocks: HomeBlocks, context: SkillMove.Context,
                                 trash: @escaping (URL) throws -> URL? = Trash.move,
                                 hold: SkillMove.Hold = { _, work in try await work() }) async throws(Failure) {
        guard let homePlan = blocks.home, let brain = blocks.brain, !blocks.paths.isEmpty else {
            throw Failure(message: "No global file takes the core block now. Brain → core → Update Home Folder… shows why.")
        }
        if let path = ProjectSetup.changedSincePreview(homePlan, paths: blocks.paths) {
            throw Failure(message: "~/\(path) changed since the preview. Look at the preview again.")
        }
        let excluded = Set(homePlan.changes.map(\.path)).subtracting(blocks.paths)
        let home = context.env.homeDirectory, env = context.env
        do {
            _ = try await hold(homePlan.id) {
                try await ProjectSetup.apply(homePlan, excluding: excluded, deferring: excluded, brain: brain, home: home, env: env, trash: trash)
            }
        } catch {
            throw Failure(message: "The global files were not updated: \(error.localizedDescription) Brain → core → Update Home Folder… finishes it.")
        }
    }

    /// An analysis suggestion applied to the core text: a section (`## Heading`) of core gets the
    /// new text ("" removes it); no section adds the text at the end. Nil when the section is not
    /// in core (it is in a file's own text: Take Over… first) or nothing would change.
    public static func applying(_ suggestion: String, toSection section: String?, in text: String) -> String? {
        let new = suggestion.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let section else {
            // Only a new section: its own ## heading, not one core has. A rewrite of the
            // whole text would double it.
            guard let heading = InstructionText.sections(new).first?.heading, new.hasPrefix("## "),
                  !InstructionText.sections(text).contains(where: { $0.heading?.lowercased() == heading.lowercased() }) else { return nil }
            return text.isEmpty ? new : text + "\n\n" + new
        }
        let wanted = section.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "^#+\\s*", with: "", options: .regularExpression).lowercased()
        let sections = InstructionText.sections(text)
        guard let index = sections.firstIndex(where: { $0.heading?.trimmingCharacters(in: .whitespaces).lowercased() == wanted }) else { return nil }
        var parts = sections.map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
        if new.isEmpty {
            parts.remove(at: index)
        } else {
            // A suggestion without its heading would merge into the section before it.
            guard new.hasPrefix("## ") else { return nil }
            parts[index] = new
        }
        let result = parts.filter { !$0.isEmpty }.joined(separator: "\n\n")
        return result == text ? nil : result
    }

    // MARK: - Take Over

    /// One piece of own text that can join the core text: the same text in one or more global files.
    public struct Candidate: Identifiable, Hashable, Sendable {
        public struct Place: Hashable, Sendable {
            public let file: URL
            public let path: String
            public let section: InstructionSection
            /// Why AKit can't take it out of this file after the move (it stays there); nil: it can.
            public let stays: String?
        }

        public let heading: String?
        /// The text as the first file has it.
        public let text: String
        public let places: [Place]
        /// Other candidates with the same heading and other text: pick one.
        public internal(set) var differs: [String]
        /// The core text has this text already: only the files' copies can go.
        public let inCore: Bool
        public var id: String { InstructionText.normalized(InstructionSection(heading: heading, text: text, isAKitBlock: false, line: 1)) }
        public var title: String { heading.map { "## \($0)" } ?? String(text.split(separator: "\n").first ?? "") }
    }

    /// The own text of every global file, the same text in two files once, in file order.
    public static func candidates(_ status: Status, env: HarnessEnvironment) -> [Candidate] {
        let core = Set(InstructionText.sections(status.text).map(InstructionText.normalized))
        var order: [String] = [], places: [String: [Candidate.Place]] = [:], first: [String: InstructionSection] = [:]
        for copy in status.copies {
            let partial = Set(copy.partial)
            for section in copy.own {
                let key = InstructionText.normalized(section)
                if places[key] == nil { order.append(key); first[key] = section }
                places[key, default: []].append(.init(file: copy.file, path: copy.path, section: section,
                                                      stays: partial.contains(section.line)
                                                          ? "It shares a section with another tool's block; take it out of the file by hand."
                                                          : stays(section, in: copy, env: env)))
            }
        }
        var list = order.map { key in
            Candidate(heading: first[key]!.heading, text: first[key]!.text, places: places[key]!, differs: [], inCore: core.contains(key))
        }
        for index in list.indices {
            guard let heading = list[index].heading?.lowercased() else { continue }
            list[index].differs = list.filter { $0.id != list[index].id && $0.heading?.lowercased() == heading }.map(\.id)
        }
        return list
    }

    static func stays(_ section: InstructionSection, in copy: Copy, env: HarnessEnvironment) -> String? {
        guard copy.getsBlock else { return "AKit writes no core block into \(copy.path), so it keeps its copy." }
        do {
            _ = try InstructionEdit.removing(section, from: copy.file, rendered: [], env: env)
            return nil
        } catch {
            return error.message
        }
    }

    /// Take Over…: the picked pieces at the end of the core text, as a diff.
    public struct TakeOverPlan: Sendable {
        public let before: String
        public let after: String
        public let picked: [Candidate]
        public var lines: [TextDiff.Line] { TextDiff.lines(from: before, to: after) }
        /// The text added to core (pieces core has already are not added again).
        public var piece: String { picked.filter { !$0.inCore }.map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }.joined(separator: "\n\n") }
    }

    public static func takeOver(_ picked: [Candidate], status: Status) throws(Failure) -> TakeOverPlan {
        guard status.hasCore else { throw Failure(message: "The brain has no core layer.") }
        guard !picked.isEmpty else { throw Failure(message: "Pick at least one section.") }
        if let marked = picked.first(where: { hasMarkers($0.text) }) {
            throw Failure(message: "\(marked.title) holds a block marker line; AKit doesn't move another tool's block.")
        }
        let coreHeadings = Set(InstructionText.sections(status.text).compactMap { $0.heading?.lowercased() })
        if let clash = picked.first(where: { !$0.inCore && $0.heading.map { coreHeadings.contains($0.lowercased()) } == true }) {
            throw Failure(message: "The core text has \(clash.title) already, with other text. Edit… the core text to merge them instead.")
        }
        let ids = Set(picked.map(\.id))
        if let clash = picked.first(where: { !$0.differs.filter(ids.contains).isEmpty }) {
            throw Failure(message: "Two versions of \(clash.title) are picked. Keep one; edit the core text afterwards to merge them.")
        }
        // Text without a ## heading would become part of the section before it: it goes first,
        // and only into an empty core text.
        let ordered = picked.filter { $0.heading == nil } + picked.filter { $0.heading != nil }
        let leads = ordered.filter { $0.heading == nil && !$0.inCore }
        if !leads.isEmpty, !status.text.isEmpty || leads.count > 1 {
            throw Failure(message: "\(leads[0].title) has no ## heading, so in the core text it would join the section before it. Give it a ## heading in its file first.")
        }
        let added = ordered.filter { !$0.inCore }.map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
        let after = ([status.text].filter { !$0.isEmpty } + added).joined(separator: "\n\n")
        return TakeOverPlan(before: status.text, after: after, picked: ordered)
    }

    /// Step 1: the pieces join core (one commit). Refused when core changed since the plan.
    public static func commit(_ plan: TakeOverPlan, brain: Brain, env: HarnessEnvironment) async throws(Failure) {
        guard !plan.piece.isEmpty else { return }
        do {
            try await LayerEditor.appendToAgentsSection(plan.piece, inLayer: "core", expected: plan.before, in: brain, env: env)
        } catch {
            throw Failure(message: error.message)
        }
    }

    /// Step 3, after the blocks are written: each picked piece leaves each file whose own block
    /// now has it (checked on disk), one write per section with a backup. A file without the
    /// piece in its block, or one AKit can't edit, keeps its copy. Returns what stayed and why.
    public static func removeTakenOver(_ plan: TakeOverPlan, env: HarnessEnvironment) -> [String] {
        var kept: [String] = []
        for candidate in plan.picked {
            for place in candidate.places {
                if let stays = place.stays { kept.append("\(place.path) keeps \(candidate.title): \(stays)"); continue }
                guard let data = try? Data(contentsOf: place.file), let text = String(data: data, encoding: .utf8) else {
                    kept.append("\(place.path) keeps \(candidate.title): it can't be read.")
                    continue
                }
                guard InstructionText.units(text).contains(where: { $0.isAKitBlock && InstructionText.normalized($0) == candidate.id }) else {
                    kept.append("\(place.path) keeps \(candidate.title): its core block doesn't have it yet.")
                    continue
                }
                // Only a whole own section (never one inside another tool's block), at its line
                // in the preview when it is still there.
                let whole = ownParts(of: text, managed: managedBlocks(in: text)).filter { !$0.partial && InstructionText.normalized($0.section) == candidate.id }
                guard let own = (whole.first { $0.section.line == place.section.line } ?? whole.first)?.section else {
                    kept.append("\(place.path) keeps \(candidate.title): it changed since the preview.")
                    continue
                }
                do {
                    let removal = try InstructionEdit.removing(own, from: place.file, rendered: [], env: env)
                    try InstructionEdit.apply(removal, env: env)
                } catch {
                    kept.append("\(place.path) keeps \(candidate.title): \(error.message)")
                }
            }
        }
        return kept
    }
}
