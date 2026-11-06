// Draws the AKit icons (1024×1024) and every size: AppIcon (graphite, release builds) and
// AppIconDev (orange, debug builds), so a dev build is easy to tell apart in the Dock.
// Run: swift tools/make-icon.swift   (from the akit folder), or `make icon`
import AppKit
import Foundation

let S: CGFloat = 1024
let cs = CGColorSpace(name: CGColorSpace.sRGB)!
func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: cs, components: [CGFloat((hex >> 16) & 0xff) / 255, CGFloat((hex >> 8) & 0xff) / 255, CGFloat(hex & 0xff) / 255, a])!
}
func gradient(_ colors: [CGColor]) -> CGGradient {
    CGGradient(colorsSpace: cs, colors: colors as CFArray, locations: nil)!
}

struct Palette { let tile: [UInt32], tileBase: UInt32 }
// Release: dark graphite tile. Debug: orange tile, so a dev build stands out in the Dock.
let release = Palette(tile: [0x3A3F47, 0x1C1F24], tileBase: 0x1C1F24)
let debug = Palette(tile: [0xFBBF24, 0xEA580C], tileBase: 0xC2410C)

// Gray cat head in fine pixels: shapes are sampled on a 26×22 grid, so edges stay blocky but soft.
let gridW = 26, gridH = 22
let colors: [Character: UInt32] = ["G": 0xA3A8B0, "S": 0x7A7F88, "D": 0x5E636C, "L": 0xDDE0E5,
                                   "P": 0xF2A0B0, "E": 0x16181C, "W": 0xFFFFFF]

func inTriangle(_ p: CGPoint, _ a: CGPoint, _ b: CGPoint, _ c: CGPoint) -> Bool {
    func side(_ p1: CGPoint, _ p2: CGPoint) -> CGFloat { (p.x - p2.x) * (p1.y - p2.y) - (p1.x - p2.x) * (p.y - p2.y) }
    let d1 = side(a, b), d2 = side(b, c), d3 = side(c, a)
    return !((d1 < 0 || d2 < 0 || d3 < 0) && (d1 > 0 || d2 > 0 || d3 > 0))
}
func inEllipse(_ p: CGPoint, _ cx: CGFloat, _ cy: CGFloat, _ rx: CGFloat, _ ry: CGFloat) -> CGFloat {
    let dx = (p.x - cx) / rx, dy = (p.y - cy) / ry
    return dx * dx + dy * dy
}

// Which color a grid cell gets (x right, y down, cell centers).
func catCell(_ col: Int, _ row: Int) -> Character? {
    let p = CGPoint(x: CGFloat(col) + 0.5, y: CGFloat(row) + 0.5)
    let m = CGPoint(x: CGFloat(gridW) - p.x, y: p.y)          // mirrored, for symmetric parts
    let q = p.x < CGFloat(gridW) / 2 ? p : m                  // left half coordinates
    let head = inEllipse(p, 13, 13.5, 11.8, 8.3)
    let earOuter = inTriangle(q, CGPoint(x: 2.2, y: 11), CGPoint(x: 4, y: 0.6), CGPoint(x: 11.5, y: 6.5))
    let earInner = inTriangle(q, CGPoint(x: 4.3, y: 8.5), CGPoint(x: 5.2, y: 3.2), CGPoint(x: 9.4, y: 6.8))
    guard head <= 1 || earOuter else { return nil }
    if earInner && head > 0.78 { return "P" }
    // eyes with a shine
    if inEllipse(q, 8.5, 12.5, 1.9, 2.3) <= 1 { return (q.x < 8.5 && q.y < 12) ? "W" : "E" }
    // nose and mouth
    if p.y >= 15 && p.y < 16 && abs(p.x - 13) < 1.5 { return "P" }
    if p.y >= 16 && p.y < 17 && abs(p.x - 13) < 0.6 { return "D" }
    if p.y >= 17 && p.y < 18 && (abs(p.x - 11.5) < 0.6 || abs(p.x - 14.5) < 0.6) { return "D" }
    if inEllipse(p, 13, 17.4, 4.2, 2.3) <= 1 { return "L" }
    // forehead stripes
    if p.y >= 6 && p.y < 9 && abs(p.x - 13) < 0.6 { return "S" }
    if p.y >= 7 && p.y < 9 && (abs(p.x - 10.5) < 0.6 || abs(p.x - 15.5) < 0.6) { return "S" }
    // darker rim along the bottom and the ear edges
    if head <= 1 && head > 0.72 && p.y > 15 { return "S" }
    if head > 1 { return earOuter && !inTriangle(q, CGPoint(x: 3, y: 10.5), CGPoint(x: 4.3, y: 1.8), CGPoint(x: 10.6, y: 6.6)) ? "S" : "G" }
    return "G"
}

