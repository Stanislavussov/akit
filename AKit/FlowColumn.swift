import AKitFlows
import SwiftUI

/// The diagram of a flow (F2): a column of cards in run order. A ↓ between two cards means done
/// goes on to the next one; each route back to the same or an earlier step is an arrow in the
/// left gutter, in its own lane (shorter routes nearer the cards, so lines don't cross), with
/// its outcome (✗ failed, ⏸ blocked, ✓ done) at the start. Flows (editable cards) and Runs
/// (read-only cards) both draw it.
struct FlowColumn<Card: View>: View {
    let flow: Flow
    @ViewBuilder let card: (Int, FlowStep) -> Card
    /// The step under the pointer: its routes are drawn bold, the others faded.
    @State private var hovered: String?

    private struct Back: Identifiable {
        let id: String
        let from: String
        let to: String
        let outcome: String
        let span: Int
    }

    /// Routes back, shortest first: the shortest gets the lane next to the cards.
    private var backs: [Back] {
        flow.steps.enumerated().flatMap { index, step in
            step.routes.sorted { $0.key < $1.key }.compactMap { key, target -> Back? in
                guard let to = flow.index(of: target), to <= index else { return nil }
                return Back(id: "\(step.id)/\(key)", from: step.id, to: target, outcome: String(key.prefix { $0 != ":" }), span: index - to)
            }
        }
        .sorted { ($0.span, $0.id) < ($1.span, $1.id) }
    }

    private static var lane: CGFloat { 13 }

    var body: some View {
        let backs = backs
        let gutter = CGFloat(max(backs.count, 1)) * Self.lane + 22
        VStack(alignment: .leading, spacing: 4) {
            legend
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(flow.steps.enumerated()), id: \.element.id) { index, step in
                    if index > 0 { link(after: flow.steps[index - 1], at: index - 1) }
                    card(index, step)
                        .onHover { inside in
                            if inside { hovered = step.id } else if hovered == step.id { hovered = nil }
                        }
                        .anchorPreference(key: CardFrames.self, value: .bounds) { [step.id: $0] }
                }
            }
            .padding(.leading, gutter)
            .overlayPreferenceValue(CardFrames.self) { anchors in
                GeometryReader { proxy in arrows(backs, frames: anchors.mapValues { proxy[$0] }, gutter: gutter) }
            }
        }
    }

    private var legend: some View {
        HStack(spacing: 12) {
            Label("done: next step", systemImage: "arrow.down").foregroundStyle(Color.accentColor)
            Text("✗ failed: back").foregroundStyle(FlowStepLine.color("failed"))
            Text("⏸ blocked: back").foregroundStyle(FlowStepLine.color("blocked"))
            Text("Point at a step to see its routes").foregroundStyle(.secondary)
        }
        .font(.caption)
        .labelStyle(.titleAndIcon)
    }

    /// The gap between two cards: ↓ when done goes on to the next step, else an empty gap.
    private func link(after step: FlowStep, at index: Int) -> some View {
        let next = FlowStepLine.target(step, index: index, flow: flow, outcome: "done") == flow.steps[index + 1].id
        return HStack(spacing: 4) {
            if next {
                Image(systemName: "arrow.down").font(.caption.bold()).foregroundStyle(Color.accentColor.opacity(0.8))
                    .help("Done: on to the next step")
            }
        }
        .frame(height: 16)
        .padding(.leading, 26)
    }

    private func arrows(_ backs: [Back], frames: [String: CGRect], gutter: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(Array(backs.enumerated()), id: \.element.id) { lane, back in
                if let from = frames[back.from], let to = frames[back.to] {
                    let lit = hovered == nil || hovered == back.from || hovered == back.to
                    let color = FlowStepLine.color(back.outcome).opacity(lit ? 1 : 0.18)
                    let width: CGFloat = hovered != nil && lit ? 3 : 2
                    let x = gutter - 16 - CGFloat(lane) * Self.lane
                    // Arrows leave from a card's lower half and arrive on its upper half, each at
                    // its own height, so routes into or out of one card never share a line.
                    let out = backs.filter { $0.from == back.from }.firstIndex { $0.id == back.id } ?? 0
                    let into = backs.filter { $0.to == back.to }.firstIndex { $0.id == back.id } ?? 0
                    let start = CGPoint(x: from.minX, y: max(from.maxY - 8 - CGFloat(out) * 9, from.midY + 2))
                    let end = CGPoint(x: to.minX, y: min(to.minY + 8 + CGFloat(into) * 9, to.midY - 2))
                    Path { path in
                        path.move(to: start)
                        path.addLine(to: CGPoint(x: x, y: start.y))
                        path.addLine(to: CGPoint(x: x, y: end.y))
                        path.addLine(to: CGPoint(x: end.x - 1, y: end.y))
                    }
                    .stroke(color, style: StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round))
                    Path { path in
                        path.move(to: CGPoint(x: end.x - 8, y: end.y - 5))
                        path.addLine(to: end)
                        path.addLine(to: CGPoint(x: end.x - 8, y: end.y + 5))
                        path.closeSubpath()
                    }
                    .fill(color)
                    Text(back.outcome == "failed" ? "✗" : back.outcome == "blocked" ? "⏸" : "✓")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 13, height: 13)
                        .background(color, in: Circle())
                        .position(x: x, y: start.y)
                        .help("On \(back.outcome), \(back.from) goes back to \(back.to)")
                }
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
            if let thinking = step.thinking {
                Label(thinking, systemImage: "brain").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    .help("Reasoning: \(thinking)")
            }
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
