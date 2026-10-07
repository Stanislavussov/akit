import CoreGraphics
import Testing
@testable import AKitFoundation

struct TreemapLayoutTests {
    let frame = CGRect(x: 10, y: 20, width: 600, height: 400)

    @Test func areasMatchTheValuesAndFillTheFrame() {
        let values: [Double] = [6, 6, 4, 3, 2, 2, 1]
        let rects = TreemapLayout.squarify(values, in: frame)
        let total = values.reduce(0, +)
        for (value, rect) in zip(values, rects) {
            let expected = Double(frame.width * frame.height) * value / total
            #expect(abs(Double(rect.width * rect.height) - expected) < 0.5, "\(value): \(rect)")
            #expect(frame.insetBy(dx: -0.01, dy: -0.01).contains(rect), "\(rect)")
        }
        // No overlaps: the rectangles together cover the frame once.
        for (a, b) in zip(rects.indices, rects.indices.dropFirst()) {
            let overlap = rects[a].intersection(rects[b])
            #expect(overlap.isNull || overlap.width * overlap.height < 0.5)
        }
    }

    @Test func rectanglesStayCloseToSquares() {
        let rects = TreemapLayout.squarify([6, 6, 4, 3, 2, 2, 1], in: CGRect(x: 0, y: 0, width: 600, height: 400))
        let ratios = rects.map { max($0.width / $0.height, $0.height / $0.width) }
        #expect(ratios.allSatisfy { $0 < 4 }, "\(ratios)")
    }

    @Test func emptyAndZeroValuesGetNoArea() {
        #expect(TreemapLayout.squarify([], in: frame).isEmpty)
        #expect(TreemapLayout.squarify([0, 0], in: frame) == [.zero, .zero])
        let rects = TreemapLayout.squarify([5, 0, -1, 5], in: frame)
        #expect(rects[1] == .zero && rects[2] == .zero)
        #expect(abs(rects[0].width * rects[0].height - frame.width * frame.height / 2) < 0.5)
        #expect(TreemapLayout.squarify([1], in: .zero) == [.zero])
    }
}
