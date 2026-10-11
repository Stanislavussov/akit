import AKitBrain
import AKitFoundation
import AKitInsights
import AKitModel
import AKitSkills
import Foundation

/// Remove Everywhere (layers.md, "Remove a skill everywhere"): every place a harness on this Mac
/// would load a skill from, and the one action that takes it out of each, so the skill stops
/// reaching any context. Places come from `SkillScanner` (every root of every installed
/// harness: Claude Code's, Pi's, Codex's and OpenCode's global and project folders, plugins,
/// claude.ai skills, Pi packages), matched by folder name (what Claude Code keys on); a folder of
/// another name whose header says the name is listed as "maybe the same skill", never ticked by
/// default. One place per real path: a link and its target are one skill.
///
/// ```
/// brain layers (layer.yaml, one commit each) → each record on this Mac: Apply of only the skill's
/// files (answers saved; worktree links go with the sync) → answers of projects on other Macs →
/// own copies to the Trash (skills.sh lock forgotten) → claude.ai skill: Claude switch Off →
/// the brain library's skills/<name> (only when asked)
/// ```
///
/// A project's own copy that git tracks is never deleted (remove it in that repository); a
/// plugin skill leaves only with its plugin (Disable Plugin…, never part of this); a Pi package's
/// skill is filtered in the package's own settings entry, which AKit doesn't write.
public enum SkillRemoval {
    /// What happens at one place.
    public enum Action: Hashable, Sendable {
        /// The folder (or only the link) goes to the Trash.
        case trash
        /// The skill's entry leaves this brain layer's `layer.yaml` (committed).
        case layer(String)
        /// The skill's entry leaves this project's answers.
        case answers(String)
        /// A claude.ai skill: the Claude switch Off (`skillOverrides`).
        case claudeOff
        /// AKit's render of a brain entry: it goes with that entry's Apply.
        case rendered
        /// The brain library's `skills/<name>` (git history stays).
        case library
        /// AKit removes nothing here; `reason` says why and what to do instead.
        case keep
    }

    public struct Place: Identifiable, Sendable {
        public let id: String
        public let action: Action
        /// A path as shown (`~/.agents/skills/deploy`), or the brain file (`layers/core/layer.yaml`).
        public let title: String
        /// Its group: `Global ~/.agents/skills`, `Project <id>`, `Brain`, `Claude plugin p`, `claude.ai`, `Pi package p`.
        public let group: String
        /// The harnesses that load it from here.
        public let harnesses: [HarnessID]
        public let skill: Skill?
        /// Found by its header's name in a folder of another name: maybe the same skill.
        public let byHeader: Bool
        /// Part of this removal.
        public let selected: Bool
        /// Why AKit can't remove it here, and what to do instead; nil when it can.
        public let reason: String?
        /// A plugin skill: the plugin Disable Plugin… turns off.
        public let plugin: String?
        /// A brain entry: its file before and after.
        public let before: String?
        public let after: String?
        /// A link of its own to the skill's folder: only the link goes (`title` says where it leads).
        public let isLink: Bool
        /// Other paths harnesses reach this folder through (a folder of skills that is a link, like
        /// `~/.claude/skills` → `~/.agents/skills`), shown with it.
        public let via: [String]
        /// The real folder goes: a skills.sh lock entry of it is forgotten too.
        let forgetsLock: Bool

        /// The removal can include it (a checkbox).
        public var canSelect: Bool {
            guard reason == nil else { return false }
            switch action {
            case .trash, .layer, .answers, .claudeOff, .library: return true
            case .rendered, .keep: return false
            }
        }
    }

    /// One project (or the home folder) whose files or answers change.
    struct Record: Sendable {
        let id: String
        /// nil: not on this Mac; only its answers change.
        let folder: URL?
        let setup: ProjectSetup.Plan?
        let paths: Set<String>
        let excluded: Set<String>
        /// Answers of a project not on this Mac.
        let answers: ProjectAnswers?
        /// Those answers go to the brain from a work Mac (a personal project's record).
        let workBrainAnswers: Bool
    }

