import BetterDollarCore
import SwiftUI
import UIKit

/// BetterDollar's look comes from the banknote. The page is currency stock, a cool cotton gray-green rather than white.
/// Text is the black of a note's face. The one solid color is the green of its back, kept for the plate and for actions.
/// Red is the overprinted Treasury seal, reserved for overspending.
nonisolated enum Ink {
    static let paper = dynamic(light: 0xE9ECE0, dark: 0x0D1A15)
    /// Loose paper lying on the page: slips, notices, sheets and form rows.
    static let sheet = dynamic(light: 0xF6F7F1, dark: 0x13231C)
    static let primary = dynamic(light: 0x1F4D3A, dark: 0x9CC8AE)
    static let text = dynamic(light: 0x16201B, dark: 0xE4ECE7)
    static let secondary = dynamic(light: 0x55615A, dark: 0x93A39A)
    static let rule = dynamic(light: 0xC6CCBD, dark: 0x274036)
    static let track = dynamic(light: 0xD8DCCF, dark: 0x1D3029)
    static let seal = dynamic(light: 0xB3362C, dark: 0xF07A6E)
    static let income = dynamic(light: 0x2E6B4A, dark: 0x8FD3A6)
    /// Text drawn on top of `primary`.
    static let onPrimary = dynamic(light: 0xEDF0E4, dark: 0x0D1A15)
    /// The greenback: the solid field of an engraved plate. The same printing in both appearances.
    static let plate = dynamic(light: 0x1F4D3A, dark: 0x1A4231)
    /// Stock showing through the plate: its figure, copy and line work.
    static let onPlate = Color(UIColor(hex: 0xEDF0E4))
    /// The darker green that shades engraved lettering on the plate.
    static let plateShade = Color(UIColor(hex: 0x0C241A))

    /// SwiftUI resolves colors on its render thread too (for example during a drag), so this must not be main-actor isolated.
    static func dynamic(light: UInt32, dark: UInt32) -> Color {
        Color(UIColor { @Sendable traits in traits.userInterfaceStyle == .dark ? UIColor(hex: dark) : UIColor(hex: light) })
    }
}

/// The two printings of a plate: the greenback, and the pale red-seal note it becomes when something is short.
struct PlateInk {
    let alarm: Bool
    var ground: Color { alarm ? Ink.sheet : Ink.plate }
    var lines: Color { alarm ? Ink.seal : Ink.onPlate }
    var text: Color { alarm ? Ink.text : Ink.onPlate }
    var secondary: Color { alarm ? Ink.secondary : Ink.onPlate.opacity(0.74) }
    var track: Color { alarm ? Ink.track : Ink.onPlate.opacity(0.24) }
    /// Ink for a figure that isn't itself in the red.
    var figure: Color { alarm ? Ink.primary : Ink.onPlate }
    func shade(for figure: Color) -> Color { alarm ? figure.opacity(0.38) : Ink.plateShade }
}

