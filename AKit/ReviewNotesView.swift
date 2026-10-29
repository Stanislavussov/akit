import AKitErrorAnalysis
import AKitLab
import SwiftUI

/// A one-call review's notes (`docs/design/error-analysis.md`, "Step 1", "Diagnosis" and
/// "Verifier"), diagnosis first: a card with the outcome, the main problem, its cause, why and the
/// fix; then the user's reactions with what the agent did and why, loops, what to change, the
/// accepted notes grouped by error-analysis mode, and the rest (paragraph, requirements,
/// deviation steps, rejected notes) under Details.
struct ReviewNotesView: View {
    let notes: SessionNotes
    /// Mode names and definitions for the notes' groups; without them a group shows its mode id.
    var modes: [Mode] = []
    /// The reviewed session's numbers (`analysis.json` of a Lab review).
    var metrics: SessionMetrics?
    /// On a Lab review run, which has Re-check with Another Model….
    var inLabRun = false
    /// Snapshots: `--tab notes` opens the disclosures.
    @State private var showDetails = DebugSnapshot.options?.tab == "notes"
    @State private var showRejected = DebugSnapshot.options?.tab == "notes"
    @State private var showPlainTurns = DebugSnapshot.options?.tab == "reactions"
    @State private var translator = Translator()

    private typealias Key = SessionNotes.TranslationKey

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .firstTextBaseline) {
                TranslationNote(translator: translator)
                Spacer()
                let notes = notes
                TranslateMenu(translator: translator, id: notes.sessionKey) { notes.translationSource(env: .current) }
                    .controlSize(.small)
            }
            ConclusionCard(notes: notes, metrics: metrics, inLabRun: inLabRun, translator: translator)
            if let reactions = notes.reactions, !reactions.isEmpty {
                reactionsSection(reactions).id("reactions")
            }
            if let loops = notes.loops, !loops.isEmpty {
                section("Loops") {
                    ForEach(Array(loops.enumerated()), id: \.offset) { index, loop in
                        LoopView(loop: loop, what: translator.text(Key.loop(index), loop.what))
                    }
                }
            }
            if !notes.advice.isEmpty {
                section("What to Change") {
                    ForEach(Array(notes.advice.prefix(Review.limit).enumerated()), id: \.offset) { index, advice in
                        AdviceView(number: index + 1, advice: advice,
                                   title: translator.text(Key.adviceTitle(index), advice.title),
                                   detail: translator.text(Key.adviceDetail(index), advice.detail))
                    }
                }
            }
            section("Problems by Type", spacing: 16) {
                if notes.accepted.isEmpty {
                    Text("Checked, no failures: the verifier accepted no notes.").foregroundStyle(.secondary)
                }
                ForEach(groups, id: \.id) { group in
                    VStack(alignment: .leading, spacing: 12) {
                        Label("\(group.title) · \(group.notes.count)", systemImage: "tag")
                            .font(.headline)
                            .help(group.help)
                        ForEach(group.notes) { note in
                            NoteView(note: note, collapsesQuote: true,
                                     unconfirmed: !group.id.isEmpty && types[note.id]?.confirmed == false, translator: translator)
                        }
                            .padding(.leading, 22)
                    }
                }
            }
            .id("notes")
            DisclosureGroup("Details: what happened, requirements, rejected notes", isExpanded: $showDetails) {
                details.padding(.top, 10)
            }
            .font(.callout)
        }
    }

    /// Reactions that need explaining first (negative ones, or any with a cause); plain next
    /// messages folded away.
    @ViewBuilder private func reactionsSection(_ reactions: [UserReaction]) -> some View {
        let explained = reactions.filter { $0.kind.isNegative || (notes.checkpoint(of: $0).map { $0.cause != .none } ?? false) }
        let plain = reactions.filter { reaction in !explained.contains { $0.id == reaction.id } }
        section("Your Reactions") {
            Text("Where you stopped, refused, rated or corrected the agent, and why it went that way.")
                .foregroundStyle(.secondary)
            if explained.isEmpty {
                Text("No interrupts, refusals, bad ratings or corrections.").foregroundStyle(.secondary)
            }
            ForEach(explained) { reaction in
                ReactionView(reaction: reaction, checkpoint: notes.checkpoint(of: reaction), translator: translator)
            }
            if !plain.isEmpty {
                DisclosureGroup("Other messages and good ratings (\(plain.count))", isExpanded: $showPlainTurns) {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(plain) { reaction in
                            ReactionView(reaction: reaction, checkpoint: notes.checkpoint(of: reaction), translator: translator)
                        }
                    }
                    .padding(.top, 6)
                }
                .font(.callout)
            }
        }
    }

    @ViewBuilder private var details: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(authors).foregroundStyle(.secondary).textSelection(.enabled)
            if !notes.paragraph.isEmpty {
                section("What Happened", spacing: 3) {
                    MarkdownLines(text: translator.text(Key.paragraph, notes.paragraph).trimmingCharacters(in: .whitespacesAndNewlines))
                    Text("Written before the verifier: it may mention a rejected note.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if !notes.requirements.isEmpty {
                section("Requirements", spacing: 3) {
                    ForEach(Array(notes.requirements.enumerated()), id: \.offset) { index, requirement in
                        Text("• \(translator.text(Key.requirement(index), requirement))").fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            if !deviation.isEmpty {
                section("Where It Went Off", spacing: 3) {
                    ForEach(deviation, id: \.self) { Text($0) }
                    Text("Both steps are approximate: finding the exact step is hard even for people.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if !notes.rejected.isEmpty {
                DisclosureGroup("Rejected by the verifier (\(notes.rejected.count))", isExpanded: $showRejected) {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(notes.rejected) { NoteView(note: $0, translator: translator) }
                    }
                    .padding(.top, 6)
                }
            }
        }
        .font(.body)
    }

    /// Accepted notes by mode as the mode pages count them, the most notes first; notes no
    /// mode fits come last.
    private var groups: [(id: String, title: String, help: String, notes: [Note])] {
        let byMode = Dictionary(grouping: notes.accepted) { types[$0.id]?.modeID ?? "" }
        let named = byMode.compactMap { id, notes -> (id: String, title: String, help: String, notes: [Note])? in
            guard !id.isEmpty else { return nil }
            let mode = modes.first { $0.id == id }
            return (id, mode?.name ?? id, mode?.definition ?? "An error analysis mode", notes)
        }
        .sorted { ($0.notes.count, $1.title) > ($1.notes.count, $0.title) }
        let untyped = byMode[""].map {
            [(id: "", title: "No type yet",
              help: "No error analysis mode fits these notes yet, or they aren't matched yet; clustering on the Error Analysis screen can make one.",
              notes: $0)]
        } ?? []
        return named + untyped
    }

    private var types: [String: (modeID: String?, confirmed: Bool)] { notes.noteModes(modes) }

    /// "Notes by Claude Code · opus; verified by Claude Code · opus".
    private var authors: String {
        func name(_ config: StepConfig) -> String {
            let harness = config.harness.map { LabHarness(rawValue: $0)?.title ?? $0 } ?? "unknown harness"
            let model = config.model.flatMap { $0.isEmpty ? nil : $0 } ?? "default model"
            return "\(harness) · \(model)"
        }
        let verified = notes.verifierConfig.map { "verified by \(name($0))" } ?? "not verified"
        return "Notes by \(name(notes.notesConfig)); \(verified)."
    }

    private var deviation: [String] {
        [notes.deviation.decisiveStep.map { "Decided about step #\($0)" },
         notes.deviation.observedStep.map { "Visible about step #\($0)" }].compactMap(\.self)
    }

    private func section(_ title: String, spacing: CGFloat = 10, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: spacing) {
            Text(title).font(.title3.bold())
            content()
        }
    }
}

/// The review in a few seconds: outcome and problems in one line, the conclusion, and the
/// reviewed session's size, on a background tinted by how it went.
private struct ConclusionCard: View {
    let notes: SessionNotes
    let metrics: SessionMetrics?
    let inLabRun: Bool
    let translator: Translator

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let diagnosis = notes.diagnosis {
                // The diagnosis says it all; the verifier's conclusion is for older reviews.
                Text(headline).font(.callout.weight(.medium)).foregroundStyle(.secondary)
                diagnosisView(diagnosis)
                if notes.diagnosisDoubt != nil, let conclusion = notes.conclusion {
                    // The verifier's own reading, from the notes it accepted.
                    (Text("Verifier's conclusion: ").foregroundStyle(.secondary)
                        + Text(translator.text(SessionNotes.TranslationKey.conclusion, conclusion)))
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else if let conclusion = notes.conclusion {
                Text(headline).font(.title3.bold())
                Text(translator.text(SessionNotes.TranslationKey.conclusion, conclusion)).font(.title3).fixedSize(horizontal: false, vertical: true)
            } else if !notes.notes.isEmpty, notes.verifierConfig?.promptVersion ?? 0 < 3 {
                Text(headline).font(.title3.bold())
                // From verifier prompt 3 a missing conclusion means no note reached the
                // verifier (or it left the conclusion blank), and the headline says it all.
                Text(inLabRun
                     ? "No conclusion yet: this review is older than conclusions. Re-check with the same model, effort and review language reuses the notes and reruns only the verifier and matching."
                     : "No conclusion yet: this review is older than conclusions. The next review of this session writes one.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text(headline).font(.title3.bold())
            }
            if let size {
                Text(size).font(.callout).foregroundStyle(.secondary)
            }
        }
        .textSelection(.enabled)
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(tint.opacity(0.35)))
    }

    private typealias Key = SessionNotes.TranslationKey

    @ViewBuilder private func diagnosisView(_ diagnosis: Diagnosis) -> some View {
        Text(translator.text(Key.diagnosisHeadline, diagnosis.headline))
            .font(.title2.bold())
            .fixedSize(horizontal: false, vertical: true)
        HStack(spacing: 6) {
            Text("Cause:").foregroundStyle(.secondary)
            CauseTag(cause: diagnosis.cause)
        }
        if !diagnosis.why.isEmpty {
            Text(translator.text(Key.diagnosisWhy, diagnosis.why)).fixedSize(horizontal: false, vertical: true)
        }
        if !diagnosis.fix.isEmpty {
            Text("👉 \(translator.text(Key.diagnosisFix, diagnosis.fix))")
                .fontWeight(.semibold)
                .fixedSize(horizontal: false, vertical: true)
        }
        if let doubt = notes.diagnosisDoubt {
            Label("The verifier doubts this diagnosis: \(translator.text(Key.diagnosisDoubt, doubt))", systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// "✅ Done · 🟠 2 medium · ⚪ 1 low".
    private var headline: String {
        let outcome = switch notes.outcome {
        case .achieved: "✅ Done"
        case .partly: "🟡 Partly done"
        case .no: "❌ Not done"
        case .unclear: "❔ Unclear whether done"
        }
        let accepted = notes.accepted
        guard !accepted.isEmpty else { return outcome + " · no problems found" }
        let counts: [(Severity, String)] = [(.high, "🔴"), (.medium, "🟠"), (.low, "⚪")]
        var parts = counts.compactMap { severity, mark -> String? in
            let count = accepted.filter { $0.severity == severity }.count
            return count > 0 ? "\(mark) \(count) \(severity.rawValue)" : nil
        }
        let unrated = accepted.filter { $0.severity == nil }.count
        if unrated > 0 { parts.append("\(unrated) unrated") }
        return ([outcome] + parts).joined(separator: " · ")
    }

    /// "⏱ 2 hr, 35 min · 164 calls · 515K fresh tokens · peak context 397K".
    private var size: String? {
        guard let metrics else { return nil }
        var parts: [String] = []
        if let wall = metrics.wallSeconds {
            let minutes = Duration.seconds((Double(wall) / 60).rounded() * 60)
            parts.append("⏱ " + (wall < 60 ? "\(wall) s" : minutes.formatted(.units(allowed: [.hours, .minutes], width: .abbreviated))))
        }
        parts.append("\(UsageText.full(metrics.calls)) calls")
        parts.append("\(UsageText.short(metrics.freshTokens)) fresh tokens")
        parts.append("peak context \(UsageText.short(metrics.peakContext))")
        return parts.joined(separator: " · ")
    }

    private var tint: Color {
        switch notes.outcome {
        case .achieved: notes.accepted.contains { $0.severity == .high } ? .orange : .green
        case .partly: .orange
        case .no: .red
        case .unclear: .gray
        }
    }
}

/// A root cause as a coloured tag; its help says what usually fixes it.
struct CauseTag: View {
    let cause: RootCause

    var body: some View {
        NoteTag(text: cause.title, color: color).help(cause.fixKind)
    }

    private var color: Color {
        switch cause {
        case .none: .green
        case .unclearTask, .scopeDrift: .orange
        case .missingSkill, .wrongSkill, .missingContext: .purple
        case .toolEnvironment: .gray
        case .hallucination, .ignoredInstruction, .noVerification, .weakModel: .red
        }
    }
}

/// One user reaction: what the user did and said, then the review's reading of it.
private struct ReactionView: View {
    let reaction: UserReaction
    let checkpoint: Checkpoint?
    let translator: Translator

    private typealias Key = SessionNotes.TranslationKey

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(icon)
                Text(reaction.kind.title).fontWeight(.semibold)
                Text("step #\(reaction.step)").foregroundStyle(.secondary).monospacedDigit()
                if let checkpoint { CauseTag(cause: checkpoint.cause) }
            }
            QuoteText(text: reaction.text)
            if let checkpoint {
                line("Wanted", Key.checkpoint(checkpoint.id, "wanted"), checkpoint.wanted)
                line("Agent did", Key.checkpoint(checkpoint.id, "did"), checkpoint.agentDid)
                line("Agent thought", Key.checkpoint(checkpoint.id, "thought"), checkpoint.agentThought)
                if let fix = checkpoint.fix {
                    Text("👉 \(translator.text(Key.checkpoint(checkpoint.id, "fix"), fix))").fixedSize(horizontal: false, vertical: true)
                }
            } else {
                Text("The review didn't explain this reaction.").font(.callout).foregroundStyle(.secondary)
            }
        }
        .textSelection(.enabled)
    }

    @ViewBuilder private func line(_ title: String, _ key: String, _ text: String) -> some View {
        if !text.isEmpty {
            (Text("\(title): ").foregroundStyle(.secondary) + Text(translator.text(key, text)))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var icon: String {
        switch reaction.kind {
        case .interrupt: "✋"
        case .rejected: "🚫"
        case .badRating: "👎"
        case .goodRating: "👍"
        case .pushback: "↩️"
        case .followUp: "💬"
        }
    }
}

/// A run of attempts that kept failing the same way.
private struct LoopView: View {
    let loop: Loop
    let what: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text("🔁 Steps #\(loop.fromStep)–#\(loop.toStep)").fontWeight(.semibold).monospacedDigit()
                CauseTag(cause: loop.cause)
            }
            Text(what).fixedSize(horizontal: false, vertical: true)
            if let root = loop.rootStep {
                Text("Started at step #\(root)").foregroundStyle(.secondary).monospacedDigit()
            }
        }
        .textSelection(.enabled)
    }
}

/// One improvement: the advice, what it improves, and the evidence folded away.
private struct AdviceView: View {
    let number: Int
    let advice: Advice
    /// The title and detail as shown: translated or the originals.
    let title: String
    let detail: String
    @State private var showEvidence = DebugSnapshot.options?.tab == "notes"

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("👉 \(title)").fontWeight(.semibold)
            Text(detail).foregroundStyle(.secondary)
            if !advice.evidence.isEmpty {
                DisclosureGroup("Evidence" + (advice.noteIDs.isEmpty ? "" : " (\(advice.noteIDs.joined(separator: ", ")))"),
                                isExpanded: $showEvidence) {
                    Text(advice.evidence)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 2)
                }
                .font(.callout)
            }
        }
        .textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)
    }
}

