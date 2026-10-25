import AKitFoundation
import Foundation

/// An agent's proposal (K14, P3): a file `inbox/<id>.md` that waits for the person's Accept or
/// Reject. `propose` writes only there and never commits it (it stays untracked and is never
/// indexed); Accept writes the change, commits it and removes the proposal in one commit; Reject
/// moves the file to the Trash. The check model's marks (5.2) wait beside it in
/// `inbox/.<id>.check.json` (`KnowledgeCheck`) and go with it.
///
/// The file is Markdown with a frontmatter AKit writes and reads:
///
/// ```
/// ---
/// id: "2026-10-25-payments-billing"
/// kind: note                       # note | arrow | map (5.4)
/// target: "payments/billing"       # note: the note id; arrow: the map id, or none; map: the map id
/// reason: "Retries were missing"   # optional
/// created: "2026-10-25T09:12:00Z"
/// author: "claude"                 # optional: --author, else the harness when known
/// set:                             # optional, note only: frontmatter changes (K24)
///   "owner": "team-a"
/// arrow:                           # arrow only
///   from: "payments/orders-api"
///   kind: "events"
///   to: "payments/billing"
/// ---
/// ## Retries                       # the body (note only)
/// Three tries with backoff.
/// ```
///
/// A note proposal's body is a whole new note when the target doesn't exist (a `# title` is added
/// when it has none; a new area is created on Accept, K23), else `## Heading` blocks: each
/// replaces the section with the same heading, or is appended. An arrow proposal changes no file:
/// the person draws it on the map in the app. A map proposal (5.4, K21) has its draft beside it,
/// `inbox/<id>.excalidraw`, and a body that lists the draft's blocks and arrows; the person
/// accepts it in the app, which links the blocks to their notes and saves Excalidraw's own bytes.
public struct KnowledgeProposal: Sendable, Equatable {
    public enum Kind: String, Sendable, Encodable, CaseIterable { case note, arrow, map }

    public struct Arrow: Sendable, Equatable, Encodable {
        /// Note ids.
        public let from: String
        /// The arrow's label (what flows); nil for a bare arrow.
        public let kind: String?
        public let to: String
        /// The map id it goes on; nil when the proposal names none.
        public let map: String?

        private enum CodingKeys: String, CodingKey { case from, kind, to, map }

        public init(from: String, kind: String?, to: String, map: String?) {
            (self.from, self.kind, self.to, self.map) = (from, kind, to, map)
        }

        public func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(from, forKey: .from)
            try container.encode(kind, forKey: .kind)
            try container.encode(to, forKey: .to)
            try container.encode(map, forKey: .map)
        }

        /// `orders-api -events-> billing`, as the proposal was written.
        public var text: String { "\(from) " + (kind.map { "-\($0)-> " } ?? "-> ") + to }
    }

    /// One frontmatter change: `KEY=VALUE` as written (the value is parsed on Accept).
    public struct Setting: Sendable, Equatable {
        public let key: String
        public let value: String

        public init(key: String, value: String) {
            self.key = key
            self.value = value
        }
    }

    public let id: String
    public let kind: Kind
    /// Note: the note id. Arrow: the map id, or nil. Map: the map id (`payments/maps/flow`).
    public let target: String?
    public let reason: String?
    /// ISO 8601, UTC.
    public let created: String
    public let author: String?
    public let set: [Setting]
    public let arrow: Arrow?
    public let body: String

    public init(id: String, kind: Kind, target: String?, reason: String?, created: String, author: String?,
                set: [Setting] = [], arrow: Arrow? = nil, body: String = "") {
        (self.id, self.kind, self.target, self.reason, self.created, self.author) = (id, kind, target, reason, created, author)
        (self.set, self.arrow, self.body) = (set, arrow, body)
    }

    /// Base-relative.
    public var path: String { KnowledgeInbox.path(of: id) }

    /// The proposal file's text.
    public var text: String {
        func quoted(_ value: String) -> String {
            let data = (try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .withoutEscapingSlashes])) ?? Data()
            return String(data: data, encoding: .utf8) ?? "\"\""
        }
        var lines = ["---", "id: \(quoted(id))", "kind: \(kind.rawValue)"]
        if let target { lines.append("target: \(quoted(target))") }
        if let reason { lines.append("reason: \(quoted(reason))") }
        lines.append("created: \(quoted(created))")
        if let author { lines.append("author: \(quoted(author))") }
        if !set.isEmpty { lines += ["set:"] + set.map { "  \(quoted($0.key)): \(quoted($0.value))" } }
        if let arrow {
            lines += ["arrow:", "  from: \(quoted(arrow.from))"] + (arrow.kind.map { ["  kind: \(quoted($0))"] } ?? [])
                + ["  to: \(quoted(arrow.to))"] + (arrow.map.map { ["  map: \(quoted($0))"] } ?? [])
        }
        lines.append("---")
        return lines.joined(separator: "\n") + "\n" + body
    }

    /// Reads a proposal file's text; nil when its frontmatter isn't one AKit wrote.
    public static func parse(_ text: String) -> KnowledgeProposal? {
        let note = KnowledgeNote(text: text)
        let front = note.frontmatter
        func string(_ value: Any?) -> String? {
            switch value {
            case let text as String: text
            case let number as Int: String(number)
            case let number as Double: String(number)
            case let flag as Bool: String(flag)
            default: nil
            }
        }
        guard let id = string(front["id"]), let kindText = string(front["kind"]), let kind = Kind(rawValue: kindText),
              let created = string(front["created"]) else { return nil }
        let set = ((front["set"] as? [String: Any]) ?? [:]).compactMap { key, value in string(value).map { Setting(key: key, value: $0) } }
            .sorted { $0.key < $1.key }
        var arrow: Arrow?
        if let fields = front["arrow"] as? [String: Any] {
            guard let from = string(fields["from"]), let to = string(fields["to"]) else { return nil }
            arrow = Arrow(from: from, kind: string(fields["kind"]), to: to, map: string(fields["map"]))
        }
        if kind == .arrow, arrow == nil { return nil }
        return KnowledgeProposal(id: id, kind: kind, target: string(front["target"]), reason: string(front["reason"]), created: created,
                                 author: string(front["author"]), set: set, arrow: arrow, body: String(note.body))
    }
}

