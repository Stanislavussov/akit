import AKitErrorAnalysis
import AKitFoundation
import AKitLab
import AKitReview
import AKitSessions
import AKitHarnesses
import AKitModel
import AKitProjectSetup
import SwiftUI

/// Brain → Global Instructions: the core layer's AGENTS.md text, the one source of every
/// harness's global instructions, and its copies in the global files
/// (docs/design/global-instructions.md).
struct GlobalInstructionsDetailView: View {
    @Environment(AppModel.self) private var model
    @State private var status: GlobalInstructions.Status?
    @State private var sheet: Sheet?
    @AppStorage("brain.global.source") private var showSource = false
    @State private var report: InstructionAnalysis.Report?
    @State private var running: InstructionAnalysis.Part?
    @State private var analysisProblem: String?
    /// Edit… opened with a suggestion applied.
    @State private var draft: String?
    /// Loaded in Sessions: the files recorded sessions really loaded.
    @State private var seen: GlobalInstructions.Sightings?
    @State private var seeing = false

    enum Sheet: String, Identifiable {
        case edit, blocks, takeOver = "take-over", review, sessions
        var id: String { rawValue }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header
                if let status {
                    text(status)
                    files(status)
                    loadedInSessions
                    analysis(status)
                    ForEach(status.notes, id: \.self) { note in
                        Label(note, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).font(.callout)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } else {
                    ProgressView().frame(maxWidth: .infinity)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task(id: model.lastScan) {
            status = await model.globalInstructionsStatus()
            report = await Task.detached { InstructionAnalysis.load(env: .current) }.value
            await findInSessions()
        }
        .sheet(item: $sheet) { which in
            switch which {
            case .edit: EditGlobalInstructionsSheet(text: status?.text ?? "", draft: draft) { reload() }
            case .review, .sessions:
                AnalyzeInstructionsSheet(part: which == .review ? .review : .sessions) { made in report = made }
            case .blocks: GlobalBlocksSheet(blocks: nil) { reload() }
            case .takeOver: if let status { TakeOverSheet(status: status) { reload() } }
            }
        }
        .onAppear {
            // Snapshots: `--tab edit` / `blocks` open the sheets.
            if let tab = DebugSnapshot.options?.tab { sheet = Sheet(rawValue: tab) }
        }
    }

    private func findInSessions() async {
        seeing = true
        seen = await Task.detached { GlobalInstructions.sightings(env: .current) }.value
        seeing = false
    }

    /// Use as Core Text…: Edit… with the file's own text (other tools' blocks and AKit's left out).
    private func useAsCoreText(_ sighting: InstructionSightings.Sighting) {
        guard let text = GlobalInstructions.ownText(of: URL(filePath: sighting.path)) else { return }
        draft = text
        sheet = .edit
    }

    private var loadedInSessions: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("The instruction files your recorded sessions of the last 30 days loaded (Claude Code, Pi). A global file AKit doesn't look at means the harness reads another folder.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button(seeing ? "Reading…" : "Refresh", systemImage: "arrow.clockwise") { Task { await findInSessions() } }
                        .disabled(seeing)
                }
                if let seen {
                    ForEach(seen.notes, id: \.self) { note in
                        Label(note, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).font(.callout)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Text("Global").font(.headline)
                    if seen.report.global.isEmpty { Text("No session recorded a global file.").foregroundStyle(.secondary) }
                    ForEach(seen.report.global) { sighting in
                        SightingRow(sighting: sighting, sessions: sighting.sessions, unknown: !seen.isKnown(sighting)) { useAsCoreText(sighting) }
                    }
                    let projects = seen.report.byProject
                    if !projects.isEmpty {
                        Text("Projects (\(projects.count))").font(.headline)
                        ForEach(projects, id: \.project) { group in
                            DisclosureGroup {
                                ForEach(group.files, id: \.file.id) { item in
                                    SightingRow(sighting: item.file, sessions: item.sessions, unknown: false) { useAsCoreText(item.file) }
                                }
                            } label: {
                                Text(sightingPath(group.project))
                                    .font(.callout.monospaced())
                            }
                        }
                    }
                } else {
                    ProgressView().frame(maxWidth: .infinity)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(4)
        } label: {
            Text("Loaded in Sessions")
        }
    }

    private func reload() {
        draft = nil
        Task { status = await model.globalInstructionsStatus() }
    }

    private func analysis(_ status: GlobalInstructions.Status) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Button(running == .size ? "Counting…" : "Size and Repeats", systemImage: "ruler") { runSize() }
                        .disabled(running != nil)
                        .help("What each section costs in the requests of the last 30 days, and where projects repeat it. No model call.")
                    Button("Model Review…", systemImage: "sparkle.magnifyingglass") { sheet = .review }
                        .help("A model reads the global text: contradictions, vague rules, rules with no effect, stale names, wrong place")
                    Button("Check Sessions…", systemImage: "text.bubble") { sheet = .sessions }
                        .help("A model matches your corrections in recorded sessions to the rules: broken rules and rules you keep asking for by hand")
                }
                .fixedSize(horizontal: true, vertical: false)
                if let report {
                    Text("Last analysis: \(report.made.formatted(date: .abbreviated, time: .shortened))").font(.caption).foregroundStyle(.secondary)
                }
                if let analysisProblem {
                    Label(analysisProblem, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let report {
                    ForEach(report.notes, id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary) }
                    costs(report)
                    if report.findings.isEmpty {
                        Text(report.parts.isEmpty ? "No analysis yet." : "No findings.").foregroundStyle(.secondary)
                    }
                    ForEach(report.sorted) { finding in
                        FindingRow(finding: finding, coreText: status.text) { text in
                            draft = text
                            sheet = .edit
                        }
                        Divider()
                    }
                } else {
                    Text("No analysis yet. Start with Size and Repeats: it needs no model.").foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(4)
        } label: {
            Text("Analysis").fontWeight(.medium)
        }
    }

