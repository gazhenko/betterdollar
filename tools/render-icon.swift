#!/usr/bin/env swift
// Renders the BetterDollar app icon: a serif B engraved with fine horizontal hatching,
// like the lettering on a banknote. Usage: swift tools/render-icon.swift [appiconset-dir]
import AppKit
import CoreText

let size: CGFloat = 1024
let output = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "BetterDollar/Resources/Assets.xcassets/AppIcon.appiconset")

func rgb(_ hex: UInt32) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
}

/// The outline of a single character in the system serif face, scaled so its height is `height` and centered.
func glyphPath(_ character: String, height: CGFloat, center: CGPoint) -> CGPath {
    let descriptor = NSFont.systemFont(ofSize: 100, weight: .heavy).fontDescriptor.withDesign(.serif)!
    let font = NSFont(descriptor: descriptor, size: 100)! as CTFont
    var glyph = CGGlyph(0)
    var unichar = Array(character.utf16)
    CTFontGetGlyphsForCharacters(font, &unichar, &glyph, 1)
    let raw = CTFontCreatePathForGlyph(font, glyph, nil)!
    let box = raw.boundingBoxOfPath
    let scale = height / box.height
    var transform = CGAffineTransform(translationX: center.x, y: center.y)
        .scaledBy(x: scale, y: scale)
        .translatedBy(x: -box.midX, y: -box.midY)
    return raw.copy(using: &transform)!
}

func render(background: UInt32, ink: UInt32, to url: URL) throws {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    ctx.setFillColor(rgb(background))
    ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))

    // Nudged right of center: the B's bowls carry more visual weight than its stem.
    let letter = glyphPath("B", height: 690, center: CGPoint(x: size / 2 + 8, y: size / 2))
    ctx.saveGState()
    ctx.addPath(letter)
    ctx.clip()
    ctx.setStrokeColor(rgb(ink))
    ctx.setLineWidth(8)
    var y: CGFloat = 0
    while y < size {
        ctx.move(to: CGPoint(x: 0, y: y))
        ctx.addLine(to: CGPoint(x: size, y: y))
        y += 15
    }
    ctx.strokePath()
    ctx.restoreGState()
    ctx.addPath(letter)
    ctx.setLineWidth(11)
    ctx.setLineJoin(.round)
    ctx.setStrokeColor(rgb(ink))
    ctx.strokePath()

    NSGraphicsContext.restoreGraphicsState()
    try rep.representation(using: .png, properties: [:])!.write(to: url)
}

try render(background: 0xF2F4EF, ink: 0x1F4D3A, to: output.appendingPathComponent("AppIcon.png"))
try render(background: 0x0A1712, ink: 0x9CC8AE, to: output.appendingPathComponent("AppIcon-Dark.png"))
print("Wrote icons to \(output.path)")