public enum KnowledgeInbox {
    /// What git keeps in `inbox/` so the folder is tracked (P3) and `git status` names each
    /// proposal file (`?? inbox/<id>.md`) instead of the folder.
    public static let keepFile = "inbox/.gitkeep"
    /// A proposal is small (K19).
    public static let maxBytes = 256 * 1024

    public static func path(of id: String) -> String { "inbox/\(id).md" }

    /// A check without a model (K14): `failed` blocks `propose` and Accept, `warning` only marks.
    public struct Check: Sendable, Equatable, Encodable {
        public enum Status: String, Sendable, Encodable { case passed, warning, failed }
        /// target, secret, links, arrow, format.
        public let name: String
        public let status: Status
        public let message: String?

        private enum CodingKeys: String, CodingKey { case name, status, message }

        public init(name: String, status: Status, message: String? = nil) {
            (self.name, self.status, self.message) = (name, status, message)
        }

        public func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(name, forKey: .name)
            try container.encode(status, forKey: .status)
            try container.encode(message, forKey: .message)
        }
    }

    /// What `propose` is asked for, as the CLI read it.
    public struct Draft: Sendable, Equatable {
        public enum Change: Sendable, Equatable {
            /// `--note NOTE` with a body (a file or stdin) and/or `--set` changes.
            case note(String, body: String, set: [KnowledgeProposal.Setting])
            /// `--arrow "A -kind-> B"`, optionally on `--map MAP`.
            case arrow(String, map: String?)
            /// `--map AREA/NAME` with a draft `.excalidraw` (a file or stdin), 5.4.
            case map(String, draft: Data)
        }

        public let change: Change
        public let reason: String?
        public let author: String?

        public init(_ change: Change, reason: String? = nil, author: String? = nil) {
            (self.change, self.reason, self.author) = (change, reason, author)
        }
    }

    /// One proposal as `kb inbox` lists it, with its checks run now. A file that can't be read as a
    /// proposal is listed too, with kind nil and a failed `format` check.
    public struct Entry: Sendable, Equatable, Encodable {
        public let id: String
        public let path: String
        public let kind: KnowledgeProposal.Kind?
        public let target: String?
        public let reason: String?
        public let created: String?
        public let author: String?
        public let set: [KnowledgeProposal.Setting]
        public let arrow: KnowledgeProposal.Arrow?
        public let checks: [Check]
        /// The check model's marks (5.2); nil when the proposal wasn't checked.
        public let modelCheck: ModelCheck?
        public let proposal: KnowledgeProposal?

        /// A stored model check as listed: `stale` when the proposal changed since.
        public struct ModelCheck: Sendable, Equatable, Encodable {
            public let model: String
            public let checked: String
            public let stale: Bool
            public let marks: [KnowledgeCheck.Mark]
        }

        public init(id: String, path: String, kind: KnowledgeProposal.Kind?, target: String?, reason: String?, created: String?,
                    author: String?, set: [KnowledgeProposal.Setting], arrow: KnowledgeProposal.Arrow?, checks: [Check],
                    modelCheck: ModelCheck? = nil, proposal: KnowledgeProposal?) {
            (self.id, self.path, self.kind, self.target, self.reason, self.created) = (id, path, kind, target, reason, created)
            (self.author, self.set, self.arrow, self.checks, self.modelCheck, self.proposal) = (author, set, arrow, checks, modelCheck, proposal)
        }

        private enum CodingKeys: String, CodingKey { case id, path, kind, target, reason, created, author, set, arrow, checks, modelCheck }

        public func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(id, forKey: .id)
            try container.encode(path, forKey: .path)
            try container.encode(kind, forKey: .kind)
            try container.encode(target, forKey: .target)
            try container.encode(reason, forKey: .reason)
            try container.encode(created, forKey: .created)
            try container.encode(author, forKey: .author)
            try container.encode(Dictionary(set.map { ($0.key, $0.value) }, uniquingKeysWith: { $1 }), forKey: .set)
            try container.encode(arrow, forKey: .arrow)
            try container.encode(checks, forKey: .checks)
            try container.encode(modelCheck, forKey: .modelCheck) // null before a check
        }
    }

    /// What Accept of a note proposal writes: the note's new text and its diff.
    public struct Plan: Sendable, Equatable {
        public let proposal: KnowledgeProposal
        /// The note id and its base-relative path.
        public let note: String
        public let notePath: String
        /// The note's bytes now; nil for a new note.
        public let original: Data?
        public let planned: String
        /// The area folder doesn't exist yet: Accept creates it (K23).
        public let newArea: Bool

        /// `diff -u` style lines, the path first.
        public var diff: String {
            let old = original.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            let lines = TextDiff.unified(TextDiff.lines(from: old, to: planned))
            return ([original == nil ? "\(notePath) (new" + (newArea ? ", in a new area" : "") + ")" : notePath] + lines).joined(separator: "\n")
        }
    }

    /// What Accept did.
    public struct Accepted: Sendable, Equatable {
        public let plan: Plan
        /// The committed paths.
        public let paths: [String]
        /// The note's copy from before the write; nil for a new note.
        public let backup: URL?
    }

    /// `orders-api -events-> billing`, `orders-api -> billing` → (from, kind, to).
    static func parseArrow(_ text: String) -> (from: String, kind: String?, to: String)? {
        guard let arrow = text.range(of: "->", options: .backwards) else { return nil }
        let to = text[arrow.upperBound...].trimmingCharacters(in: .whitespaces)
        var left = String(text[..<arrow.lowerBound])
        var kind: String?
        if !left.hasSuffix(" "), let dash = left.range(of: " -", options: .backwards) {
            kind = String(left[dash.upperBound...]).trimmingCharacters(in: .whitespaces)
            left = String(left[..<dash.lowerBound])
        }
        let from = left.trimmingCharacters(in: .whitespaces)
        guard !from.isEmpty, !to.isEmpty, kind?.isEmpty != true else { return nil }
        return (from, kind, to)
    }

    /// `payments/billing` → `payments-billing`: lowercase letters, digits and `-`, at most 60.
    static func slug(_ text: String) -> String {
        var result = ""
        for character in text.lowercased() {
            if character.isLetter || character.isNumber { result.append(character) } else if !result.hasSuffix("-") { result.append("-") }
        }
        let trimmed = result.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return String(trimmed.prefix(60)).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    /// Text that holds a secret (a token shape, a key, a password value): the Scrubber's rules.
    static func hasSecret(_ text: String) -> Bool {
        !text.isEmpty && (text.contains("PRIVATE KEY") || SecretFilter.masked(text) != text)
    }
}

