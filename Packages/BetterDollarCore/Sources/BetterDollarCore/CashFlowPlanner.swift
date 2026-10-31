import Foundation
import SwiftData

/// Builds the cash flow forecast from the store: checking balances, paychecks and bills found in
/// checking history, card payments, and the budget's due dates and everyday spending.
@MainActor public enum CashFlowPlanner {
    /// A credit card as cash flow sees it.
    public struct Card: Identifiable, Sendable {
        public var id: UUID
        public var name: String
        public var balanceCents: Int
        public var dueDay: Int
        public var fixedCents: Int
    }

    /// Everything the cash flow screens show.
    public struct Snapshot: Sendable {
        public var forecast: CashFlowForecast
        /// Paychecks and bills found in history, including ignored ones.
        public var patterns: [RecurringPattern]
        /// Detected ones nobody has looked at yet.
        public var unreviewedCount: Int
        public var checkingNames: [String]
        /// No checking account is connected, so the starting balance was entered by hand.
        public var usesManualBalance: Bool
        public var balanceAsOf: Date?
        public var cards: [Card]
        /// The day of the month card payments usually leave checking, from history.
        public var usualCardPaymentDay: Int?
        public var savingsCents: Int

        public var hasPaydays: Bool { forecast.events.contains { $0.kind == .payday } }
        public var cardsWithoutDueDay: [Card] { cards.filter { $0.dueDay == 0 && $0.balanceCents > 0 } }
    }

    /// Plaid categories that move money rather than spend it.
    static let movementCategories: Set<String> = ["TRANSFER_IN", "TRANSFER_OUT", "LOAN_PAYMENTS"]

    /// Checking accounts the forecast follows.
    public static func checkingAccounts(_ accounts: [BankAccount]) -> [BankAccount] {
        let visible = accounts.filter { !$0.isHidden && $0.type == "depository" }
        let checking = visible.filter { $0.subtype == "checking" }
        return checking.isEmpty ? visible.filter { !["savings", "money market", "cd"].contains($0.subtype) } : checking
    }