func draw(_ palette: Palette) -> CGImage {
let ctx = CGContext(data: nil, width: Int(S), height: Int(S), bitsPerComponent: 8, bytesPerRow: 0,
                    space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!

// 1. Background: rounded square on the macOS icon grid (824 in a 1024 canvas) with a shadow.
let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
let tilePath = CGPath(roundedRect: tile, cornerWidth: 186, cornerHeight: 186, transform: nil)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 28, color: rgb(0x000000, 0.35))
ctx.addPath(tilePath); ctx.setFillColor(rgb(palette.tileBase)); ctx.fillPath()
ctx.restoreGState()
ctx.saveGState()
ctx.addPath(tilePath); ctx.clip()
ctx.drawLinearGradient(gradient(palette.tile.map { rgb($0) }),
                       start: CGPoint(x: 0, y: 924), end: CGPoint(x: 0, y: 100), options: [])
ctx.restoreGState()

// 2. The cat, crisp square pixels, centered on the tile.
let cell: CGFloat = 26
let cols = CGFloat(gridW), rows = CGFloat(gridH)
let x0 = (S - cols * cell) / 2, yTop = (S + rows * cell) / 2 - 10
ctx.setShouldAntialias(false)
for r in 0..<gridH {
    for c in 0..<gridW {
        guard let ch = catCell(c, r), let hex = colors[ch] else { continue }
        ctx.setFillColor(rgb(hex))
        ctx.fill(CGRect(x: x0 + CGFloat(c) * cell, y: yTop - CGFloat(r + 1) * cell, width: cell, height: cell))
    }
}
return ctx.makeImage()!
}

// Output: all sizes of both icon sets, plus the 1024 release master for the README banner.

func writePNG(_ img: CGImage, px: Int, to url: URL) {
    let c = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    c.interpolationQuality = .high
    c.draw(img, in: CGRect(x: 0, y: 0, width: px, height: px))
    let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, c.makeImage()!, nil)
    CGImageDestinationFinalize(dest)
}

func writeIconSet(_ image: CGImage, named name: String) throws {
    let outDir = URL(filePath: "AKit/Assets.xcassets/\(name).appiconset")
    try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
    var entries: [String] = []
    for pt in [16, 32, 128, 256, 512] {
        for scale in [1, 2] {
            let file = "icon_\(pt)x\(pt)\(scale == 2 ? "@2x" : "").png"
            writePNG(image, px: pt * scale, to: outDir.appending(path: file))
            entries.append(#"{"idiom":"mac","size":"\#(pt)x\#(pt)","scale":"\#(scale)x","filename":"\#(file)"}"#)
        }
    }
    let contents = #"{"images":[\#(entries.joined(separator: ","))],"info":{"author":"xcode","version":1}}"#
    try contents.write(to: outDir.appending(path: "Contents.json"), atomically: true, encoding: .utf8)
}

let image = draw(release)
try writeIconSet(image, named: "AppIcon")
try writeIconSet(draw(debug), named: "AppIconDev")
try #"{"info":{"author":"xcode","version":1}}"#.write(to: URL(filePath: "AKit/Assets.xcassets/Contents.json"), atomically: true, encoding: .utf8)
writePNG(image, px: 1024, to: URL(filePath: "tools/icon-1024.png"))
print("ok")
