import AKitFoundation
import AKitInsights
import SwiftUI

/// Insights' Skill Listing box: Claude Code's skill listing per session against its budget, the
/// settings behind it, and the fix order: first the recommendations (manual, moved), then, only
/// when they can't fit every description, Raise Budget…. The same numbers as `akit stats listing`.
struct SkillListingBox: View {
    @Environment(AppModel.self) private var model
    let listing: ListingReport
    /// Scrolls to the recommendations.
    let onShowRecommendations: () -> Void
    @State private var raising: Double?

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                let settings = listing.settings
                Text("Budget: \(Self.percent(settings.fraction)) of the context window (skillListingBudgetFraction \(Self.number(settings.fraction)), \(settings.fractionFrom)) · descriptions cut at \(settings.maxDescChars) characters (skillListingMaxDescChars, \(settings.maxDescCharsFrom))")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .help("Claude Code 2.1.296: budget = context window × 4 characters per token (3 for models newer than Opus and Sonnet 4.6) × the fraction. Over it, the least-used skills are listed by name only. settings.local.json is not read.")
                ForEach(settings.problems, id: \.self) { Label($0, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).font(.callout) }
                if listing.sessions.count == 0 {
                    Text("No Claude Code session with a skill listing in this window.").foregroundStyle(.secondary)
                } else {
                    measured
                    fixes
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(4)
        } label: {
            Text("Skill Listing").font(.headline)
        }
        .sheet(item: Binding(get: { raising.map(RaiseTarget.init) }, set: { raising = $0?.fraction })) { target in
            RaiseBudgetSheet(fraction: target.fraction, listing: listing)
        }
    }

    private struct RaiseTarget: Identifiable {
        let fraction: Double
        var id: Double { fraction }
    }

    private var measured: some View {
        let sessions = listing.sessions
        return Text("\(InsightsView.count(sessions.count, "session")): listing median \(sessions.medianChars.formatted()) characters (p90 \(sessions.p90Chars.formatted())), \(sessions.medianFullChars.formatted()) with every description, against a budget of \(sessions.medianBudget.formatted()) (median session) · \(sessions.overBudget) over budget (\(Self.percent(sessions.share)))")
            .font(.callout.monospacedDigit())
            .fixedSize(horizontal: false, vertical: true)
            .help("Sizes as Claude Code counts them: each skill's name + 4 + its description (name only: name + 2), one newline between. A session counts as 1M context when a request of it recorded more than 200,000 tokens.")
    }

    @ViewBuilder
    private var fixes: some View {
        if let needed = listing.now.neededFraction {
            Text(needed > 1 ? "Even the whole context window can't hold every description."
                 : "Every description would have fit at \(Self.number(needed)) (≈ \(ContextSize.short(listing.now.extraTokensPerRequest)) tokens more per request).")
                .font(.callout)
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text("1.")
                    if let after = listing.afterFixes {
                        Text("The recommendations above take \(InsightsView.count(listing.fixSkills.count, "skill")) out of the listing (manual, moved, a plugin off): "
                             + (after.overBudget == 0 ? "that fits every session." : "\(InsightsView.count(after.overBudget, "session")) stay over budget."))
                    } else {
                        Text("Make unused skills manual or move them (Unused Only below, right-click a skill).")
                    }
                    Spacer()
                    Button("Show Recommendations", action: onShowRecommendations).buttonStyle(.link)
                }
                if let raise = listing.raiseTo {
                    HStack(alignment: .firstTextBaseline) {
                        Text("2.")
                        Text("Then raise the budget to \(Self.number(raise)) (≈ \(ContextSize.short((listing.afterFixes ?? listing.now).extraTokensPerRequest)) tokens more per request, in every session).")
                        Spacer()
                        Button("Raise Budget…") { raising = raise }
                            .help("Set skillListingBudgetFraction in \(listing.settings.file): a diff first, then a backup and only that key")
                    }
                }
            }
            .font(.callout)
            .fixedSize(horizontal: false, vertical: true)
        } else {
            Label("Every description fit its budget.", systemImage: "checkmark.circle").foregroundStyle(.green).font(.callout)
        }
    }

    static func percent(_ value: Double) -> String { String(format: "%g%%", (value * 1000).rounded() / 10) }
    static func number(_ value: Double) -> String { String(format: "%g", value) }
}

/// Raise Budget…: `skillListingBudgetFraction` in the settings file the budget is read from, with
/// the diff of only that key and the extra ≈ tokens per request. Apply backs the file up and
/// refuses when the key changed since the preview.
struct RaiseBudgetSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let fraction: Double
    let listing: ListingReport
    @State private var change: SettingsFile.Change?
    @State private var error: String?
    @State private var busy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Raise the Skill Listing Budget").font(.title2.bold())
            Text("Claude Code gets \(SkillListingBox.number(fraction)) of the context window for skill descriptions instead of \(SkillListingBox.number(listing.settings.fraction)): every description fits, and every request carries ≈ \(ContextSize.short((listing.afterFixes ?? listing.now).extraTokensPerRequest)) tokens more. Do the recommendations first: a skill made manual or moved costs nothing.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let change {
                Text(change.file.tildePath).font(.callout.monospaced())
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) { DiffPreview(diff: change.diff) }
                        .font(.callout.monospaced())
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(6)
                }
                .frame(height: 120)
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
            }
            if let error {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red).font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Apply", action: apply).keyboardShortcut(.defaultAction).disabled(change == nil || busy)
            }
        }
        .padding(20)
        .frame(width: 560)
        .task {
            do {
                change = try SkillListing.raise(to: fraction, settings: listing.settings, env: .current)
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    private func apply() {
        guard let change else { return }
        busy = true
        let home = HarnessEnvironment.current.homeDirectory
        Task {
            do {
                _ = try await Task.detached { try SettingsFile.apply(change, home: home) }.value
                await model.refresh()
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
            busy = false
        }
    }
}
