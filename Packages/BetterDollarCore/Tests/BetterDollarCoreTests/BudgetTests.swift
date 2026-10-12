import Foundation
import SwiftData
import Testing
@testable import BetterDollarCore

@MainActor struct BudgetTests {
    let container: ModelContainer
    var context: ModelContext { container.mainContext }

    init() throws { container = try BetterDollarSchema.container(inMemory: true) }

    private func date(_ key: MonthKey, _ day: Int) -> Date {
        Calendar.current.date(from: DateComponents(year: key.year, month: key.month, day: day, hour: 12))!
    }

    @Test func moneyParsingAndFormatting() {
        #expect(Money.parse("$1,234.56") == 123_456)
        #expect(Money.parse("(12.00)") == -1_200)
        #expect(Money.parse("-3") == -300)
        #expect(Money.parse("0.1") == 10)
        #expect(Money.parse("12.345") == 1_235)
        #expect(Money.parse("abc") == nil)
        #expect(Money.parse("1.2.3") == nil)
        #expect(Money.format(123_456) == "$1,234.56")
        #expect(Money.format(-1_200) == "-$12.00")
        #expect(Money.editableText(1_250) == "12.50")
        #expect(Money.editableText(1_200) == "12")
    }

    @Test func monthKeyArithmetic() {
        let january = MonthKey(year: 2026, month: 1)
        #expect(january.previous == MonthKey(year: 2025, month: 12))
        #expect(MonthKey(year: 2025, month: 12).next == january)
        #expect(january.adding(months: -13) == MonthKey(year: 2024, month: 12))
        #expect(MonthKey("2026-10") == MonthKey(year: 2026, month: 10))
        #expect(MonthKey("2026-13") == nil)
        #expect(january.id == "2026-01")
    }

    @Test func templateStartsWithNothingAssumed() {
        let month = BudgetPlanner.createFromTemplate(MonthKey(year: 2026, month: 10), in: context)
        #expect(month.incomeGroup?.name == "Income")
        #expect(month.allItems.allSatisfy { $0.plannedCents == 0 })
        #expect(month.allItems.contains { $0.name == "Emergency Fund" && $0.isFund })
        #expect(BudgetMath.totals(for: month).leftToBudgetCents == 0)
        #expect(!BudgetMath.totals(for: month).isZeroBased)
    }

    @Test func zeroBasedTotalsAndAssignment() throws {
        let key = MonthKey(year: 2026, month: 10)
        let month = BudgetPlanner.createBlank(key, in: context)
        month.incomeGroup!.sortedItems[0].plannedCents = 5_000_00
        let food = BudgetPlanner.addGroup(named: "Food", to: month, in: context)
        let groceries = BudgetPlanner.addItem(named: "Groceries", plannedCents: 600_00, to: food, in: context)
        let dining = BudgetPlanner.addItem(named: "Dining", plannedCents: 150_00, to: food, in: context)
        #expect(BudgetMath.totals(for: month).leftToBudgetCents == 4_250_00)

        let purchase = Ledger.addManual(date: date(key, 9), amountCents: 84_12, isIncome: false, merchant: "Whole Foods", in: context)
        #expect(purchase.status == .new)
        #expect(BudgetMath.activity(of: groceries) == 0)

        Ledger.assign(purchase, to: groceries, in: context)
        #expect(purchase.status == .tracked)
        #expect(BudgetMath.totals(for: groceries).remainingCents == 515_88)

        // Reassigning moves the whole amount.
        Ledger.assign(purchase, to: dining, in: context)
        #expect(BudgetMath.activity(of: groceries) == 0)
        #expect(BudgetMath.activity(of: dining) == 84_12)

        // A refund (income) assigned to an expense item reduces spending.
        let refund = Ledger.addManual(date: date(key, 10), amountCents: 10_00, isIncome: true, merchant: "Whole Foods refund", in: context)
        Ledger.assign(refund, to: dining, in: context)
        #expect(BudgetMath.activity(of: dining) == 74_12)

        let paycheck = Ledger.addManual(date: date(key, 1), amountCents: 2_500_00, isIncome: true, merchant: "Payroll", in: context)
        Ledger.assign(paycheck, to: month.incomeGroup!.sortedItems[0], in: context)
        let totals = BudgetMath.totals(for: month)
        #expect(totals.receivedCents == 2_500_00)
        #expect(totals.spentCents == 74_12)
    }

    @Test func splitsMustAddUp() throws {
        let key = MonthKey(year: 2026, month: 10)
        let month = BudgetPlanner.createFromTemplate(key, in: context)
        let groceries = month.allItems.first { $0.name == "Groceries" }!
        let misc = month.allItems.first { $0.name == "Miscellaneous" }!
        let target = Ledger.addManual(date: date(key, 6), amountCents: 86_40, isIncome: false, merchant: "Target", in: context)

        #expect(throws: LedgerError.splitDoesNotAddUp(expected: 86_40, actual: 80_00)) {
            try Ledger.split(target, into: [(groceries, 50_00), (misc, 30_00)], in: context)
        }
        #expect(target.status == .new)