    public struct Plan: Sendable {
        public let name: String
        public let places: [Place]
        let records: [Record]
        /// Place id → what goes to the Trash; path → its digest when planned.
        let trashItems: [String: [URL]]
        let trashDigests: [String: String]
        let claudeOff: [String: SkillSwitches.Plan]
        let store: ProjectStore
        /// Rendered copies edited by hand, for Show Edits.
        public let edits: [SkillMove.Edit]
        public let blockers: [String]
        public let notes: [String]
        /// Where it still loads afterwards, and why; empty: nowhere.
        public let remaining: [String]

        public var canApply: Bool { blockers.isEmpty && places.contains { $0.selected } }
        /// "After this, NAME loads in: nowhere." or the places left.
        public var summary: String {
            if places.isEmpty { return "No harness on this Mac loads \(name), and the brain doesn't list it." }
            return remaining.isEmpty ? "After this, \(name) loads in: nowhere."
                : "After this, \(name) still loads in: " + remaining.joined(separator: "; ") + "."
        }
        /// The ticked places, for the next plan.
        public var leaving: Set<String> { Set(places.filter { $0.canSelect && !$0.selected }.map(\.id)) }
        /// Projects on this Mac whose files change (the app holds their worktree sync).
        public var projects: [String] { records.filter { $0.folder != nil }.map(\.id) }
    }

    public struct Outcome: Sendable {
        /// What happened, place by place, in order.
        public var done: [String] = []
        public var notes: [String] = []
    }

    public struct Failure: Error, LocalizedError {
        public let message: String
        public let outcome: Outcome
        public var errorDescription: String? { message }
    }

    static func prefix(_ name: String) -> String { "\(ProjectBundle.skillsFolder)/\(name)/" }

    /// Places left out by default: header-name matches, the claude.ai switch, the brain library.
    public static func defaultLeaving(_ plan: Plan) -> Set<String> {
        Set(plan.places.filter { $0.byHeader || $0.action == .claudeOff || $0.action == .library }.map(\.id))
    }

    // MARK: - Plan

