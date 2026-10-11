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
                HStack(spacing: 10) {
                    Capsule().fill(Ink.rule).frame(width: 36, height: 5)
                        .frame(maxWidth: .infinity)
                        .overlay(alignment: .leading) {
                            Text(title)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(inMonth.isEmpty ? Ink.secondary : Ink.text)
                        }
                        .overlay(alignment: .trailing) {
                            Image(systemName: isExpanded ? "chevron.down" : "chevron.up")
                                .font(.footnote.weight(.bold))
                                .foregroundStyle(Ink.secondary)
                        }
                }
                .padding(.horizontal, 20)
                .padding(.top, 10)
                .padding(.bottom, isExpanded ? 6 : 12)
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
                                        TransactionSlip(transaction: transaction).frame(width: 150)
                                    }
                                    .accessibilityAddTraits(.isButton)
                                    .accessibilityHint("Double-tap to assign. Or drag it onto a budget item.")
                            }
                        }
                        .padding(.horizontal, 20)
                        .padding(.bottom, 12)
                    }
                    .scrollIndicators(.hidden)
                    .frame(height: 104)
                    Text("Drag onto a budget item, or tap to choose.")
                        .font(.caption2)
                        .foregroundStyle(Ink.secondary)
                        .padding(.bottom, 8)
                }
            }
        }
        .background {
            UnevenRoundedRectangle(topLeadingRadius: 22, topTrailingRadius: 22)
                .fill(Ink.sheet)
                .shadow(color: Ink.primary.opacity(0.12), radius: 10, y: -2)
                .ignoresSafeArea(edges: .bottom)
        }
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
            Text(transaction.date.formatted(.dateTime.month(.abbreviated).day()) + (transaction.isPending ? ", pending" : ""))
                .font(.caption)
                .foregroundStyle(Ink.secondary)
            Spacer(minLength: 0)
            Text((transaction.isIncome ? "+" : "−") + Money.format(transaction.amountCents))
                .font(Typeface.amount.weight(.semibold))
                .foregroundStyle(transaction.isIncome ? Ink.income : Ink.text)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(width: 150, height: 92, alignment: .leading)
        .background(Ink.paper, in: SlipShape())
        .overlay { SlipShape().stroke(Ink.rule, lineWidth: 1) }
        .contentShape(SlipShape())
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("slip-\(transaction.merchant)")
    }
}

/// A rounded stub with a row of perforation notches down its left edge.
nonisolated struct SlipShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path(roundedRect: rect, cornerRadius: 10)
        let notch: CGFloat = 3
        var y = rect.minY + 12
        while y < rect.maxY - 10 {
            path.addEllipse(in: CGRect(x: rect.minX - notch, y: y, width: notch * 2, height: notch * 2))
            y += 11
        }
        return path.normalized(eoFill: true)
    }
}