extension KnowledgeBase {
    public typealias Proposal = KnowledgeProposal

    // MARK: - Propose

    /// Writes a proposal into `inbox/` and nothing else, after the checks without a model: the
    /// target is a note path under `areas/` (no `..`, no absolute path, not `inbox/`), the text
    /// holds no secret, every `[[link]]` of the body resolves (the proposed note counts), the
    /// change applies. A failed check refuses it; nothing is written. Returns the proposal and its checks.
    @discardableResult
    public func propose(_ draft: KnowledgeInbox.Draft, now: Date = .now) throws(Failure) -> (proposal: Proposal, checks: [KnowledgeInbox.Check]) {
        let created = ISO8601DateFormatter().string(from: now)
        let reason = draft.reason?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        let author = draft.author?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        var proposal: Proposal
        var mapDraft: Data?
        switch draft.change {
        case .note(let name, let body, let set):
            if body.utf8.count > KnowledgeInbox.maxBytes {
                throw Failure(message: "The proposal is \(body.utf8.count / 1024) KB; a proposal holds at most \(KnowledgeInbox.maxBytes / 1024) KB. Propose one note's change at a time.")
            }
            if body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, set.isEmpty {
                throw Failure(message: "Nothing to propose: give the text (--file F or --stdin) or a property (--set KEY=VALUE).")
            }
            for setting in set where !KnowledgeNote.validKey(setting.key) {
                throw Failure(message: "“\(setting.key)” can't be a property: letters, digits, _, - and . (like repo or owner).")
            }
            let target = try proposalTarget(name)
            proposal = Proposal(id: "", kind: .note, target: target.id, reason: reason, created: created, author: author,
                                set: set, body: body)
        case .arrow(let text, let map):
            guard let parts = KnowledgeInbox.parseArrow(text) else {
                throw Failure(message: "“\(text)” is not an arrow: write it as \"A -kind-> B\" (like \"orders-api -events-> billing\") or \"A -> B\".")
            }
            let from = try arrowEnd(parts.from), to = try arrowEnd(parts.to)
            var onMap: String?
            if let map { onMap = try mapID(map) }
            proposal = Proposal(id: "", kind: .arrow, target: onMap, reason: reason, created: created, author: author,
                                arrow: .init(from: from, kind: parts.kind, to: to, map: onMap))
        case .map(let name, let data):
            mapDraft = data
            if data.count > KnowledgeInbox.maxMapBytes {
                throw Failure(message: "The draft is \(data.count / 1024) KB; a map draft holds at most \(KnowledgeInbox.maxMapBytes / 1024) KB.")
            }
            let target = try mapProposalTarget(name)
            let scene: ExcalidrawFile
            switch ExcalidrawFile.parse(data) {
            case .success(let read): scene = read
            case .failure(let failure): throw Failure(message: "Refused, nothing was written: the draft is \(failure.message).")
            }
            proposal = Proposal(id: "", kind: .map, target: target.id, reason: reason, created: created, author: author,
                                body: KnowledgeInbox.mapSummary(scene))
        }
        let checks = checks(of: proposal, draft: mapDraft)
        let failed = checks.filter { $0.status == .failed }
        if !failed.isEmpty {
            throw Failure(message: "Refused, nothing was written: " + failed.map { $0.message ?? $0.name }.joined(separator: " "))
        }
        if proposal.kind == .note {
            _ = try planAccept(proposal) // the change applies to the note as it is now
        }
        let id = try newProposalID(for: proposal, now: now)
        proposal = Proposal(id: id, kind: proposal.kind, target: proposal.target, reason: proposal.reason, created: proposal.created,
                            author: proposal.author, set: proposal.set, arrow: proposal.arrow, body: proposal.body)
        let draftFile = root.appending(path: KnowledgeInbox.draftPath(of: id))
        do {
            try FileManager.default.createDirectory(at: inboxFolder, withIntermediateDirectories: true)
            // The draft first: a map proposal is never without it.
            if let mapDraft { try mapDraft.write(to: draftFile, options: .withoutOverwriting) }
            try Data(proposal.text.utf8).write(to: root.appending(path: proposal.path), options: .withoutOverwriting)
        } catch {
            if mapDraft != nil { try? FileManager.default.removeItem(at: draftFile) }
            throw Failure(message: "Couldn't write \(proposal.path): \(error.localizedDescription)")
        }
        return (proposal, checks)
    }

