import CoreGraphics

/// Rectangles whose areas match values: the squarified treemap layout (Bruls, Huizing and
/// van Wijk, 2000). Big values come first and the rectangles stay close to squares.
public enum TreemapLayout {
    /// One rectangle per value, in the order given, filling `rect`. A value of 0 or less gets
    /// an empty rectangle.
    public static func squarify(_ values: [Double], in rect: CGRect) -> [CGRect] {
        var result = [CGRect](repeating: .zero, count: values.count)
        let total = values.filter { $0 > 0 }.reduce(0, +)
        guard total > 0, rect.width > 0, rect.height > 0 else { return result }
        let scale = Double(rect.width * rect.height) / total
        var remaining = rect
        var row: [Int] = []

        func areas(_ row: [Int]) -> [Double] { row.map { values[$0] * scale } }

        /// The worst aspect ratio of a row laid along a side of this length.
        func worst(_ row: [Int], side: Double) -> Double {
            let row = areas(row)
            let sum = row.reduce(0, +)
            guard sum > 0, side > 0, let largest = row.max(), let smallest = row.min(), smallest > 0 else { return .infinity }
            return max(side * side * largest / (sum * sum), sum * sum / (side * side * smallest))
        }

        /// Lays the row along the shorter side of what is left and takes it off.
        func place(_ row: [Int]) {
            let sizes = areas(row)
            let sum = sizes.reduce(0, +)
            if remaining.width >= remaining.height {
                let width = remaining.height > 0 ? sum / Double(remaining.height) : 0
                var y = Double(remaining.minY)
                for (index, area) in zip(row, sizes) {
                    let height = width > 0 ? area / width : 0
                    result[index] = CGRect(x: Double(remaining.minX), y: y, width: width, height: height)
                    y += height
                }
                remaining = CGRect(x: Double(remaining.minX) + width, y: Double(remaining.minY),
                                   width: max(0, Double(remaining.width) - width), height: Double(remaining.height))
            } else {
                let height = remaining.width > 0 ? sum / Double(remaining.width) : 0
                var x = Double(remaining.minX)
                for (index, area) in zip(row, sizes) {
                    let width = height > 0 ? area / height : 0
                    result[index] = CGRect(x: x, y: Double(remaining.minY), width: width, height: height)
                    x += width
                }
                remaining = CGRect(x: Double(remaining.minX), y: Double(remaining.minY) + height,
                                   width: Double(remaining.width), height: max(0, Double(remaining.height) - height))
            }
        }

        for index in values.indices.sorted(by: { values[$0] > values[$1] }) where values[index] > 0 {
            let side = Double(min(remaining.width, remaining.height))
            if row.isEmpty || worst(row + [index], side: side) <= worst(row, side: side) {
                row.append(index)
            } else {
                place(row)
                row = [index]
            }
        }
        if !row.isEmpty { place(row) }
        return result
    }
}