    /// Every place `name` loads from, and what removing it does. Only reads (`git ls-files`).
    /// `leaving`: places the user unticked; nil: the defaults (`defaultLeaving`).
    public static func plan(name: String, brain: Brain?, context: SkillMove.Context, leaving: Set<String>? = nil) -> Plan {
        let env = context.env, home = env.homeDirectory, store = context.store
        var folders = context.projectFolders
        folders[context.homeID] = home
        func shown(_ url: URL) -> String { SkillMove.shown(url, home: home) }
        func projectID(of url: URL) -> String? {
            let path = url.standardizedFileURL.path
            return folders.first { $0.key != context.homeID && $0.value.standardizedFileURL.path == path }?.key
        }

        // Installed copies: by folder name, then header-name matches in other folders.
        let matches = context.installed.filter { SkillMove.folderName($0) == name }
        let byHeader = context.installed.filter { SkillMove.folderName($0) != name && $0.name == name }
        let links = brain.map { BrainLinks.links(for: matches + byHeader, brain: $0, folders: folders, store: store) } ?? [:]

        struct Draft {
            var id: String, action: Action, title: String, group: String, harnesses: [HarnessID], skill: Skill?
            var byHeader = false, reason: String? = nil, plugin: String? = nil, before: String? = nil, after: String? = nil
            var isLink = false, via: [String] = [], forgetsLock = false
            /// A link's target place, when it has one.
            var target: String? = nil
        }
        // Every project the scan found skills in, not only those with a record.
        var scannedProjects = Set(context.projectFolders.values.map(\.standardizedFileURL))
        for skill in context.installed { if case .project(let url) = skill.scope { scannedProjects.insert(url.standardizedFileURL) } }
        let roots = SkillScanner.rootFolders(projects: Array(scannedProjects), in: env)
        var notes: [String] = []
        var drafts: [Draft] = []
        var trashItems: [String: [URL]] = [:], claudeOff: [String: SkillSwitches.Plan] = [:]

        for skill in matches + byHeader {
            let header = !matches.contains(where: { $0.id == skill.id })
            // A link is shown as the link (only it goes); a folder by its real path, as its group names it.
            let place = SkillRemover.removesOnlyLink(skill) ? (skill.isSingleFile ? skill.file : skill.folder)
                : (skill.isSingleFile ? skill.realFile : skill.realFolder)
            var draft = Draft(id: "copy:" + (skill.isSingleFile ? skill.realFile : skill.realFolder).standardizedFileURL.path,
                              action: .keep, title: shown(place), group: "", harnesses: skill.visibleTo, skill: skill, byHeader: header)
            switch skill.scope {
            case .plugin(let plugin):
                let others = context.installed.filter { $0.scope == skill.scope && $0.id != skill.id }.count
                draft.group = "Claude plugin \(plugin)"
                draft.plugin = plugin
                draft.reason = "Comes with the plugin \(plugin)\(others > 0 ? " (\(others) other skill\(others == 1 ? "" : "s"))" : ""); Claude Code's skill switches don't reach plugin skills. Disable Plugin… turns the whole plugin off."
            case .synced:
                draft.group = "claude.ai"
                do {
                    let off = try SkillSwitches.plan(skill, harness: .claudeCode, to: .off, in: env)
                    if off.changesNothing {
                        draft.reason = "Already off in Claude Code (skillOverrides)."
                    } else {
                        draft.action = .claudeOff
                        draft.title = "\(shown(place)) (Claude switch Off)"
                        claudeOff[draft.id] = off
                    }
                } catch {
                    draft.reason = "A claude.ai skill: \(error.message)"
                }
            case .package(let package, _):
                draft.group = "Pi package \(package)"
                draft.reason = "Comes with the Pi package \(package); Pi filters a package's skills in the package's own entry of its settings (pi config), which AKit doesn't write."
            case .bundled(let harness):
                draft.group = "Built into \(harness.displayName)"
                draft.reason = "Part of \(harness.displayName) itself."
            case .global, .project:
                // Each folder a harness reaches it through: a link of its own goes alone (the link);
                // the real folder goes when it sits in a folder harnesses load from.
                let real = (skill.isSingleFile ? skill.realFile : skill.realFolder).standardizedFileURL
                var linkHarnesses: [String: [HarnessID]] = [:], realHarnesses: [HarnessID] = [], via: Set<String> = []
                for (harness, reached) in skill.places.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
                    let folder = skill.isSingleFile ? reached.file : reached.file.deletingLastPathComponent()
                    if isLink(folder) {
                        linkHarnesses[folder.standardizedFileURL.path, default: []].append(harness)
                    } else {
                        realHarnesses.append(harness)
                        if folder.standardizedFileURL.path != real.path { via.insert(shown(folder)) }
                    }
                }
                func group(of folder: URL) -> String {
                    if case .project(let url) = skill.scope {
                        let id = projectID(of: url) ?? shown(url)
                        return "Project \(id) · \(shown(folder.deletingLastPathComponent()))"
                    }
                    return "Global \(shown(folder.deletingLastPathComponent()))"
                }
                for (path, harnesses) in linkHarnesses.sorted(by: { $0.key < $1.key }) {
                    let link = URL(filePath: path)
                    var entry = Draft(id: "link:" + path, action: .trash, title: "\(shown(link)) → \(shown(real))", group: group(of: link),
                                      harnesses: harnesses, skill: skill, byHeader: header)
                    entry.isLink = true
                    entry.target = "copy:" + real.path
                    if let tracked = trackedReason(folder: link, env: env) {
                        entry.action = .keep
                        entry.reason = tracked
                    } else {
                        trashItems[entry.id] = [link]
                    }
                    drafts.append(entry)
                }
                // Only a skill folder directly in a folder harnesses load skills from can go.
                let parent = real.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL.path
                let inRoot = roots.contains { $0.path == parent }
                guard inRoot || !realHarnesses.isEmpty else {
                    notes.append("\(shown(real)) stays: the links to it go, and no harness loads it from there.")
                    continue
                }
                var entry = Draft(id: "copy:" + real.path, action: .keep, title: shown(real), group: group(of: real), harnesses: realHarnesses,
                                  skill: skill, byHeader: header)
                entry.via = via.sorted()
                if !inRoot {
                    entry.reason = "Not directly in a skill folder AKit removes from (\(shown(real.deletingLastPathComponent()))); remove it by hand."
                } else if case .rendered(_, let layers, _)? = links[skill.id] {
                    entry.action = .rendered
                    entry.title = "\(shown(real)) (rendered by \(layers.map { $0 == ProjectBundle.projectSource ? "the project's answers" : "layer \($0)" }.joined(separator: ", ")))"
                } else if let tracked = trackedReason(folder: real, env: env) {
                    entry.reason = tracked
                } else if let problem = realFolderProblem(skill) {
                    entry.reason = problem
                } else {
                    entry.action = .trash
                    entry.forgetsLock = true
                    trashItems[entry.id] = [real]
                }
                drafts.append(entry)
                continue
            }
            drafts.append(draft)
        }
        // What the Trash would take, hashed now and checked again before the first write.
        var trashDigests: [String: String] = [:]
        for (index, draft) in drafts.enumerated() {
            for item in trashItems[draft.id] ?? [] {
                let digest = SkillMove.treeDigest(item)
                if digest == SkillMove.digestTooLarge {
                    drafts[index].reason = "Holds more than 10,000 files, too many to check again before the Trash; remove it by hand."
                } else if digest == SkillMove.digestUnreadable {
                    drafts[index].reason = "Has parts AKit can't read, so it can't check them again before the Trash; remove it by hand."
                }
                trashDigests[item.path] = digest
            }
            if drafts[index].reason != nil { drafts[index].action = .keep; trashItems[draft.id] = nil }
        }