    @ViewBuilder private func costs(_ report: InstructionAnalysis.Report) -> some View {
        let top = report.costs.sorted { $0.sent != $1.sent ? $0.sent > $1.sent : $0.tokens > $1.tokens }.prefix(8)
        if !top.isEmpty {
            VStack(alignment: .leading, spacing: 3) {
                Text("Most expensive sections, last \(report.days) days").font(.callout.weight(.medium))
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 2) {
                    ForEach(Array(top)) { cost in
                        GridRow {
                            Text(cost.section).lineLimit(1)
                            Text(cost.file).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1)
                            Text("≈ \(cost.tokens.formatted()) tokens").monospacedDigit()
                            Text(cost.requests > 0 ? "× \(cost.requests.formatted()) = \(cost.sent.formatted())" : "no requests")
                                .monospacedDigit().foregroundStyle(.secondary)
                        }
                        .font(.caption)
                    }
                }
            }
        }
    }

    private func runSize() {
        running = .size
        analysisProblem = nil
        Task {
            do { report = try await model.analyzeGlobalInstructions(.size, agent: nil) } catch { analysisProblem = error.localizedDescription }
            running = nil
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Label("Global Instructions", systemImage: "text.book.closed").font(.title2.bold())
                Spacer()
                Button("Edit…", systemImage: "pencil") { sheet = .edit }
                    .disabled(status?.hasCore != true)
                    .help("Change the global text: a diff, a commit in the brain, then the block in each global file")
                Button("Take Over…", systemImage: "tray.and.arrow.down") { sheet = .takeOver }
                    .disabled(status?.copies.allSatisfy(\.own.isEmpty) != false)
                    .help("Move your own text from the global files into the brain: it joins the core text, and the files get it back as AKit's block")
                Button("Update Blocks…", systemImage: "arrow.down.doc") { sheet = .blocks }
                    .disabled(status?.outdated != true)
                    .help("Write the core text into the global files whose block is out of date (diff first, backup)")
            }
            Text("The core layer's AGENTS.md text. AKit writes it as its own block into each harness's global file, so every session in every project gets it. Change it here, not in the files: the brain is the source.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func text(_ status: GlobalInstructions.Status) -> some View {
        GroupBox {
            if status.text.isEmpty {
                Text("No global text yet. Edit… writes the first one.")
                    .foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(4)
            } else if showSource {
                Text(status.text).font(.callout.monospaced()).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(4)
            } else {
                MarkdownText(text: status.text).padding(4)
            }
        } label: {
            HStack {
                Text("Text").fontWeight(.medium)
                if !status.text.isEmpty {
                    Text("\(status.bytes.formatted(.byteCount(style: .file))) ≈ \(status.tokens.formatted()) tokens in every request")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("Source", isOn: $showSource).toggleStyle(.switch).controlSize(.mini)
                    .help("Show the Markdown as written")
            }
        }
    }

    private func files(_ status: GlobalInstructions.Status) -> some View {
        GroupBox("Global Files (\(status.copies.count))") {
            VStack(alignment: .leading, spacing: 12) {
                if status.copies.isEmpty {
                    Text("No harness with a global instruction file is installed.").foregroundStyle(.secondary)
                }
                ForEach(status.copies) { copy in
                    GlobalCopyRow(copy: copy)
                    if copy.id != status.copies.last?.id { Divider() }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(4)
        }
    }
}

/// `~/…` for a path a session recorded; `/tmp` and `/private/tmp` are the same folder.
private func sightingPath(_ path: String) -> String {
    let home = HarnessEnvironment.current.homeDirectory, url = URL(filePath: path)
    let shown = FileWalk.tilde(url, home: home)
    return shown.hasPrefix("~") ? shown : FileWalk.tilde(url.resolvingSymlinksInPath(), home: home.resolvingSymlinksInPath())
}

/// One file the sessions loaded, with Use as Core Text….
private struct SightingRow: View {
    let sighting: InstructionSightings.Sighting
    let sessions: Int
    /// A global file AKit doesn't look at.
    let unknown: Bool
    let use: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(sightingPath(sighting.path))
                    .font(.callout.monospaced())
                ForEach(sighting.harnesses, id: \.self) { harness in
                    Text(harness.displayName).font(.caption).padding(.horizontal, 5).padding(.vertical, 1)
                        .background(.quaternary, in: Capsule())
                }
                Spacer()
                if unknown {
                    Label("AKit doesn't look here", systemImage: "eye.slash").foregroundStyle(.orange).font(.caption)
                }
                Button("Use as Core Text…", systemImage: "square.and.arrow.down") { use() }
                    .disabled(!sighting.exists)
                    .help("Open Edit… with this file's own text (without other tools' blocks) as the global instructions")
                Button("Open", systemImage: "arrow.up.forward.app") { NSWorkspace.shared.open(URL(filePath: sighting.path)) }
                    .labelStyle(.iconOnly).buttonStyle(.borderless)
                    .disabled(!sighting.exists)
                    .help("Open the file in its app")
            }
            Text((sessions == 1 ? "1 session" : "\(sessions) sessions") + ", last \(sighting.lastSeen.formatted(date: .abbreviated, time: .omitted))"
                 + (sighting.exists ? "" : " · the file is gone now"))
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

private struct GlobalCopyRow: View {
    let copy: GlobalInstructions.Copy

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(copy.path).font(.callout.monospaced()).fontWeight(.medium)
                ForEach(copy.harnesses, id: \.self) { harness in
                    Text(harness.displayName).font(.caption).padding(.horizontal, 5).padding(.vertical, 1)
                        .background(.quaternary, in: Capsule())
                }
                Spacer()
                state
                Button("Open", systemImage: "arrow.up.forward.app") { NSWorkspace.shared.open(copy.file) }
                    .labelStyle(.iconOnly).buttonStyle(.borderless)
                    .disabled(!FileManager.default.fileExists(atPath: copy.file.path))
                    .help("Open \(copy.path) in its app")
            }
            Text("\(copy.bytes.formatted(.byteCount(style: .file))) in all").font(.caption).foregroundStyle(.secondary)
            ForEach(copy.managed, id: \.self) { block in
                Label("\(block.name) block, lines \(block.lines.lowerBound)–\(block.lines.upperBound), \(block.bytes.formatted(.byteCount(style: .file))): another tool writes it; AKit leaves it alone",
                      systemImage: "lock").font(.caption).foregroundStyle(.secondary)
            }
            if !copy.own.isEmpty {
                Label("Your own text, \(copy.ownBytes.formatted(.byteCount(style: .file))), not in the brain: "
                      + copy.own.map { $0.heading.map { "## \($0)" } ?? "line \($0.line)" }.joined(separator: ", "),
                      systemImage: "person").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder private var state: some View {
        switch copy.state {
        case .current:
            Label("Current", systemImage: "checkmark.circle.fill").foregroundStyle(.green).font(.caption)
        case .outdated(let why):
            Label("Out of date", systemImage: "arrow.triangle.2.circlepath").foregroundStyle(.orange).font(.caption).help(why)
        case .noBlock(let why):
            Label("No block", systemImage: "minus.circle").foregroundStyle(.secondary).font(.caption).help(why)
        }
    }
}

/// Edit…: the core text in an editor → Review Changes (diff) → Commit to Brain → the global
/// files' blocks (diffs) → Apply.
struct EditGlobalInstructionsSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let initial: String
    let onDone: () -> Void
    @State private var text: String
    @State private var plan: GlobalInstructions.EditPlan?
    @State private var blocks: GlobalInstructions.HomeBlocks?
    @State private var problem: String?
    @State private var busy = false

    /// `draft`: the editor starts with it (an analysis suggestion applied) instead of the text.
    init(text: String, draft: String? = nil, onDone: @escaping () -> Void) {
        initial = text
        self.onDone = onDone
        _text = State(initialValue: draft ?? text)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Edit Global Instructions").font(.title2.bold())
            Text(blocks != nil
                 ? "Step 3 of 3: the block in each global file gets the new text."
                 : plan != nil ? "Step 2 of 3: the core layer's AGENTS.md text in the brain (a commit)." : "Step 1 of 3: the text every session gets. Markdown; ## headings make sections.")
                .font(.callout).foregroundStyle(.secondary)
            if let blocks {
                GlobalBlocksPreview(blocks: blocks)
            } else if let plan {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        Text("layers/core · AGENTS.md text (brain)").fontWeight(.medium).padding(.bottom, 2)
                        DiffPreview(diff: plan.lines)
                    }
                    .font(.callout.monospaced()).frame(maxWidth: .infinity, alignment: .leading).padding(6)
                }
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
            } else {
                TextEditor(text: $text)
                    .font(.callout.monospaced())
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
            }
            if let problem {
                Label(problem, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).font(.callout).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                if plan != nil, blocks == nil { Button("Back") { plan = nil }.disabled(busy) }
                Spacer()
                Button(blocks == nil ? "Cancel" : "Close") {
                    if blocks != nil { onDone() }
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                if let blocks {
                    Button("Apply") { apply(blocks) }
                        .keyboardShortcut(.defaultAction)
                        .disabled(busy || !blocks.canApply)
                        .help("Back up and write the block in each global file. Refused if a file changed since this preview.")
                } else if let plan {
                    Button("Commit to Brain") { commit(plan) }
                        .keyboardShortcut(.defaultAction)
                        .disabled(busy)
                        .help("Commit the text in the core layer. The global files change only in the next step, after you see their diffs.")
                } else {
                    Button("Review Changes", action: review)
                        .keyboardShortcut(.defaultAction)
                        .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines) == initial.trimmingCharacters(in: .whitespacesAndNewlines))
                }
            }
        }
        .padding(20)
        .frame(width: 760, height: 600)
    }

    private func review() {
        problem = nil
        guard let brain = model.brain else { problem = "The brain is not loaded."; return }
        do { plan = try GlobalInstructions.editing(to: text, brain: brain) } catch { problem = error.message }
    }

    private func commit(_ plan: GlobalInstructions.EditPlan) {
        busy = true
        problem = nil
        Task {
            do {
                let made = try await model.commitGlobalInstructions(plan)
                blocks = made
                if made.diffs.isEmpty {
                    problem = "Core has the new text (committed). No global file needs a change: " + (made.warnings.first ?? "they are current.")
                }
            } catch {
                problem = error.localizedDescription
            }
            busy = false
        }
    }

    private func apply(_ blocks: GlobalInstructions.HomeBlocks) {
        busy = true
        problem = nil
        Task {
            do {
                try await model.applyGlobalInstructionBlocks(blocks)
                onDone()
                dismiss()
            } catch {
                problem = error.localizedDescription
            }
            busy = false
        }
    }
}

