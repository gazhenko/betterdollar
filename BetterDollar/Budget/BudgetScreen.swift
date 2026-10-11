import BetterDollarCore
import SwiftData
import SwiftUI

/// What the right-hand column of the budget shows, as in EveryDollar.
enum BudgetColumn: String, CaseIterable, Identifiable {
    case planned = "Planned", spent = "Spent", remaining = "Remaining"
    var id: String { rawValue }
}

struct BudgetScreen: View {
    @Environment(AppModel.self) private var app
    @Environment(\.modelContext) private var context
    @Query(sort: \BudgetMonth.key) private var months: [BudgetMonth]
    @AppStorage("budgetColumn") private var column: BudgetColumn = .remaining
    @State private var editingItem: BudgetItem?
    @State private var assigning: LedgerTransaction?
    @State private var newGroupName = ""
    @State private var isAddingGroup = false
    @FocusState private var focusedItem: PersistentIdentifier?

    private var month: BudgetMonth? { months.first { $0.key == app.month.id } }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    MonthHeader()
                        .padding(.bottom, 14)
                    if let month {
                        plan(for: month)
                    } else {
                        StartMonthView(month: app.month)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 40)
            }
            .scrollDismissesKeyboard(.interactively)
            .statusBarShield()
            .paperBackground()
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if month != nil {
                    TransactionTray(month: app.month, onSelect: { assigning = $0 })
                }
            }
            .toolbar(.hidden, for: .navigationBar)
            .sheet(item: $editingItem) { item in
                ItemDetailView(item: item)
            }
            .sheet(item: $assigning) { transaction in
                AssignSheet(transaction: transaction)
            }
            .alert("New group", isPresented: $isAddingGroup) {
                TextField("Name", text: $newGroupName)
                Button("Add") {
                    if let month, !newGroupName.trimmingCharacters(in: .whitespaces).isEmpty {
                        BudgetPlanner.addGroup(named: newGroupName.trimmingCharacters(in: .whitespaces), to: month, in: context)
                    }
                    newGroupName = ""
                }
                Button("Cancel", role: .cancel) { newGroupName = "" }
            }
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { focusedItem = nil }
                }
            }
        }
    }

    @ViewBuilder private func plan(for month: BudgetMonth) -> some View {
        let funds = FundLedger(months: months)
        let totals = BudgetMath.totals(for: month)
        LeftToBudgetPlate(totals: totals)
            .padding(.bottom, 18)
        Picker("Show", selection: $column) {
            ForEach(BudgetColumn.allCases) { Text($0.rawValue).tag($0) }
        }
        .pickerStyle(.segmented)
        .padding(.bottom, 8)
        ForEach(month.sortedGroups) { group in
            BudgetGroupSection(group: group, column: column, funds: funds, focusedItem: $focusedItem,
                               onOpen: { editingItem = $0 })
        }
        Button("Add group", systemImage: "plus") { isAddingGroup = true }
            .font(.body.weight(.medium))
            .foregroundStyle(Ink.primary)
            .padding(.vertical, 22)
    }
}

/// "October 2026" with month navigation.
struct MonthHeader: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 0) {
                Text(app.month.monthName)
                    .font(Typeface.title(34))
                    .foregroundStyle(Ink.text)
                Text(String(app.month.year))
                    .font(.subheadline.weight(.medium).monospacedDigit())
                    .foregroundStyle(Ink.secondary)
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            Spacer()
            if !app.isViewingCurrentMonth {
                Button("Today") { withAnimation(.snappy) { app.month = .current() } }
                    .font(.subheadline.weight(.semibold))
                    .padding(.trailing, 6)
            }
            Button { withAnimation(.snappy) { app.month = app.month.previous } } label: {
                Image(systemName: "chevron.left").frame(width: 40, height: 40)
            }
            .accessibilityLabel("Previous month")
            Button { withAnimation(.snappy) { app.month = app.month.next } } label: {
                Image(systemName: "chevron.right").frame(width: 40, height: 40)
            }
            .accessibilityLabel("Next month")
        }
        .font(.title3.weight(.semibold))
        .foregroundStyle(Ink.primary)
        .padding(.top, 8)
    }
}

/// The engraved plate at the top of the budget. The guilloche draws in as income gets a job
/// and completes when the budget is zero-based.
struct LeftToBudgetPlate: View {
    let totals: MonthTotals
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var completion: Double {
        guard totals.plannedIncomeCents > 0 else { return 0.04 }
        return min(1, max(0.04, Double(totals.plannedExpenseCents) / Double(totals.plannedIncomeCents)))
    }
    private var isOver: Bool { totals.leftToBudgetCents < 0 }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            AmountText(cents: abs(totals.leftToBudgetCents), font: Typeface.figure(40),
                       color: isOver ? Ink.seal : Ink.primary)
                .accessibilityIdentifier("leftToBudget")
            Text(isOver ? "over budget" : "left to budget")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Ink.secondary)
            Text(statusLine)
                .font(.callout)
                .foregroundStyle(isOver ? Ink.seal : Ink.text)
                .padding(.top, 6)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(20)
        .padding(.bottom, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            Guilloche(completion: completion, color: isOver ? Ink.seal : Ink.primary)
                .animation(reduceMotion ? nil : .easeInOut(duration: 1.1), value: completion)
        }
        .background(Ink.sheet, in: .rect(cornerRadius: 22))
        .overlay {
            RoundedRectangle(cornerRadius: 22).strokeBorder(Ink.primary.opacity(totals.isZeroBased ? 0.55 : 0.18), lineWidth: totals.isZeroBased ? 1.5 : 1)
        }
        .accessibilityElement(children: .combine)
    }

    private var statusLine: String {
        if totals.plannedIncomeCents == 0 { return "Start with the income you expect this month." }
        if totals.isZeroBased { return "It's a zero-based budget. Every dollar has a job." }
        if isOver { return "You've planned \(Money.format(-totals.leftToBudgetCents)) more than you expect to make." }
        return "Give the rest of your income a job until this reaches zero."
    }
}
