import AKitFlows
import SwiftUI

/// The diagram of a flow (F2): a column of cards with the back-routes drawn as arrows in the left
/// gutter. Flows (editable cards) and Runs (read-only cards) both draw it.
struct FlowColumn<Card: View>: View {
    let flow: Flow
    @ViewBuilder let card: (Int, FlowStep) -> Card

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(flow.steps.enumerated()), id: \.element.id) { index, step in
                card(index, step)
                    .anchorPreference(key: CardFrames.self, value: .bounds) { [step.id: $0] }
            }
        }
        .padding(.leading, 34)
        .overlayPreferenceValue(CardFrames.self) { anchors in
            GeometryReader { proxy in backArrows(frames: anchors.mapValues { proxy[$0] }) }
        }
    }

    /// Routes to the same or an earlier step, drawn as arrows in the left gutter (F2).
    private func backArrows(frames: [String: CGRect]) -> some View {
        var arrows: [(from: CGRect, to: CGRect, outcome: String)] = []
        for (index, step) in flow.steps.enumerated() {
            for (key, target) in step.routes.sorted(by: { $0.key < $1.key }) {
                guard let targetIndex = flow.index(of: target), targetIndex <= index,
                      let from = frames[step.id], let to = frames[target] else { continue }
                arrows.append((from, to, String(key.prefix { $0 != ":" })))
            }
        }
        return ZStack {
            ForEach(Array(arrows.enumerated()), id: \.offset) { number, arrow in
                let x = 28 - CGFloat(number % 4) * 7
                let start = CGPoint(x: arrow.from.minX, y: arrow.from.minY + 14 + CGFloat(number % 3) * 4)
                let end = CGPoint(x: arrow.to.minX, y: arrow.to.minY + 10)
                Path { path in
                    path.move(to: start)
                    path.addLine(to: CGPoint(x: x, y: start.y))
                    path.addLine(to: CGPoint(x: x, y: end.y))
                    path.addLine(to: end)
                    path.move(to: CGPoint(x: end.x - 6, y: end.y - 4))
                    path.addLine(to: end)
                    path.addLine(to: CGPoint(x: end.x - 6, y: end.y + 4))
                }
                .stroke(FlowStepLine.color(arrow.outcome), style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                .help("On \(arrow.outcome): back")
            }
        }
    }
}

/// One collapsed card in one line: number, step, agent, model's short name, skill count, gate,
/// and the routes set on the step as chips (the defaults go without saying).
struct FlowStepLine: View {
    let step: FlowStep
    let index: Int
    let flow: Flow

    static func color(_ outcome: String) -> Color {
        outcome == "blocked" ? .purple : outcome == "failed" ? .orange : .accentColor
    }

    /// Where `outcome` goes: the route, else the next step (done) or "stop" (failed, blocked).
    static func target(_ step: FlowStep, index: Int, flow: Flow, outcome: String) -> String {
        if let target = step.routes["\(outcome):*"] { return target }
        guard outcome == "done" else { return "stop" }
        return index + 1 < flow.steps.count ? flow.steps[index + 1].id : FlowRouting.end
    }

    var body: some View {
        HStack(spacing: 8) {
            Text("\(index + 1). \(step.id)").font(.headline).lineLimit(1)
            Text(step.agent).foregroundStyle(.secondary).lineLimit(1)
            if step.isClaudeCode {
                Text("Claude Code").font(.caption).padding(.horizontal, 6).padding(.vertical, 2)
                    .background(.orange.opacity(0.15), in: Capsule())
                    .help("This step runs on Claude Code (claude -p), read only")
            }
            Text(step.model.isEmpty ? "no model" : String(step.model.split(separator: "/").last ?? ""))
                .font(.callout.monospaced()).foregroundStyle(step.model.isEmpty ? .red : .secondary).lineLimit(1)
                .help(step.model)
            if !step.skills.isEmpty {
                Label("\(step.skills.count)", systemImage: "book.closed").font(.caption).foregroundStyle(.secondary)
                    .help("\(step.skills.count) skill\(step.skills.count == 1 ? "" : "s"): \(step.skills.joined(separator: ", "))")
            }
            if step.gate { Image(systemName: "diamond.fill").foregroundStyle(.orange).help("Gate after this step") }
            Spacer(minLength: 4)
            // Only routes that differ from the default (done: next step; failed, blocked: stop).
            ForEach(["done", "failed", "blocked"].filter { step.routes["\($0):*"] != nil }, id: \.self) { outcome in
                let target = Self.target(step, index: index, flow: flow, outcome: outcome)
                Text("\(outcome == "done" ? "✓" : outcome == "failed" ? "✗" : "⏸") \(target)")
                    .font(.caption).lineLimit(1)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Self.color(outcome).opacity(target == "stop" ? 0.06 : 0.15), in: Capsule())
                    .help("On \(outcome): \(target == "stop" ? "stop and ask" : target)")
            }
        }
    }
}

private struct CardFrames: PreferenceKey {
    static let defaultValue: [String: Anchor<CGRect>] = [:]
    static func reduce(value: inout [String: Anchor<CGRect>], nextValue: () -> [String: Anchor<CGRect>]) {
        value.merge(nextValue()) { $1 }
    }
}