/// Update Blocks…: the global files whose block is out of date, as diffs, with Apply.
struct GlobalBlocksSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State var blocks: GlobalInstructions.HomeBlocks?
    let onDone: () -> Void
    @State private var problem: String?
    @State private var busy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Update Global Files").font(.title2.bold())
            Text("AKit's block in each global file gets the core text. Only the block changes; the rest of each file stays.")
                .font(.callout).foregroundStyle(.secondary)
            if let blocks { GlobalBlocksPreview(blocks: blocks) } else { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity) }
            if let problem {
                Label(problem, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).font(.callout).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Apply") {
                    guard let blocks else { return }
                    busy = true
                    Task {
                        do {
                            try await model.applyGlobalInstructionBlocks(blocks)
                            onDone()
                            dismiss()
                        } catch {
                            problem = error.localizedDescription
                        }
                        busy = false
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(busy || blocks?.canApply != true)
            }
        }
        .padding(20)
        .frame(width: 760, height: 560)
        .task { if blocks == nil { blocks = await model.globalInstructionBlocks() } }
    }
}

private struct GlobalBlocksPreview: View {
    let blocks: GlobalInstructions.HomeBlocks
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if blocks.diffs.isEmpty { Text("No global file needs a change.").foregroundStyle(.secondary) }
                    ForEach(blocks.diffs) { diff in
                        VStack(alignment: .leading, spacing: 0) {
                            Text(diff.path + " (AKit's block)").fontWeight(.medium).padding(.bottom, 2)
                            DiffPreview(diff: diff.lines)
                        }
                    }
                }
                .font(.callout.monospaced()).frame(maxWidth: .infinity, alignment: .leading).padding(6)
            }
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
            ForEach(blocks.warnings, id: \.self) { Text($0).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
        }
    }
}