    /// `inbox/<yyyy-MM-dd>-<slug>.md`, with `-2`, `-3` … when taken.
    private func newProposalID(for proposal: Proposal, now: Date) throws(Failure) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC") // the day of `created`
        formatter.dateFormat = "yyyy-MM-dd"
        let subject: String
        if let arrow = proposal.arrow {
            subject = "arrow-" + [arrow.from, arrow.to].map { $0.split(separator: "/").last.map(String.init) ?? $0 }.joined(separator: "-")
        } else {
            subject = proposal.target ?? "note"
        }
        let stem = formatter.string(from: now) + "-" + (KnowledgeInbox.slug(subject).nilIfEmpty ?? "proposal")
        for counter in 1...999 {
            let id = counter == 1 ? stem : "\(stem)-\(counter)"
            if !FileManager.default.fileExists(atPath: root.appending(path: KnowledgeInbox.path(of: id)).path),
               !FileManager.default.fileExists(atPath: root.appending(path: KnowledgeInbox.draftPath(of: id)).path) { return id }
        }
        throw Failure(message: "inbox/ has too many proposals named \(stem); accept or reject some first.")
    }

    /// The note a note proposal targets: an existing note as `noteID` finds it, else a new
    /// `AREA/NAME` (the area may be new, K23). Refused: `..`, an absolute or `~` path, hidden
    /// parts, `inbox/`, a `maps/` folder, a name without its area, a path that leaves `areas/`.
    func proposalTarget(_ name: String) throws(Failure) -> (id: String, exists: Bool, newArea: Bool) {
        var value = Self.nfc(name.trimmingCharacters(in: .whitespaces))
        if value.hasPrefix("[["), value.hasSuffix("]]") { value = String(value.dropFirst(2).dropLast(2)) }
        let refused = "“\(name)” can't be a proposal's note:"
        if value.hasPrefix("/") || value.hasPrefix("~") || value.split(separator: "/", omittingEmptySubsequences: false).contains(where: { $0 == ".." || $0 == "." }) {
            throw Failure(message: "\(refused) a proposal names a note under areas/ as AREA/NAME, never a path that leaves it.")
        }
        if value.hasPrefix("areas/") { value.removeFirst("areas/".count) }
        if value.hasSuffix(".md") { value.removeLast(3) }
        if value == "inbox" || value.hasPrefix("inbox/") || value.contains(where: { "#|[]".contains($0) }) {
            throw Failure(message: "\(refused) the target is a note under areas/, written AREA/NAME.")
        }
        let parts = value.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !parts.isEmpty, parts.allSatisfy(Self.validName) else {
            throw Failure(message: "\(refused) each part of AREA/NAME is one file or folder name, not hidden.")
        }
        let existing: String?
        do { existing = try noteID(value) } catch {
            if case .ambiguous = linkTargets().resolve(value, from: "") { throw error }
            existing = nil
        }
        if let existing {
            guard Self.isWithin(noteFile(existing), areasFolder) else { throw Failure(message: "\(refused) its file is outside areas/.") }
            return (existing, true, false)
        }
        guard parts.count >= 2 else {
            throw Failure(message: "No note “\(value)” in the base. Name the area of a new note: --note AREA/\(value) (an area per system; a new one is created on Accept).")
        }
        if parts.dropLast().contains(where: { $0.lowercased() == "maps" }) {
            throw Failure(message: "\(refused) a note can't go into a maps/ folder: links there mean maps.")
        }
        guard Self.isWithin(noteFile(value), areasFolder) else { throw Failure(message: "\(refused) its folder is outside areas/.") }
        let newArea = (try? areaFolder(parts[0])) == nil
        return (value, false, newArea)
    }

    /// An arrow's end: one note.
    private func arrowEnd(_ name: String) throws(Failure) -> String {
        do { return try noteID(name) } catch {
            if case .ambiguous = linkTargets().resolve(name, from: "") { throw Failure(message: "Refused, nothing was written: \(error.message)") }
            throw Failure(message: "Refused, nothing was written: the arrow's end “\(name)” is no note of the base. Propose the note first: --note AREA/NAME.")
        }
    }

    /// A map id: `payments/maps/overview`, `[[maps/overview]]`, with or without `.excalidraw`.
    private func mapID(_ value: String) throws(Failure) -> String {
        var name = Self.nfc(value.trimmingCharacters(in: .whitespaces))
        if name.hasPrefix("areas/") { name.removeFirst("areas/".count) }
        if name.hasSuffix(".excalidraw") { name.removeLast(".excalidraw".count) }
        if KnowledgeGit.isInside(name), FileWalk.isRegularFile(mapFile(name)) { return name }
        let targets = linkTargets()
        for candidate in [name, "maps/" + name] {
            if case .map(let id) = targets.resolve(candidate, from: "") { return id }
        }
        throw Failure(message: "Refused, nothing was written: no map “\(value)” in the base (see akit kb maps).")
    }

    // MARK: - Inbox

    /// The proposals in `inbox/` (hidden files left out), by id, each with its checks run now.
    public func proposals() -> [KnowledgeInbox.Entry] {
        let files = FileWalk.children(of: inboxFolder).filter { $0.pathExtension == "md" && !$0.lastPathComponent.hasPrefix(".") && FileWalk.isRegularFile($0) }
        return files.map { file in
            let id = Self.nfc(file.deletingPathExtension().lastPathComponent)
            let path = KnowledgeInbox.path(of: id)
            guard let text = KnowledgeNote.load(file)?.text, let proposal = KnowledgeProposal.parse(text), proposal.id == id else {
                return KnowledgeInbox.Entry(id: id, path: path, kind: nil, target: nil, reason: nil, created: nil, author: nil, set: [],
                                            arrow: nil, checks: [.init(name: "format", status: .failed,
                                                                       message: "\(path) is not a proposal AKit can read (its frontmatter needs id, kind and created).")],
                                            proposal: nil)
            }
            let stored = check(of: proposal).map { result in
                KnowledgeInbox.Entry.ModelCheck(model: result.model, checked: result.checked,
                                                stale: result.proposalHash != KnowledgeCheck.hash(proposal), marks: result.marks)
            }
            return KnowledgeInbox.Entry(id: id, path: path, kind: proposal.kind, target: proposal.target, reason: proposal.reason,
                                        created: proposal.created, author: proposal.author, set: proposal.set, arrow: proposal.arrow,
                                        checks: checks(of: proposal), modelCheck: stored, proposal: proposal)
        }.sorted { $0.id < $1.id }
    }

    /// The proposal `id` names (`2026-10-25-payments-billing`, with `.md` or `inbox/` too).
    public func proposal(_ id: String) throws(Failure) -> Proposal {
        var name = Self.nfc(id.trimmingCharacters(in: .whitespaces))
        if name.hasPrefix("inbox/") { name.removeFirst("inbox/".count) }
        if name.hasSuffix(".md") { name.removeLast(3) }
        guard Self.validName(name) else { throw Failure(message: "“\(id)” is not a proposal id (see akit kb inbox).") }
        let file = root.appending(path: KnowledgeInbox.path(of: name))
        guard FileWalk.isRegularFile(file) else { throw Failure(message: "No proposal \(name) in \(root.path)/inbox (see akit kb inbox).") }
        guard let text = KnowledgeNote.load(file)?.text, let proposal = KnowledgeProposal.parse(text), proposal.id == name else {
            throw Failure(message: "inbox/\(name).md is not a proposal AKit can read; reject it (akit kb reject \(name)).")
        }
        return proposal
    }

    /// The checks without a model, run against the base as it is now. A map proposal's draft is
    /// read from `inbox/<id>.excalidraw`.
    public func checks(of proposal: Proposal) -> [KnowledgeInbox.Check] {
        checks(of: proposal, draft: proposal.kind == .map ? try? Data(contentsOf: root.appending(path: KnowledgeInbox.draftPath(of: proposal.id))) : nil)
    }

    /// The checks with a map proposal's draft as given (`propose` checks it before it is written).
    func checks(of proposal: Proposal, draft: Data?) -> [KnowledgeInbox.Check] {
        var checks: [KnowledgeInbox.Check] = []
        var texts = [proposal.body, proposal.reason ?? "", proposal.arrow?.text ?? "", proposal.arrow?.map ?? "", proposal.target ?? ""]
            + proposal.set.flatMap { [$0.key, $0.value] }
        if proposal.kind == .map, let draft, case .success(let scene) = ExcalidrawFile.parse(draft) {
            texts += scene.elements.flatMap { [$0.text ?? "", $0.link ?? ""] }
        }
        checks.append(texts.contains(where: KnowledgeInbox.hasSecret)
            ? .init(name: "secret", status: .failed, message: "The proposal holds what looks like a secret (a token, a key or a password); a base never keeps one.")
            : .init(name: "secret", status: .passed))
        switch proposal.kind {
        case .note:
            guard let target = proposal.target else {
                checks.append(.init(name: "target", status: .failed, message: "The proposal names no note."))
                return checks
            }
            let found: (id: String, exists: Bool, newArea: Bool)
            do { found = try proposalTarget(target) } catch {
                checks.append(.init(name: "target", status: .failed, message: error.message))
                return checks
            }
            checks.append(.init(name: "target", status: .passed, message: found.exists ? nil
                : found.newArea ? "A new note in a new area \(found.id.split(separator: "/")[0]), created on Accept." : "A new note."))
            let targets = linkTargets()
            let pool = found.exists ? targets : KnowledgeLinks(notes: targets.notes + [found.id], maps: targets.maps)
            var broken: [String] = [], unclear: [String] = []
            for token in KnowledgeRename.noteTokens(proposal.body) where !KnowledgeLint.isAttachment(token.value) && !KnowledgeLint.isOutside(token.value) {
                switch pool.resolve(token.value, from: notePath(found.id)) {
                case .missing: if !broken.contains(token.value) { broken.append(token.value) }
                case .ambiguous: if !unclear.contains(token.value) { unclear.append(token.value) }
                case .note, .map: break
                }
            }
            if !broken.isEmpty {
                checks.append(.init(name: "links", status: .failed,
                                    message: "Broken link\(broken.count == 1 ? "" : "s"): \(broken.joined(separator: ", ")) point\(broken.count == 1 ? "s" : "") to no note or map of the base."))
            } else if !unclear.isEmpty {
                checks.append(.init(name: "links", status: .warning,
                                    message: "Ambiguous link\(unclear.count == 1 ? "" : "s"): \(unclear.joined(separator: ", ")) fit\(unclear.count == 1 ? "s" : "") more than one note."))
            } else {
                checks.append(.init(name: "links", status: .passed))
            }
        case .arrow:
            guard let arrow = proposal.arrow else {
                checks.append(.init(name: "arrow", status: .failed, message: "The proposal has no arrow."))
                return checks
            }
            let notes = Set(linkTargets().notes)
            let missing = [arrow.from, arrow.to].filter { !notes.contains($0) }
            if !missing.isEmpty {
                checks.append(.init(name: "arrow", status: .failed, message: "No note \(missing.joined(separator: ", ")) in the base."))
            } else if let map = arrow.map, !FileWalk.isRegularFile(mapFile(map)) || !KnowledgeGit.isInside(mapPath(map)) {
                checks.append(.init(name: "arrow", status: .failed, message: "No map \(map) in the base."))
            } else {
                checks.append(.init(name: "arrow", status: .passed))
            }
        case .map:
            checks += mapChecks(proposal, draft: draft)
        }
        return checks
    }

    // MARK: - Accept and Reject

    /// What Accept of a note proposal would write (nothing is written). Refused for an arrow (the
    /// person draws it in the app), for a proposal whose checks fail now, and for a body that
    /// doesn't fit the note: an existing note takes only `## Heading` blocks (no frontmatter, no
    /// `# title`; properties come with `set`).
    public func planAccept(_ proposal: Proposal) throws(Failure) -> KnowledgeInbox.Plan {
        guard proposal.kind == .note else {
            throw Failure(message: proposal.kind == .map ? KnowledgeInbox.mapMessage : KnowledgeInbox.arrowMessage(proposal))
        }
        if let failed = checks(of: proposal).first(where: { $0.status == .failed }) {
            throw Failure(message: "The proposal fails its \(failed.name) check: \(failed.message ?? "")")
        }
        let target = try proposalTarget(proposal.target ?? "")
        let draft = KnowledgeNote(text: proposal.body)
        var note: KnowledgeNote
        let original: Data?
        do {
            if target.exists {
                let file = noteFile(target.id)
                guard let data = try? Data(contentsOf: file), let current = KnowledgeNote.load(file) else {
                    throw Failure(message: "\(notePath(target.id)) isn't UTF-8 text, so AKit doesn't change it.")
                }
                original = data
                note = current
                let sections = draft.sections
                let lead = sections.first.map { draft.text[..<$0.headingRange.lowerBound] } ?? draft.text[...]
                guard draft.body.startIndex == draft.text.startIndex, draft.title == nil,
                      lead.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw Failure(message: "\(target.id) exists, so the proposal's text must be ## Heading blocks (each replaces that section or is added); properties go with --set KEY=VALUE.")
                }
                for section in sections {
                    var body = String(draft.text[section.bodyRange])
                    if let old = note.section(section.heading) {
                        // Keep the note's blank line after the heading.
                        if let first = note.text[old.bodyRange].first, first.isNewline, body.first?.isNewline != true {
                            body = String(first) + body
                        }
                        note = try note.replacingSection(section.heading, with: body)
                    } else {
                        note = note.appendingSection(section.heading, body: body)
                    }
                }
            } else {
                original = nil
                let name = String(target.id.split(separator: "/").last ?? "")
                var text = proposal.body
                if draft.title == nil, draft.body.startIndex == draft.text.startIndex {
                    text = "# \(name)\n" + (text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "" : "\n" + text)
                }
                if !text.isEmpty, text.last?.isNewline != true { text += "\n" }
                note = KnowledgeNote(text: text)
            }
            for setting in proposal.set { note = try note.setting(setting.key, to: .parse(setting.value)) }
        } catch let error as KnowledgeNote.Failure {
            throw Failure(message: "\(target.id): \(error.message)")
        } catch let error as Failure {
            throw error
        } catch {
            throw Failure(message: error.localizedDescription)
        }
        return KnowledgeInbox.Plan(proposal: proposal, note: target.id, notePath: notePath(target.id), original: original,
                                   planned: note.text, newArea: target.newArea)
    }

    /// Writes a planned Accept: commits the pending edits first (U2), backs the note up (P3,
    /// `~/.akit/local/backups/knowledge/<world>/<time>/`), writes it (a new area's folder too),
    /// removes the proposal file and commits the note (and the removal, were the proposal ever
    /// tracked) in one commit. Refused when the note or the proposal changed since the plan; on a
    /// commit failure the note and the proposal are put back.
    @discardableResult
    public func accept(_ plan: KnowledgeInbox.Plan, env: HarnessEnvironment, now: Date = .now) async throws(Failure) -> KnowledgeInbox.Accepted {
        _ = await KnowledgeCommitQueue(base: root, env: env).flush()
        let file = noteFile(plan.note)
        let proposalFile = root.appending(path: plan.proposal.path)
        guard (try? Data(contentsOf: file)) == plan.original else {
            throw Failure(message: "\(plan.notePath) changed after the proposal was planned; nothing was written. Look at it again.")
        }
        guard let proposalData = try? Data(contentsOf: proposalFile),
              KnowledgeProposal.parse(String(decoding: proposalData, as: UTF8.self)) == plan.proposal else {
            throw Failure(message: "\(plan.proposal.path) changed or is gone; nothing was written.")
        }
        let fm = FileManager.default
        var backup: URL?
        if let original = plan.original {
            do { backup = try backupNote(original, path: plan.notePath, home: env.homeDirectory, now: now) } catch {
                throw Failure(message: "Couldn't back up \(plan.notePath) (\(error.localizedDescription)); nothing was written.")
            }
        }
        let keep = root.appending(path: KnowledgeInbox.keepFile)
        let addsKeep = !fm.fileExists(atPath: keep.path)
        do {
            try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(plan.planned.utf8).write(to: file, options: .atomic)
            if addsKeep { try Data().write(to: keep) }
            try fm.removeItem(at: proposalFile)
        } catch {
            restore(plan, proposal: proposalData, keep: addsKeep ? keep : nil)
            throw Failure(message: "Couldn't write \(plan.notePath) (\(error.localizedDescription)); the note and the proposal are as they were.")
        }
        let paths = [plan.notePath, plan.proposal.path] + (addsKeep ? [KnowledgeInbox.keepFile] : [])
        let message = (plan.original == nil ? "Add note \(plan.note)" : "Edit \(plan.note)") + " (accept proposal \(plan.proposal.id))"
        do { try await KnowledgeGit(base: root, env: env).commit(paths: paths, message: message) } catch {
            restore(plan, proposal: proposalData, keep: addsKeep ? keep : nil)
            throw Failure(message: "Couldn't commit the accepted proposal (\(error.message)); the note and the proposal are as they were.")
        }
        removeCheck(of: plan.proposal.id)
        return KnowledgeInbox.Accepted(plan: plan, paths: [plan.notePath] + (addsKeep ? [KnowledgeInbox.keepFile] : []), backup: backup)
    }

    /// Puts a failed Accept back: the note's old bytes (or no note), the proposal file.
    private func restore(_ plan: KnowledgeInbox.Plan, proposal: Data, keep: URL?) {
        let fm = FileManager.default
        let file = noteFile(plan.note)
        if let original = plan.original { try? original.write(to: file, options: .atomic) } else { try? fm.removeItem(at: file) }
        if plan.newArea {
            let area = areasFolder.appending(path: String(plan.note.split(separator: "/")[0]))
            var folder = file.deletingLastPathComponent()
            while folder.path.hasPrefix(area.path), (try? fm.contentsOfDirectory(atPath: folder.path))?.isEmpty == true {
                try? fm.removeItem(at: folder)
                folder = folder.deletingLastPathComponent()
            }
        }
        if let keep { try? fm.removeItem(at: keep) }
        try? fm.createDirectory(at: inboxFolder, withIntermediateDirectories: true)
        try? proposal.write(to: root.appending(path: plan.proposal.path), options: .atomic)
    }

    /// `~/.akit/local/backups/knowledge/<world>/<yyyy-MM-dd'T'HHmmss.SSS>/<path>`, readable only by the user.
    func backupNote(_ data: Data, path: String, home: URL, now: Date) throws -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd'T'HHmmss.SSS"
        let fm = FileManager.default
        let world = home.appending(path: ".akit/local/backups/knowledge/\(name)")
        var folder = world.appending(path: formatter.string(from: now))
        var counter = 2
        while fm.fileExists(atPath: folder.path) {
            folder = world.appending(path: formatter.string(from: now) + "-\(counter)")
            counter += 1
        }
        let file = folder.appending(path: path)
        try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard fm.createFile(atPath: file.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: file.path])
        }
        return file
    }

    /// Moves a proposal file to the Trash. Nothing to commit: a proposal is never tracked (P3);
    /// one that is gets its removal committed. Returns where it went.
    @discardableResult
    public func reject(_ proposal: Proposal, env: HarnessEnvironment, trash: (URL) throws -> URL? = Trash.move) async throws(Failure) -> URL? {
        let file = root.appending(path: proposal.path)
        let git = KnowledgeGit(base: root, env: env)
        // A map proposal's draft goes with it.
        let draftPath = KnowledgeInbox.draftPath(of: proposal.id)
        let draft = root.appending(path: draftPath)
        let paths = [proposal.path] + (FileWalk.isRegularFile(draft) ? [draftPath] : [])
        let tracked = !((try? await git.run(["ls-files", "--"] + paths)) ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let place: URL?
        do {
            place = try trash(file)
            if paths.count > 1 { _ = try trash(draft) }
        } catch {
            throw Failure(message: "Couldn't move \(proposal.path) to the Trash: \(error.localizedDescription)")
        }
        removeCheck(of: proposal.id)
        guard tracked else { return place }
        do { try await git.commit(paths: paths, message: "Reject proposal \(proposal.id)") } catch {
            throw Failure(message: "\(proposal.path) is in the Trash, but its removal wasn't committed: \(error.message)")
        }
        return place
    }
}