extension UIColor {
    nonisolated convenience init(hex: UInt32) {
        self.init(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}

/// Type has two families. New York (serif) sets the headings, like the lettering on a ledger page.
/// SF Pro does everything else, and at its expanded width and heaviest weights it sets the denominations:
/// headline amounts drawn wide, as the numerals in the corners of a note are.
enum Typeface {
    static func title(_ size: CGFloat = 28) -> Font { .system(size: size, weight: .semibold, design: .serif) }
    static let groupTitle = Font.system(size: 19, weight: .semibold, design: .serif)
    /// Wider than standard, short of fully expanded: at full width a heavy zero is a circle and "$0.00" reads as a letter.
    static let figureWidth = Font.Width(0.05)
    static func figure(_ size: CGFloat, weight: Font.Weight = .bold) -> Font { .system(size: size, weight: weight).width(Typeface.figureWidth) }
    static let amount = Font.system(size: 16, weight: .medium).monospacedDigit()
    static let amountSmall = Font.system(size: 13, weight: .regular).monospacedDigit()

    /// System navigation bars take the same ink and serif as the screens that draw their own titles.
    @MainActor static func styleSystemControls() {
        func serif(_ size: CGFloat) -> UIFont {
            let base = UIFont.systemFont(ofSize: size, weight: .semibold)
            return UIFont(descriptor: base.fontDescriptor.withDesign(.serif) ?? base.fontDescriptor, size: size)
        }
        let text = UIColor(Ink.text)
        let bar = UINavigationBar.appearance()
        bar.largeTitleTextAttributes = [.font: serif(34), .foregroundColor: text]
        bar.titleTextAttributes = [.font: serif(17), .foregroundColor: text]
    }
}

/// Shared measurements. Paper has crisp corners: the plate, slips and notices are cut sheets, not soft cards.
/// Controls the system draws in glass keep their own roundness.
enum Layout {
    /// Side margin for screens that draw their own content; matches the inset of system lists.
    static let margin: CGFloat = 16
    static let cardRadius: CGFloat = 6
    static let plateRadius: CGFloat = 6
}

extension View {
    func paperBackground() -> some View {
        background(Ink.paper.ignoresSafeArea())
    }

    /// Loose paper on the page: a notice, a statement. Budget and list content is printed on the page itself and doesn't use this.
    /// `edge` changes only to flag a problem.
    func card(radius: CGFloat = Layout.cardRadius, edge: Color = Ink.rule) -> some View {
        background(Ink.sheet, in: .rect(cornerRadius: radius))
            .overlay { RoundedRectangle(cornerRadius: radius).strokeBorder(edge, lineWidth: 0.75) }
    }

    /// The note behind a headline figure, and the one solid block of color in the app.
    /// Lathe work in the top trailing corner is faint until `completion` inks it in; a `framed` plate
    /// gets the second border line of a finished one.
    func engravedPlate(completion: Double, ink: PlateInk = PlateInk(alarm: false), framed: Bool = false,
                       rosetteRadius: CGFloat = 100, animates: Bool = true) -> some View {
        background {
            Guilloche(completion: completion, color: ink.lines, strength: ink.alarm ? 1 : 1.5, rosetteRadius: rosetteRadius)
                .mask(LinearGradient(stops: [.init(color: .black.opacity(0.3), location: 0),
                                             .init(color: .black.opacity(0.65), location: 0.5),
                                             .init(color: .black, location: 0.85)],
                                     startPoint: .leading, endPoint: .trailing))
                .animation(animates ? .easeInOut(duration: 1.1) : nil, value: completion)
        }
        .background(ink.ground)
        .clipShape(.rect(cornerRadius: Layout.plateRadius))
        .overlay {
            // Every note has a border line inside its edge.
            RoundedRectangle(cornerRadius: 3).strokeBorder(ink.lines.opacity(framed ? 0.8 : 0.45), lineWidth: 0.75).padding(5)
        }
        .overlay {
            if framed { RoundedRectangle(cornerRadius: 2).strokeBorder(ink.lines.opacity(0.45), lineWidth: 0.5).padding(8) }
        }
        .overlay {
            if ink.alarm { RoundedRectangle(cornerRadius: Layout.plateRadius).strokeBorder(Ink.seal.opacity(0.55), lineWidth: 1) }
        }
    }

    /// Screens without a navigation bar: keeps scrolled content from showing through the status bar.
    func statusBarShield() -> some View {
        safeAreaInset(edge: .top, spacing: 0) {
            Color.clear.frame(height: 0).background(Ink.paper.ignoresSafeArea(edges: .top))
        }
    }
}

/// A form printed on the page: ruled lines under each row, no rounded groups and none of the system's white or gray.
struct LedgerForm<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        Form {
            Group { content }
                // Rows fill the measure so the rules between them run margin to margin, like the lines of the budget.
                .frame(maxWidth: .infinity, alignment: .leading)
                .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] }
                .alignmentGuide(.listRowSeparatorTrailing) { $0[.trailing] }
                .listRowBackground(Color.clear)
                .listRowSeparatorTint(Ink.rule)
                .listRowInsets(.horizontal, 0)
        }
        .listStyle(.grouped)
        .scrollContentBackground(.hidden)
        .paperBackground()
    }
}

