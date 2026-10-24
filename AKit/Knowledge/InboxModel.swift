import AKitFoundation
import AKitKnowledge
import AKitLab
import Foundation

/// The Inbox tab's actions (5.3): the same core calls as `akit kb inbox / accept / reject / check`.
/// Accept of a note proposal writes and commits it (with a backup); Accept of an arrow opens its
/// map in Edit with "Add an arrow?", and Add draws it, saves the map the normal way (its commit
/// waits in the queue) and closes the proposal; Reject moves the file to the Trash; Check Again
/// asks the check model through the sending policy.
extension KnowledgeModel {
    var selectedProposal: KnowledgeInbox.Entry? {
        proposals.first { $0.id == proposalID }
    }

    /// The proposals again (`kb inbox`), keeping the selection while it is there.
    func readInbox() {
        guard let base else {
            (proposals, proposalID) = ([], nil)
            return
        }
        proposals = base.proposals()
        inboxCount = WatchFilter.inboxCount(base.root)
        if proposalID.map({ id in !proposals.contains { $0.id == id } }) ?? true { proposalID = proposals.first?.id }
        if let request = arrowRequest, !proposals.contains(where: { $0.id == request.proposal.id }) { arrowRequest = nil }
    }

    /// What Accept of a note proposal would write (`kb accept ID` without `--yes`); nil for an arrow.
    func acceptPlan(_ entry: KnowledgeInbox.Entry) -> Result<KnowledgeInbox.Plan, KnowledgeBase.Failure>? {
        guard let base, let proposal = entry.proposal, proposal.kind == .note else { return nil }
        do { return .success(try base.planAccept(proposal)) } catch { return .failure(error) }
    }

    /// Accept…: a note proposal asks its confirmation with the diff; an arrow opens its map.
    func requestAccept(_ entry: KnowledgeInbox.Entry) {
        guard let proposal = entry.proposal else { return }
        switch proposal.kind {
        case .note:
            switch acceptPlan(entry) {
            case .success(let plan)?: acceptRequest = plan
            case .failure(let error)?: problem = error.message
            case nil: break
            }
        case .arrow:
            guard let base else { return }
            let maps = base.arrowMaps(for: proposal)
            if maps.isEmpty {
                let areas = [proposal.arrow?.from, proposal.arrow?.to].compactMap { $0?.split(separator: "/").first.map(String.init) }
                problem = "No map in \(Array(Set(areas)).sorted().joined(separator: " or ")) to draw the arrow on. Add one with New Map… first."
            } else if maps.count == 1 {
                openArrow(entry.id, on: maps[0])
            } else {
                arrowMapRequest = ArrowMapRequest(proposal: entry.id, maps: maps)
            }
        }
    }

    /// Accept (confirmed) of a note proposal: `kb accept ID --yes`. Edits waiting in this window
    /// are queued first, so the accept's queue flush commits them before the note.
    @discardableResult
    func accept(_ plan: KnowledgeInbox.Plan) async -> Bool {
        guard let base else { return false }
        await forcePostDirty()
        await lastEnqueueDone()
        do {
            let accepted = try await base.accept(plan, env: env)
            // AKit's own write: the watcher must not queue it again.
            markOwnWrite(note: plan.note)
            reload()
            notice = "Accepted \(plan.proposal.id): wrote \(plan.notePath)" + (plan.newArea ? " in a new area" : "") + ", committed"
                + (accepted.backup.map { "; the old note is in \(FileWalk.tilde($0, home: home))" } ?? "") + "."
            return true
        } catch {
            problem = error.message
            readInbox()
            return false
        }
    }

    /// Reject (confirmed): `kb reject ID --yes`, the file to the Trash.
    @discardableResult
    func reject(_ id: String) async -> Bool {
        guard let base else { return false }
        do {
            let proposal = try base.proposal(id)
            let place = try await base.reject(proposal, env: env)
            if arrowRequest?.proposal.id == id { arrowRequest = nil }
            readInbox()
            notice = "Rejected \(id)" + (place.map { "; the file is in the Trash (\($0.lastPathComponent))" } ?? "") + "."
            return true
        } catch {
            problem = error.message
            readInbox()
            return false
        }
    }