        // The brain: layers and answers that render it, and its library copy.
        var savedRecords: [String: ProjectAnswers] = [:]
        var brainOnly: Set<String> = []
        /// Work Mac: brain records of projects this Mac keeps its own copy of, which list the skill.
        var shadowed: [String] = []
        if let brain {
            for layer in brain.layers where layer.skills.contains(where: { $0.name == name }) {
                var draft = Draft(id: "layer:\(layer.name)", action: .layer(layer.name), title: "layers/\(layer.name)/layer.yaml", group: "Brain",
                                  harnesses: [], skill: nil)
                do {
                    let edit = try BrainRemove.layerWithoutSkill(name, in: layer)
                    draft.before = edit.before
                    draft.after = edit.after
                } catch {
                    draft.action = .keep
                    draft.reason = error.message
                }
                drafts.append(draft)
            }
            for saved in BrainRemove.savedAnswers(in: store) { savedRecords[saved.id] = saved.answers }
            if store.isLocal {
                // A work Mac: personal projects only the brain has a record of. A brain record of a project
                // this Mac also keeps locally is never rewritten from here (only WorkFilter writes the brain).
                for saved in BrainRemove.savedAnswers(in: .brain(brain.root)) {
                    if savedRecords[saved.id] == nil {
                        savedRecords[saved.id] = saved.answers
                        brainOnly.insert(saved.id)
                    } else if saved.answers.skills.contains(where: { $0.name == name }) {
                        shadowed.append(saved.id)
                    }
                }
            }
            for (id, answers) in savedRecords.sorted(by: { $0.key < $1.key }) where answers.skills.contains(where: { $0.name == name }) {
                var after = answers
                after.skills.removeAll { $0.name == name }
                drafts.append(Draft(id: "answers:\(id)", action: .answers(id), title: "projects/\(id)/answers.json",
                                    group: folders[id] == nil ? "Project \(id) (not on this Mac)" : "Project \(id)", harnesses: [], skill: nil,
                                    before: json(answers), after: json(after)))
            }
            if FileWalk.isDirectory(brain.root.appending(path: "skills/\(name)")) {
                drafts.append(Draft(id: "library", action: .library, title: "skills/\(name)", group: "Brain", harnesses: [], skill: nil))
            }
        }