extension KnowledgeInbox {
    /// What Accept of an arrow proposal draws on one map (5.3): each end's block, or a new block
    /// with a link to the note when the map has none, and the arrow between them. The app draws it
    /// through the canvas (bridge.js `akitAddArrow`), saves Excalidraw's bytes the normal way, then
    /// closes the proposal (`closeArrow`).
    public struct ArrowPlan: Sendable, Equatable {
        public struct End: Sendable, Equatable {
            /// The note id.
            public let note: String
            /// The map's block for the note (the first one); nil when a new block is drawn.
            public let element: String?
            /// The new block's link: the shortest `[[…]]` that resolves to the note from the map.
            public let link: String
            /// The new block's label: the note's title.
            public let label: String
        }

        public let proposal: KnowledgeProposal
        /// The map id.
        public let map: String
        public let from: End
        public let to: End
        /// The arrow's label; nil for a bare arrow.
        public let kind: String?
        /// The map has this arrow already: Add only closes the proposal.
        public let exists: Bool

        /// `payments/billing -paid orders-> logistics/warehouse`.
        public var text: String { proposal.arrow?.text ?? "\(from.note) -> \(to.note)" }
    }
}

extension KnowledgeBase {
    // MARK: - Arrow proposals (5.3)

    /// The maps an arrow proposal can go on: the one it names, else the maps of its ends' areas
    /// (the start's first), so the person picks one.
    public func arrowMaps(for proposal: Proposal) -> [String] {
        guard let arrow = proposal.arrow else { return [] }
        if let map = arrow.map { return [map] }
        let maps = linkTargets().maps
        var areas: [String] = []
        for note in [arrow.from, arrow.to] {
            if let area = note.split(separator: "/").first.map(String.init), !areas.contains(area) { areas.append(area) }
        }
        return areas.flatMap { area in maps.filter { $0.hasPrefix(area + "/maps/") } }
    }

