import AKitKnowledge
import SwiftUI

/// The Inbox tab of the Knowledge screen (5.3): the agents' proposals in `inbox/` (`akit kb
/// inbox`) with their checks and the check model's marks; the selected one shows what Accept
/// would write. Accept… writes a note proposal in one commit (after its diff is confirmed), opens
/// an arrow's map with "Add an arrow?", or (5.4) puts a map draft in Edit with its blocks linked
/// to their notes for Save Map; Reject… moves the file to the Trash; Check Again asks the check
/// model (`akit kb check`).
struct InboxPanel: View {
    @Environment(KnowledgeModel.self) private var model

    var body: some View {
        @Bindable var model = model
        if model.proposals.isEmpty {
            ContentUnavailableView("No proposals", systemImage: "tray",
                                   description: Text("An agent proposes a change with akit kb propose: a section of a note, a new note, or an arrow for a map. It waits here until you accept or reject it."))
        } else {
            HSplitView {
                List(selection: $model.proposalID) {
                    ForEach(model.proposals, id: \.id) { ProposalRow(entry: $0).tag(Optional($0.id)) }
                }
                .frame(minWidth: 260, idealWidth: 320, maxWidth: 440)
                Group {
                    if let entry = model.selectedProposal { ProposalDetail(entry: entry) } else {
                        ContentUnavailableView("Choose a proposal", systemImage: "tray")
                    }
                }
                .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

/// What a proposal changes, in one line: the note, or the arrow.
private func proposalTitle(_ entry: KnowledgeInbox.Entry) -> String {
    entry.arrow?.text ?? entry.target ?? entry.id
}

private struct ProposalRow: View {
    let entry: KnowledgeInbox.Entry

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: entry.kind == .arrow ? "arrow.right" : entry.kind == .map ? "point.3.connected.trianglepath.dotted" : "doc.text")
                .foregroundStyle(.secondary)
                .help(entry.kind == .arrow ? "An arrow for a map" : entry.kind == .map ? "A map an agent drew" : "A change of a note")
            VStack(alignment: .leading, spacing: 2) {
                Text(proposalTitle(entry)).lineLimit(1)
                if let reason = entry.reason { Text(reason).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
                Text([entry.author, entry.created].compactMap(\.self).joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            CheckSummary(entry: entry)
        }
        .padding(.vertical, 2)
    }
}

/// Icons for the checks: red when one fails, orange for a warning, and the model's marks.
private struct CheckSummary: View {
    let entry: KnowledgeInbox.Entry

    var body: some View {
        HStack(spacing: 4) {
            if entry.checks.contains(where: { $0.status == .failed }) {
                Image(systemName: "xmark.octagon.fill").foregroundStyle(.red).help("A check fails: Accept is refused")
            } else if entry.checks.contains(where: { $0.status == .warning }) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).help("A check warns")
            } else {
                Image(systemName: "checkmark.circle").foregroundStyle(.green).help("Every check passes")
            }
            if let check = entry.modelCheck, !check.marks.isEmpty {
                Label("\(check.marks.count)", systemImage: "flag.fill")
                    .labelStyle(.titleAndIcon)
                    .font(.caption)
                    .foregroundStyle(check.stale ? Color.secondary : Color.orange)
                    .help("\(check.marks.count) mark\(check.marks.count == 1 ? "" : "s") from the check model" + (check.stale ? ", from before the proposal changed" : ""))
            }
        }
    }
}

private struct ProposalDetail: View {
    @Environment(KnowledgeModel.self) private var model
    let entry: KnowledgeInbox.Entry

    var body: some View {
        let plan = model.acceptPlan(entry)
        let mapRefused = { if case .failure? = model.mapPlan(entry) { true } else { false } }()
        let accepting = model.mapAcceptRequest?.proposal.id == entry.id
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(proposalTitle(entry)).font(.headline).lineLimit(1)
                    Text(entry.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
                Spacer()
                if let notice = model.notice {
                    Text(notice).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Button("Accept…", systemImage: "checkmark") { model.requestAccept(entry) }
                    .disabled(entry.proposal == nil || entry.checks.contains { $0.status == .failed } || { if case .failure? = plan { true } else { false } }()
                        || mapRefused || accepting)
                    .help(entry.kind == .arrow
                        ? "Open the map in Edit and draw this arrow there (and a block for a note the map lacks)"
                        : entry.kind == .map
                        ? "Put the draft in Edit with each block linked to the note its label names; then Save Map saves it into the base in one commit"
                        : "See the change, then write it into the note and commit it; the old note is backed up")
                Button("Reject…", systemImage: "xmark") { model.rejectRequest = entry.id }
                    .help("Move the proposal's file to the Trash; nothing in the base changes")
                Button("Check Again", systemImage: "wand.and.stars") { Task { await model.checkAgain(entry.id) } }
                    .disabled(model.checkingProposal != nil || entry.proposal == nil)
                    .help("Ask the check model (Settings → Knowledge check model) for marks: a duplicate, a contradiction with a map arrow, a broken link. It sends through the sending policy and only marks (akit kb check)")
                if model.checkingProposal == entry.id { ProgressView().controlSize(.small) }
            }
            .labelStyle(.titleAndIcon)
            .controlSize(.small)
            .padding(8)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if entry.kind == .map { MapDraftView(entry: entry) }
                    if let reason = entry.reason {
                        LabeledContent("Reason") { Text(reason).textSelection(.enabled) }
                    }
                    LabeledContent("From") { Text([entry.author ?? "unknown", entry.created].compactMap(\.self).joined(separator: " · ")) }
                    GroupBox("Checks") {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(entry.checks, id: \.name) { check in
                                HStack(alignment: .firstTextBaseline, spacing: 6) {
                                    CheckIcon(status: check.status)
                                    Text(check.name).bold()
                                    Text(check.message ?? check.status.rawValue).foregroundStyle(.secondary).textSelection(.enabled)
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    GroupBox("Check model") {
                        VStack(alignment: .leading, spacing: 4) {
                            if let check = entry.modelCheck {
                                Text("\(check.model) · \(check.checked)").font(.caption).foregroundStyle(.secondary)
                                if check.stale {
                                    Label("These marks are from before the proposal changed: Check Again.", systemImage: "clock.arrow.circlepath")
                                        .foregroundStyle(.orange)
                                }
                                if check.marks.isEmpty { Text("No marks.") }
                                ForEach(Array(check.marks.enumerated()), id: \.offset) { _, mark in
                                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                                        Image(systemName: "flag.fill").foregroundStyle(.orange)
                                        Text(mark.kind.rawValue).bold()
                                        Text(([mark.note, mark.edge, mark.link].compactMap(\.self).first.map { "\($0): " } ?? "") + mark.message)
                                            .textSelection(.enabled)
                                    }
                                }
                            } else {
                                Text("Not checked yet. Check Again asks the check model.").foregroundStyle(.secondary)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if entry.kind != .map {
                        GroupBox(entry.kind == .arrow ? "Arrow" : "What Accept writes") {
                            Group {
                                switch plan {
                                case .success(let plan)?: Text(plan.diff).font(.callout.monospaced())
                                case .failure(let error)?: Text(error.message).foregroundStyle(.red)
                                case nil:
                                    if let arrow = entry.arrow {
                                        Text("\(arrow.text)\n" + (arrow.map.map { "on the map \($0)" } ?? "on a map of \(arrow.from.split(separator: "/").first ?? "")")
                                            + ". Accept… opens the map in Edit and asks “Add an arrow?”.")
                                    } else {
                                        Text("AKit can't read this proposal; reject it.").foregroundStyle(.red)
                                    }
                                }
                            }
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .padding(12)
            }
        }
    }
}

/// A map proposal (5.4): the draft on a read-only canvas, what Accept links (label → [[note]]),
/// the labels that stay plain, and the blocks and arrows it adds or replaces. In Accept the canvas
/// is in Edit with the links set, under "Save the map?".
private struct MapDraftView: View {
    @Environment(KnowledgeModel.self) private var model
    let entry: KnowledgeInbox.Entry

    var body: some View {
        let plan = model.mapPlan(entry)
        let accepting = model.mapAcceptRequest?.proposal.id == entry.id
        VStack(alignment: .leading, spacing: 10) {
            if accepting, let request = model.mapAcceptRequest { SaveMapBanner(plan: request) }
            if let text = model.draftText(entry) {
                MapCanvasView(scene: .init(key: KnowledgeInbox.draftPath(of: entry.id), text: text, generation: model.draftGeneration),
                              viewMode: !accepting)
                    .frame(height: 340)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(.separator))
                    .help(accepting ? "The draft in Edit: change it if you like; Save Map saves what you see" : "The agent's draft, as Excalidraw shows it (read only)")
            } else {
                Text("The draft \(KnowledgeInbox.draftPath(of: entry.id)) is missing; reject the proposal.").foregroundStyle(.red)
            }
            GroupBox("Links on Accept") {
                VStack(alignment: .leading, spacing: 4) {
                    switch plan {
                    case .success(let plan)?:
                        if plan.links.isEmpty { Text("No label names a note: every block stays plain.").foregroundStyle(.secondary) }
                        ForEach(plan.links, id: \.element) { link in
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Image(systemName: "link").foregroundStyle(.tint)
                                Text(link.label).bold()
                                Text("→ \(link.link)").font(.callout.monospaced())
                                Text(link.note).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        ForEach(plan.unlinked, id: \.element) { plain in
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Image(systemName: "minus.circle").foregroundStyle(.secondary)
                                Text(plain.label).bold()
                                Text(plain.candidates.isEmpty ? "stays plain: no note has this name"
                                    : "stays plain: fits " + plain.candidates.joined(separator: ", "))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Divider()
                        Text(plan.diff).font(.callout.monospaced())
                    case .failure(let error)?: Text(error.message).foregroundStyle(.red)
                    case nil: EmptyView()
                    }
                }
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

/// "Save the map?" above the draft in Edit (Accept of a map proposal): Save Map writes it into the
/// base and commits it; Cancel leaves the proposal open.
private struct SaveMapBanner: View {
    @Environment(KnowledgeModel.self) private var model
    let plan: KnowledgeInbox.MapPlan
    @State private var working = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "square.and.arrow.down").font(.title3).foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text("Save the map?").bold()
                Text(plan.mapPath + (plan.original == nil ? (plan.newArea ? " (new, in a new area)" : " (new)") : " (replaces the map; the old one is backed up)"))
                    .font(.callout.monospaced()).textSelection(.enabled)
                Text("\(plan.links.count) block\(plan.links.count == 1 ? "" : "s") linked to notes" + (plan.unlinked.isEmpty ? "." : ", \(plan.unlinked.count) plain."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Cancel") { model.cancelMapAccept() }
                .help("Leave the proposal in the Inbox; nothing is saved")
            Button("Save Map") {
                working = true
                Task {
                    await model.saveAcceptedMap()
                    working = false
                }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(working)
            .help("Save the map as Excalidraw wrote it into the base, commit it, and remove the proposal")
        }
        .controlSize(.small)
        .padding(8)
        .background(Color.accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
    }
}

private struct CheckIcon: View {
    let status: KnowledgeInbox.Check.Status

    var body: some View {
        switch status {
        case .passed: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).help("Passed")
        case .warning: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).help("Warning")
        case .failed: Image(systemName: "xmark.octagon.fill").foregroundStyle(.red).help("Failed")
        }
    }
}

/// Accept… of a note proposal: the diff, then Accept writes it and commits it (`kb accept ID --yes`).
struct AcceptProposalSheet: View {
    @Environment(KnowledgeModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let plan: KnowledgeInbox.Plan
    @State private var working = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Accept Proposal").font(.title3.bold())
            Text("Writes \(plan.notePath)" + (plan.newArea ? " in a new area" : "") + " and commits it with the proposal's removal, in one commit. "
                + (plan.original == nil ? "" : "The note as it is now is backed up in ~/.akit/local/backups/knowledge first."))
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            GroupBox {
                ScrollView {
                    Text(plan.diff)
                        .font(.callout.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 240)
            } label: {
                Text("Changes")
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Accept") {
                    working = true
                    Task {
                        await model.accept(plan)
                        working = false
                        dismiss()
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(working)
            }
        }
        .padding(20)
        .frame(width: 620)
    }
}

/// "Add an arrow?" above a map in Edit (Accept of an arrow proposal): Add draws it, Cancel leaves
/// the proposal open.
struct AddArrowBanner: View {
    @Environment(KnowledgeModel.self) private var model
    let plan: KnowledgeInbox.ArrowPlan
    @State private var working = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.right.circle").font(.title3).foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text("Add an arrow?").bold()
                Text(plan.text).font(.callout.monospaced()).textSelection(.enabled)
                let missing = [plan.from, plan.to].filter { $0.element == nil }
                if plan.exists {
                    Text("The map has this arrow already: Add only closes the proposal.").font(.caption).foregroundStyle(.secondary)
                } else if !missing.isEmpty {
                    Text("A new block for " + missing.map { "\($0.label) (\($0.link))" }.joined(separator: " and ") + ", right of the drawing.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button("Cancel") { model.arrowRequest = nil }
                .help("Leave the proposal in the Inbox; nothing is drawn")
            Button("Add") {
                working = true
                Task {
                    await model.addArrow()
                    working = false
                }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(working)
            .help("Draw the arrow on this map, save it, and close the proposal; the map's change is committed with your other edits")
        }
        .controlSize(.small)
        .padding(8)
        .background(Color.accentColor.opacity(0.1))
    }
}

/// The Inbox's confirmations, on the Knowledge screen: Accept… (the diff), Reject…, and which map
/// gets an arrow when the proposal names none.
struct InboxDialogs: ViewModifier {
    @Environment(KnowledgeModel.self) private var model

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: Binding(get: { model.acceptRequest != nil }, set: { if !$0 { model.acceptRequest = nil } })) {
                if let plan = model.acceptRequest { AcceptProposalSheet(plan: plan) }
            }
            .confirmationDialog("Reject the proposal \(model.rejectRequest ?? "")?",
                                isPresented: Binding(get: { model.rejectRequest != nil }, set: { if !$0 { model.rejectRequest = nil } })) {
                Button("Move to Trash", role: .destructive) {
                    if let id = model.rejectRequest { Task { await model.reject(id) } }
                }
            } message: {
                Text("The proposal's file goes to the Trash. Nothing in the base changes, and there is nothing to commit.")
            }
            .confirmationDialog("Which map gets the arrow?",
                                isPresented: Binding(get: { model.arrowMapRequest != nil }, set: { if !$0 { model.arrowMapRequest = nil } })) {
                ForEach(model.arrowMapRequest?.maps ?? [], id: \.self) { map in
                    Button(map) {
                        if let request = model.arrowMapRequest { model.openArrow(request.proposal, on: map) }
                    }
                }
            } message: {
                Text("The proposal names no map. The map opens in Edit, and you add the arrow there.")
            }
    }
}