        // Ticked: removable and not left out.
        let defaults = Set(drafts.filter { $0.byHeader || $0.action == .claudeOff || $0.action == .library }.map(\.id))
        let left = leaving ?? defaults
        func ticked(_ draft: Draft) -> Bool {
            guard draft.reason == nil else { return false }
            switch draft.action {
            case .trash, .layer, .answers, .claudeOff, .library: return !left.contains(draft.id)
            case .rendered, .keep: return false
            }
        }
        var blockers: [String] = [], edits: [SkillMove.Edit] = []
        let layers = drafts.compactMap { draft -> String? in if case .layer(let layer) = draft.action, ticked(draft) { layer } else { nil } }
        let answered = Set(drafts.compactMap { draft -> String? in if case .answers(let id) = draft.action, ticked(draft) { id } else { nil } })
        // The library copy only goes when nothing in the brain lists the skill any more.
        if let index = drafts.firstIndex(where: { $0.action == .library }), ticked(drafts[index]) {
            let listing = drafts.filter { draft in
                switch draft.action {
                case .layer, .answers: !ticked(draft)
                default: false
                }
            }
            if !listing.isEmpty {
                drafts[index].reason = "Still listed in \(listing.map(\.title).joined(separator: ", ")); tick those first."
            } else if !shadowed.isEmpty {
                drafts[index].reason = "The brain's answers of \(shadowed.joined(separator: ", ")) still list it, and this work Mac keeps its own copy of them, so it doesn't change the brain's; delete skills/\(name) from a personal Mac."
            }
        }

        // Each record whose rendered copy or answers change: one Apply of only the skill's files.
        var records: [Record] = []
        if let brain {
            var edited = brain
            for layer in layers {
                if let draft = drafts.first(where: { $0.action == .layer(layer) }), let after = draft.after,
                   let next = edited.replacingLayer(layer, text: after) {
                    edited = next
                }
            }
            var ids = Set(answered)
            for (id, _) in folders where ProjectRecords.savedLock(id: id, in: store)?.files.keys.contains(where: { $0.hasPrefix(prefix(name)) }) == true {
                ids.insert(id)
            }
            for id in ids.sorted() {
                let isHome = id == context.homeID
                let saved = savedRecords[id] ?? ProjectRecords.savedAnswers(id: id, in: store)
                var answers = saved ?? ProjectAnswers(targets: context.targets)
                if isHome { answers.layers = ["core"] }
                if answered.contains(id) { answers.skills.removeAll { $0.name == name } }
                guard let folder = folders[id], FileWalk.isDirectory(folder) else {
                    if answered.contains(id) {
                        let localRecord = store.isLocal && FileManager.default.fileExists(atPath: store.folder(id: id).appending(path: "answers.json").path)
                        records.append(Record(id: id, folder: nil, setup: nil, paths: [], excluded: [], answers: answers,
                                              workBrainAnswers: store.isLocal && !localRecord && brainOnly.contains(id)))
                    }
                    continue
                }
                guard layers.isEmpty == false || answered.contains(id) else { continue }
                let setup = ProjectSetup.plan(project: folder, id: id, answers: answers, brain: edited, store: store, forHome: isHome,
                                              piAgentDirSetting: context.piAgentDirSetting, rememberPiAgentDir: context.rememberPiAgentDir, env: env)
                let ours = setup.changes.filter { $0.path.hasPrefix(prefix(name)) }
                let handEdited = ours.filter { $0.kind == .keepEdited }
                let root = isHome ? "~/" : shown(folder) + "/"
                if !handEdited.isEmpty {
                    blockers.append("\(handEdited.map { root + $0.path }.joined(separator: ", ")) was edited by hand since AKit wrote it. Show Edits, bring what you want to keep into the brain's skills/\(name), then remove it again.")
                    for change in handEdited {
                        let relative = String(change.path.dropFirst(prefix(name).count))
                        edits.append(.init(path: root + change.path,
                                           brainText: try? String(contentsOf: brain.root.appending(path: "skills/\(name)/\(relative)"), encoding: .utf8),
                                           copyText: change.oldText))
                    }
                }
                if !setup.canApply { blockers += (setup.render.errors + setup.blockers).map { "\(id): \($0)" } }
                let paths = Set(ours.filter { $0.kind == .remove }.map(\.path))
                guard !paths.isEmpty || answered.contains(id) else { continue }
                records.append(Record(id: id, folder: folder, setup: setup, paths: paths,
                                      excluded: Set(setup.changes.map(\.path)).subtracting(paths), answers: nil, workBrainAnswers: false))
            }
        }

