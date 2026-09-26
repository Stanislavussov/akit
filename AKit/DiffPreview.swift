import AKitCore
import SwiftUI

/// Changed lines of a file with 3 lines of context; long unchanged runs become "…".
struct DiffPreview: View {
    let diff: [TextDiff.Line]

    var body: some View {
        ForEach(Array(changedLines.enumerated()), id: \.offset) { _, line in
            switch line {
            case .same(let text): Text("  " + text).foregroundStyle(.secondary)
            case .added(let text): Text("+ " + text).foregroundStyle(.green).frame(maxWidth: .infinity, alignment: .leading).background(.green.opacity(0.1))
            case .removed(let text): Text("- " + text).foregroundStyle(.red).frame(maxWidth: .infinity, alignment: .leading).background(.red.opacity(0.1))
            case nil: Text("  …").foregroundStyle(.tertiary)
            }
        }
    }

    private var changedLines: [TextDiff.Line?] {
        let changed = diff.indices.filter { if case .same = diff[$0] { false } else { true } }
        var result: [TextDiff.Line?] = []
        var last = -1
        for index in diff.indices where changed.contains(where: { abs($0 - index) <= 3 }) {
            if last >= 0, index > last + 1 { result.append(nil) }
            result.append(diff[index])
            last = index
        }
        return result
    }
}
