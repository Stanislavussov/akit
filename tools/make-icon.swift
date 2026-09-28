// Draws the AKit icons (1024×1024) and every size: AppIcon (purple, release builds) and
// AppIconDev (orange, debug builds), so a dev build is easy to tell apart in the Dock.
// Run: swift tools/make-icon.swift   (from the akit folder), or `make icon`
import AppKit
import CoreText
import Foundation

let S: CGFloat = 1024
let cs = CGColorSpace(name: CGColorSpace.sRGB)!
func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: cs, components: [CGFloat((hex >> 16) & 0xff) / 255, CGFloat((hex >> 8) & 0xff) / 255, CGFloat(hex & 0xff) / 255, a])!
}
func gradient(_ colors: [CGColor]) -> CGGradient {
    CGGradient(colorsSpace: cs, colors: colors as CFArray, locations: nil)!
}

struct Palette {
    let tileBase: UInt32, tile: [UInt32], bodyShadow: UInt32, bodyBottom: UInt32, letter: [UInt32]
}
let release = Palette(tileBase: 0x3B2FD1, tile: [0x7C5CFF, 0x4338CA, 0x0E7490], bodyShadow: 0x0B0633,
                      bodyBottom: 0xE6E9FF, letter: [0x6D4AFF, 0x2563EB, 0x0891B2])
let debug = Palette(tileBase: 0xC2410C, tile: [0xFBBF24, 0xF97316, 0xB91C1C], bodyShadow: 0x431407,
                    bodyBottom: 0xFFEDD5, letter: [0xF59E0B, 0xEA580C, 0xDC2626])

let base = NSFont.systemFont(ofSize: 360, weight: .black)
let useFont: CTFont = base.fontDescriptor.withDesign(.rounded).flatMap { NSFont(descriptor: $0, size: 360) } ?? base

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
                       start: CGPoint(x: 150, y: 924), end: CGPoint(x: 874, y: 100), options: [])
// soft highlight at the top
ctx.drawRadialGradient(gradient([rgb(0xFFFFFF, 0.28), rgb(0xFFFFFF, 0)]),
                       startCenter: CGPoint(x: 380, y: 880), startRadius: 0,
                       endCenter: CGPoint(x: 380, y: 880), endRadius: 520, options: [])
ctx.restoreGState()

// 2. Case handle.
let handle = CGPath(roundedRect: CGRect(x: 402, y: 600, width: 220, height: 150), cornerWidth: 50, cornerHeight: 50, transform: nil)
ctx.saveGState()
ctx.addPath(handle); ctx.setStrokeColor(rgb(0xFFFFFF, 0.92)); ctx.setLineWidth(46); ctx.strokePath()
ctx.restoreGState()

// 3. Case body with a shadow.
let body = CGRect(x: 232, y: 232, width: 560, height: 420)
let bodyPath = CGPath(roundedRect: body, cornerWidth: 78, cornerHeight: 78, transform: nil)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -18), blur: 36, color: rgb(palette.bodyShadow, 0.45))
ctx.addPath(bodyPath); ctx.setFillColor(rgb(0xFFFFFF)); ctx.fillPath()
ctx.restoreGState()
ctx.saveGState()
ctx.addPath(bodyPath); ctx.clip()
ctx.drawLinearGradient(gradient([rgb(0xFFFFFF), rgb(palette.bodyBottom)]),
                       start: CGPoint(x: 0, y: body.maxY), end: CGPoint(x: 0, y: body.minY), options: [])
ctx.restoreGState()

// 4. Gradient letter "A", centered on the case.
var ch: [UniChar] = Array("A".utf16), glyph = [CGGlyph](repeating: 0, count: 1)
CTFontGetGlyphsForCharacters(useFont, &ch, &glyph, 1)
let glyphPath = CTFontCreatePathForGlyph(useFont, glyph[0], nil)!
let gb = glyphPath.boundingBoxOfPath
var move = CGAffineTransform(translationX: body.midX - gb.midX, y: body.midY - gb.midY - 6)
let aPath = glyphPath.copy(using: &move)!
ctx.saveGState()
ctx.addPath(aPath); ctx.clip()
ctx.drawLinearGradient(gradient(palette.letter.map { rgb($0) }),
                       start: CGPoint(x: body.minX, y: body.maxY), end: CGPoint(x: body.maxX, y: body.minY), options: [])
ctx.restoreGState()

// 5. "Agent" sparkles — four-point stars in the top-right corner.
func sparkle(center c: CGPoint, r: CGFloat) -> CGPath {
    let p = CGMutablePath(); let k: CGFloat = 0.22
    p.move(to: CGPoint(x: c.x, y: c.y + r))
    p.addQuadCurve(to: CGPoint(x: c.x + r, y: c.y), control: CGPoint(x: c.x + r * k, y: c.y + r * k))
    p.addQuadCurve(to: CGPoint(x: c.x, y: c.y - r), control: CGPoint(x: c.x + r * k, y: c.y - r * k))
    p.addQuadCurve(to: CGPoint(x: c.x - r, y: c.y), control: CGPoint(x: c.x - r * k, y: c.y - r * k))
    p.addQuadCurve(to: CGPoint(x: c.x, y: c.y + r), control: CGPoint(x: c.x - r * k, y: c.y + r * k))
    return p
}
for (c, r, a) in [(CGPoint(x: 770, y: 770), CGFloat(92), CGFloat(1)), (CGPoint(x: 850, y: 640), CGFloat(40), CGFloat(0.85))] {
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: 30, color: rgb(0xFDE68A, 0.9))
    ctx.addPath(sparkle(center: c, r: r)); ctx.setFillColor(rgb(0xFFF7D6, a)); ctx.fillPath()
    ctx.restoreGState()
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
print("ok:", CTFontCopyFullName(useFont))