/// Take Over…: the own text of the global files → pick → the core text's diff → Commit to
/// Brain → the blocks' diffs → Apply (blocks, then the picked text leaves the files).
struct TakeOverSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let status: GlobalInstructions.Status
    let onDone: () -> Void
    @State private var candidates: [GlobalInstructions.Candidate] = []
    @State private var picked: Set<String> = []
    @State private var plan: GlobalInstructions.TakeOverPlan?
    @State private var blocks: GlobalInstructions.HomeBlocks?
    @State private var kept: [String]?
    @State private var problem: String?
    @State private var busy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Take Over Global Instructions").font(.title2.bold())
            Text(stepText).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Group {
                if let kept {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 6) {
                            Label("Done: the picked text is in the brain, and the global files get it as AKit's block.", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                            ForEach(kept, id: \.self) { Text($0).font(.callout).foregroundStyle(.secondary) }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading).padding(6)
                    }
                } else if let blocks {
                    GlobalBlocksPreview(blocks: blocks)
                } else if let plan {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            Text("layers/core · AGENTS.md text (brain)").fontWeight(.medium).padding(.bottom, 2)
                            DiffPreview(diff: plan.lines)
                        }
                        .font(.callout.monospaced()).frame(maxWidth: .infinity, alignment: .leading).padding(6)
                    }
                    .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
                } else {
                    List(candidates) { candidate in row(candidate) }
                        .listStyle(.bordered)
                }
            }
            .frame(maxHeight: .infinity)
            if let problem {
                Label(problem, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).font(.callout).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                if plan != nil, blocks == nil { Button("Back") { plan = nil }.disabled(busy) }
                Spacer()
                Button(kept != nil || blocks != nil ? "Close" : "Cancel") {
                    if blocks != nil { onDone() }
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                if kept != nil {
                    EmptyView()
                } else if let blocks, let plan {
                    Button("Apply") { finish(plan, blocks) }
                        .keyboardShortcut(.defaultAction).disabled(busy)
                        .help("Back up and write the blocks, then take the picked text out of each file whose block has it")
                } else if let plan {
                    Button("Commit to Brain") { commit(plan) }
                        .keyboardShortcut(.defaultAction).disabled(busy)
                } else {
                    Button("Review Changes", action: review)
                        .keyboardShortcut(.defaultAction).disabled(picked.isEmpty)
                }
            }
        }
        .padding(20)
        .frame(width: 780, height: 620)
        .task {
            let status = status, env = HarnessEnvironment.current
            candidates = await Task.detached { GlobalInstructions.candidates(status, env: env) }.value
            // Ticked at first: a text with one version that can leave every file it is in.
            picked = Set(candidates.filter { $0.differs.isEmpty && $0.places.allSatisfy { $0.stays == nil } }.map(\.id))
        }
    }

    private var stepText: String {
        if kept != nil { return "What happened." }
        if blocks != nil { return "Step 3 of 3: AKit's block in each global file gets the new core text. Then the picked text leaves the files whose block has it (backup first)." }
        if plan != nil { return "Step 2 of 3: the picked text joins the core layer's AGENTS.md text (a commit in the brain). The files don't change yet." }
        return "Step 1 of 3: your own text in the global files, not in the brain yet. Other tools' blocks (such as oh-my-claudecode's) are not listed: AKit leaves them alone. Pick what every harness should get."
    }

    private func row(_ candidate: GlobalInstructions.Candidate) -> some View {
        Toggle(isOn: Binding(get: { picked.contains(candidate.id) }, set: { on in
            if on { picked.insert(candidate.id); picked.subtract(candidate.differs) } else { picked.remove(candidate.id) }
        })) {
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(candidate.title).fontWeight(.medium)
                    Text(candidate.text.utf8.count.formatted(.byteCount(style: .file))).font(.caption).foregroundStyle(.secondary)
                    if candidate.inCore { Text("in the brain already").font(.caption).foregroundStyle(.green) }
                }
                Text(candidate.places.map { "\($0.path):\($0.section.line)" }.joined(separator: " · ")).font(.caption.monospaced()).foregroundStyle(.secondary)
                if !candidate.differs.isEmpty {
                    Label("Another file has the same heading with other text: pick one version.", systemImage: "arrow.left.arrow.right")
                        .font(.caption).foregroundStyle(.orange)
                }
                ForEach(candidate.places.compactMap(\.stays), id: \.self) { stays in
                    Label("Stays in the file: \(stays)", systemImage: "info.circle").font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text(candidate.text.trimmingCharacters(in: .whitespacesAndNewlines)).font(.caption.monospaced()).lineLimit(4)
                    .foregroundStyle(.secondary).textSelection(.enabled)
            }
            .padding(.vertical, 3)
        }
    }

    private func review() {
        problem = nil
        do { plan = try GlobalInstructions.takeOver(candidates.filter { picked.contains($0.id) }, status: status) } catch { problem = error.message }
    }

    private func commit(_ plan: GlobalInstructions.TakeOverPlan) {
        busy = true
        problem = nil
        Task {
            do { blocks = try await model.commitGlobalTakeOver(plan) } catch { problem = error.localizedDescription }
            busy = false
        }
    }

    private func finish(_ plan: GlobalInstructions.TakeOverPlan, _ blocks: GlobalInstructions.HomeBlocks) {
        busy = true
        problem = nil
        Task {
            do { kept = try await model.finishGlobalTakeOver(plan, blocks: blocks) } catch { problem = error.localizedDescription }
            busy = false
            onDone()
        }
    }
}

