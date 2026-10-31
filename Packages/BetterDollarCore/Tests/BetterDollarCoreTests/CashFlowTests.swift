import Foundation
import SwiftData
import Testing
@testable import BetterDollarCore

@MainActor struct CashFlowTests {
    let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        return calendar
    }()

    private func day(_ month: Int, _ day: Int, _ year: Int = 2026) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day))!
    }

    private func entry(_ date: Date, _ cents: Int, income: Bool = false, _ merchant: String, category: String? = nil) -> CashFlowHistoryEntry {
        CashFlowHistoryEntry(date: calendar.date(byAdding: .hour, value: 12, to: date)!, amountCents: cents, isIncome: income,
                             merchant: merchant, category: category)
    }

    // MARK: Detection

    @Test func findsPaychecksAndBillsInCheckingHistory() {
        var history: [CashFlowHistoryEntry] = []
        var payday = day(7, 23)
        for index in 0..<8 {
            history.append(entry(payday, index < 2 ? 2_150_00 : 2_210_40, income: true, "Direct deposit from Northwind Traders", category: "INCOME"))
            payday = calendar.date(byAdding: .day, value: 14, to: payday)!
        }
        // One lender, two payments on the same days (loan and escrow): two bills.
        for date in [day(8, 3), day(9, 2), day(10, 9)] {
            history.append(entry(date, 1_412_00, "Harbor Home Loans", category: "LOAN_PAYMENTS"))
            history.append(entry(date, 388_25, "Harbor Home Loans", category: "LOAN_PAYMENTS"))
        }
        history += [entry(day(8, 12), 142_10, "Bluebird Insurance"), entry(day(9, 11), 139_80, "Bluebird Insurance"),
                    entry(day(10, 13), 139_80, "Bluebird Insurance")]
        // A skipped month still reads as monthly, and the 30th counts as "around the 1st".
        history += [entry(day(8, 2), 610_00, "To Little Oaks Preschool"), entry(day(9, 1), 610_00, "To Little Oaks Preschool"),
                    entry(day(10, 30), 610_00, "To Little Oaks Preschool")]
        // Noise: interest, irregular transfers, a one-off.
        history += [entry(day(8, 31), 3_10, income: true, "Interest paid"), entry(day(9, 30), 2_95, income: true, "Interest paid"),
                    entry(day(10, 30), 3_40, income: true, "Interest paid")]
        history += [entry(day(8, 6), 300_00, income: true, "From Investments"), entry(day(8, 13), 120_50, income: true, "From Investments"),
                    entry(day(9, 15), 75_00, income: true, "From Investments"), entry(day(10, 21), 45_25, income: true, "From Investments")]
        history.append(entry(day(9, 10), 212_40, "Valley Electric"))

        let patterns = RecurringDetector.detect(history, today: day(10, 31), calendar: calendar)
        let byName = Dictionary(grouping: patterns, by: \.name)

        let pay = try! #require(byName["Northwind Traders"]?.first)
        #expect(pay.isIncome && pay.cadence == .biweekly && pay.amountCents == 2_210_40)
        #expect(pay.nextDate(calendar: calendar) == day(11, 12))
        let loans = (byName["Harbor Home Loans"] ?? []).sorted { $0.amountCents > $1.amountCents }
        #expect(loans.map(\.amountCents) == [1_412_00, 388_25])
        #expect(loans.allSatisfy { $0.cadence == .monthly && $0.nextDate(calendar: calendar) == day(11, 3) })
        #expect(Set(loans.map(\.id)).count == 2)
        #expect(byName["Bluebird Insurance"]?.first?.nextDate(calendar: calendar) == day(11, 12))
        #expect(byName["Little Oaks Preschool"]?.first?.nextDate(calendar: calendar) == day(12, 1))
        #expect(byName["Interest paid"] == nil && byName["Investments"] == nil && byName["Valley Electric"] == nil)
        #expect(patterns.first?.isIncome == true)
    }

    @Test func twiceAMonthPayAndCardPaymentsAreRecognized() {
        var history: [CashFlowHistoryEntry] = []
        for month in 7...10 {
            history.append(entry(day(month, 1), 2_000_00, income: true, "Acme Payroll"))
            history.append(entry(day(month, 15), 2_000_00, income: true, "Acme Payroll"))
            history.append(entry(day(month, 16), 750_00, "Card Services", category: "LOAN_PAYMENTS"))
        }
        let card = (7...10).map { entry(day($0, 18), 750_00, income: true, "Payment received") }
        RecurringDetector.markCardPayments(&history, cardHistory: card, calendar: calendar)
        #expect(history.filter(\.isCardPayment).count == 4)

        let patterns = RecurringDetector.detect(history, today: day(10, 20), calendar: calendar)
        #expect(patterns.count == 1)
        #expect(patterns.first?.cadence == .semimonthly && patterns.first?.monthDays == [1, 15])
        #expect(patterns.first?.nextDate(calendar: calendar) == day(11, 1))
    }

    @Test func billsThatStoppedAreDropped() {
        let history = [entry(day(5, 3), 60_00, "Old Gym"), entry(day(6, 3), 60_00, "Old Gym"), entry(day(7, 3), 60_00, "Old Gym")]
        #expect(RecurringDetector.detect(history, today: day(10, 31), calendar: calendar).isEmpty)
    }

    @Test func schedulesStepThroughShortMonths() {
        let monthly = CashFlowSchedule(id: "rent", name: "Rent", isIncome: false, amountCents: 1, cadence: .monthly, nextDate: day(1, 31), monthDays: [31])
        #expect(monthly.dates(through: day(4, 30), calendar: calendar) == [day(1, 31), day(2, 28), day(3, 31), day(4, 30)])
        let twice = CashFlowSchedule(id: "pay", name: "Pay", isIncome: true, amountCents: 1, cadence: .semimonthly, nextDate: day(1, 15), monthDays: [15, 31])
        #expect(twice.dates(through: day(2, 28), calendar: calendar) == [day(1, 15), day(1, 31), day(2, 15), day(2, 28)])
    }

    // MARK: Forecast

    @Test func forecastFindsTheDipAndWhatFixesIt() {
        let today = day(11, 1)
        let inputs = CashFlowInputs(
            today: today, horizonDays: 30, startingCents: 1_000_00,
            schedules: [
                CashFlowSchedule(id: "pay", name: "Paycheck", isIncome: true, amountCents: 2_000_00, cadence: .biweekly, nextDate: day(11, 10)),
                CashFlowSchedule(id: "rent", name: "Rent", isIncome: false, amountCents: 1_500_00, cadence: .monthly, nextDate: day(11, 5), monthDays: [5])
            ],
            savingsCents: 800_00)
        let forecast = CashFlowForecast.make(inputs, calendar: calendar)

        let dip = try! #require(forecast.dip)
        #expect(dip.start == day(11, 5) && dip.lowest.endCents == -500_00 && dip.recovery == day(11, 10) && dip.neededCents == 500_00)
        #expect(forecast.day(day(11, 10))?.endCents == 1_500_00)
        #expect(forecast.days.filter(\.hasPayday).map(\.date) == [day(11, 10), day(11, 24)])
        #expect(forecast.suggestions.map(\.kind) == [.moveSavings, .moveBill])
        #expect(forecast.suggestions[1].title == "Pay Rent ($1,500.00) on Nov 10 instead of Nov 5")
    }

    @Test func latePaymentsCountTodayAndOldOnesDrop() {
        let today = day(11, 20)
        let inputs = CashFlowInputs(today: today, horizonDays: 5, startingCents: 0, schedules: [
            CashFlowSchedule(id: "late", name: "Phone", isIncome: false, amountCents: 50_00, cadence: .monthly, nextDate: day(11, 17), monthDays: [17]),
            CashFlowSchedule(id: "old", name: "Gym", isIncome: false, amountCents: 30_00, cadence: .monthly, nextDate: day(11, 1), monthDays: [1])
        ])
        let events = CashFlowForecast.make(inputs, calendar: calendar).events
        #expect(events.count == 1)
        #expect(events.first?.date == today && events.first?.expectedDate == day(11, 17))
    }

    @Test func everydaySpendingSpreadsToTheCent() {
        let inputs = CashFlowInputs(today: day(11, 28), horizonDays: 3, startingCents: 0,
                                    everyday: [EverydaySpending(start: day(11, 28), end: day(11, 30), amountCents: 10_00)])
        let forecast = CashFlowForecast.make(inputs, calendar: calendar)
        #expect(forecast.days.map(\.everydayCents) == [3_34, 3_33, 3_33])
        #expect(forecast.days.last?.endCents == -10_00)
    }

    @Test func aBigCardBalanceBecomesAPaymentPlan() {
        let today = day(10, 31)
        let inputs = CashFlowInputs(
            today: today, horizonDays: 60, startingCents: 2_800_00,
            schedules: [
                CashFlowSchedule(id: "pay", name: "Paycheck", isIncome: true, amountCents: 2_600_00, cadence: .biweekly, nextDate: day(11, 12)),
                CashFlowSchedule(id: "mortgage", name: "Mortgage", isIncome: false, amountCents: 1_900_00, cadence: .monthly, nextDate: day(11, 8), monthDays: [8])
            ],
            cards: [CardPayment(id: "card", name: "Card", dueDay: 15, amountCents: 7_200_00, repeats: false)])
        let forecast = CashFlowForecast.make(inputs, calendar: calendar)
        let plan = try! #require(forecast.suggestions.first { $0.kind == .splitPayment })
        // As much as checking can spare on the due date and each payday, without bouncing the mortgage.
        #expect(plan.title == "Pay Card in 4 parts")
        #expect(plan.detail.hasPrefix("$3,500 on Nov 15, $700 on Nov 26, $2,600 on Dec 10, and $400 on Dec 24."))
    }

    // MARK: From the store

    @Test func plannerCombinesHistoryBudgetAndChoices() throws {
        let container = try BetterDollarSchema.container(inMemory: true)
        let context = container.mainContext
        let today = day(10, 31)
        let link = BankLink(itemID: "item", institutionName: "Bank")
        let checking = BankAccount(externalID: "checking", name: "Checking")
        checking.type = "depository"; checking.subtype = "checking"; checking.availableBalanceCents = 2_000_00
        let savings = BankAccount(externalID: "savings", name: "Savings")
        savings.type = "depository"; savings.subtype = "savings"; savings.currentBalanceCents = 500_00
        let card = BankAccount(externalID: "card", name: "Card")
        card.type = "credit"; card.subtype = "credit card"; card.currentBalanceCents = 400_00
        for account in [checking, savings, card] { context.insert(account); account.link = link }
        context.insert(link)

        let month = BudgetPlanner.createBlank(MonthKey(date: today, calendar: calendar), in: context)
        let housing = BudgetPlanner.addGroup(named: "Housing", to: month, in: context)
        let rent = BudgetPlanner.addItem(named: "Rent", to: housing, in: context)
        rent.plannedCents = 1_200_00
        rent.dueDay = 1
        let groceries = BudgetPlanner.addItem(named: "Groceries", to: housing, in: context)
        groceries.plannedCents = 310_00

        func add(_ date: Date, _ cents: Int, income: Bool = false, _ merchant: String) -> LedgerTransaction {
            let transaction = LedgerTransaction(date: calendar.date(byAdding: .hour, value: 12, to: date)!, amountCents: cents, isIncome: income,
                                                merchant: merchant, source: .plaid)
            context.insert(transaction)
            transaction.account = checking
            return transaction
        }
        var payday = day(8, 6)
        while payday <= today {
            _ = add(payday, 1_800_00, income: true, "Payroll")
            payday = calendar.date(byAdding: .day, value: 14, to: payday)!
        }
        // Rent was assigned to the budget item, so the detected landlord covers it instead of counting twice.
        let rentPaid = [day(8, 1), day(9, 1), day(10, 1)].map { add($0, 1_200_00, "Landlord LLC") }
        Ledger.assign(rentPaid[2], to: rent, in: context)
        _ = [day(8, 20), day(9, 20), day(10, 20)].map { add($0, 15_00, "Streaming") }
        try context.save()

        var snapshot = CashFlowPlanner.snapshot(in: context, today: today, horizonDays: 35, calendar: calendar)
        #expect(snapshot.patterns.map(\.name).sorted() == ["Landlord LLC", "Payroll", "Streaming"])
        #expect(snapshot.unreviewedCount == 3)
        #expect(snapshot.forecast.startingCents == 2_000_00 && snapshot.savingsCents == 500_00)
        #expect(snapshot.cardsWithoutDueDay.map(\.name) == ["Card"])
        let names = snapshot.forecast.events.map(\.name)
        #expect(names.contains("Landlord LLC") && !names.contains("Rent"))
        // November has no plan, so October's groceries carry over and spread across it.
        #expect(snapshot.forecast.days.first { $0.date == day(11, 10) }?.everydayCents == 310_00 / 30 + 1)

        let streaming = try #require(snapshot.patterns.first { $0.name == "Streaming" })
        CashFlowPlanner.decision(for: streaming, in: context).isIgnored = true
        let side = RecurringFlow(name: "Side gig", isIncome: true)
        side.amountCents = 250_00
        side.cadence = .monthly
        side.nextDate = day(11, 15)
        context.insert(side)
        card.paymentDueDay = 22
        CashFlowPlanner.markReviewed(snapshot.patterns, in: context)

        snapshot = CashFlowPlanner.snapshot(in: context, today: today, horizonDays: 35, calendar: calendar)
        let events = snapshot.forecast.events
        #expect(!events.contains { $0.name == "Streaming" })
        #expect(events.contains { $0.name == "Side gig" && $0.date == day(11, 15) && $0.amountCents == 250_00 })
        #expect(events.contains { $0.kind == .card && $0.date == day(11, 22) && $0.amountCents == -400_00 })
        #expect(snapshot.unreviewedCount == 0 && snapshot.cardsWithoutDueDay.isEmpty)
    }

    @Test func sampleHouseholdShowsItsPaydaysAndCard() throws {
        let container = try BetterDollarSchema.container(inMemory: true)
        DemoData.seed(into: container.mainContext)
        let snapshot = CashFlowPlanner.snapshot(in: container.mainContext)
        #expect(snapshot.patterns.contains { $0.isIncome && $0.cadence == .semimonthly })
        #expect(snapshot.hasPaydays)
        #expect(snapshot.forecast.events.contains { $0.kind == .card })
        // Rent was always assigned, so it shows once, under the landlord's name.
        #expect(!snapshot.forecast.events.contains { $0.name == "Rent" })
    }

    @Test func backupsKeepCashFlowChoices() throws {
        let container = try BetterDollarSchema.container(inMemory: true)
        let context = container.mainContext
        let card = BankAccount(externalID: "card", name: "Card")
        card.type = "credit"
        card.paymentDueDay = 12
        card.paymentFixedCents = 300_00
        context.insert(card)
        let flow = RecurringFlow(key: "out:gym", isIncome: false)
        flow.isIgnored = true
        flow.coversSeriesID = UUID()
        context.insert(flow)
        try context.save()

        let archive = try BackupArchive.make(from: context, vault: nil, includeBankConnections: false)
        let restoredContainer = try BetterDollarSchema.container(inMemory: true)
        let restored = restoredContainer.mainContext
        try archive.restore(into: restored, vault: nil)
        let account = try #require(try restored.fetch(FetchDescriptor<BankAccount>()).first)
        #expect(account.paymentDueDay == 12 && account.paymentFixedCents == 300_00)
        let choice = try #require(try restored.fetch(FetchDescriptor<RecurringFlow>()).first)
        #expect(choice.key == "out:gym" && choice.isIgnored && choice.coversSeriesID == flow.coversSeriesID)
    }
}
