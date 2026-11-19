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
                .padding(.horizontal, Layout.margin)
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

    private var daysLeft: Int? {
        guard app.isViewingCurrentMonth else { return nil }
        let calendar = Calendar.current
        let days = calendar.range(of: .day, in: .month, for: Date())?.count ?? 30
        return days - calendar.component(.day, from: Date()) + 1
    }

    @ViewBuilder private func plan(for month: BudgetMonth) -> some View {
        let funds = FundLedger(months: months)
        let totals = BudgetMath.totals(for: month)
        LeftToBudgetPlate(totals: totals, daysLeft: daysLeft)
            .padding(.bottom, 10)
        LedgerTabs(selection: $column, options: BudgetColumn.allCases.map { ($0, $0.rawValue) })
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
        ScreenHeader(title: app.month.monthName) {
            Text(String(app.month.year)).monospacedDigit()
        } actions: {
            if !app.isViewingCurrentMonth {
                Button("Today") { withAnimation(.snappy) { app.month = .current() } }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Ink.primary)
                    .padding(.horizontal, 14)
                    .frame(height: 38)
                    .background(Ink.sheet, in: .capsule)
                    .overlay { Capsule().strokeBorder(Ink.rule, lineWidth: 0.75) }
            }
            Button { withAnimation(.snappy) { app.month = app.month.previous } } label: {
                HeaderButtonLabel(systemImage: "chevron.left")
            }
            .accessibilityLabel("Previous month")
            Button { withAnimation(.snappy) { app.month = app.month.next } } label: {
                HeaderButtonLabel(systemImage: "chevron.right")
            }
            .accessibilityLabel("Next month")
        }
        .buttonStyle(.plain)
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
    /// Planned more than you make, or spent more than you planned: the greenback is reprinted as a red-seal note.
    private var ink: PlateInk { PlateInk(alarm: isOver || totals.spentCents > totals.plannedExpenseCents) }

    var body: some View {
        let figure = isOver ? Ink.seal : ink.figure
        VStack(alignment: .leading, spacing: 4) {
            MoneyFigure(cents: abs(totals.leftToBudgetCents), color: figure, shade: ink.shade(for: figure))
                .accessibilityIdentifier("leftToBudget")
            Text(isOver ? "over budget" : "left to budget")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(ink.secondary)
            Text(statusLine)
                .font(.callout)
                .foregroundStyle(ink.text)
                .padding(.top, 12)
                .fixedSize(horizontal: false, vertical: true)
            if totals.plannedExpenseCents > 0 {
                MonthProgress(totals: totals, daysLeft: daysLeft, ink: ink)
                    .padding(.top, 14)
            }
        }
        .padding(22)
        .padding(.bottom, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .engravedPlate(completion: completion, ink: ink, framed: totals.isZeroBased, animates: !reduceMotion)
        .accessibilityElement(children: .combine)
    }

    /// Days left in the month being shown, counting today. Nil for past and future months.
    var daysLeft: Int?

    private var statusLine: String {
        if totals.plannedIncomeCents == 0 { return "Start with the income you expect this month." }
        if totals.isZeroBased { return "It's a zero-based budget. Every dollar has a job." }
        if isOver { return "You've planned \(Money.format(-totals.leftToBudgetCents)) more than you expect to make." }
        return "Give the rest of your income a job until this reaches zero."
    }
}

/// Where the month stands at a glance: what's been spent against the plan, and how long is left.
struct MonthProgress: View {
    let totals: MonthTotals
    let daysLeft: Int?
    var ink = PlateInk(alarm: false)

    private var isOver: Bool { totals.spentCents > totals.plannedExpenseCents }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SpendRule(progress: min(1, Double(totals.spentCents) / Double(max(1, totals.plannedExpenseCents))), overspent: isOver,
                      tint: ink.text, track: ink.track)
            HStack(alignment: .firstTextBaseline) {
                Text("\(Money.format(totals.spentCents, showsCents: false)) spent of \(Money.format(totals.plannedExpenseCents, showsCents: false))")
                    .foregroundStyle(isOver ? Ink.seal : ink.text)
                Spacer()
                if let daysLeft {
                    Text(daysLeft == 1 ? "Last day" : "\(daysLeft) days left")
                        .foregroundStyle(ink.secondary)
                }
            }
            .font(.footnote.weight(.medium).monospacedDigit())
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("month-progress")
    }
}
