import BetterDollarCore
import SwiftUI

struct TransactionRow: View {
    let transaction: LedgerTransaction
    /// For split transactions shown under one item: that item's share.
    var highlightAmount: Int?
    /// Lists grouped by day already show the date.
    var showsDate = true

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(transaction.merchant.isEmpty ? "Untitled" : transaction.merchant)
                    .font(.body.weight(.medium))
                    .foregroundStyle(Ink.text)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(transaction.status == .new ? Ink.primary : Ink.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 2) {
                Text((transaction.isIncome ? "+" : "−") + Money.format(highlightAmount ?? transaction.amountCents))
                    .font(Typeface.amount)
                    .foregroundStyle(transaction.isIncome ? Ink.income : Ink.text)
                if let highlightAmount, highlightAmount != transaction.amountCents {
                    Text("of \(Money.format(transaction.amountCents))").font(.caption2).foregroundStyle(Ink.secondary)
                } else if transaction.isPending {
                    Text("Pending").font(.caption2).foregroundStyle(Ink.secondary)
                }
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    private var subtitle: String {
        var parts: [String] = showsDate ? [transaction.date.formatted(.dateTime.month(.abbreviated).day())] : []
        switch transaction.status {
        case .new: parts.append("Not assigned")
        case .deleted: parts.append("Deleted")
        case .tracked:
            let names = (transaction.allocations ?? []).compactMap { $0.item?.name }
            parts.append(names.count > 1 ? "Split: " + names.joined(separator: ", ") : names.first ?? "Assigned")
        }
        if let account = transaction.account { parts.append(account.displayName) }
        return parts.joined(separator: ", ")
    }
}
