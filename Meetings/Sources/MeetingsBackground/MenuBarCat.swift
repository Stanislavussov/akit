import AppKit

/// M41: the background recorder's menu bar icon, AKit's cat head in a few square pixels. A
/// template image, so macOS draws it in the menu bar's own color, light or dark, with no red
/// or glowing state (M4).
public enum MenuBarCat {
    /// `#` is a pixel, `.` is empty: ears, the eyes and the nose are holes.
    static let pixels = [
        ".##..........##.",
        ".###........###.",
        ".####......####.",
        ".##############.",
        "################",
        "################",
        "###..######..###",
        "###..######..###",
        "################",
        "#######..#######",
        ".##############.",
        "..############..",
        "....########....",
    ]

    public static let image: NSImage = {
        let width = pixels[0].count, height = pixels.count
        let image = NSImage(size: NSSize(width: width, height: height), flipped: true) { _ in
            NSColor.black.setFill()
            for (row, line) in pixels.enumerated() {
                for (column, pixel) in line.enumerated() where pixel == "#" {
                    NSRect(x: column, y: row, width: 1, height: 1).fill()
                }
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Meetings Recorder"
        return image
    }()
}