        try Ledger.split(target, into: [(groceries, 52_10), (misc, 34_30)], in: context)
        #expect(target.isSplit)
        #expect(BudgetMath.activity(of: groceries) == 52_10)
        #expect(BudgetMath.activity(of: misc) == 34_30)

        // Deleting hides it from the budget; restoring puts it back in the tray.
        Ledger.delete(target, in: context)
        #expect(target.status == .deleted)
        #expect(BudgetMath.activity(of: groceries) == 0)
        Ledger.restore(target)
        #expect(target.status == .new)
    }

    @Test func deletingAnItemReturnsTransactionsToTheTray() {
        let key = MonthKey(year: 2026, month: 10)
        let month = BudgetPlanner.createFromTemplate(key, in: context)
        let gym = month.allItems.first { $0.name == "Gym" }!
        let charge = Ledger.addManual(date: date(key, 3), amountCents: 40_00, isIncome: false, merchant: "Planet Fitness", in: context)
        Ledger.assign(charge, to: gym, in: context)
        BudgetPlanner.delete(gym, in: context)
        #expect(charge.status == .new)
        #expect((charge.allocations ?? []).isEmpty)
    }

    @Test func fundsRollOverAcrossMonths() throws {
        let september = MonthKey(year: 2026, month: 9)
        let first = BudgetPlanner.createBlank(september, in: context)
        let savings = BudgetPlanner.addGroup(named: "Savings", to: first, in: context)
        let car = BudgetPlanner.addItem(named: "Car Repairs", plannedCents: 100_00, isFund: true, to: savings, in: context)
        car.fundStartingCents = 250_00
        car.fundGoalCents = 1_000_00
        let repair = Ledger.addManual(date: date(september, 20), amountCents: 80_00, isIncome: false, merchant: "Jiffy Lube", in: context)
        Ledger.assign(repair, to: car, in: context)

        let october = BudgetPlanner.createByCopying(first, to: september.next, in: context)
        let carOctober = october.allItems.first { $0.name == "Car Repairs" }!
        #expect(carOctober.seriesID == car.seriesID)

        let ledger = FundLedger(months: BudgetPlanner.allMonths(in: context))
        #expect(ledger.balance(for: car) == 270_00)
        #expect(ledger.carryIn(for: carOctober) == 270_00)
        #expect(BudgetMath.totals(for: carOctober, funds: ledger).remainingCents == 370_00)

        // Overspending a fund is allowed; the balance just drops.
        let bigRepair = Ledger.addManual(date: date(september.next, 3), amountCents: 500_00, isIncome: false, merchant: "Dealer", in: context)
        Ledger.assign(bigRepair, to: carOctober, in: context)
        let updated = FundLedger(months: BudgetPlanner.allMonths(in: context))
        #expect(BudgetMath.totals(for: carOctober, funds: updated).remainingCents == -130_00)
    }

    @Test func monthlyAmountToReachAGoal() {
        let october = MonthKey(year: 2026, month: 10)
        let target = Calendar.current.date(from: DateComponents(year: 2027, month: 3, day: 1))!
        // October through March is six months.
        #expect(BudgetMath.monthlyToReachGoal(balanceCents: 400_00, goalCents: 1_000_00, from: october, target: target) == 100_00)
        #expect(BudgetMath.monthlyToReachGoal(balanceCents: 1_200_00, goalCents: 1_000_00, from: october, target: target) == 0)
        #expect(BudgetMath.monthlyToReachGoal(balanceCents: 0, goalCents: 0, from: october, target: target) == nil)
    }

    @Test func suggestionComesFromThePastButIsNeverApplied() {
        let september = MonthKey(year: 2026, month: 9)
        let first = BudgetPlanner.createFromTemplate(september, in: context)
        let gas = first.allItems.first { $0.name == "Gas" }!
        let old = Ledger.addManual(date: date(september, 4), amountCents: 40_00, isIncome: false, merchant: "SHELL OIL 57444", in: context)
        Ledger.assign(old, to: gas, in: context)

        let october = BudgetPlanner.createByCopying(first, to: september.next, in: context)
        let fresh = Ledger.addManual(date: date(september.next, 2), amountCents: 45_00, isIncome: false, merchant: "Shell Oil 12", in: context)
        let suggestion = Ledger.suggestedItem(for: fresh, in: october, context: context)
        #expect(suggestion?.name == "Gas")
        #expect(suggestion?.monthKey == september.next)
        #expect(fresh.status == .new)
    }

    @Test func demoDataIsZeroBasedWithATray() throws {
        let today = Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 20, hour: 9))!
        DemoData.seed(into: context, today: today)
        let october = try #require(BudgetPlanner.month(MonthKey(year: 2026, month: 10), in: context))
        #expect(BudgetMath.totals(for: october).isZeroBased)
        let tray = Ledger.transactions(in: MonthKey(year: 2026, month: 10), status: .new, context: context)
        #expect(tray.count == 4)
        #expect(BudgetPlanner.allMonths(in: context).count == 3)
        let all = try context.fetch(FetchDescriptor<LedgerTransaction>())
        #expect(all.filter { $0.status == .tracked }.allSatisfy { $0.allocatedCents == $0.amountCents })
    }

    @Test func financeDataSummarizesForTheCoach() {
        let today = Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 20, hour: 9))!
        DemoData.seed(into: context, today: today)
        let data = FinanceData.build(month: MonthKey(year: 2026, month: 10), context: context, today: today)
        #expect(data.hasPlan)
        #expect(data.newTransactionCount == 4)
        #expect(data.history.count == 2)
        let overview = data.overview()
        #expect(overview.contains("Zero-based"))
        #expect(overview.contains("Cash flow so far this month"))
        #expect(overview.contains("Groceries"))
        #expect(data.itemDetail(named: "groceries")?.contains("Trader Joe's") == true)
        #expect(data.relevantContext(for: "How is my emergency fund goal going?").contains("Emergency Fund"))
        #expect(data.searchTransactions("shell").contains("Shell"))
    }

    @Test func removingAFundMonthKeepsLaterBalances() throws {
        let october = MonthKey(year: 2026, month: 10)
        let first = BudgetPlanner.createBlank(october, in: context)
        let savings = BudgetPlanner.addGroup(named: "Savings", to: first, in: context)
        let fund = BudgetPlanner.addItem(named: "Emergency", plannedCents: 500_00, isFund: true, to: savings, in: context)
        fund.fundStartingCents = 1_000_00
        let november = BudgetPlanner.createByCopying(first, to: october.next, in: context)
        let december = BudgetPlanner.createByCopying(november, to: october.adding(months: 2), in: context)
        let novFund = november.allItems.first { $0.name == "Emergency" }!
        let decFund = december.allItems.first { $0.name == "Emergency" }!
        #expect(FundLedger(months: BudgetPlanner.allMonths(in: context)).carryIn(for: decFund) == 2_000_00)

        // Making November's item regular must not change December's balance.
        BudgetPlanner.setFund(novFund, false, in: context)
        #expect(FundLedger(months: BudgetPlanner.allMonths(in: context)).carryIn(for: decFund) == 2_000_00)

        // Deleting October's (the first) fund item must not either.
        BudgetPlanner.delete(fund, in: context)
        try context.save()
        #expect(FundLedger(months: BudgetPlanner.allMonths(in: context)).carryIn(for: decFund) == 2_000_00)

        // Income items can't become funds.
        let paycheck = first.incomeGroup!.sortedItems[0]
        BudgetPlanner.setFund(paycheck, true, in: context)
        #expect(!paycheck.isFund)
    }

    @Test func removingSampleDataKeepsBankData() throws {
        let today = MonthKey(date: Date())
        DemoData.seed(into: context)
        let link = BankLink(itemID: "item-1", institutionName: "Real Bank")
        let checking = BankAccount(externalID: "account-1", name: "Checking")
        context.insert(link)
        context.insert(checking)
        checking.link = link
        let assigned = LedgerTransaction(date: Date(), amountCents: 42_00, isIncome: false, merchant: "Corner Store", source: .plaid, externalID: "t1")
        let waiting = LedgerTransaction(date: Date(), amountCents: 9_99, isIncome: false, merchant: "Streaming", source: .plaid, externalID: "t2")
        for transaction in [assigned, waiting] {
            context.insert(transaction)
            transaction.account = checking
        }
        let groceries = try #require(try context.fetch(FetchDescriptor<BudgetItem>()).first { $0.name == "Groceries" && $0.group?.month?.key == today.id })
        Ledger.assign(assigned, to: groceries, in: context)
        // A month planned after exploring the sample is the person's own.
        let later = BudgetPlanner.createFromTemplate(today.next, in: context)
        later.createdAt = Date().addingTimeInterval(60)
        try context.save()
        #expect(DemoData.isSample(try #require(try context.fetch(FetchDescriptor<BankAccount>()).first { $0.externalID == "demo-card" })))

        DemoData.remove(from: context)

        #expect(try context.fetch(FetchDescriptor<BankAccount>()).map(\.name) == ["Checking"])
        let left = try context.fetch(FetchDescriptor<LedgerTransaction>())
        #expect(Set(left.map(\.merchant)) == ["Corner Store", "Streaming"])
        #expect(left.allSatisfy { $0.status == .new && ($0.allocations ?? []).isEmpty && $0.account === checking })
        #expect(try context.fetch(FetchDescriptor<BudgetMonth>()).map(\.key) == [today.next.id])
        #expect(try context.fetch(FetchDescriptor<Allocation>()).isEmpty)
        #expect(try context.fetchCount(FetchDescriptor<BankLink>()) == 1)
    }
}