/// One finding of the analysis: severity, title, why, where, and its suggestion.
private struct FindingRow: View {
    let finding: InstructionAnalysis.Finding
    let coreText: String
    let onUse: (String) -> Void
    @State private var open = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                SeverityBadge(severity: ReviewSeverity(rawValue: finding.severity.rawValue) ?? .medium)
                Text(finding.title).fontWeight(.medium)
                Text(partTitle).font(.caption).foregroundStyle(.secondary)
                Spacer()
                if let confidence = finding.confidence {
                    Text("confidence \(confidence.formatted(.number.precision(.fractionLength(2))))").font(.caption).foregroundStyle(.secondary)
                }
            }
            if !finding.why.isEmpty { Text(finding.why).font(.callout).fixedSize(horizontal: false, vertical: true) }
            Text([finding.section, finding.file].compactMap { $0 }.joined(separator: " · ")).font(.caption.monospaced()).foregroundStyle(.secondary)
            if !finding.places.isEmpty {
                Text("Also: " + finding.places.prefix(6).joined(separator: ", ") + (finding.places.count > 6 ? " +\(finding.places.count - 6)" : ""))
                    .font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(2)
            }
            if let suggestion = finding.suggestion {
                DisclosureGroup(isExpanded: $open) {
                    VStack(alignment: .leading, spacing: 6) {
                        if suggestion.isEmpty {
                            Text("Remove the section.").font(.callout)
                        } else {
                            Text(suggestion).font(.caption.monospaced()).textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading).padding(6)
                                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
                        }
                        if let applied = GlobalInstructions.applying(suggestion, toSection: finding.section, in: coreText) {
                            Button("Use in Edit…") { onUse(applied) }
                                .help("Open Edit… with the suggestion in the core text; you see the diff before the commit")
                        } else {
                            Text("The section is not in the brain's text. Take Over… brings it there; then the suggestion can be used.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                } label: {
                    Text("Suggested change").font(.callout)
                }
            }
        }
    }

    private var partTitle: String {
        switch finding.part {
        case .size: "size"
        case .review: "model review"
        case .sessions: "sessions"
        }
    }
}

