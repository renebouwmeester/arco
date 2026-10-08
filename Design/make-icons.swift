// Draws Arco's icons: the app icon (every size macOS asks for) and the menu bar glyph (a template PDF, so it follows
// light and dark by itself). A bow, and the sound it makes: the stick in Basso's rose, the hair and the three waves in
// greys — the family look of Basso, in black.
//
//   swift Design/make-icons.swift        (from the project folder)
import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

// The drawing, in a 160 × 160 space (the sketch it came from).
struct Stroke { let path: CGPath; let width: CGFloat; let color: CGColor }

func quad(_ x0: CGFloat, _ y0: CGFloat, _ cx: CGFloat, _ cy: CGFloat, _ x1: CGFloat, _ y1: CGFloat) -> CGPath {
    let p = CGMutablePath(); p.move(to: CGPoint(x: x0, y: y0)); p.addQuadCurve(to: CGPoint(x: x1, y: y1), control: CGPoint(x: cx, y: cy)); return p
}
func line(_ x0: CGFloat, _ y0: CGFloat, _ x1: CGFloat, _ y1: CGFloat) -> CGPath {
    let p = CGMutablePath(); p.move(to: CGPoint(x: x0, y: y0)); p.addLine(to: CGPoint(x: x1, y: y1)); return p
}
func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat(hex >> 16 & 255) / 255, green: CGFloat(hex >> 8 & 255) / 255, blue: CGFloat(hex & 255) / 255, alpha: a)
}

let rose = rgb(0xF45A6C)        // Basso's accent
let background = rgb(0x141416)  // Basso's icon
let stick = quad(44, 34, 84, 80, 44, 126)
let hair = line(44, 36, 44, 124)   // from the tip to the frog, at the stick's two ends
let waves = [quad(78, 60, 90, 80, 78, 100), quad(96, 48, 114, 80, 96, 112), quad(114, 36, 138, 80, 114, 124)]

func appStrokes() -> [Stroke] {
    [Stroke(path: hair, width: 2.4, color: rgb(0xD1D1D6)),
     Stroke(path: stick, width: 6.5, color: rose),
     Stroke(path: waves[0], width: 6.5, color: rgb(0xE5E5EA)),
     Stroke(path: waves[1], width: 6.5, color: rgb(0xAEAEB2)),
     Stroke(path: waves[2], width: 6.5, color: rgb(0x6C6C70))]
}

func draw(_ strokes: [Stroke], in ctx: CGContext) {
    ctx.setLineCap(.round)
    for s in strokes { ctx.addPath(s.path); ctx.setLineWidth(s.width); ctx.setStrokeColor(s.color); ctx.strokePath() }
}

/// The app icon at `size` pixels: macOS's grid (an 824 rounded square in 1024, a soft shadow), the drawing centred in it.
func appIcon(_ size: Int) -> CGImage {
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let k = CGFloat(size) / 1024
    ctx.scaleBy(x: k, y: k)
    // Flip to the drawing's own coordinates (y down), as in the sketch.
    ctx.translateBy(x: 0, y: 1024); ctx.scaleBy(x: 1, y: -1)
    let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
    let shape = CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: 10), blur: 28, color: rgb(0x000000, 0.35))
    ctx.addPath(shape); ctx.setFillColor(background); ctx.fillPath()
    ctx.restoreGState()
    ctx.addPath(shape); ctx.setStrokeColor(rgb(0xFFFFFF, 0.06)); ctx.setLineWidth(2); ctx.strokePath()
    // The drawing spans x 41…129, y 31…129 in its 160 space: centred, at 824/160.
    let s: CGFloat = 824 / 160
    ctx.translateBy(x: 100 + (80 - 85) * s, y: 100); ctx.scaleBy(x: s, y: s)
    draw(appStrokes(), in: ctx)
    return ctx.makeImage()!
}

func writePNG(_ image: CGImage, to url: URL) {
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, image, nil); CGImageDestinationFinalize(dest)
}

