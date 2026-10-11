import SwiftUI

/// Banknote-style guilloche engraving drawn from hypotrochoid curves.
/// `completion` (0...1) controls how much of the pattern is drawn, so the plate can
/// "finish engraving" when the budget reaches zero.
struct Guilloche: View {
    var completion: Double = 1
    var color: Color = Ink.primary
    var lineWidth: CGFloat = 0.6
    var layers = 10

    var body: some View {
        Canvas { context, size in
            let center = CGPoint(x: size.width * 0.82, y: size.height * 0.5)
            let scale = max(size.width, size.height) / 230
            for layer in 0..<layers {
                let path = Self.curve(center: center, outer: 96, inner: 36, pen: 50,
                                      rotation: Double(layer) * .pi / 80, scale: scale, completion: completion)
                context.stroke(path, with: .color(color.opacity(0.22 + 0.02 * Double(layer % 3))), lineWidth: lineWidth)
            }
            // A flowing band along the bottom, like the border of a note.
            var band = Path()
            for wave in 0..<6 {
                let offset = Double(wave) * 0.9
                for step in 0...240 {
                    let x = Double(step) / 240 * size.width
                    let y = size.height - 18 + 7 * sin(x / 13 + offset) * cos(x / 41 - offset)
                    step == 0 ? band.move(to: CGPoint(x: x, y: y)) : band.addLine(to: CGPoint(x: x, y: y))
                }
            }
            context.stroke(band.trimmedPath(from: 0, to: completion), with: .color(color.opacity(0.25)), lineWidth: lineWidth)
        }
        .accessibilityHidden(true)
    }

    nonisolated static func curve(center: CGPoint, outer R: Double, inner r: Double, pen d: Double, rotation: Double,
                      scale: Double, completion: Double) -> Path {
        var path = Path()
        let loops = r / Double(gcd(Int(R), Int(r)))
        let steps = 900
        let last = Int(Double(steps) * min(1, max(0, completion)))
        guard last > 0 else { return path }
        for step in 0...last {
            let t = Double(step) / Double(steps) * 2 * .pi * loops
            let x = (R - r) * cos(t) + d * cos((R - r) / r * t)
            let y = (R - r) * sin(t) - d * sin((R - r) / r * t)
            let point = CGPoint(x: center.x + (x * cos(rotation) - y * sin(rotation)) * scale,
                                y: center.y + (x * sin(rotation) + y * cos(rotation)) * scale)
            step == 0 ? path.move(to: point) : path.addLine(to: point)
        }
        return path
    }

    nonisolated private static func gcd(_ a: Int, _ b: Int) -> Int { b == 0 ? a : gcd(b, a % b) }
}