        // A rendered copy goes when a record's Apply removes its files.
        let removedFolders = Set(records.compactMap { record -> String? in
            guard let folder = record.folder, record.paths.contains(where: { $0.hasPrefix(prefix(name)) }) else { return nil }
            return folder.appending(path: "\(ProjectBundle.skillsFolder)/\(name)").resolvingSymlinksInPath().standardizedFileURL.path
        })
        var places: [Place] = []
        var remaining: [String] = []
        func isSelected(_ draft: Draft) -> Bool {
            if draft.action == .rendered, let skill = draft.skill {
                return removedFolders.contains(skill.realFolder.resolvingSymlinksInPath().standardizedFileURL.path)
            }
            return ticked(draft)
        }
        let selectedIDs = Set(drafts.filter(isSelected).map(\.id))
        for draft in drafts {
            let selected = selectedIDs.contains(draft.id)
            places.append(Place(id: draft.id, action: draft.action, title: draft.title, group: draft.group, harnesses: draft.harnesses,
                                skill: draft.skill, byHeader: draft.byHeader, selected: selected, reason: draft.reason, plugin: draft.plugin,
                                before: draft.before, after: draft.after, isLink: draft.isLink, via: draft.via,
                                forgetsLock: draft.forgetsLock))
            // Only places a harness loads from count as remaining; a brain entry shows through its rendered copies.
            guard draft.skill != nil, !selected, !draft.byHeader else { continue }
            // A link that stays while its folder goes loads nothing: it dangles.
            if draft.isLink, let target = draft.target, selectedIDs.contains(target) {
                notes.append("\(draft.title.components(separatedBy: " → ").first ?? draft.title) stays as a link to a removed folder; remove it in its repository.")
                continue
            }
            let harnesses = draft.harnesses.map(\.displayName).joined(separator: ", ")
            let why = draft.reason.map { $0.split(separator: ";").first.map(String.init) ?? $0 }
                ?? (draft.action == .rendered ? "its brain entry stays" : "not ticked")
            remaining.append("\(draft.title)\(harnesses.isEmpty ? "" : " [\(harnesses)]") (\(why))")
        }
        if brain != nil {
            notes.append("Projects set up on a work Mac keep their records on that Mac, out of AKit's sight here: they keep \(name) until it is removed there.")
        }
        if records.contains(where: { $0.folder == nil }) || !layers.isEmpty {
            notes.append("Other Macs: Brain → Sync there, then Update Home Folder and each project's Apply take \(name) out of their folders.")
        }
        if places.contains(where: { $0.action == .library && !$0.selected }) {
            notes.append("The brain's skills/\(name) stays in its library (tick it to delete it there too; its git history stays).")
        }
        return Plan(name: name, places: places, records: records, trashItems: trashItems, trashDigests: trashDigests,
                    claudeOff: claudeOff.filter { id, _ in places.contains { $0.id == id && $0.selected } },
                    store: store, edits: edits, blockers: blockers, notes: notes, remaining: remaining)
    }

    /// Why a project's own copy stays: git tracks it (remove it in that repository), or AKit can't
    /// tell. nil: not tracked, or not in a git repository.
    /// A link itself, not what it leads to.
    static func isLink(_ url: URL) -> Bool { (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) != nil }

    /// Why the skill's real folder can't go to the Trash, if it can't: no SKILL.md of its own (a linked
    /// SKILL.md), git history, or a link out of the skill.
    static func realFolderProblem(_ skill: Skill) -> String? {
        guard !skill.isSingleFile else { return skill.realFile.pathExtension == "md" ? nil : "Not a skill file." }
        let folder = skill.realFolder
        guard skill.realFile.deletingLastPathComponent().standardizedFileURL.path == folder.standardizedFileURL.path,
              SkillScanner.hasSkillFile(folder), folder.pathComponents.count > 3 else {
            return "Its SKILL.md is a link to another folder; remove it by hand."
        }
        let skipped = BrainImport.skippedFiles(in: folder)
        if skipped.contains(where: { $0.hasSuffix("(git data)") }) { return "Has its own git history; move or remove it by hand." }
        if skipped.contains(where: { $0.hasSuffix("(link outside the skill)") }) { return "Links outside the skill; move or remove it by hand." }
        return nil
    }

    /// Why a folder (or a link) stays: git tracks it (remove it there), or AKit can't tell. nil: not
    /// tracked, or not in a git checkout. Also for global folders: a home folder may be a dotfiles repository.
    static func trackedReason(folder: URL, env: HarnessEnvironment) -> String? {
        // A link is checked as itself; a folder by its real path.
        let resolvedParent = folder.deletingLastPathComponent().resolvingSymlinksInPath()
        guard let checkout = GitCheckout.containing(resolvedParent) else { return nil }
        let top = checkout.folder.resolvingSymlinksInPath().standardizedFileURL.path + "/"
        let path = (isLink(folder) ? resolvedParent.appending(path: folder.lastPathComponent) : folder.resolvingSymlinksInPath())
            .standardizedFileURL.path
        let alternative = "Turn it off per harness instead (Skills → the Claude / Pi picker)."
        guard path.hasPrefix(top) else {
            return "AKit can't tell whether git tracks it. Remove it in its repository. \(alternative)"
        }
        guard let tracked = LocalOnly.tracked([String(path.dropFirst(top.count))], in: checkout.folder, env: env) else {
            return "git didn't run, so AKit can't tell whether git tracks it. \(alternative)"
        }
        guard tracked.isEmpty else {
            return "Tracked in git in \(SkillMove.shown(checkout.folder, home: env.homeDirectory)); remove it there with a commit. \(alternative)"
        }
        return nil
    }

    static func json(_ answers: ProjectAnswers) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(answers)).map { String(decoding: $0, as: UTF8.self) + "\n" } ?? ""
    }

    // MARK: - Apply

    /// Carries out the ticked places in order (see the type), after checking that nothing it
    /// will change moved since the preview. Stops at the first failure and says what was done.
    @discardableResult
    public static func apply(_ plan: Plan, brain: Brain?, env: HarnessEnvironment, trash: @escaping (URL) throws -> URL? = Trash.move,
                             hold: SkillMove.Hold = { _, work in try await work() }) async throws(Failure) -> Outcome {
        var outcome = Outcome()
        func fail(_ message: String) -> Failure {
            Failure(message: message + (outcome.done.isEmpty ? " Nothing was changed." : " Done before it stopped: \(outcome.done.joined(separator: "; ")).") ,
                    outcome: outcome)
        }
        guard plan.canApply else { throw fail((plan.blockers.isEmpty ? ["Nothing is ticked."] : plan.blockers).joined(separator: "\n")) }
        let home = env.homeDirectory
        let selected = plan.places.filter(\.selected)

        // Before the first write: what goes to the Trash, the records' files, the layer files.
        for place in selected where place.action == .trash {
            for item in plan.trashItems[place.id] ?? [] where SkillMove.treeDigest(item) != plan.trashDigests[item.path] {
                throw fail("\(SkillMove.shown(item, home: home)) changed since the preview. Look at the preview again.")
            }
        }
        for record in plan.records {
            if let setup = record.setup, let path = ProjectSetup.changedSincePreview(setup, paths: record.paths) {
                throw fail("\(record.id == setup.id && setup.forHome ? "~/" : "")\(path) changed since the preview. Look at the preview again.")
            }
        }
        if selected.contains(where: { if case .layer = $0.action { true } else { false } }) || selected.contains(where: { $0.action == .library }) {
            guard brain != nil else { throw fail("The brain is not loaded.") }
        }
        for place in selected {
            guard case .layer = place.action, let brain else { continue }
            if (try? String(contentsOf: brain.root.appending(path: place.title), encoding: .utf8)) != place.before {
                throw fail("\(place.title) changed since the preview. Look at the preview again.")
            }
        }

        // 1. Brain layers.
        var current = brain
        for place in selected {
            guard case .layer(let layer) = place.action, let brain = current else { continue }
            do {
                try await BrainRemove.removeSkill(plan.name, fromLayer: layer, in: brain, env: env)
            } catch {
                throw fail("Taking \(plan.name) out of layer \(layer) stopped: \(error.message)")
            }
            outcome.done.append("out of layer \(layer) (committed)")
            current = Brain.load(from: brain.root) ?? brain
        }
        // 2. Records on this Mac: only the skill's files; their answers are saved with the Apply.
        for record in plan.records {
            guard let setup = record.setup, let brain = current else { continue }
            do {
                let result = try await hold(record.id) {
                    try await ProjectSetup.apply(setup, excluding: record.excluded, deferring: record.excluded, brain: brain, home: home,
                                                 env: env, trash: trash)
                }
                outcome.done.append("\(record.id): \(result.removed.count) file\(result.removed.count == 1 ? "" : "s") to the Trash")
                outcome.notes += result.notes
            } catch {
                throw fail("Applying \(record.id) stopped: \(error.localizedDescription)")
            }
        }
        // 3. Answers of projects on other Macs.
        for record in plan.records where record.folder == nil {
            guard let answers = record.answers else { continue }
            do {
                if record.workBrainAnswers, let root = current?.root {
                    try await WorkAnswers.removeSkill(plan.name, from: record.id, brain: root, env: env)
                } else {
                    try await ProjectRecords.saveAnswers(answers, id: record.id, in: plan.store,
                                                         message: "Remove skill \(plan.name) from \(record.id)'s answers", env: env)
                }
                outcome.done.append("\(record.id)'s answers (set it up on its Mac)")
            } catch {
                throw fail("Saving \(record.id)'s answers stopped: \(error.localizedDescription)")
            }
        }
        // 4. Own copies and links, each checked again right before it goes (commits and Applies ran meanwhile).
        for place in selected where place.action == .trash {
            var moved = 0
            for item in plan.trashItems[place.id] ?? [] {
                var info = stat()
                guard lstat(item.path, &info) == 0 else {
                    // A worktree link the sync of an Apply above already removed.
                    outcome.notes.append("\(SkillMove.shown(item, home: home)) was already gone.")
                    continue
                }
                guard SkillMove.treeDigest(item) == plan.trashDigests[item.path] else {
                    throw fail("\(SkillMove.shown(item, home: home)) changed since the preview, so it stays. Look at the preview again.")
                }
                // Resolved while the folder is still there, as the skills.sh lock recorded it.
                let lockPath = place.forgetsLock ? item.resolvingSymlinksInPath().path : nil
                do {
                    _ = try trash(item)
                } catch {
                    throw fail("Moving \(SkillMove.shown(item, home: home)) to the Trash stopped: \(error.localizedDescription)")
                }
                moved += 1
                if let lockPath { InstalledSkillLock.forget(path: lockPath, in: env) }
            }
            if moved > 0 { outcome.done.append("\(place.title) to the Trash") }
        }
        // 5. claude.ai skills: the Claude switch.
        for place in selected where place.action == .claudeOff {
            guard let off = plan.claudeOff[place.id] else { continue }
            do {
                try SkillSwitches.apply(off, home: home)
                outcome.done.append("\(place.title): off in Claude Code")
            } catch {
                throw fail("Turning \(place.title) off stopped: \(error.message)")
            }
        }
        // 6. The brain library, when asked: nothing lists it any more.
        if selected.contains(where: { $0.action == .library }) {
            guard let brain = current.flatMap({ Brain.load(from: $0.root) }) else {
                throw fail("The brain couldn't be read again, so skills/\(plan.name) stays in its library.")
            }
            do {
                try await BrainRemove.removeSkill(plan.name, in: brain, env: env, trash: trash)
                outcome.done.append("skills/\(plan.name) out of the brain library (committed)")
            } catch {
                throw fail("Deleting skills/\(plan.name) from the brain stopped: \(error.message)")
            }
        }
        return outcome
    }
}