    /// What Accept of an arrow proposal draws on `map` (nothing is written). Refused for a note
    /// proposal, for one whose checks fail now, and for a map that doesn't parse.
    public func planArrow(_ proposal: Proposal, on map: String) throws(Failure) -> KnowledgeInbox.ArrowPlan {
        guard proposal.kind == .arrow, let arrow = proposal.arrow else {
            throw Failure(message: "\(proposal.id) is not an arrow proposal.")
        }
        if let failed = checks(of: proposal).first(where: { $0.status == .failed }) {
            throw Failure(message: "The proposal fails its \(failed.name) check: \(failed.message ?? "")")
        }
        let targets = linkTargets()
        guard targets.maps.contains(map) else { throw Failure(message: "No map \(map) in the base.") }
        let graph = MapGraph.map(id: map, file: ExcalidrawFile.load(mapFile(map)), targets: targets)
        if let error = graph.error { throw Failure(message: "The map \(map) can't be read: \(error)") }
        let titles = Dictionary(((try? notes()) ?? []).map { ($0.id, $0.title) }, uniquingKeysWith: { first, _ in first })
        func end(_ note: String) -> KnowledgeInbox.ArrowPlan.End {
            let parts = note.split(separator: "/").map(String.init)
            let forms = (1...parts.count).map { parts.suffix($0).joined(separator: "/") }
            let link = forms.map { "[[\($0)]]" }.first { targets.resolve($0, from: mapPath(map)) == .note(note) } ?? "akit:note/\(note)"
            return .init(note: note, element: graph.blocks.first { $0.note == note }?.element, link: link,
                         label: titles[note] ?? parts.last ?? note)
        }
        let exists = graph.edges.contains { $0.from == arrow.from && $0.to == arrow.to && $0.kind == arrow.kind }
        return KnowledgeInbox.ArrowPlan(proposal: proposal, map: map, from: end(arrow.from), to: end(arrow.to), kind: arrow.kind,
                                        exists: exists)
    }

