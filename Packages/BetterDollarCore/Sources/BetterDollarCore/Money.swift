import Foundation

/// Money is stored as whole cents in an `Int` so budget math never drifts.
public enum Money {
    /// "$1,234.56", or "-$12.00" for negative values.
    public static func format(_ cents: Int, showsCents: Bool = true, currencyCode: String = "USD") -> String {
        let style = Decimal.FormatStyle.Currency(code: currencyCode, locale: Locale(identifier: "en_US"))
            .precision(.fractionLength(showsCents ? 2 : 0))
        return decimal(cents).formatted(style)
    }

    /// Compact form for tight layouts: "$1.2k", "$842".
    public static func compact(_ cents: Int) -> String {
        let dollars = Double(cents) / 100
        let sign = dollars < 0 ? "-" : ""
        let magnitude = abs(dollars)
        if magnitude >= 10_000 { return "\(sign)$\(Int((magnitude / 1000).rounded()))k" }
        if magnitude >= 1_000 { return "\(sign)$\(String(format: "%.1f", magnitude / 1000))k" }
        return "\(sign)$\(Int(magnitude.rounded()))"
    }

    /// Plain editable text without a currency symbol: "1234.50".
    public static func editableText(_ cents: Int) -> String {
        guard cents != 0 else { return "" }
        let whole = abs(cents) / 100, fraction = abs(cents) % 100
        return (cents < 0 ? "-" : "") + (fraction == 0 ? "\(whole)" : String(format: "%d.%02d", whole, fraction))
    }

    /// Parses user or bank text such as "$1,234.5", "(12.00)", "-3" into cents.
    public static func parse(_ text: String) -> Int? {
        var cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return nil }
        var negative = false
        if cleaned.hasPrefix("(") && cleaned.hasSuffix(")") {
            negative = true
            cleaned = String(cleaned.dropFirst().dropLast())
        }
        cleaned = cleaned.replacingOccurrences(of: "$", with: "")
            .replacingOccurrences(of: ",", with: "")
            .replacingOccurrences(of: " ", with: "")
        if cleaned.hasPrefix("-") { negative.toggle(); cleaned.removeFirst() }
        if cleaned.hasPrefix("+") { cleaned.removeFirst() }
        guard !cleaned.isEmpty, cleaned.allSatisfy({ $0.isNumber || $0 == "." }),
              cleaned.filter({ $0 == "." }).count <= 1,
              let value = Decimal(string: cleaned, locale: Locale(identifier: "en_US")) else { return nil }
        let cents = cents(from: value)
        return negative ? -cents : cents
    }

    public static func cents(from value: Decimal) -> Int {
        var scaled = value * 100, rounded = Decimal()
        NSDecimalRound(&rounded, &scaled, 0, .plain)
        return NSDecimalNumber(decimal: rounded).intValue
    }

    public static func decimal(_ cents: Int) -> Decimal { Decimal(cents) / 100 }
}
