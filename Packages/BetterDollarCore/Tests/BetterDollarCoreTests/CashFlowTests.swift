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
            cards: [CardPayment(id: "card", name: "Card", dueDay: 15, owedCents: 7_200_00, plan: .balance)])
        let forecast = CashFlowForecast.make(inputs, calendar: calendar)
        let plan = try! #require(forecast.suggestions.first { $0.kind == .splitPayment })
        // As much as checking can spare on the due date and each payday, without bouncing the mortgage.
        #expect(plan.title == "Pay Card in 4 parts")
        #expect(plan.detail.hasPrefix("$3,500 on Nov 15, $700 on Nov 26, $2,600 on Dec 10, and $400 on Dec 24."))
    }

    @Test func cardPlansPayWhatIsOwedToday() {
        let today = day(10, 31)
        func payments(_ plan: CardPayment.Plan) -> [Int] {
            CardPayment(id: "card", name: "Card", dueDay: 20, owedCents: 1_000_00, plan: plan)
                .payments(from: today, through: day(12, 29), calendar: calendar).map(\.cents)
        }
        #expect(payments(.balance) == [1_000_00])
        // The statement now, the charges since it closed next month; later spending is everyday spending.
        #expect(payments(.statement(remainingCents: 600_00)) == [600_00, 400_00])
        #expect(payments(.statement(remainingCents: 0)) == [1_000_00])
        #expect(payments(.monthly(300_00)) == [300_00, 300_00])
        #expect(payments(.monthly(800_00)) == [800_00, 200_00])

        // Paid in parts with each paycheck since the last due date.
        let inputs = CashFlowInputs(
            today: today, horizonDays: 60, startingCents: 3_000_00,
            schedules: [CashFlowSchedule(id: "pay", name: "Paycheck", isIncome: true, amountCents: 1_500_00, cadence: .biweekly, nextDate: day(11, 6))],
            cards: [CardPayment(id: "card", name: "Card", dueDay: 20, owedCents: 1_000_00, plan: .statement(remainingCents: 601_00), splitsWithPay: true)])
        let card = CashFlowForecast.make(inputs, calendar: calendar).events.filter { $0.kind == .card }
        #expect(card.map(\.date) == [day(11, 6), day(11, 20), day(12, 4), day(12, 18)])
        #expect(card.map(\.amountCents) == [-300_50, -300_50, -199_50, -199_50])
        #expect(card.first?.detail == "Part 1 of 2, due Nov 20")
    }

    @Test func budgetSpendingOnACardIsPaidWithIt() {
        let today = day(10, 31)
        // $100 a day of budget spending charged in November; statements close 25 days before the 20th.
        let november = [EverydaySpending(start: day(11, 1), end: day(11, 30), amountCents: 3_000_00)]
        func payments(_ plan: CardPayment.Plan) -> [CardPayment.Payment] {
            CardPayment(id: "card", name: "Card", dueDay: 20, owedCents: 1_000_00, plan: plan, spending: november)
                .payments(from: today, through: day(12, 29), calendar: calendar)
        }
        // Nov 20 pays the statement that closed Oct 26; Dec 20 the rest owed now plus Nov 1–25.
        #expect(payments(.statement(remainingCents: 600_00)).map(\.cents) == [600_00, 2_900_00])
        #expect(payments(.statement(remainingCents: 600_00)).map(\.spendingCents) == [0, 2_500_00])
        #expect(payments(.balance).map(\.cents) == [3_000_00, 1_000_00])
        // A set amount keeps going while anything is owed.
        #expect(payments(.monthly(1_000_00)).map(\.cents) == [1_000_00, 1_000_00])

        let inputs = CashFlowInputs(today: today, horizonDays: 60, startingCents: 5_000_00,
                                    cards: [CardPayment(id: "card", name: "Card", dueDay: 20, owedCents: 1_000_00,
                                                        plan: .statement(remainingCents: 600_00), spending: november)])
        let forecast = CashFlowForecast.make(inputs, calendar: calendar)
        #expect(forecast.days.allSatisfy { $0.everydayCents == 0 }, "card spending doesn't leave checking day by day")
        #expect(forecast.events.last?.detail == "Includes about $2,500 of budget spending")
    }

    @Test func cardHabitsAndStatementsComeFromHistory() {
        let cash = [entry(day(8, 16), 500_00, "Card payment"), entry(day(9, 15), 640_00, "Card payment"),
                    entry(day(9, 18), 100_00, "Card payment"), entry(day(10, 16), 720_00, "Card payment"),
                    entry(day(10, 16), 85_00, "Corner Grocer")]
        var card = [entry(day(8, 17), 500_00, income: true, "Payment", category: "LOAN_PAYMENTS"),
                    entry(day(9, 17), 640_00, income: true, "Payment", category: "LOAN_PAYMENTS"),
                    entry(day(9, 18), 100_00, income: true, "Payment", category: "LOAN_PAYMENTS"),
                    entry(day(10, 17), 720_00, income: true, "Payment", category: "LOAN_PAYMENTS"),
                    entry(day(10, 2), 85_00, income: true, "Refund")]
        let paid = RecurringDetector.payments(to: card, from: cash)
        #expect(paid.count == 4)
        // Whole months only (August, September, October), counted high.
        #expect(RecurringDetector.cardHabit(paid, today: day(11, 1), calendar: calendar) == CardHabit(day: 16, monthlyCents: 720_00))
        #expect(RecurringDetector.cardHabit(paid, today: day(1, 20, 2027), calendar: calendar) == nil)
        #expect(RecurringDetector.cardHabit(Array(paid.prefix(1)), today: day(9, 1), calendar: calendar) == nil)

        // The statement due Nov 16 closed about Oct 22. Charges after that, less refunds, wait for the next one.
        card += [entry(day(10, 25), 150_00, "Hardware Barn"), entry(day(10, 30), 50_00, "Lantern Books"),
                 entry(day(10, 28), 20_00, income: true, "Return"), entry(day(10, 26), 300_00, income: true, "Payment", category: "LOAN_PAYMENTS")]
        func remaining(_ today: Date, closeDay: Int = 0) -> Int {
            CardPayment.statementRemaining(owedCents: 900_00, cardHistory: card, dueDay: 16, closeDay: closeDay, today: today, calendar: calendar)
        }
        #expect(remaining(day(11, 1)) == 720_00)
        #expect(remaining(day(10, 20)) == 900_00)
        #expect(remaining(day(11, 1), closeDay: 26) == 870_00)
        #expect(CardPayment.statementClose(before: day(11, 16), closeDay: 5, calendar: calendar) == day(10, 5))
        #expect(CardPayment.statementClose(before: day(11, 16), closeDay: 30, calendar: calendar) == day(9, 30))
        #expect([7_204_50, 500_00, 30_00].map(CardPayment.estimatedMinimum) == [217_00, 40_00, 30_00])
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

    @Test func cardsArePaidOnTheirUsualDayUntilSet() throws {
        let container = try BetterDollarSchema.container(inMemory: true)
        let context = container.mainContext
        let today = day(10, 31)
        let checking = BankAccount(externalID: "checking", name: "Checking")
        checking.type = "depository"; checking.subtype = "checking"; checking.availableBalanceCents = 3_000_00
        let card = BankAccount(externalID: "card", name: "Card")
        card.type = "credit"; card.subtype = "credit card"; card.currentBalanceCents = 800_00
        context.insert(checking)
        context.insert(card)
        func add(_ date: Date, _ cents: Int, income: Bool = false, _ merchant: String, on account: BankAccount, category: String? = nil) {
            let transaction = LedgerTransaction(date: calendar.date(byAdding: .hour, value: 12, to: date)!, amountCents: cents, isIncome: income,
                                                merchant: merchant, source: .plaid)
            transaction.bankCategory = category
            context.insert(transaction)
            transaction.account = account
        }
        for (month, cents) in [(8, 280_00), (9, 300_00), (10, 320_00)] {
            add(day(month, 9), cents, "Card payment", on: checking, category: "LOAN_PAYMENTS")
            add(day(month, 10), cents, income: true, "Payment", on: card, category: "LOAN_PAYMENTS")
        }
        add(day(10, 25), 120_00, "Hardware Barn", on: card)
        try context.save()

        func cardEvents() -> [CashFlowEvent] {
            CashFlowPlanner.snapshot(in: context, today: today, horizonDays: 45, calendar: calendar).forecast.events.filter { $0.kind == .card }
        }
        // No day set: the usual one from checking, the statement first and newer charges a month later.
        var snapshot = CashFlowPlanner.snapshot(in: context, today: today, horizonDays: 45, calendar: calendar)
        #expect(snapshot.patterns.isEmpty, "card payments aren't bills")
        #expect(snapshot.cardsWithoutDueDay.isEmpty && snapshot.cardsOnUsualDay.map(\.name) == ["Card"])
        #expect(snapshot.cards.first?.payments.map(\.amountCents) == [-680_00, -120_00])
        #expect(cardEvents().map(\.date) == [day(11, 9), day(12, 9)])
        #expect(cardEvents().allSatisfy { $0.isEstimate && $0.detail == "On your usual payment day" })

        card.paymentMode = .minimum
        #expect(cardEvents().map(\.amountCents) == [-40_00, -40_00])
        #expect(cardEvents().first?.detail == "Estimated minimum, on your usual payment day")

        card.paymentDueDay = 20
        card.paymentMode = .usual
        #expect(cardEvents().map(\.amountCents) == [-300_00])
        #expect(cardEvents().map(\.date) == [day(11, 20)])
        #expect(cardEvents().allSatisfy { !$0.isEstimate && $0.detail == nil })

        card.paymentMode = .elsewhere
        snapshot = CashFlowPlanner.snapshot(in: context, today: today, horizonDays: 45, calendar: calendar)
        #expect(cardEvents().isEmpty && snapshot.cardsOnUsualDay.isEmpty && snapshot.cardsWithoutDueDay.isEmpty)
    }

    @Test func billsAndCardsFindTheirBudgetLines() throws {
        let container = try BetterDollarSchema.container(inMemory: true)
        let context = container.mainContext
        let today = day(10, 31)
        let checking = BankAccount(externalID: "checking", name: "Checking")
        checking.type = "depository"; checking.subtype = "checking"; checking.availableBalanceCents = 5_000_00
        let card = BankAccount(externalID: "card", name: "Card")
        card.type = "credit"; card.currentBalanceCents = 500_00; card.paymentDueDay = 10
        context.insert(checking)
        context.insert(card)
        let month = BudgetPlanner.createBlank(MonthKey(date: today, calendar: calendar), in: context)
        let bills = BudgetPlanner.addGroup(named: "Bills", to: month, in: context)
        var lines: [String: BudgetItem] = [:]
        for (name, cents) in [("Car loan", 312_45), ("Home loan", 1_800_25), ("Credit card", 150_00), ("Groceries", 600_00)] {
            let item = BudgetPlanner.addItem(named: name, to: bills, in: context)
            item.plannedCents = cents
            lines[name] = item
        }
        func add(_ date: Date, _ cents: Int, _ merchant: String) {
            let transaction = LedgerTransaction(date: calendar.date(byAdding: .hour, value: 12, to: date)!, amountCents: cents, isIncome: false,
                                                merchant: merchant, source: .plaid)
            context.insert(transaction)
            transaction.account = checking
        }
        for date in [day(8, 5), day(9, 5), day(10, 5)] { add(date, 312_45, "Granite Auto Finance") }
        // A loan and its escrow, paid together: the two add up to the plan.
        for date in [day(8, 3), day(9, 2), day(10, 3)] {
            add(date, 1_412_00, "Harbor Home Loans")
            add(date, 388_25, "Harbor Home Loans")
        }
        try context.save()

        var snapshot = CashFlowPlanner.snapshot(in: context, today: today, horizonDays: 35, calendar: calendar)
        let links = Dictionary(snapshot.patterns.map { ($0.id, $0.seriesID) }, uniquingKeysWith: { first, _ in first })
        #expect(links["out:granite auto finance"] == lines["Car loan"]?.seriesID)
        #expect(links["out:harbor home loans#1"] == lines["Home loan"]?.seriesID && links["out:harbor home loans#2"] == lines["Home loan"]?.seriesID)
        #expect(snapshot.cards.first?.coversSeriesID == lines["Credit card"]?.seriesID)
        // Only groceries are left as everyday spending; November borrows October's plan.
        #expect(snapshot.forecast.days.first { $0.date == day(11, 10) }?.everydayCents == 20_00)

        // Saying a bill isn't in the budget puts its line back.
        let granite = try #require(snapshot.patterns.first { $0.id == "out:granite auto finance" })
        CashFlowPlanner.decision(for: granite, in: context).coversSeriesID = RecurringFlow.notInBudget
        card.paymentCoversSeriesID = RecurringFlow.notInBudget
        snapshot = CashFlowPlanner.snapshot(in: context, today: today, horizonDays: 35, calendar: calendar)
        #expect(snapshot.cards.first?.coversSeriesID == nil)
        #expect(snapshot.forecast.days.first { $0.date == day(11, 10) }?.everydayCents == (600_00 + 312_45 + 150_00) / 30 + 1)
    }

    @Test func budgetGroupsPaidByCardLeaveCheckingWithThePayment() throws {
        let container = try BetterDollarSchema.container(inMemory: true)
        let context = container.mainContext
        let today = day(10, 31)
        let checking = BankAccount(externalID: "checking", name: "Checking")
        checking.type = "depository"; checking.subtype = "checking"; checking.availableBalanceCents = 5_000_00
        let card = BankAccount(externalID: "card", name: "Card")
        card.type = "credit"; card.currentBalanceCents = 0; card.paymentDueDay = 20
        context.insert(checking)
        context.insert(card)
        let month = BudgetPlanner.createBlank(MonthKey(date: today, calendar: calendar), in: context)
        let food = BudgetPlanner.addGroup(named: "Food", to: month, in: context)
        BudgetPlanner.addItem(named: "Groceries", to: food, in: context).plannedCents = 600_00
        let home = BudgetPlanner.addGroup(named: "Home", to: month, in: context)
        BudgetPlanner.addItem(named: "Electric", to: home, in: context).plannedCents = 300_00
        try context.save()

        func snapshot() -> CashFlowPlanner.Snapshot { CashFlowPlanner.snapshot(in: context, today: today, horizonDays: 60, calendar: calendar) }
        #expect(snapshot().forecast.days.first { $0.date == day(11, 10) }?.everydayCents == 900_00 / 30)
        #expect(snapshot().cards.first?.payments.isEmpty == true)

        card.cardGroupNames = ["Food"]
        // Groceries build up on the card: October's last day and Nov 1–25 close into the Dec 20 statement.
        #expect(snapshot().forecast.days.first { $0.date == day(11, 10) }?.everydayCents == 300_00 / 30)
        #expect(snapshot().cards.first?.payments.map(\.amountCents) == [-(600_00 / 31 + 25 * 20_00)])
        #expect(snapshot().cards.first?.payments.first?.date == day(12, 20))

        // Paid from another account: groceries leave the forecast.
        card.paymentMode = .elsewhere
        #expect(snapshot().forecast.days.first { $0.date == day(11, 10) }?.everydayCents == 300_00 / 30)
        #expect(snapshot().forecast.events.allSatisfy { $0.kind != .card })
    }

    @Test func budgetLinesFollowWhereTheMoneyGoes() throws {
        let container = try BetterDollarSchema.container(inMemory: true)
        let context = container.mainContext
        let today = day(10, 31)
        let checking = BankAccount(externalID: "checking", name: "Checking")
        checking.type = "depository"; checking.subtype = "checking"; checking.availableBalanceCents = 5_000_00
        let card = BankAccount(externalID: "card", name: "Card")
        card.type = "credit"; card.currentBalanceCents = 55_00; card.paymentDueDay = 20
        context.insert(checking)
        context.insert(card)
        let month = BudgetPlanner.createBlank(MonthKey(date: today, calendar: calendar), in: context)
        let income = BudgetGroup(name: "Income", isIncome: true, sortIndex: 0)
        income.month = month
        context.insert(income)
        for (index, (name, cents)) in [("Paycheck", 2_000_00), ("Side work", 400_00)].enumerated() {
            let item = BudgetItem(name: name, plannedCents: cents, sortIndex: index)
            item.group = income
            context.insert(item)
        }
        let home = BudgetPlanner.addGroup(named: "Home", to: month, in: context)
        var lines: [String: BudgetItem] = [:]
        for (name, cents) in [("Water", 75_00), ("Tutoring", 455_00), ("Electric", 410_00)] {
            let item = BudgetPlanner.addItem(named: name, to: home, in: context)
            item.plannedCents = cents
            lines[name] = item
        }
        let food = BudgetPlanner.addGroup(named: "Food", to: month, in: context)
        let groceries = BudgetPlanner.addItem(named: "Groceries", to: food, in: context)
        groceries.plannedCents = 600_00
        func add(_ date: Date, _ cents: Int, income: Bool = false, _ merchant: String, on account: BankAccount) -> LedgerTransaction {
            let transaction = LedgerTransaction(date: calendar.date(byAdding: .hour, value: 12, to: date)!, amountCents: cents, isIncome: income,
                                                merchant: merchant, source: .plaid)
            context.insert(transaction)
            transaction.account = account
            return transaction
        }
        var payday = day(8, 6)
        while payday <= today {
            _ = add(payday, 2_000_00, income: true, "Payroll", on: checking)
            payday = calendar.date(byAdding: .day, value: 14, to: payday)!
        }
        for month in 8...10 {
            _ = add(day(month, 9), 91_40, "Riverside Water Authority", on: checking)
            _ = add(day(month, 1), 438_10, "Bright Path Learning", on: checking)
        }
        // Paid once a month, but the latest one early.
        for date in [day(7, 7), day(8, 8), day(9, 16), day(10, 2)] { _ = add(date, 1_500_00, "Summit Mortgage", on: checking) }
        Ledger.assign(add(day(10, 20), 55_00, "Corner Grocer", on: card), to: groceries, in: context)
        Ledger.assign(add(day(10, 12), 98_00, "Lakeside Power", on: checking), to: lines["Electric"]!, in: context)
        try context.save()

        let snapshot = CashFlowPlanner.snapshot(in: context, today: today, horizonDays: 60, calendar: calendar)
        #expect(snapshot.patterns.contains { $0.name == "Summit Mortgage" && $0.cadence == .monthly })
        let links = Dictionary(snapshot.patterns.map { ($0.name, $0.seriesID) }, uniquingKeysWith: { first, _ in first })
        // Named in the bill, and the closest amount within 10% (Electric is close too, but not as close).
        #expect(links["Riverside Water Authority"] == lines["Water"]?.seriesID)
        #expect(links["Bright Path Learning"] == lines["Tutoring"]?.seriesID)
        // Groceries were charged to the card, so they build up there; Electric was paid from checking and stays there.
        #expect(snapshot.cards.first?.chargedItemNames == ["Groceries"] && snapshot.cards.first?.assumedItemNames == [])
        #expect(snapshot.forecast.days.first { $0.date == day(11, 10) }?.everydayCents == 410_00 / 30 + 1)
        #expect(snapshot.cards.first?.payments.map(\.amountCents) == [-55_00, -(600_00 / 31 + 25 * 20_00)])
        #expect(snapshot.missingIncome == [CashFlowPlanner.MissingIncome(name: "Side work", cents: 400_00)])
    }

    @Test func linesWithNoChargesGoWhereMostSpendingGoes() throws {
        let container = try BetterDollarSchema.container(inMemory: true)
        let context = container.mainContext
        let today = day(10, 31)
        let checking = BankAccount(externalID: "checking", name: "Checking")
        checking.type = "depository"; checking.subtype = "checking"; checking.availableBalanceCents = 2_000_00
        let card = BankAccount(externalID: "card", name: "Card")
        card.type = "credit"; card.currentBalanceCents = 0; card.paymentDueDay = 20
        context.insert(checking)
        context.insert(card)
        let month = BudgetPlanner.createBlank(MonthKey(date: today, calendar: calendar), in: context)
        let group = BudgetPlanner.addGroup(named: "Everyday", to: month, in: context)
        var lines: [String: BudgetItem] = [:]
        for (name, cents) in [("Groceries", 300_00), ("Dining", 150_00), ("Power", 200_00), ("Gifts", 90_00)] {
            let item = BudgetPlanner.addItem(named: name, to: group, in: context)
            item.plannedCents = cents
            lines[name] = item
        }
        func charge(_ cents: Int, _ merchant: String, on account: BankAccount, to name: String) {
            let transaction = LedgerTransaction(date: calendar.date(byAdding: .hour, value: 12, to: day(10, 15))!, amountCents: cents,
                                                isIncome: false, merchant: merchant, source: .plaid)
            context.insert(transaction)
            transaction.account = account
            Ledger.assign(transaction, to: lines[name]!, in: context)
        }
        charge(40_00, "Corner Grocer", on: card, to: "Groceries")
        charge(22_00, "Noodle Bar", on: card, to: "Dining")
        charge(61_00, "Lakeside Power", on: checking, to: "Power")
        try context.save()

        // Two of the three charged lines went on the card, so Gifts is counted there too; Power stays in checking.
        let snapshot = CashFlowPlanner.snapshot(in: context, today: today, horizonDays: 60, calendar: calendar)
        #expect(snapshot.cards.first?.chargedItemNames == ["Dining", "Groceries"])
        #expect(snapshot.cards.first?.assumedItemNames == ["Gifts"])
        #expect(snapshot.forecast.days.first { $0.date == day(11, 10) }?.everydayCents == 200_00 / 30 + 1)
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
        card.paymentMode = .minimum
        card.statementCloseDay = 18
        card.paymentSplitsWithPay = true
        card.paymentCoversSeriesID = RecurringFlow.notInBudget
        card.cardGroupNames = ["Food", "Fun"]
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
        #expect(account.paymentMode == .minimum && account.statementCloseDay == 18 && account.paymentSplitsWithPay)
        #expect(account.paymentCoversSeriesID == RecurringFlow.notInBudget && account.cardGroupNames == ["Food", "Fun"])
        let choice = try #require(try restored.fetch(FetchDescriptor<RecurringFlow>()).first)
        #expect(choice.key == "out:gym" && choice.isIgnored && choice.coversSeriesID == flow.coversSeriesID)
    }
}