    /// Closes an arrow proposal once the app has drawn it: the map on disk must have the arrow
    /// (from → to with its label); then the proposal file and its marks are removed. The map's
    /// edit goes through the commit queue like any canvas save; the proposal was never tracked
    /// (P3), so nothing is committed, unless it was, and then its removal is.
    public func closeArrow(_ proposal: Proposal, on map: String, env: HarnessEnvironment) async throws(Failure) {
        guard proposal.kind == .arrow, let arrow = proposal.arrow else {
            throw Failure(message: "\(proposal.id) is not an arrow proposal.")
        }
        let graph = MapGraph.map(id: map, file: ExcalidrawFile.load(mapFile(map)), targets: linkTargets())
        guard graph.edges.contains(where: { $0.from == arrow.from && $0.to == arrow.to && $0.kind == arrow.kind }) else {
            throw Failure(message: "The map \(map) has no arrow \(arrow.text) yet, so the proposal stays open.")
        }
        let file = root.appending(path: proposal.path)
        let git = KnowledgeGit(base: root, env: env)
        let tracked = !((try? await git.run(["ls-files", "--", proposal.path])) ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        do { try FileManager.default.removeItem(at: file) } catch {
            throw Failure(message: "Couldn't remove \(proposal.path): \(error.localizedDescription)")
        }
        removeCheck(of: proposal.id)
        guard tracked else { return }
        do { try await git.commit(paths: [proposal.path], message: "Close proposal \(proposal.id) (arrow drawn on \(map))") } catch {
            throw Failure(message: "\(proposal.path) is removed, but its removal wasn't committed: \(error.message)")
        }
    }
}

extension KnowledgeInbox {
    /// What the CLI says for an arrow proposal: the person draws it in the app.
    public static func arrowMessage(_ proposal: KnowledgeProposal) -> String {
        guard let arrow = proposal.arrow else { return "The proposal \(proposal.id) has no arrow." }
        let map = arrow.map.map { "on map \($0)" } ?? "on a map of \(arrow.from.split(separator: "/").first.map(String.init) ?? arrow.from)"
        return "Add the arrow \(arrow.text) \(map) in the app (Knowledge → Inbox)."
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
