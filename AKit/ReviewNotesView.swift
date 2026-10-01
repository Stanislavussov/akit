import AKitErrorAnalysis
import AKitLab
import SwiftUI

/// A one-call review's notes (`docs/design/error-analysis.md`, "Step 1" and "Verifier"):
/// outcome, requirements, deviation steps "about here", the notes the verifier accepted,
/// the rejected ones, then the paragraph and the advice with the notes it rests on.
struct ReviewNotesView: View {
    let notes: SessionNotes
    /// Snapshots: `--tab notes` opens the disclosures.
    @State private var showRejected = DebugSnapshot.options?.tab == "notes"

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            header
            if !notes.paragraph.isEmpty {
                MarkdownLines(text: notes.paragraph.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            if !notes.requirements.isEmpty {
                section("Requirements", spacing: 3) {
                    ForEach(Array(notes.requirements.enumerated()), id: \.offset) { _, requirement in
                        Text("• \(requirement)").fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            if !deviation.isEmpty {
                section("Where it went off", spacing: 3) {
                    ForEach(deviation, id: \.self) { Text($0) }
                    Text("Both steps are approximate: finding the exact step is hard even for people.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            section("Notes", spacing: 14) {
                if notes.accepted.isEmpty {
                    Text("Checked, no failures: the verifier accepted no notes.").foregroundStyle(.secondary)
                }
                ForEach(notes.accepted) { NoteView(note: $0) }
                if !notes.rejected.isEmpty {
                    DisclosureGroup("Rejected by the verifier (\(notes.rejected.count))", isExpanded: $showRejected) {
                        VStack(alignment: .leading, spacing: 12) {
                            ForEach(notes.rejected) { NoteView(note: $0) }
                        }
                        .padding(.top, 6)
                    }
                }
            }
            .id("notes")
            section("What to Improve") {
                if notes.advice.isEmpty {
                    Text("Nothing worth changing.").foregroundStyle(.secondary)
                }
                ForEach(Array(notes.advice.prefix(Review.limit).enumerated()), id: \.offset) { index, advice in
                    VStack(alignment: .leading, spacing: 3) {
                        Text("\(index + 1). \(advice.title)").fontWeight(.semibold)
                        if !advice.evidence.isEmpty {
                            Text("Evidence: \(advice.evidence)").foregroundStyle(.secondary)
                        }
                        Text(advice.detail).foregroundStyle(.secondary)
                        if !advice.noteIDs.isEmpty {
                            Text("Rests on \(advice.noteIDs.joined(separator: ", "))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("Outcome").font(.title3.bold())
                OutcomeBadge(outcome: notes.outcome)
            }
            Text(authors).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
        }
    }

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

private struct OutcomeBadge: View {
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
private struct NoteView: View {
    let note: Note
    @State private var showSteelman = DebugSnapshot.options?.tab == "notes"

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Text(note.id).fontWeight(.semibold).monospaced()
                Text("step #\(note.step)").foregroundStyle(.secondary).monospacedDigit()
                if let phase = note.phase { NoteTag(text: phase.title, color: .blue) }
                if let severity = note.severity { NoteTag(text: severity.rawValue.capitalized, color: severity.color) }
                if let layer = note.faultLayer { NoteTag(text: layer.title, color: .purple) }
                if note.source == .human { NoteTag(text: "Yours", color: .teal) }
                if let root = note.symptomOf {
                    Text("symptom of \(root)").font(.caption).foregroundStyle(.secondary)
                }
            }
            Text(note.description).fixedSize(horizontal: false, vertical: true)
            if !note.quote.isEmpty {
                Text(note.quote)
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
            if let verdict = note.verdict {
                if !verdict.accepted {
                    Label("\(verdict.by == .code ? "Rejected by code" : "Rejected by the verifier model"): \(verdict.reason)",
                          systemImage: "xmark.circle")
                        .font(.callout)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                } else if note.severity == .high, let steelman = verdict.steelman, !steelman.isEmpty {
                    DisclosureGroup("The verifier's case against it", isExpanded: $showSteelman) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(steelman)
                            if !verdict.reason.isEmpty { Text("Verdict: \(verdict.reason)").foregroundStyle(.secondary) }
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

private struct NoteTag: View {
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
