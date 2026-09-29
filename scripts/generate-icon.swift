// Run from repository root: swift scripts/generate-icon.swift
// Draw the same outlined glyphs into portable SVG and an opaque iOS PNG.
import AppKit
import CoreText
import ImageIO
import UniformTypeIdentifiers

let font = CTFontCreateWithName("Menlo-Bold" as CFString, 160, nil)
let text = Array("chadmux".utf16)
var glyphs = [CGGlyph](repeating: 0, count: text.count)
precondition(CTFontGetGlyphsForCharacters(font, text, &glyphs, text.count))
var advances = [CGSize](repeating: .zero, count: glyphs.count)
CTFontGetAdvancesForGlyphs(font, .horizontal, glyphs, &advances, glyphs.count)
let outlines = CGMutablePath()
var x: CGFloat = 0
for (index, glyph) in glyphs.enumerated() {
    var offset = CGAffineTransform(translationX: x, y: 0)
    guard let path = CTFontCreatePathForGlyph(font, glyph, &offset) else {
        fatalError("Missing wordmark glyph")
    }
    outlines.addPath(path)
    x += advances[index].width
}
let bounds = outlines.boundingBoxOfPath
// 18% margin on each side; center visible ink rather than font metrics.
let scale = 655.36 / bounds.width
var transform = CGAffineTransform(a: scale, b: 0, c: 0, d: -scale,
    tx: 512 - bounds.midX * scale, ty: 512 + bounds.midY * scale)
let path = outlines.copy(using: &transform)!
func point(_ p: CGPoint) -> String { String(format: "%.4f %.4f", p.x, p.y) }
var commands: [String] = []
path.applyWithBlock { element in
    let e = element.pointee
    switch e.type {
    case .moveToPoint: commands.append("M" + point(e.points[0]))
    case .addLineToPoint: commands.append("L" + point(e.points[0]))
    case .addQuadCurveToPoint: commands.append("Q" + point(e.points[0]) + " " + point(e.points[1]))
    case .addCurveToPoint: commands.append("C" + point(e.points[0]) + " " + point(e.points[1]) + " " + point(e.points[2]))
    case .closeSubpath: commands.append("Z")
    @unknown default: fatalError("Unknown path element")
    }
}
let svg = """
<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024" role="img" aria-labelledby="title">
  <title id="title">chadmux</title>
  <rect width="1024" height="1024" fill="#000"/>
  <path fill="#fff" d="\(commands.joined(separator: " "))"/>
</svg>

"""
try svg.write(toFile: "artwork/chadmux-icon.svg", atomically: true, encoding: .utf8)
let context = CGContext(data: nil, width: 1024, height: 1024, bitsPerComponent: 8,
    bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
context.setFillColor(CGColor(gray: 0, alpha: 1))
context.fill(CGRect(x: 0, y: 0, width: 1024, height: 1024))
context.translateBy(x: 0, y: 1024)
context.scaleBy(x: 1, y: -1)
context.addPath(path)
context.setFillColor(CGColor(gray: 1, alpha: 1))
context.fillPath()
let destination = CGImageDestinationCreateWithURL(
    URL(fileURLWithPath: "Chadmux/Assets.xcassets/AppIcon.appiconset/AppIcon.png") as CFURL,
    UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(destination, context.makeImage()!, nil)
precondition(CGImageDestinationFinalize(destination), "Could not write icon PNG")
print("Generated outlined SVG and opaque 1024px PNG; ink bounds: \(path.boundingBoxOfPath)")
