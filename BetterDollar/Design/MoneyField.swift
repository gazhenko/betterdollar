import BetterDollarCore
import SwiftUI

/// A decimal-pad text field bound to whole cents.
struct MoneyField: View {
    let title: String
    @Binding var cents: Int
    var prompt = "0.00"

    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack {
            Text(title)
                .foregroundStyle(Ink.text)
            Spacer()
            HStack(spacing: 2) {
                Text("$").foregroundStyle(Ink.secondary)
                TextField(prompt, text: $text)
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
                    .focused($focused)
                    .frame(minWidth: 70, maxWidth: 140)
                    .accessibilityLabel(title)
            }
            .font(Typeface.amount)
        }
        .onAppear { text = Money.editableText(cents) }
        .onChange(of: text) { _, value in
            let parsed = Money.parse(value) ?? 0
            if parsed != cents { cents = max(0, parsed) }
        }
        .onChange(of: cents) { _, value in
            if !focused { text = Money.editableText(value) }
        }
    }
}
