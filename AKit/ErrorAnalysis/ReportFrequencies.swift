import AKitErrorAnalysis
import SwiftUI

/// Mode frequencies of a batch, from checks only (`docs/design/error-analysis.md`, "Correction
/// and intervals"): the reported share (corrected for a validated check, weighted for an exact
/// one) with its 95% interval, the plain share, goal reached against not. Modes without such a
/// check show "seen in k notes" and never a percentage.
struct ReportFrequencies: View {
    let report: BatchReport

    var body: some View {
        let scale = Self.scale(report.modes)
        VStack(alignment: .leading, spacing: 8) {
            Text("Mode frequencies").font(.title3.bold())
            Text("From each mode's check over the batch's sessions, weighted by how likely the sampling was to pick each session. Matching never counts here.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 16, verticalSpacing: 10) {
                GridRow {
                    Text("Mode")
                    Text("Share (95% interval)")
                    Text("Plain")
                    Text("Goal reached / not")
                    Text("Check")
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                Divider()
                ForEach(report.modes, id: \.modeID) { mode in
                    row(mode, scale: scale)
                }
            }
            .font(.callout)
            if report.modes.isEmpty {
                Text("No active modes yet: confirm modes on the Modes tab.").foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private func row(_ mode: ModeFrequency, scale: Double) -> some View {
        GridRow {
            VStack(alignment: .leading, spacing: 2) {
                Text(mode.name).fontWeight(.medium)
                if mode.notWorthFixing {
                    Label("As frequent when the goal was reached: maybe not worth fixing", systemImage: "questionmark.circle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            .frame(minWidth: 180, alignment: .leading)
            if mode.hasFrequency {
                share(mode, scale: scale)
                Text(AnalysisText.percent(mode.unweighted)).monospacedDigit().foregroundStyle(.secondary)
                    .help("The plain share: \(mode.positive) of \(mode.checked) sessions, without weights")
                Text("\(AnalysisText.percent(mode.achieved)) / \(AnalysisText.percent(mode.notAchieved))").monospacedDigit()
                    .help("Weighted share among sessions that reached their goal / that didn't")
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Seen in \(AnalysisText.notes(mode.seenInNotes))")
                    if mode.trust == .provisional, mode.checked > 0 {
                        Text("Provisional check: \(mode.positive) of \(mode.checked) (\(AnalysisText.percent(Double(mode.positive) / Double(mode.checked)))) — not a frequency")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
                .gridCellColumns(3)
            }
            TrustBadge(level: mode.trust)
        }
    }

    @ViewBuilder private func share(_ mode: ModeFrequency, scale: Double) -> some View {
        if mode.belowDetectionThreshold {
            Text("Below detection threshold")
                .foregroundStyle(.secondary)
                .help("The observed share is no higher than the check's false-positive rate (1 − TNR): the check can't tell it from zero")
        } else {
            let value = mode.corrected ?? mode.weighted
            HStack(spacing: 8) {
                IntervalBar(value: value, interval: mode.interval, scale: scale)
                    .frame(width: 160, height: 14)
                VStack(alignment: .leading, spacing: 0) {
                    Text(AnalysisText.percent(value)).fontWeight(.semibold).monospacedDigit()
                    if let interval = mode.interval {
                        Text("\(AnalysisText.percent(interval.low))–\(AnalysisText.percent(interval.high))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
            }
            .help(mode.corrected != nil ? "Corrected for the check's TPR and TNR (Rogan–Gladen); weighted \(AnalysisText.percent(mode.weighted))"
                  : "Weighted share (Horvitz–Thompson)")
        }
    }

    /// One scale for every bar: the highest interval end, rounded up to 10%.
    static func scale(_ modes: [ModeFrequency]) -> Double {
        let top = modes.compactMap { $0.interval?.high ?? $0.corrected ?? $0.weighted }.max() ?? 0.1
        return min(1, max(0.1, (top * 10).rounded(.up) / 10))
    }
}

/// A share as a dot on a track with its 95% interval as a whisker.
struct IntervalBar: View {
    let value: Double?
    let interval: Stats.Interval?
    /// The share at the right end of the track.
    let scale: Double

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width, mid = proxy.size.height / 2
            let x = { (share: Double) -> CGFloat in CGFloat(min(share / scale, 1)) * width }
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary).frame(height: 4).offset(y: 0)
                if let interval {
                    Capsule()
                        .fill(Color.accentColor.opacity(0.35))
                        .frame(width: max(x(interval.high) - x(interval.low), 2), height: 8)
                        .offset(x: x(interval.low))
                }
                if let value {
                    Circle()
                        .fill(Color.accentColor)
                        .frame(width: 10, height: 10)
                        .offset(x: x(value) - 5)
                }
            }
            .frame(height: proxy.size.height)
            .position(x: width / 2, y: mid)
        }
        .accessibilityElement()
        .accessibilityLabel(value.map { AnalysisText.percent($0) } ?? "no share")
    }
}

/// exact / validated / provisional / not validated.
struct TrustBadge: View {
    let level: CheckTrust.Level

    var body: some View {
        Text(title)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(color.opacity(0.18), in: Capsule())
            .foregroundStyle(color)
            .help(help)
    }

    private var title: String {
        switch level {
        case .exact: "exact"
        case .validated: "validated"
        case .provisional: "provisional"
        case .none: "not validated"
        }
    }

    private var color: Color {
        switch level {
        case .exact: .green
        case .validated: .blue
        case .provisional: .orange
        case .none: .secondary
        }
    }

    private var help: String {
        switch level {
        case .exact: "A mechanical code check: the check is the definition, no correction"
        case .validated: "Wilson lower bounds of TPR and TNR ≥ 80% on 30+ test labels per class"
        case .provisional: "20+ test labels per class, but not validated: its rate is not a frequency"
        case .none: "No validated check: the mode shows as \"seen in k notes\""
        }
    }
}
