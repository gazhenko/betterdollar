import BetterDollarCore
import SwiftData
import SwiftUI

/// EveryDollar-style tray of new transactions. Drag a slip onto a budget item to assign it,
/// or tap it to pick an item or split it.
struct TransactionTray: View {
    let month: MonthKey
    let onSelect: (LedgerTransaction) -> Void

    @Environment(AppModel.self) private var app
    @Query(filter: #Predicate<LedgerTransaction> { $0.statusRaw == "new" }, sort: \LedgerTransaction.date, order: .reverse)
    private var newTransactions: [LedgerTransaction]
    @AppStorage("trayExpanded") private var isExpanded = true

    private var inMonth: [LedgerTransaction] { newTransactions.filter { month.contains($0.date) } }
    private var elsewhere: Int { newTransactions.count - inMonth.count }

    var body: some View {
        VStack(spacing: 0) {
            Button {
                withAnimation(.snappy) { isExpanded.toggle() }
            } label: {
                HStack(spacing: 8) {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(inMonth.isEmpty ? Ink.secondary : Ink.text)
                    Spacer()
                    if !inMonth.isEmpty {
                        Text(isExpanded ? "Drag or tap to assign" : nextUp)
                            .font(.caption)
                            .foregroundStyle(Ink.secondary)
                            .lineLimit(1)
                    }
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.up")
                        .font(.footnote.weight(.bold))
                        .foregroundStyle(Ink.secondary)
                }
                .padding(.horizontal, Layout.margin + 4)
                .padding(.top, 12)
                .padding(.bottom, isExpanded ? 8 : 12)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(title)
            .accessibilityHint(isExpanded ? "Collapses the tray" : "Shows transactions to assign")
            .accessibilityIdentifier("tray-toggle")

            if isExpanded {
                if inMonth.isEmpty {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.seal")
                        Text(elsewhere > 0 ? "Nothing new in \(month.monthName). \(elsewhere) waiting in other months." :
                                "All caught up. Every transaction has a home.")
                    }
                    .font(.footnote)
                    .foregroundStyle(Ink.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.bottom, 14)
                    .onTapGesture { if elsewhere > 0 { app.tab = .transactions } }
                } else {
                    ScrollView(.horizontal) {
                        LazyHStack(spacing: 10) {
                            ForEach(inMonth) { transaction in
                                TransactionSlip(transaction: transaction)
                                    .onTapGesture { onSelect(transaction) }
                                    .draggable(transaction.uuid.uuidString) {
                                        TransactionSlip(transaction: transaction).frame(width: 168)
                                    }
                                    .accessibilityAddTraits(.isButton)
                                    .accessibilityHint("Double-tap to assign. Or drag it onto a budget item.")
                            }
                        }
                        .padding(.horizontal, Layout.margin)
                        .padding(.bottom, 10)
                    }
                    .scrollIndicators(.hidden)
                    .frame(height: 74)
                }
            }
        }
        .background {
            UnevenRoundedRectangle(topLeadingRadius: Layout.plateRadius, topTrailingRadius: Layout.plateRadius)
                .fill(Ink.sheet)
                .overlay { UnevenRoundedRectangle(topLeadingRadius: Layout.plateRadius, topTrailingRadius: Layout.plateRadius).strokeBorder(Ink.rule, lineWidth: 0.75) }
                .shadow(color: Ink.text.opacity(0.08), radius: 12, y: -3)
                .ignoresSafeArea(edges: .bottom)
        }
    }

    /// The collapsed tray names the newest transaction, so there's something to act on without opening it.
    private var nextUp: String {
        guard let first = inMonth.first else { return "" }
        return "\(first.merchant), \(Money.format(first.amountCents))"
    }

    private var title: String {
        switch inMonth.count {
        case 0: "No new transactions"
        case 1: "1 new transaction"
        default: "\(inMonth.count) new transactions"
        }
    }
}

/// A transaction drawn like a receipt stub with a perforated edge.
struct TransactionSlip: View {
    let transaction: LedgerTransaction

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(transaction.merchant)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Ink.text)
                .lineLimit(1)
            Spacer(minLength: 0)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text((transaction.isIncome ? "+" : "−") + Money.format(transaction.amountCents))
                    .font(Typeface.amount.weight(.semibold))
                    .foregroundStyle(transaction.isIncome ? Ink.income : Ink.text)
                    .layoutPriority(1)
                Spacer(minLength: 0)
                Text(transaction.date.formatted(.dateTime.month(.abbreviated).day()) + (transaction.isPending ? ", pending" : ""))
                    .font(.caption)
                    .foregroundStyle(Ink.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.leading, 16)
        .padding(.trailing, 12)
        .padding(.vertical, 9)
        .frame(width: 168, height: 64, alignment: .leading)
        .background(Ink.paper, in: SlipShape())
        .overlay { SlipShape().stroke(Ink.rule, lineWidth: 1) }
        .contentShape(SlipShape())
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("slip-\(transaction.merchant)")
    }
}

/// A rounded stub torn off along its left edge: a row of half-round bites where the perforation was.
nonisolated struct SlipShape: Shape {
    func path(in rect: CGRect) -> Path {
        let notch: CGFloat = 2.5, pitch: CGFloat = 9
        let count = max(0, Int((rect.height - 20) / pitch))
        var bites = Path()
        // Centered down the edge, clear of the rounded corners.
        var y = rect.midY - CGFloat(count - 1) * pitch / 2
        for _ in 0..<count {
            bites.addEllipse(in: CGRect(x: rect.minX - notch, y: y - notch, width: notch * 2, height: notch * 2))
            y += pitch
        }
        return Path(roundedRect: rect, cornerRadius: 4).subtracting(bites)
    }
}
