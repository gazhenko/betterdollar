import BetterDollarCore
import SwiftData
import SwiftUI

/// Edit one budget item: its plan, fund settings, due date, note and the transactions assigned to it.
struct ItemDetailView: View {
    @Bindable var item: BudgetItem
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \BudgetMonth.key) private var months: [BudgetMonth]
    @State private var confirmingDelete = false
    @State private var editing: LedgerTransaction?

    var body: some View {
        let funds = FundLedger(months: months)
        let totals = BudgetMath.totals(for: item, funds: funds)
        let isFirstInSeries = funds.history(for: item).first?.month == item.monthKey || funds.history(for: item).isEmpty
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $item.name)
                        .font(.title3.weight(.semibold))
                    MoneyField(title: item.isIncomeItem ? "Expected this month" : "Planned this month", cents: $item.plannedCents)
                } footer: {
                    summary(totals)
                }

                if !item.isIncomeItem {
                    Section {
                        Toggle("Fund (keeps its balance)", isOn: Binding(
                            get: { item.isFund },
                            set: { BudgetPlanner.setFund(item, $0, in: context) }
                        ).animation())
                        if item.isFund {
                            if isFirstInSeries {
                                MoneyField(title: "Starting balance", cents: $item.fundStartingCents)
                            }
                            MoneyField(title: "Goal", cents: $item.fundGoalCents)
                            Toggle("Target date", isOn: Binding(
                                get: { item.fundTargetDate != nil },
                                set: { item.fundTargetDate = $0 ? (item.fundTargetDate ?? Calendar.current.date(byAdding: .month, value: 6, to: .now)) : nil }
                            ).animation())
                            if let target = item.fundTargetDate {
                                DatePicker("Reach it by", selection: Binding(get: { target }, set: { item.fundTargetDate = $0 }),
                                           in: Date()..., displayedComponents: .date)
                            }
                        }
                    } footer: {
                        if item.isFund { fundFooter(totals: totals) } else {
                            Text("Funds are for saving up over several months, like car repairs or a vacation. What you don't spend stays in the fund.")
                        }
                    }
                }

                Section {
                    Picker("Due", selection: $item.dueDay) {
                        Text("No due date").tag(0)
                        ForEach(1...31, id: \.self) { Text("The \(ordinal($0))").tag($0) }
                    }
                    TextField("Note", text: $item.note, axis: .vertical)
                        .lineLimit(1...4)
                }

                Section(item.monthKey.map { "Transactions in \($0.monthName)" } ?? "Transactions") {
                    let assigned = (item.allocations ?? []).filter { $0.transaction?.status == .tracked }
                        .sorted { ($0.transaction?.date ?? .distantPast) > ($1.transaction?.date ?? .distantPast) }
                    if assigned.isEmpty {
                        Text("Nothing assigned yet. Drag a transaction from the tray onto this item.")
                            .font(.callout)
                            .foregroundStyle(Ink.secondary)
                    }
                    ForEach(assigned) { allocation in
                        if let transaction = allocation.transaction {
                            Button { editing = transaction } label: {
                                TransactionRow(transaction: transaction, highlightAmount: transaction.isSplit ? allocation.amountCents : nil)
                            }
                            .buttonStyle(.plain)
                            .swipeActions {
                                Button("Unassign", systemImage: "tray.and.arrow.up") {
                                    withAnimation { Ledger.unassign(transaction, in: context) }
                                }
                                .tint(Ink.primary)
                            }
                        }
                    }
                }

                Section {
                    Button("Delete \(item.name)", role: .destructive) { confirmingDelete = true }
                }
            }
            .scrollContentBackground(.hidden)
            .paperBackground()
            .navigationTitle(item.isIncomeItem ? "Income" : (item.group?.name ?? "Item"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .confirmationDialog("Delete \(item.name)?", isPresented: $confirmingDelete, titleVisibility: .visible) {
                Button("Delete item", role: .destructive) {
                    BudgetPlanner.delete(item, in: context)
                    dismiss()
                }
            } message: {
                Text("Its transactions go back to your tray. Other months keep their own copy of this item.")
            }
            .sheet(item: $editing) { TransactionEditor(transaction: $0) }
        }
    }

    @ViewBuilder private func summary(_ totals: ItemTotals) -> some View {
        let verb = item.isIncomeItem ? "received" : "spent"
        if item.isFund {
            Text("\(Money.format(totals.carryInCents)) carried in, \(Money.format(totals.activityCents)) \(verb), \(Money.format(totals.remainingCents)) available.")
        } else if item.isIncomeItem {
            Text("\(Money.format(totals.activityCents)) received, \(Money.format(max(0, totals.remainingCents))) still to come.")
        } else {
            Text(totals.isOverspent
                 ? "\(Money.format(totals.activityCents)) spent, \(Money.format(-totals.remainingCents)) over plan."
                 : "\(Money.format(totals.activityCents)) spent, \(Money.format(totals.remainingCents)) left.")
        }
    }

    @ViewBuilder private func fundFooter(totals: ItemTotals) -> some View {
        if let key = item.monthKey, item.fundGoalCents > 0,
           let monthly = BudgetMath.monthlyToReachGoal(balanceCents: totals.carryInCents, goalCents: item.fundGoalCents,
                                                       from: key, target: item.fundTargetDate) {
            Text(monthly == 0 ? "You've reached this goal." : "Plan \(Money.format(monthly)) a month to reach \(Money.format(item.fundGoalCents)) on time.")
        } else if item.fundGoalCents > 0 && totals.remainingCents > 0 {
            let percent = Int(Double(totals.remainingCents) / Double(item.fundGoalCents) * 100)
            Text("\(min(percent, 100))% of the way to \(Money.format(item.fundGoalCents)).")
        } else {
            Text("Planned money adds to the fund each month; spending from it lowers the balance.")
        }
    }
}
