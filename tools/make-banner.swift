// Draws the README banner (docs/assets/banner.png, 2560×800): the icon, the name and a
// tagline on the icon's gradient. Run: swift tools/make-banner.swift  (from the akit folder),
// or `make banner`.
import AppKit
import CoreText
import Foundation

let W: CGFloat = 2560, H: CGFloat = 800
let cs = CGColorSpace(name: CGColorSpace.sRGB)!
func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: cs, components: [CGFloat((hex >> 16) & 0xff) / 255, CGFloat((hex >> 8) & 0xff) / 255, CGFloat(hex & 0xff) / 255, a])!
}

let ctx = CGContext(data: nil, width: Int(W), height: Int(H), bitsPerComponent: 8, bytesPerRow: 0,
                    space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!

// 1. Rounded card with the icon's gradient, plus two soft glows.
let card = CGPath(roundedRect: CGRect(x: 0, y: 0, width: W, height: H), cornerWidth: 64, cornerHeight: 64, transform: nil)
ctx.addPath(card); ctx.clip()
ctx.drawLinearGradient(CGGradient(colorsSpace: cs, colors: [rgb(0x7C5CFF), rgb(0x4338CA), rgb(0x0E7490)] as CFArray, locations: [0, 0.55, 1])!,
                       start: CGPoint(x: 0, y: H), end: CGPoint(x: W, y: 0), options: [])
for (center, radius, color) in [(CGPoint(x: 420, y: 720), 700.0, rgb(0xFFFFFF, 0.16)), (CGPoint(x: 2350, y: 60), 800.0, rgb(0x22D3EE, 0.22))] {
    ctx.drawRadialGradient(CGGradient(colorsSpace: cs, colors: [color, rgb(0xFFFFFF, 0)] as CFArray, locations: [0, 1])!,
                           startCenter: center, startRadius: 0, endCenter: center, endRadius: radius, options: [])
}

// 2. Sparkles, like the icon's.
func sparkle(_ c: CGPoint, _ r: CGFloat, _ alpha: CGFloat) {
    let path = CGMutablePath()
    path.move(to: CGPoint(x: c.x, y: c.y + r))
    for (dx, dy) in [(1.0, 0.0), (0.0, -1.0), (-1.0, 0.0), (0.0, 1.0)] {
        let tip = CGPoint(x: c.x + dx * r, y: c.y + dy * r)
        path.addQuadCurve(to: tip, control: c)
    }
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: r * 0.6, color: rgb(0xFFF7D6, 0.8 * alpha))
    ctx.addPath(path); ctx.setFillColor(rgb(0xFFF7D6, alpha)); ctx.fillPath()
    ctx.restoreGState()
}
sparkle(CGPoint(x: 2330, y: 610), 70, 0.95)
sparkle(CGPoint(x: 2440, y: 500), 34, 0.85)
sparkle(CGPoint(x: 2180, y: 170), 26, 0.6)
sparkle(CGPoint(x: 1480, y: 700), 18, 0.5)

// 3. The app icon on the left.
let iconURL = URL(filePath: "tools/icon-1024.png")
guard let icon = NSImage(contentsOf: iconURL)?.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
    fatalError("Run from the akit folder: tools/icon-1024.png not found")
}
ctx.draw(icon, in: CGRect(x: 110, y: 50, width: 700, height: 700))

// 4. Name, tagline and the agents it works with.
func text(_ string: String, size: CGFloat, weight: NSFont.Weight, color: CGColor, at point: CGPoint, tracking: CGFloat = 0) {
    let font = NSFont.systemFont(ofSize: size, weight: weight)
    let attributed = NSAttributedString(string: string, attributes: [
        .font: font, .foregroundColor: NSColor(cgColor: color)!, .kern: tracking,
    ])
    let line = CTLineCreateWithAttributedString(attributed)
    ctx.textPosition = point
    CTLineDraw(line, ctx)
}
text("AKit", size: 250, weight: .heavy, color: rgb(0xFFFFFF), at: CGPoint(x: 860, y: 430), tracking: -4)
text("Skills, MCP servers and project setup", size: 76, weight: .semibold, color: rgb(0xFFFFFF, 0.95), at: CGPoint(x: 868, y: 300))
text("for your AI coding agents, on every Mac.", size: 76, weight: .semibold, color: rgb(0xFFFFFF, 0.95), at: CGPoint(x: 868, y: 205))
text("CLAUDE CODE  ·  PI  ·  CODEX  ·  OPENCODE", size: 40, weight: .bold, color: rgb(0xFFFFFF, 0.6), at: CGPoint(x: 870, y: 105), tracking: 4)

let out = URL(filePath: "docs/assets/banner.png")  // then scaled to 1920 wide by `make banner`
try FileManager.default.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
try rep.representation(using: .png, properties: [:])!.write(to: out)
print("Wrote \(out.path)")
