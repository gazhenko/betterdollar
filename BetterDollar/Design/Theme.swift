import BetterDollarCore
import SwiftUI
import UIKit

/// BetterDollar's look borrows from banknote printing: rag paper, intaglio green ink,
/// fine guilloche engraving, and the red of an old Treasury seal reserved for overspending.
nonisolated enum Ink {
    static let paper = dynamic(light: 0xF2F4EF, dark: 0x0D1A15)
    /// Raised surfaces such as the tray and sheets.
    static let sheet = dynamic(light: 0xFAFBF8, dark: 0x13231C)
    static let primary = dynamic(light: 0x1F4D3A, dark: 0x9CC8AE)
    static let text = dynamic(light: 0x1B2420, dark: 0xE4ECE7)
    static let secondary = dynamic(light: 0x5F6B65, dark: 0x93A39A)
    static let rule = dynamic(light: 0xD3DAD2, dark: 0x274036)
    static let track = dynamic(light: 0xE2E7E0, dark: 0x1D3029)
    static let seal = dynamic(light: 0xB3362C, dark: 0xF07A6E)
    static let income = dynamic(light: 0x2E6B4A, dark: 0x8FD3A6)
    /// Text drawn on top of `primary`.
    static let onPrimary = dynamic(light: 0xF2F4EF, dark: 0x0D1A15)

    /// SwiftUI resolves colors on its render thread too (for example during a drag), so this must not be main-actor isolated.
    static func dynamic(light: UInt32, dark: UInt32) -> Color {
        Color(UIColor { @Sendable traits in traits.userInterfaceStyle == .dark ? UIColor(hex: dark) : UIColor(hex: light) })
    }
}

extension UIColor {
    nonisolated convenience init(hex: UInt32) {
        self.init(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}

/// Type: New York for titles (ledger headings), SF Pro for everything else, with an expanded
/// width for large money figures, echoing the wide lettering of banknote denominations.
enum Typeface {
    static func title(_ size: CGFloat = 28) -> Font { .system(size: size, weight: .semibold, design: .serif) }
    static let groupTitle = Font.system(size: 19, weight: .semibold, design: .serif)
    static func figure(_ size: CGFloat) -> Font { .system(size: size, weight: .bold).width(.expanded) }
    static let amount = Font.system(size: 16, weight: .medium).monospacedDigit()
    static let amountSmall = Font.system(size: 13, weight: .regular).monospacedDigit()
}

extension View {
    func paperBackground() -> some View {
        background(Ink.paper.ignoresSafeArea())
    }

    /// Screens without a navigation bar: keeps scrolled content from showing through the status bar.
    func statusBarShield() -> some View {
        safeAreaInset(edge: .top, spacing: 0) {
            Color.clear.frame(height: 0).background(Ink.paper.ignoresSafeArea(edges: .top))
        }
    }
}

/// Money text that keeps digits aligned and turns seal-red when negative if asked.
struct AmountText: View {
    let cents: Int
    var font: Font = Typeface.amount
    var showsCents = true
    var flagsNegative = false
    var color: Color = Ink.text

    var body: some View {
        Text(Money.format(cents, showsCents: showsCents))
            .font(font)
            .foregroundStyle(flagsNegative && cents < 0 ? Ink.seal : color)
            .contentTransition(.numericText(value: Double(cents)))
    }
}

/// The accounting double underline that marks a total.
struct DoubleRule: View {
    var color: Color = Ink.text
    var body: some View {
        VStack(spacing: 2) {
            Rectangle().fill(color).frame(height: 0.75)
            Rectangle().fill(color).frame(height: 0.75)
        }
        .accessibilityHidden(true)
    }
}

/// A thin progress line under a budget item. Overspent items show the overflow in seal red.
struct SpendRule: View {
    let progress: Double
    var overspent = false
    var tint: Color = Ink.primary

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Ink.track)
                Capsule().fill(overspent ? Ink.seal : tint)
                    .frame(width: max(overspent ? proxy.size.width : proxy.size.width * progress, progress > 0 ? 3 : 0))
            }
        }
        .frame(height: 3)
        .accessibilityHidden(true)
    }
}

/// A primary button styled like a stamped ink block.
struct InkButtonStyle: ButtonStyle {
    var prominent = true
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.semibold))
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity)
            .foregroundStyle(prominent ? Ink.onPrimary : Ink.primary)
            .background(prominent ? Ink.primary : Color.clear, in: .rect(cornerRadius: 14))
            .overlay {
                if !prominent { RoundedRectangle(cornerRadius: 14).strokeBorder(Ink.primary, lineWidth: 1.25) }
            }
            .opacity(configuration.isPressed ? 0.75 : 1)
    }
}