/// A section heading in a `LedgerForm`: serif over an ink rule, the way the budget's groups are headed.
struct LedgerHeading: View {
    let title: String
    init(_ title: String) { self.title = title }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(Typeface.groupTitle)
                .foregroundStyle(Ink.text)
                .textCase(nil)
                .accessibilityAddTraits(.isHeader)
            Rectangle().fill(Ink.text).frame(height: 1.5)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 10)
    }
}

extension Section where Parent == LedgerHeading, Content: View, Footer == EmptyView {
    /// A form section under a ledger heading.
    init(ledger title: String, @ViewBuilder content: () -> Content) {
        self.init(content: content, header: { LedgerHeading(title) })
    }
}

/// The heading every tab opens with: a serif title, a line of context under it, and round actions on the right.
struct ScreenHeader<Subtitle: View, Actions: View>: View {
    let title: String
    @ViewBuilder var subtitle: Subtitle
    @ViewBuilder var actions: Actions

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 0) {
                Text(title)
                    .font(Typeface.title(34))
                    .foregroundStyle(Ink.text)
                    .accessibilityAddTraits(.isHeader)
                subtitle
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Ink.secondary)
            }
            Spacer(minLength: 8)
            HStack(spacing: 8) { actions }
                .padding(.top, 4)
        }
        .padding(.top, 8)
    }
}

extension ScreenHeader where Subtitle == EmptyView {
    init(title: String, @ViewBuilder actions: () -> Actions) {
        self.init(title: title, subtitle: { EmptyView() }, actions: actions)
    }
}

extension ScreenHeader where Subtitle == EmptyView, Actions == EmptyView {
    init(title: String) {
        self.init(title: title, subtitle: { EmptyView() }, actions: { EmptyView() })
    }
}

/// A switch between a few views of the same thing, printed on the page like the tabs of a ledger:
/// names on a rule, with the chosen one underlined in ink.
struct LedgerTabs<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [(value: Value, title: String)]
    @Namespace private var mark

    var body: some View {
        HStack(spacing: 0) {
            ForEach(options, id: \.value) { option in
                let isOn = option.value == selection
                Button { selection = option.value } label: {
                    Text(option.title)
                        .font(.subheadline.weight(isOn ? .semibold : .regular))
                        .foregroundStyle(isOn ? Ink.text : Ink.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .padding(.horizontal, 2)
                        .frame(maxWidth: .infinity, minHeight: 38)
                        .overlay(alignment: .bottom) {
                            if isOn { Rectangle().fill(Ink.text).frame(height: 2).matchedGeometryEffect(id: "mark", in: mark) }
                        }
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isOn ? .isSelected : [])
            }
        }
        .background(alignment: .bottom) { Rectangle().fill(Ink.rule).frame(height: 0.75) }
        .animation(.snappy(duration: 0.25), value: selection)
        .sensoryFeedback(.selection, trigger: selection)
        .accessibilityElement(children: .contain)
    }
}

/// A round button for a screen header: an ink glyph on a small sheet.
struct HeaderButtonLabel: View {
    let systemImage: String

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(Ink.primary)
            .frame(width: 38, height: 38)
            .background(Ink.sheet, in: .circle)
            .overlay { Circle().strokeBorder(Ink.rule, lineWidth: 0.75) }
            .contentShape(.circle)
    }
}

/// A headline amount set as a denomination: wide, heavy numerals with a raised dollar sign and the cents stepped down.
/// On a plate it gets a `shade`: the line-ruled drop shadow engravers give the lettering on a note.
struct MoneyFigure: View {
    let cents: Int
    var size: CGFloat = 40
    var weight: Font.Weight = .heavy
    var showsCents = true
    var color: Color = Ink.text
    var shade: Color?

