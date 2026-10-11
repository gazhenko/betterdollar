#!/usr/bin/env swift
// Renders the BetterDollar app icon: an engraved guilloche rosette, like the security
// printing on a banknote, around a dollar sign. Usage: swift tools/render-icon.swift
import AppKit

let size: CGFloat = 1024
let output = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "BetterDollar/Resources/Assets.xcassets/AppIcon.appiconset")

struct Palette { let paper: NSColor; let ink: NSColor; let fine: NSColor }
let light = Palette(paper: NSColor(srgbRed: 0.949, green: 0.957, blue: 0.937, alpha: 1),
                    ink: NSColor(srgbRed: 0.122, green: 0.302, blue: 0.227, alpha: 1),
                    fine: NSColor(srgbRed: 0.122, green: 0.302, blue: 0.227, alpha: 0.55))
let dark = Palette(paper: NSColor(srgbRed: 0.051, green: 0.102, blue: 0.082, alpha: 1),
                   ink: NSColor(srgbRed: 0.612, green: 0.784, blue: 0.682, alpha: 1),
                   fine: NSColor(srgbRed: 0.612, green: 0.784, blue: 0.682, alpha: 0.5))

/// A hypotrochoid: the curve traced by a point on a circle rolling inside another circle.
func rosette(center: CGPoint, outer R: CGFloat, inner r: CGFloat, pen d: CGFloat, rotation: CGFloat, scale: CGFloat) -> CGPath {
    let path = CGMutablePath()
    let loops = r / gcd(Int(R), Int(r))
    let steps = 2400
    for step in 0...steps {
        let t = CGFloat(step) / CGFloat(steps) * 2 * .pi * loops
        let x = (R - r) * cos(t) + d * cos((R - r) / r * t)
        let y = (R - r) * sin(t) - d * sin((R - r) / r * t)
        let rx = x * cos(rotation) - y * sin(rotation), ry = x * sin(rotation) + y * cos(rotation)
        let point = CGPoint(x: center.x + rx * scale, y: center.y + ry * scale)
        step == 0 ? path.move(to: point) : path.addLine(to: point)
    }
    path.closeSubpath()
    return path
}

func gcd(_ a: Int, _ b: Int) -> CGFloat { b == 0 ? CGFloat(a) : gcd(b, a % b) }

func render(_ palette: Palette, to url: URL) throws {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let context = NSGraphicsContext.current!.cgContext
    context.setFillColor(palette.paper.cgColor)
    context.fill(CGRect(x: 0, y: 0, width: size, height: size))
    let center = CGPoint(x: size / 2, y: size / 2)

    // Fine engraved band: many slightly rotated rosettes.
    context.setLineWidth(1.6)
    context.setStrokeColor(palette.fine.cgColor)
    for index in 0..<18 {
        let path = rosette(center: center, outer: 96, inner: 36, pen: 52, rotation: CGFloat(index) * .pi / 90, scale: 4.6)
        context.addPath(path)
        context.strokePath()
    }
    // Bolder inner rosette.
    context.setLineWidth(3)
    context.setStrokeColor(palette.ink.withAlphaComponent(0.85).cgColor)
    for index in 0..<3 {
        context.addPath(rosette(center: center, outer: 60, inner: 25, pen: 22, rotation: CGFloat(index) * .pi / 60, scale: 4.3))
        context.strokePath()
    }
    // Medallion.
    let medallion = CGRect(x: center.x - 190, y: center.y - 190, width: 380, height: 380)
    context.setFillColor(palette.paper.cgColor)
    context.fillEllipse(in: medallion)
    context.setLineWidth(10)
    context.setStrokeColor(palette.ink.cgColor)
    context.strokeEllipse(in: medallion.insetBy(dx: 14, dy: 14))
    context.setLineWidth(3)
    context.strokeEllipse(in: medallion.insetBy(dx: 34, dy: 34))

    let descriptor = NSFont.systemFont(ofSize: 300, weight: .bold).fontDescriptor.withDesign(.serif)!
    let font = NSFont(descriptor: descriptor, size: 300)!
    let text = NSAttributedString(string: "$", attributes: [.font: font, .foregroundColor: palette.ink])
    let bounds = text.boundingRect(with: NSSize(width: size, height: size), options: [.usesDeviceMetrics])
    text.draw(at: NSPoint(x: center.x - bounds.width / 2 - bounds.origin.x, y: center.y - bounds.height / 2 - bounds.origin.y))

    NSGraphicsContext.restoreGraphicsState()
    try rep.representation(using: .png, properties: [:])!.write(to: url)
}

try render(light, to: output.appendingPathComponent("AppIcon.png"))
try render(dark, to: output.appendingPathComponent("AppIcon-Dark.png"))
print("Wrote icons to \(output.path)")