    /// Check Again: `kb check ID` (the check model through the sending policy). A refusal shows
    /// its reason, as the CLI prints it.
    func checkAgain(_ id: String) async {
        guard let base, checkingProposal == nil else { return }
        let proposal: KnowledgeProposal
        do { proposal = try base.proposal(id) } catch {
            problem = error.message
            return
        }
        checkingProposal = id
        let env = env
        let result: Result<KnowledgeChecker.Outcome, any Error> = await Task.detached {
            do { return .success(try await KnowledgeChecker.run(proposal, in: base, env: env)) } catch { return .failure(error) }
        }.value
        checkingProposal = nil
        switch result {
        case .success(let outcome):
            let count = outcome.result.marks.count
            notice = "Checked \(id) with \(outcome.result.model): " + (count == 0 ? "no marks." : "\(count) mark\(count == 1 ? "" : "s").")
        case .failure(let error):
            problem = error.localizedDescription
        }
        readInbox()
    }

    /// Accept of an arrow on one map: the map opens in Edit, with "Add an arrow?" above it.
    func openArrow(_ id: String, on map: String) {
        guard let base else { return }
        do {
            let plan = try base.planArrow(try base.proposal(id), on: map)
            screenTab = .notes
            open(map: map)
            mapEditing = true
            arrowRequest = plan
        } catch {
            problem = error.message
        }
    }

    /// "Add an arrow?" → Add: the canvas draws the arrow (and a block for a note the map lacks),
    /// the change is saved now through the normal save, then the proposal is closed. The map's
    /// commit waits in the queue with the other edits (U2).
    @discardableResult
    func addArrow() async -> Bool {
        guard let base, let plan = arrowRequest else { return false }
        guard map == plan.map, let canvas = MapCanvasView.Coordinator.current else {
            problem = "Open the map \(plan.map) to add the arrow."
            return false
        }
        if !plan.exists {
            let arrow: String?
            do { arrow = try await canvas.addArrow(plan) } catch {
                let page = (error as NSError).userInfo["WKJavaScriptExceptionMessage"] as? String
                problem = "The map couldn't add the arrow \(plan.text): \(page ?? error.localizedDescription)"
                return false
            }
            guard let arrow else {
                problem = "The map couldn't add the arrow \(plan.text)."
                return false
            }
            if DebugSnapshot.options != nil { print("map: added the arrow \(arrow) for \(plan.text)") }
            guard await forcePostDirty() else {
                problem = "The arrow is on the map, but the map couldn't be saved, so the proposal stays open."
                return false
            }
        }
        do {
            try await base.closeArrow(plan.proposal, on: plan.map, env: env)
            arrowRequest = nil
            readInbox()
            notice = "Added \(plan.text) to \(plan.map); the proposal is closed. The map's change is committed with your other edits."
            return true
        } catch {
            problem = error.message
            return false
        }
    }

    /// Snapshots: the Inbox tab as text, with the selected proposal's diff and marks.
    var inboxManifest: [String] {
        var lines: [String] = []
        for entry in proposals {
            let failing: [String] = entry.checks.filter { $0.status != .passed }.map { "\($0.status.rawValue) \($0.name)" }
            let checks = failing.isEmpty ? "passed" : failing.joined(separator: "; ")
            var marks = "not checked"
            if let check = entry.modelCheck {
                marks = "\(check.marks.count) mark" + (check.marks.count == 1 ? "" : "s") + (check.stale ? ", stale" : "")
            }
            let selected = entry.id == proposalID ? "*" : ""
            let what: String = entry.arrow?.text ?? entry.target ?? "-"
            lines.append("proposal: \(entry.id)\(selected), \(entry.kind?.rawValue ?? "unreadable") \(what), by \(entry.author ?? "-"), "
                + "\(entry.created ?? "-"), checks \(checks), \(marks)")
        }
        guard let entry = selectedProposal else { return lines + ["inbox: no proposals"] }
        if let reason = entry.reason { lines.append("reason: \(reason)") }
        for check in entry.checks where check.message != nil { lines.append("check \(check.status.rawValue) \(check.name): \(check.message ?? "")") }
        if let check = entry.modelCheck {
            lines.append("model check: \(check.model), \(check.checked)" + (check.stale ? ", stale" : ""))
            for mark in check.marks {
                lines.append("mark \(mark.kind.rawValue)" + ([mark.note, mark.edge, mark.link].compactMap { $0 }.first.map { " \($0)" } ?? "") + ": \(mark.message)")
            }
        }
        switch acceptPlan(entry) {
        case .success(let plan)?: lines.append("diff:\n" + plan.diff)
        case .failure(let error)?: lines.append("accept refused: \(error.message)")
        case nil:
            if let proposal = entry.proposal, proposal.kind == .arrow {
                lines.append("arrow: \(proposal.arrow?.text ?? "-"), maps: " + (base?.arrowMaps(for: proposal).joined(separator: ", ") ?? "-"))
            }
        }
        lines.append("buttons: Accept…, Reject…, Check Again" + (checkingProposal == entry.id ? " (checking)" : ""))
        return lines
    }
}