    var body: some View {
        lettering
            .foregroundStyle(color)
            .background {
                if let shade {
                    EngraverShade(color: shade, pitch: max(1.5, size * 0.055))
                        .mask { lettering }
                        .offset(x: size * 0.065, y: size * 0.065)
                        .accessibilityHidden(true)
                }
            }
            .accessibilityLabel(Money.format(cents, showsCents: showsCents))
    }

    private var lettering: some View {
        let full = Money.format(cents, showsCents: showsCents)
        let digits = full.drop { $0 == "-" || $0 == "$" }.split(separator: ".", maxSplits: 1)
        let small = Typeface.figure(size * 0.5, weight: weight)
        let sign = Text((cents < 0 ? "−" : "") + "$").font(small).baselineOffset(size * 0.33)
        let fraction = Text(digits.count > 1 ? "." + digits[1] : "").font(small).baselineOffset(size * 0.33)
        return Text("\(sign)\(Text(String(digits.first ?? "0")))\(fraction)")
            .font(Typeface.figure(size, weight: weight))
            .lineLimit(1)
            .minimumScaleFactor(0.6)
            .contentTransition(.numericText(value: Double(cents)))
    }
}

/// Fine horizontal ruling, the way an engraver builds a tone out of lines.
struct EngraverShade: View {
    let color: Color
    var pitch: CGFloat = 2

    var body: some View {
        Canvas { context, size in
            var lines = Path()
            var y: CGFloat = 0
            while y < size.height {
                lines.addRect(CGRect(x: 0, y: y, width: size.width, height: pitch * 0.5))
                y += pitch
            }
            context.fill(lines, with: .color(color))
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

/// A thin progress line: under a budget item, and as the meters on Insights. Overspending fills it in seal red.
struct SpendRule: View {
    let progress: Double
    var overspent = false
    var tint: Color = Ink.primary
    /// How far through the month it is. A tick marks where spending would be at an even pace,
    /// so a fill past it is ahead of pace.
    var pace: Double?
    var height: CGFloat = 3
    var track: Color = Ink.track

    var body: some View {
        Capsule().fill(track)
            .overlay(alignment: .leading) {
                GeometryReader { proxy in
                    let fraction = overspent ? 1 : min(1, max(0, progress))
                    Capsule().fill(overspent ? Ink.seal : tint)
                        .frame(width: max(proxy.size.width * fraction, progress > 0 ? height : 0))
                }
            }
            .overlay(alignment: .leading) {
                if let pace {
                    GeometryReader { proxy in
                        // Taller than the line, so it stays visible whether the fill has reached it or not.
                        Capsule().fill(Ink.text)
                            .frame(width: 1.5, height: height + 6)
                            .offset(x: min(max(0, proxy.size.width * pace - 0.75), proxy.size.width - 1.5), y: -3)
                    }
                }
            }
            .frame(height: height)
            .accessibilityHidden(true)
    }
}

/// A primary button styled like a stamped ink block. On a plate it is stamped out of the stock instead.
struct InkButtonStyle: ButtonStyle {
    var prominent = true
    var onPlate = false
    func makeBody(configuration: Configuration) -> some View {
        let ink = onPlate ? Ink.onPlate : Ink.primary
        configuration.label
            .font(.body.weight(.semibold))
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity)
            .foregroundStyle(prominent ? (onPlate ? Ink.plate : Ink.onPrimary) : ink)
            .background(prominent ? ink : Color.clear, in: .rect(cornerRadius: Layout.cardRadius))
            .overlay {
                if !prominent { RoundedRectangle(cornerRadius: Layout.cardRadius).strokeBorder(ink, lineWidth: 1.25) }
            }
            .opacity(configuration.isPressed ? 0.75 : 1)
    }
}
