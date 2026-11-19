import SwiftUI

/// Banknote-style guilloche engraving drawn from hypotrochoid curves.
/// The rosette is always there as a watermark; `completion` (0...1) is how much of it has been inked,
/// so the plate can "finish engraving" when the budget reaches zero. The band along the bottom is the
/// border of the note and is always whole.
struct Guilloche: View, Animatable {
    var completion: Double = 1
    var color: Color = Ink.primary
    var lineWidth: CGFloat = 0.6
    var layers = 10
    /// Scales the line opacity: stock-colored lines on the green plate need more than ink on paper.
    var strength: Double = 1
    /// Radius of the rosette tucked into the top trailing corner. Nil spreads one across the whole view.
    var rosetteRadius: CGFloat? = 100

    var animatableData: Double {
        get { completion }
        set { completion = newValue }
    }

    var body: some View {
        Canvas { context, size in
            let center: CGPoint, scale: Double
            if let rosetteRadius {
                center = CGPoint(x: size.width - rosetteRadius * 0.62, y: rosetteRadius * 0.62)
                scale = rosetteRadius / 110
            } else {
                center = CGPoint(x: size.width * 0.82, y: size.height * 0.5)
                scale = max(size.width, size.height) / 230
            }
            context.drawLayer { rosette in
                if let rosetteRadius {
                    // A corner rosette thins out toward its tips, so the copy it reaches stays easy to read.
                    rosette.clipToLayer { mask in
                        let fade = Gradient(stops: [.init(color: .black, location: 0.45), .init(color: .black.opacity(0.12), location: 1)])
                        mask.fill(Path(CGRect(origin: .zero, size: size)),
                                  with: .radialGradient(fade, center: center, startRadius: 0, endRadius: rosetteRadius))
                    }
                }
                for layer in 0..<layers {
                    let rotation = Double(layer) * .pi / 80
                    if completion < 1 {
                        let whole = Self.curve(center: center, outer: 96, inner: 36, pen: 50, rotation: rotation, scale: scale, completion: 1)
                        rosette.stroke(whole, with: .color(color.opacity(0.07 * strength)), lineWidth: lineWidth)
                    }
                    let inked = Self.curve(center: center, outer: 96, inner: 36, pen: 50, rotation: rotation, scale: scale, completion: completion)
                    rosette.stroke(inked, with: .color(color.opacity((0.22 + 0.02 * Double(layer % 3)) * strength)), lineWidth: lineWidth)
                }
            }
            var band = Path()
            for wave in 0..<6 {
                let offset = Double(wave) * 0.9
                for step in 0...240 {
                    let x = Double(step) / 240 * size.width
                    let y = size.height - 18 + 7 * sin(x / 13 + offset) * cos(x / 41 - offset)
                    step == 0 ? band.move(to: CGPoint(x: x, y: y)) : band.addLine(to: CGPoint(x: x, y: y))
                }
            }
            context.stroke(band, with: .color(color.opacity(0.25 * strength)), lineWidth: lineWidth)
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