/// The menu bar glyph: 18 × 18 points, black on clear (macOS tints a template image itself), as a vector PDF.
func menuGlyph(to url: URL) {
    var box = CGRect(x: 0, y: 0, width: 18, height: 18)
    let ctx = CGContext(url as CFURL, mediaBox: &box, nil)!
    ctx.beginPDFPage(nil)
    ctx.translateBy(x: 0, y: 18); ctx.scaleBy(x: 1, y: -1)
    let s: CGFloat = 15 / 100           // the drawing with its strokes, about 100 units, into 15 points
    ctx.translateBy(x: 9 - 86 * s, y: 9 - 80 * s); ctx.scaleBy(x: s, y: s)
    let black = rgb(0x000000)
    draw([Stroke(path: hair, width: 6, color: black), Stroke(path: stick, width: 10, color: black)]
         + waves.map { Stroke(path: $0, width: 10, color: black) }, in: ctx)
    ctx.endPDFPage(); ctx.closePDF()
}

/// The icon Roon shows for Arco's source (the signal path, the zone): Basso's rose on clear, edge to edge — Roon draws
/// source icons small inside its own circle, so a tile with a margin (the app icon) shrinks to a speck. Rose, not white:
/// one image serves Roon's light and dark mode alike, and white vanished in light mode. The menu bar's bold strokes,
/// centred on the drawing's box (x 39…131, y 29…131 with the strokes), filling the square.
func roonIcon(_ size: Int) -> CGImage {
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.translateBy(x: 0, y: CGFloat(size)); ctx.scaleBy(x: 1, y: -1)
    let s = CGFloat(size) / 102
    ctx.translateBy(x: CGFloat(size) / 2 - 85 * s, y: CGFloat(size) / 2 - 80 * s); ctx.scaleBy(x: s, y: s)
    draw([Stroke(path: hair, width: 6, color: rose), Stroke(path: stick, width: 10, color: rose)]
         + waves.map { Stroke(path: $0, width: 10, color: rose) }, in: ctx)
    return ctx.makeImage()!
}

let assets = URL(fileURLWithPath: "Arco/Assets.xcassets")
let iconset = assets.appendingPathComponent("AppIcon.appiconset")
let menuset = assets.appendingPathComponent("MenuIcon.imageset")
for dir in [iconset, menuset] { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
try #"{"info":{"author":"xcode","version":1}}"#.write(to: assets.appendingPathComponent("Contents.json"), atomically: true, encoding: .utf8)

var images: [String] = []
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = "icon-\(points)@\(scale)x.png"
        writePNG(appIcon(points * scale), to: iconset.appendingPathComponent(name))
        images.append(#"{"idiom":"mac","size":"\#(points)x\#(points)","scale":"\#(scale)x","filename":"\#(name)"}"#)
    }
}
try #"{"images":[\#(images.joined(separator: ","))],"info":{"author":"xcode","version":1}}"#
    .write(to: iconset.appendingPathComponent("Contents.json"), atomically: true, encoding: .utf8)

menuGlyph(to: menuset.appendingPathComponent("menu.pdf"))
try #"{"images":[{"idiom":"universal","filename":"menu.pdf"}],"info":{"author":"xcode","version":1},"properties":{"template-rendering-intent":"template","preserves-vector-representation":true}}"#
    .write(to: menuset.appendingPathComponent("Contents.json"), atomically: true, encoding: .utf8)
let roonset = assets.appendingPathComponent("RoonIcon.imageset")
try FileManager.default.createDirectory(at: roonset, withIntermediateDirectories: true)
writePNG(roonIcon(256), to: roonset.appendingPathComponent("roon.png"))
try #"{"images":[{"idiom":"universal","filename":"roon.png"}],"info":{"author":"xcode","version":1}}"#
    .write(to: roonset.appendingPathComponent("Contents.json"), atomically: true, encoding: .utf8)
print("icons written")