    public static func snapshot(in context: ModelContext, today: Date = Date(), horizonDays: Int = 60, cushionCents: Int = 0,
                                manualBalanceCents: Int = 0, calendar: Calendar = .current) -> Snapshot {
        let today = calendar.startOfDay(for: today)
        let end = calendar.date(byAdding: .day, value: max(1, horizonDays) - 1, to: today) ?? today
        let accounts = ((try? context.fetch(FetchDescriptor<BankAccount>())) ?? []).filter { !$0.isHidden }
        let checking = checkingAccounts(accounts)
        let checkingIDs = Set(checking.map(\.persistentModelID))
        let cards = accounts.filter { $0.type == "credit" }
        let cardIDs = Set(cards.map(\.persistentModelID))
        let savings = accounts.filter { $0.type == "depository" && !checkingIDs.contains($0.persistentModelID) }
        func balance(_ account: BankAccount) -> Int { account.availableBalanceCents ?? account.currentBalanceCents ?? 0 }

        // History: checking (or, with nothing connected, transactions without an account) and cards.
        let since = calendar.date(byAdding: .day, value: -RecurringDetector.lookbackDays, to: today) ?? today
        let deleted = TransactionStatus.deleted.rawValue
        let transactions = (try? context.fetch(FetchDescriptor<LedgerTransaction>(predicate: #Predicate { $0.date >= since && $0.statusRaw != deleted }))) ?? []
        func entry(_ transaction: LedgerTransaction) -> CashFlowHistoryEntry {
            CashFlowHistoryEntry(date: transaction.date, amountCents: transaction.amountCents, isIncome: transaction.isIncome,
                                 merchant: transaction.merchant, category: transaction.bankCategory,
                                 seriesIDs: (transaction.allocations ?? []).compactMap { $0.item?.seriesID })
        }
        var cash = transactions.filter { transaction in
            transaction.account.map { checkingIDs.contains($0.persistentModelID) } ?? checking.isEmpty
        }.map(entry)
        let cardHistory = transactions.filter { $0.account.map { cardIDs.contains($0.persistentModelID) } ?? false }.map(entry)
        RecurringDetector.markCardPayments(&cash, cardHistory: cardHistory, calendar: calendar)
        let patterns = RecurringDetector.detect(cash, today: today, calendar: calendar)

        // Paychecks and bills: detected ones as the person left them, plus ones added by hand.
        let flows = (try? context.fetch(FetchDescriptor<RecurringFlow>())) ?? []
        let decisions = Dictionary(flows.filter { !$0.isManual }.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
        var schedules: [CashFlowSchedule] = []
        for pattern in patterns {
            let decision = decisions[pattern.id]
            guard decision?.isIgnored != true else { continue }
            let customAmount = decision.map { $0.amountCents > 0 } ?? false
            schedules.append(CashFlowSchedule(
                id: pattern.id, name: decision.map { $0.name.isEmpty ? pattern.name : $0.name } ?? pattern.name,
                isIncome: pattern.isIncome, amountCents: customAmount ? decision?.amountCents ?? 0 : pattern.amountCents,
                cadence: pattern.cadence, nextDate: pattern.nextDate(calendar: calendar), monthDays: pattern.monthDays,
                isEstimate: pattern.isVariable && !customAmount, coversSeriesID: covers(decision, pattern)))
        }
        for flow in flows where flow.isManual && !flow.isIgnored {
            if let schedule = schedule(for: flow, today: today, calendar: calendar) { schedules.append(schedule) }
        }

        let cardPayments = cards.compactMap { card -> CardPayment? in
            guard card.paymentDueDay > 0 else { return nil }
            let fixed = card.paymentFixedCents
            return CardPayment(id: "card:\(card.uuid)", name: card.displayName, dueDay: card.paymentDueDay,
                               amountCents: fixed > 0 ? fixed : max(0, card.currentBalanceCents ?? 0), repeats: fixed > 0)
        }
        let cardPaymentDays = cash.filter(\.isCardPayment).map { calendar.startOfDay(for: $0.date) }

        // Spending this month that hasn't been assigned yet still uses up everyday budget.
        let current = MonthKey(date: today, calendar: calendar)
        let billMerchants = Set(patterns.filter { !$0.isIncome }.map { merchantKey(of: $0.id) })
        let unassigned = (cash + cardHistory).filter { entry in
            !entry.isIncome && !entry.isCardPayment && entry.seriesIDs.isEmpty && current.contains(entry.date, calendar: calendar)
                && !movementCategories.contains(entry.category ?? "")
                && !billMerchants.contains(Ledger.normalizedMerchant(RecurringDetector.displayName(entry.merchant)))
        }.reduce(0) { $0 + $1.amountCents }

        let (bills, everyday) = budget(in: context, today: today, end: end, current: current, covered: Set(schedules.compactMap(\.coversSeriesID)),
                                       unassignedCents: unassigned, calendar: calendar)
        let inputs = CashFlowInputs(today: today, horizonDays: horizonDays,
                                    startingCents: checking.isEmpty ? manualBalanceCents : checking.reduce(0) { $0 + balance($1) },
                                    cushionCents: cushionCents, schedules: schedules, cards: cardPayments, budgetBills: bills,
                                    everyday: everyday, savingsCents: savings.reduce(0) { $0 + max(0, balance($1)) })
        return Snapshot(
            forecast: CashFlowForecast.make(inputs, calendar: calendar),
            patterns: patterns,
            unreviewedCount: patterns.filter { decisions[$0.id] == nil }.count,
            checkingNames: checking.map(\.displayName),
            usesManualBalance: checking.isEmpty,
            balanceAsOf: checking.compactMap { $0.link?.lastSyncedAt }.min(),
            cards: cards.map { Card(id: $0.uuid, name: $0.displayName, balanceCents: max(0, $0.currentBalanceCents ?? 0),
                                    dueDay: $0.paymentDueDay, fixedCents: $0.paymentFixedCents) },
            usualCardPaymentDay: cardPaymentDays.count >= 2 ? RecurringDetector.typicalDay(cardPaymentDays, calendar: calendar) : nil,
            savingsCents: inputs.savingsCents)
    }

    /// Budget items with due days become dated bills; the rest of the plan is everyday spending.
    /// Months without a plan borrow the latest earlier one. Funds stay in checking until spent, so they're left out.
    static func budget(in context: ModelContext, today: Date, end: Date, current: MonthKey, covered: Set<UUID>, unassignedCents: Int,
                       calendar: Calendar) -> ([BudgetBill], [EverydaySpending]) {
        let months = (try? context.fetch(FetchDescriptor<BudgetMonth>(sortBy: [SortDescriptor(\.key)]))) ?? []
        var bills: [BudgetBill] = []
        var everyday: [EverydaySpending] = []
        var key = current
        let last = MonthKey(date: end, calendar: calendar)
        while key <= last {
            defer { key = key.next }
            let exact = months.first { $0.key == key.id }
            guard let plan = exact ?? months.last(where: { $0.monthKey < key }) else { continue }
            let isThisMonth = key == current && exact != nil
            var pool = 0
            var plannedPool = 0
            for item in plan.expenseGroups.flatMap(\.sortedItems) where !item.isFund && !covered.contains(item.seriesID) {
                if item.dueDay == 0 { plannedPool += item.plannedCents }
                let left = isThisMonth ? max(0, item.plannedCents - BudgetMath.activity(of: item)) : item.plannedCents
                guard left > 0 else { continue }
                if item.dueDay > 0 {
                    let date = key.day(item.dueDay, calendar: calendar)
                    if date >= today {
                        bills.append(BudgetBill(seriesID: item.seriesID, name: item.name, date: date, amountCents: left, isEstimate: exact == nil))
                    }
                } else {
                    pool += left
                }
            }
            let start = key == current ? today : key.firstDay(calendar: calendar)
            if key == current {
                // What's left this month, but never faster than the plan's usual pace: budget left over on
                // the last few days is more likely saved than spent all at once.
                let daysInMonth = calendar.range(of: .day, in: .month, for: today)?.count ?? 30
                let daysLeft = (calendar.dateComponents([.day], from: today, to: key.lastDay(calendar: calendar)).day ?? 0) + 1
                pool = min(max(0, pool - unassignedCents), plannedPool * daysLeft / daysInMonth)
            }
            everyday.append(EverydaySpending(start: start, end: key.lastDay(calendar: calendar), amountCents: pool))
        }
        return (bills, everyday)
    }

    static func schedule(for flow: RecurringFlow, today: Date, calendar: Calendar) -> CashFlowSchedule? {
        guard let next = flow.nextDate, flow.amountCents > 0 else { return nil }
        let day = calendar.component(.day, from: next)
        let monthDays: [Int] = switch flow.cadence {
        case .monthly: [day]
        case .semimonthly: [day, day > 15 ? day - 15 : day + 15].sorted()
        case .weekly, .biweekly: []
        }
        // An added bill keeps going after its first date passes.
        var date = calendar.startOfDay(for: next)
        let cutoff = calendar.date(byAdding: .day, value: -CashFlowForecast.graceDays, to: today) ?? today
        while date < cutoff {
            date = CashFlowSchedule.following(date, cadence: flow.cadence, monthDays: monthDays, calendar: calendar)
        }
        return CashFlowSchedule(id: "manual:\(flow.uuid)", name: flow.name.isEmpty ? (flow.isIncome ? "Paycheck" : "Bill") : flow.name,
                                isIncome: flow.isIncome, amountCents: flow.amountCents, cadence: flow.cadence, nextDate: date,
                                monthDays: monthDays, coversSeriesID: flow.coversSeriesID)
    }

    /// The budget item a detected bill pays: the person's choice, else the item its charges were assigned to.
    public static func covers(_ decision: RecurringFlow?, _ pattern: RecurringPattern) -> UUID? {
        guard let chosen = decision?.coversSeriesID else { return pattern.seriesID }
        return chosen == RecurringFlow.notInBudget ? nil : chosen
    }

    /// "out:harbor home loans#2" → "harbor home loans"
    static func merchantKey(of patternID: String) -> String {
        let withoutDirection = patternID.split(separator: ":", maxSplits: 1).last.map(String.init) ?? patternID
        return withoutDirection.split(separator: "#").first.map(String.init) ?? withoutDirection
    }

    // MARK: Choices

    /// The saved choice for a detected paycheck or bill, created the first time it's needed.
    public static func decision(for pattern: RecurringPattern, in context: ModelContext) -> RecurringFlow {
        let key = pattern.id
        if let existing = try? context.fetch(FetchDescriptor<RecurringFlow>(predicate: #Predicate { $0.key == key })).first {
            return existing
        }
        let flow = RecurringFlow(key: key, isIncome: pattern.isIncome)
        flow.cadence = pattern.cadence
        context.insert(flow)
        return flow
    }

    /// Records that the person has seen every detected paycheck and bill, keeping earlier choices.
    public static func markReviewed(_ patterns: [RecurringPattern], in context: ModelContext) {
        for pattern in patterns { _ = decision(for: pattern, in: context) }
        try? context.save()
    }
}
