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

// Pixel-art gray cat head, 16×13 cells, top row first.
// G gray, S darker gray (stripes, shade), L light gray (muzzle), P pink, E eye, W eye shine.
let cat = [
    ".SS..........SS.",
    ".SPS........SPS.",
    ".GPPG......GPPG.",
    ".GGGGGGSSGGGGGG.",
    "GGGGGSGSSGSGGGGG",
    "GGGWEGGGGGGWEGGG",
    "GGGEEGGGGGGEEGGG",
    "GGGGGGGPPGGGGGGG",
    "SGGGGGLSSLGGGGGS",
    ".SGGGGLLLLGGGGS.",
    "..SGGGGGGGGGGS..",
    "...SSSSSSSSSS...",
]
let colors: [Character: UInt32] = ["G": 0xA3A8B0, "S": 0x6E737C, "L": 0xD9DCE1,
                                   "P": 0xF2A0B0, "E": 0x16181C, "W": 0xFFFFFF]

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
let cell: CGFloat = 40
let cols = CGFloat(cat[0].count), rows = CGFloat(cat.count)
let x0 = (S - cols * cell) / 2, yTop = (S + rows * cell) / 2 - 10
ctx.setShouldAntialias(false)
for (r, line) in cat.enumerated() {
    for (c, ch) in line.enumerated() {
        guard let hex = colors[ch] else { continue }
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
