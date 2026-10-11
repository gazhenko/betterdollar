import BetterDollarCore
import SwiftData
import SwiftUI

/// Pick the budget item for a transaction, or split it across several.
/// The suggestion is only a hint from your own history; nothing is assigned until you tap.
struct AssignSheet: View {
    let transaction: LedgerTransaction
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \BudgetMonth.key) private var months: [BudgetMonth]
    @State private var search = ""
    @State private var isSplitting = false

    private var key: MonthKey { MonthKey(date: transaction.date) }
    private var month: BudgetMonth? { months.first { $0.key == key.id } }

    var body: some View {
        NavigationStack {
            Group {
                if let month {
                    picker(month)
                } else {
                    ContentUnavailableView {
                        Label("No plan for \(key.monthName)", systemImage: "calendar.badge.plus")
                    } description: {
                        Text("Plan \(key.title) on the Budget tab, then assign this transaction.")
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .paperBackground()
            .navigationTitle("Assign")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                if month != nil {
                    ToolbarItem(placement: .primaryAction) {
                        Button("Split", systemImage: "arrow.triangle.branch") { isSplitting = true }
                            .accessibilityIdentifier("split")
                    }
                }
            }
            .navigationDestination(isPresented: $isSplitting) {
                if let month { SplitEditor(transaction: transaction, month: month, onDone: { dismiss() }) }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func picker(_ month: BudgetMonth) -> some View {
        let funds = FundLedger(months: months)
        let suggestion = Ledger.suggestedItem(for: transaction, in: month, context: context)
        let groups = transaction.isIncome
            ? month.sortedGroups.sorted { $0.isIncome && !$1.isIncome }
            : month.sortedGroups.sorted { !$0.isIncome && $1.isIncome }
        return List {
            Section {
                TransactionRow(transaction: transaction)
            }
            if let suggestion, search.isEmpty {
                Section("Last time") {
                    itemButton(suggestion, funds: funds)
                }
            }
            ForEach(groups) { group in
                let items = group.sortedItems.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) }
                if !items.isEmpty {
                    Section(group.name) {
                        ForEach(items) { itemButton($0, funds: funds) }
                    }
                }
            }
        }
        .searchable(text: $search, prompt: "Find a budget item")
    }

    private func itemButton(_ item: BudgetItem, funds: FundLedger) -> some View {
        let totals = BudgetMath.totals(for: item, funds: funds)
        let isCurrent = (transaction.allocations ?? []).contains { $0.item?.persistentModelID == item.persistentModelID }
        return Button {
            withAnimation { Ledger.assign(transaction, to: item, in: context) }
            dismiss()
        } label: {
            HStack {
                Text(item.name).foregroundStyle(Ink.text)
                if isCurrent { Image(systemName: "checkmark").foregroundStyle(Ink.primary).accessibilityLabel("Current") }
                Spacer()
                VStack(alignment: .trailing, spacing: 1) {
                    AmountText(cents: totals.remainingCents, font: Typeface.amountSmall, flagsNegative: !item.isIncomeItem, color: Ink.secondary)
                    Text(item.isIncomeItem ? "to receive" : "left").font(.caption2).foregroundStyle(Ink.secondary)
                }
            }
            .contentShape(.rect)
        }
        .accessibilityIdentifier("assign-\(item.name)")
    }
}

/// Divide a transaction across budget items; Save unlocks when it adds up exactly.
struct SplitEditor: View {
    let transaction: LedgerTransaction
    let month: BudgetMonth
    let onDone: () -> Void
    @Environment(\.modelContext) private var context

    struct Part: Identifiable {
        let id = UUID()
        var item: BudgetItem?
        var cents: Int
    }
    @State private var parts: [Part] = []
    @State private var error: String?

    private var remaining: Int { transaction.amountCents - parts.reduce(0) { $0 + $1.cents } }
    private var canSave: Bool { remaining == 0 && parts.filter { $0.cents > 0 }.allSatisfy { $0.item != nil } && parts.contains { $0.cents > 0 } }

    var body: some View {
        Form {
            Section {
                TransactionRow(transaction: transaction)
            }
            ForEach($parts) { $part in
                Section {
                    Menu {
                        ForEach(month.sortedGroups) { group in
                            Section(group.name) {
                                ForEach(group.sortedItems) { item in
                                    Button(item.name) { part.item = item }
                                }
                            }
                        }
                    } label: {
                        HStack {
                            Text(part.item?.name ?? "Choose a budget item")
                                .foregroundStyle(part.item == nil ? Ink.secondary : Ink.text)
                            Spacer()
                            Image(systemName: "chevron.up.chevron.down").font(.footnote).foregroundStyle(Ink.secondary)
                        }
                    }
                    MoneyField(title: "Amount", cents: $part.cents)
                }
            }
            .onDelete { parts.remove(atOffsets: $0) }

            Section {
                Button("Add another item", systemImage: "plus") {
                    parts.append(Part(item: nil, cents: max(0, remaining)))
                }
            } footer: {
                Text(remaining == 0 ? "Splits add up to \(Money.format(transaction.amountCents))."
                     : remaining > 0 ? "\(Money.format(remaining)) left to split." : "\(Money.format(-remaining)) too much.")
                    .foregroundStyle(remaining < 0 ? Ink.seal : Ink.secondary)
            }
            if let error {
                Text(error).foregroundStyle(Ink.seal)
            }
        }
        .scrollContentBackground(.hidden)
        .paperBackground()
        .navigationTitle("Split")
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    do {
                        try Ledger.split(transaction, into: parts.compactMap { part in part.item.map { (item: $0, amountCents: part.cents) } },
                                         in: context)
                        onDone()
                    } catch {
                        self.error = error.localizedDescription
                    }
                }
                .disabled(!canSave)
            }
        }
        .onAppear {
            guard parts.isEmpty else { return }
            let existing = (transaction.allocations ?? []).compactMap { allocation in
                allocation.item.map { Part(item: $0, cents: allocation.amountCents) }
            }
            parts = existing.isEmpty ? [Part(item: nil, cents: transaction.amountCents), Part(item: nil, cents: 0)] : existing
        }
    }
}
