import BetterDollarCore
import SwiftData
import SwiftUI

/// Add a transaction by hand, or edit one. Bank transactions keep their amount and date.
struct TransactionEditor: View {
    let transaction: LedgerTransaction?
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \BudgetMonth.key) private var months: [BudgetMonth]
    @Query(sort: \BankAccount.name) private var accounts: [BankAccount]

    @State private var isIncome = false
    @State private var cents = 0
    @State private var merchant = ""
    @State private var date = Date()
    @State private var note = ""
    @State private var account: BankAccount?
    @State private var item: BudgetItem?
    @State private var loaded = false
    @State private var isSplitting = false
    @State private var confirmingDelete = false

    private var isBank: Bool { transaction.map { $0.source != .manual } ?? false }
    private var month: BudgetMonth? { months.first { $0.key == MonthKey(date: date).id } }
    private var canSave: Bool { cents > 0 && !merchant.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Type", selection: $isIncome) {
                        Text("Expense").tag(false)
                        Text("Income").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .disabled(isBank)
                    MoneyField(title: "Amount", cents: $cents)
                        .disabled(isBank)
                    TextField(isIncome ? "From" : "Where", text: $merchant)
                        .accessibilityIdentifier("merchant")
                    DatePicker("Date", selection: $date, displayedComponents: .date)
                        .disabled(isBank)
                }
                if !isBank && !accounts.isEmpty {
                    Section {
                        Picker("Account", selection: $account) {
                            Text("None").tag(BankAccount?.none)
                            ForEach(accounts) { Text($0.displayName).tag(BankAccount?.some($0)) }
                        }
                    }
                }
                Section {
                    if let month {
                        Picker("Budget item", selection: $item) {
                            Text("Leave in the tray").tag(BudgetItem?.none)
                            ForEach(month.sortedGroups) { group in
                                Section(group.name) {
                                    ForEach(group.sortedItems) { Text($0.name).tag(BudgetItem?.some($0)) }
                                }
                            }
                        }
                        .accessibilityIdentifier("budget-item-picker")
                        if let transaction, transaction.isSplit {
                            Text("Split across \((transaction.allocations ?? []).count) items").foregroundStyle(Ink.secondary)
                        }
                        if transaction != nil {
                            Button("Split across items", systemImage: "arrow.triangle.branch") {
                                // Keep the other edits: the split works on the saved amount and date.
                                applyEdits(assigning: false)
                                isSplitting = true
                            }
                            .disabled(!canSave)
                        }
                    } else {
                        Text("There's no plan for \(MonthKey(date: date).monthName) yet, so this will wait in the tray.")
                            .foregroundStyle(Ink.secondary)
                    }
                    TextField("Note", text: $note, axis: .vertical)
                        .lineLimit(1...4)
                }
                if let transaction, transaction.bankCategory != nil || transaction.source != .manual {
                    Section {
                        LabeledContent("Source", value: transaction.source == .plaid ? "Bank (Plaid)" : "CSV import")
                        if let category = transaction.bankCategory {
                            LabeledContent("Bank's category", value: category.replacingOccurrences(of: "_", with: " ").capitalized)
                        }
                    }
                }
                if let transaction, transaction.status != .deleted {
                    Section {
                        Button("Delete transaction", role: .destructive) { confirmingDelete = true }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .paperBackground()
            .navigationTitle(transaction == nil ? "New transaction" : "Transaction")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save).disabled(!canSave)
                        .accessibilityIdentifier("save-transaction")
                }
            }
            .navigationDestination(isPresented: $isSplitting) {
                if let transaction, let month = months.first(where: { $0.key == MonthKey(date: transaction.date).id }) {
                    SplitEditor(transaction: transaction, month: month, onDone: { dismiss() })
                }
            }
            .confirmationDialog("Delete this transaction?", isPresented: $confirmingDelete, titleVisibility: .visible) {
                Button("Delete", role: .destructive) {
                    if let transaction { Ledger.delete(transaction, in: context) }
                    dismiss()
                }
            } message: {
                Text("It moves to Deleted, where you can restore it.")
            }
            .onAppear(perform: load)
        }
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        guard let transaction else { return }
        isIncome = transaction.isIncome
        cents = transaction.amountCents
        merchant = transaction.merchant
        date = transaction.date
        note = transaction.note
        account = transaction.account
        if !transaction.isSplit { item = transaction.allocations?.first?.item }
    }

    private func save() {
        applyEdits(assigning: true)
        dismiss()
    }

    /// Writes the form back to the transaction (creating it if new) and, if asked, applies the chosen budget item.
    @discardableResult
    private func applyEdits(assigning: Bool) -> LedgerTransaction {
        let name = merchant.trimmingCharacters(in: .whitespacesAndNewlines)
        let target: LedgerTransaction
        if let transaction {
            target = transaction
            if isBank && name != target.merchant { target.merchantEdited = true }
            target.merchant = name
            target.note = note
            if !isBank {
                let amountChanged = target.amountCents != cents || target.isIncome != isIncome
                let oldMonth = MonthKey(date: target.date)
                target.isIncome = isIncome
                target.amountCents = cents
                target.date = date
                target.account = account
                if amountChanged { Ledger.amountChanged(target, in: context) }
                Ledger.dateChanged(target, from: oldMonth, in: context)
            }
        } else {
            target = Ledger.addManual(date: date, amountCents: cents, isIncome: isIncome, merchant: name, note: note,
                                      account: account, in: context)
        }
        guard assigning else { return target }
        let targetMonth = MonthKey(date: target.date)
        let wasSplit = target.isSplit
        if let item {
            // If the date moved to another month, use the same item in that month's plan.
            let resolved = item.monthKey == targetMonth ? item
                : BudgetPlanner.month(targetMonth, in: context)?.allItems.first { $0.seriesID == item.seriesID }
            if let resolved, wasSplit || target.status != .tracked
                || target.allocations?.first?.item?.persistentModelID != resolved.persistentModelID {
                Ledger.assign(target, to: resolved, in: context)
            }
        } else if target.status == .tracked && !wasSplit {
            // The user cleared the budget item: back to the tray.
            Ledger.unassign(target, in: context)
        }
        return target
    }
}
