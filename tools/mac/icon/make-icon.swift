// Draws the Ithaca app icon (a sheet of warm paper with a few lines and one accent caret) and writes
// the PNG set for iconutil. Colors come from design/tokens/color.json (light mode).
//   swift tools/mac/icon/make-icon.swift <out.iconset>
import AppKit
import CoreGraphics

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}
let canvas = rgb(0xFAF8F4)      // surface.canvas
let sidebar = rgb(0xEFEBE4)     // surface.sidebar
let soft = rgb(0xF3E6CF)        // accent.soft
let accent = rgb(0x835918)      // accent.primary
let markup = rgb(0xB9B2A6)      // ink.markup
let ink = rgb(0x45413B)         // ink.secondary

func draw(_ px: Int) -> CGImage {
    let s = CGFloat(px) / 1024
    let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.scaleBy(x: s, y: s)
    // macOS icon grid: 824pt body inset 100pt, continuous-ish corner.
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let bodyPath = CGPath(roundedRect: body, cornerWidth: 186, cornerHeight: 186, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 28, color: rgb(0x1A1815, 0.28))
    ctx.addPath(bodyPath); ctx.setFillColor(sidebar); ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(bodyPath); ctx.clip()
    let grad = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [soft, sidebar] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(grad, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
    ctx.restoreGState()

    // The sheet.
    let sheet = CGRect(x: 262, y: 196, width: 500, height: 632)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -8), blur: 22, color: rgb(0x1A1815, 0.18))
    ctx.addPath(CGPath(roundedRect: sheet, cornerWidth: 28, cornerHeight: 28, transform: nil))
    ctx.setFillColor(canvas); ctx.fillPath()
    ctx.restoreGState()

    // Title line + body lines (Markdown-ish: the "#" is faint like ink.markup).
    func bar(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ c: CGColor) {
        ctx.addPath(CGPath(roundedRect: CGRect(x: x, y: y, width: w, height: h), cornerWidth: h / 2, cornerHeight: h / 2, transform: nil))
        ctx.setFillColor(c); ctx.fillPath()
    }
    bar(330, 712, 28, 30, markup)
    bar(374, 712, 230, 30, ink)
    let lines: [CGFloat] = [330, 330, 330, 330]
    let widths: [CGFloat] = [360, 330, 364, 196]
    for (i, x) in lines.enumerated() { bar(x, 616 - CGFloat(i) * 70, widths[i], 22, markup) }
    // The caret — the one accent.
    ctx.addPath(CGPath(roundedRect: CGRect(x: 542, y: 378, width: 14, height: 78), cornerWidth: 4, cornerHeight: 4, transform: nil))
    ctx.setFillColor(accent); ctx.fillPath()
    return ctx.makeImage()!
}

let out = URL(fileURLWithPath: CommandLine.arguments[1])
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
for (pt, scale) in [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)] {
    let img = draw(pt * scale)
    let name = scale == 1 ? "icon_\(pt)x\(pt).png" : "icon_\(pt)x\(pt)@2x.png"
    let rep = NSBitmapImageRep(cgImage: img)
    try rep.representation(using: .png, properties: [:])!.write(to: out.appendingPathComponent(name))
}
print("wrote \(out.path)")