/// Model Review… and Check Sessions…: the agent that runs the call, then Run.
struct AnalyzeInstructionsSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let part: InstructionAnalysis.Part
    let onDone: (InstructionAnalysis.Report) -> Void
    @AppStorage("instructions.analyze.harness") private var harnessRaw = LabHarness.claudeCode.rawValue
    @AppStorage("instructions.analyze.model") private var modelName = ""
    @AppStorage("instructions.analyze.effort") private var effort = "high"
    @State private var busy = false
    @State private var problem: String?
    @State private var task: Task<Void, Never>?

    private var harness: Binding<LabHarness> {
        Binding(get: { LabHarness(rawValue: harnessRaw) ?? .claudeCode }, set: { harnessRaw = $0.rawValue })
    }

    private var agent: LabAgent {
        LabAgent(harness: harness.wrappedValue, model: modelName.trimmingCharacters(in: .whitespaces), effort: effort)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(part == .review ? "Model Review" : "Check Sessions").font(.title2.bold())
            Text(part == .review
                 ? "One model call reads your global files (each harness's, with AKit's block) and the names of your skills and MCP servers. It reports contradictions, vague rules, rules with no effect, stale names and rules in the wrong place, each with a severity and a suggested change."
                 : "AKit takes your reactions in recorded sessions of the last 30 days (Claude Code and Pi; interrupts, refusals, bad ratings, pushbacks, the next message), with what the agent had just said. One model call matches them to your global files: rules the agent broke, and things you ask for by hand that no rule says.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Form {
                ReviewAgentFields(harness: harness, modelName: $modelName, effort: $effort, keepsValues: DebugSnapshot.options == nil)
            }
            .formStyle(.grouped)
            .disabled(busy)
            Text("The call goes through the harness's own sign-in, under the send policy and the monthly limit; it shows in Lab → Sends.")
                .font(.caption).foregroundStyle(.secondary)
            if busy { ProgressView("Waiting for \(agent.label)…").frame(maxWidth: .infinity) }
            if let problem {
                Label(problem, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).font(.callout).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Cancel") {
                    task?.cancel()
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                Button("Run") {
                    busy = true
                    problem = nil
                    let agent = agent
                    task = Task {
                        do {
                            let report = try await model.analyzeGlobalInstructions(part, agent: agent)
                            onDone(report)
                            dismiss()
                        } catch {
                            if !Task.isCancelled { problem = error.localizedDescription }
                        }
                        busy = false
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(busy || (agent.harness == .claudeCode && agent.model.isEmpty))
            }
        }
        .padding(20)
        .frame(width: 560)
    }
}