struct OutcomeBadge: View {
    let outcome: Outcome

    var body: some View {
        Label(outcome.title, systemImage: icon)
            .font(.callout.weight(.medium))
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(color.opacity(0.2), in: Capsule())
            .foregroundStyle(color)
    }

    private var icon: String {
        switch outcome {
        case .achieved: "checkmark.circle"
        case .partly: "circle.lefthalf.filled"
        case .no: "xmark.circle"
        case .unclear: "questionmark.circle"
        }
    }

    private var color: Color {
        switch outcome {
        case .achieved: .green
        case .partly: .orange
        case .no: .red
        case .unclear: .secondary
        }
    }
}

/// One note: id, step, phase, severity, fault layer, the description and the quote.
struct NoteView: View {
    let note: Note
    /// The quote behind a disclosure, for pages that lead with the descriptions.
    var collapsesQuote = false
    /// Its mode is a low-confidence route you haven't reviewed.
    var unconfirmed = false
    /// Translate of the notes it is shown with: the description and the verifier's reasons.
    var translator: Translator? = nil

    private func shown(_ key: String, _ original: String) -> String { translator?.text(key, original) ?? original }

    @State private var showSteelman = DebugSnapshot.options?.tab == "notes"
    @State private var showQuote = DebugSnapshot.options?.tab == "notes"

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Text(note.id).fontWeight(.semibold).monospaced()
                Text("step #\(note.step)").foregroundStyle(.secondary).monospacedDigit()
                if let phase = note.phase { NoteTag(text: phase.title, color: .blue) }
                if let severity = note.severity { NoteTag(text: severity.rawValue.capitalized, color: severity.color) }
                if let layer = note.faultLayer { NoteTag(text: layer.title, color: .purple) }
                if let cause = note.cause { CauseTag(cause: cause) }
                if note.source == .human { NoteTag(text: "Yours", color: .teal) }
                if unconfirmed {
                    NoteTag(text: "Type unconfirmed", color: .gray)
                        .help("Matching wasn't sure of this type: accept or move it on the Error Analysis screen, Review tab. Mode pages don't count it yet.")
                }
                if let root = note.symptomOf {
                    Text("symptom of \(root)").font(.caption).foregroundStyle(.secondary)
                }
            }
            Text(shown(SessionNotes.TranslationKey.note(note.id), note.description)).fixedSize(horizontal: false, vertical: true)
            if collapsesQuote, !note.quote.isEmpty {
                DisclosureGroup("Quote", isExpanded: $showQuote) {
                    QuoteText(text: note.quote).padding(.top, 2)
                }
                .font(.callout)
            } else {
                QuoteText(text: note.quote)
            }
            if let verdict = note.verdict {
                if !verdict.accepted {
                    Label("\(verdict.by == .code ? "Rejected by code" : "Rejected by the verifier model"): \(shown(SessionNotes.TranslationKey.verdict(note.id), verdict.reason))",
                          systemImage: "xmark.circle")
                        .font(.callout)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                } else if note.severity == .high, let steelman = verdict.steelman, !steelman.isEmpty {
                    DisclosureGroup("The verifier's case against it", isExpanded: $showSteelman) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(shown(SessionNotes.TranslationKey.steelman(note.id), steelman))
                            if !verdict.reason.isEmpty { Text("Verdict: \(shown(SessionNotes.TranslationKey.verdict(note.id), verdict.reason))").foregroundStyle(.secondary) }
                        }
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .font(.callout)
                }
            }
        }
        .textSelection(.enabled)
    }
}

/// A quote from a transcript, with a bar on the left; nothing when it is empty.
struct QuoteText: View {
    let text: String

    var body: some View {
        if !text.isEmpty {
            Text(text)
                .font(.callout.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(6)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 5))
                .overlay(alignment: .leading) {
                    Rectangle().fill(.tertiary).frame(width: 3)
                }
        }
    }
}

struct NoteTag: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(color.opacity(0.18), in: Capsule())
            .foregroundStyle(color)
    }
}

private extension Severity {
    var color: Color {
        switch self {
        case .low: .secondary
        case .medium: .orange
        case .high: .red
        }
    }
}
