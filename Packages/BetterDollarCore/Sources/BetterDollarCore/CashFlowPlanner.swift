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
        /// The due day that was set; 0 when it wasn't.
        public var dueDay: Int
        public var mode: CardPaymentMode
        /// When and how much checking has paid it before.
        public var habit: CardHabit?
        /// What paying the statement would send on the next due date, once the day is known.
        public var statementCents: Int?
        /// The budget item its payments pay for, chosen or matched by name.
        public var coversSeriesID: UUID?
        /// Budget items whose spending has mostly been charged to this card, so it's counted on the card.
        public var chargedItemNames: [String] = []
        /// Budget items nothing has been charged to yet, counted here because most everyday items are charged to this card.
        public var assumedItemNames: [String] = []
        public var estimatedMinimumCents: Int
        /// Its payments in the forecast.
        public var payments: [CashFlowEvent]

        /// No day was set, so it's paid on the day it usually is.
        public var usesUsualDay: Bool { dueDay == 0 && habit != nil && mode != .elsewhere }
    }

    /// A budget income line the forecast doesn't see.
    public struct MissingIncome: Sendable, Hashable {
        public var name: String
        public var cents: Int
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
        public var savingsCents: Int
        /// Income the budget plans that no paycheck in the forecast matches, so it isn't counted.
        public var missingIncome: [MissingIncome] = []

        public var hasPaydays: Bool { forecast.events.contains { $0.kind == .payday } }
        /// Cards with a balance the forecast can't place: no day set and none found in history.
        public var cardsWithoutDueDay: [Card] { cards.filter { $0.dueDay == 0 && $0.habit == nil && $0.mode != .elsewhere && $0.balanceCents > 0 } }
        /// Cards with a balance placed on the day they're usually paid, until someone confirms it.
        public var cardsOnUsualDay: [Card] { cards.filter { $0.usesUsualDay && $0.balanceCents > 0 } }
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
        var historyByCard: [PersistentIdentifier: [CashFlowHistoryEntry]] = [:]
        for transaction in transactions {
            guard let account = transaction.account, cardIDs.contains(account.persistentModelID) else { continue }
            historyByCard[account.persistentModelID, default: []].append(entry(transaction))
        }
        let cardHistory = historyByCard.values.flatMap { $0 }
        RecurringDetector.markCardPayments(&cash, cardHistory: cardHistory, calendar: calendar)
        var patterns = RecurringDetector.detect(cash, today: today, calendar: calendar)

        // Paychecks and bills: detected ones as the person left them, plus ones added by hand.
        let flows = (try? context.fetch(FetchDescriptor<RecurringFlow>())) ?? []
        let decisions = Dictionary(flows.filter { !$0.isManual }.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
        let current = MonthKey(date: today, calendar: calendar)
        var planItems = currentPlanItems(in: context, current: current).filter { !$0.isFund && $0.plannedCents > 0 }
        linkByAmount(&patterns, items: &planItems, decisions: decisions)
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

        // Cards: paid on the day that was set, or the day checking usually pays them.
        var cardPayments: [CardPayment] = []
        var cardInfo: [Card] = []
        for card in cards {
            let history = historyByCard[card.persistentModelID] ?? []
            let habit = RecurringDetector.cardHabit(RecurringDetector.payments(to: history, from: cash), today: today, calendar: calendar)
            let owed = max(0, card.currentBalanceCents ?? 0)
            let mode = card.paymentMode
            let dueDay = card.paymentDueDay > 0 ? card.paymentDueDay : habit?.day ?? 0
            let statement = dueDay > 0 ? CardPayment.statementRemaining(owedCents: owed, cardHistory: history, dueDay: dueDay,
                                                                         closeDay: card.statementCloseDay, today: today, calendar: calendar) : nil
            let fixed = card.paymentFixedCents
            let minimum = CardPayment.estimatedMinimum(owedCents: owed)
            let chosen = card.paymentCoversSeriesID.map { $0 == RecurringFlow.notInBudget ? nil : $0 }
            cardInfo.append(Card(id: card.uuid, name: card.displayName, balanceCents: owed, dueDay: card.paymentDueDay, mode: mode,
                                 habit: habit, statementCents: statement, coversSeriesID: chosen ?? nil, estimatedMinimumCents: minimum, payments: []))
            guard mode != .elsewhere, dueDay > 0 else { continue }
            let plan: CardPayment.Plan = switch mode {
            case .balance: .balance
            case .minimum: .monthly(fixed > 0 ? fixed : minimum)
            case .usual: habit.map { .monthly($0.monthlyCents) } ?? .statement(remainingCents: statement ?? owed)
            case .fixed where fixed > 0: .monthly(fixed)
            default: .statement(remainingCents: statement ?? owed)
            }
            let guessesAmount = mode == .minimum && fixed == 0
            let note: String? = switch (guessesAmount, card.paymentDueDay == 0) {
            case (true, true): "Estimated minimum, on your usual payment day"
            case (true, false): "Estimated minimum"
            case (false, true): "On your usual payment day"
            case (false, false): nil
            }
            cardPayments.append(CardPayment(id: "card:\(card.uuid)", name: card.displayName, dueDay: dueDay, owedCents: owed, plan: plan,
                                            splitsWithPay: card.paymentSplitsWithPay, isEstimate: guessesAmount || card.paymentDueDay == 0,
                                            note: note, closeDay: card.statementCloseDay))
        }

        // A card nobody linked pays for the one budget item named like a card payment, if there's just one of each.
        let paid = Set(cardPayments.map(\.id))
        let unlinked = cardInfo.indices.filter { index in
            paid.contains("card:\(cardInfo[index].id)") && cards[index].paymentCoversSeriesID == nil
        }
        let named = planItems.filter { $0.name.lowercased().contains("card") }
        if unlinked.count == 1, named.count == 1, let index = unlinked.first {
            cardInfo[index].coversSeriesID = named[0].seriesID
        }

        // Spending is counted on a card, not from checking day by day, for the budget groups chosen for it, for
        // items mostly charged to it before and, when most everyday items are charged to it, for items nothing has
        // been charged to yet. A card paid from another account takes that spending out of the forecast; one without
        // a payment day leaves it in checking.
        let covered = Set(schedules.compactMap(\.coversSeriesID) + cardInfo.filter { paid.contains("card:\($0.id)") }.compactMap(\.coversSeriesID))
        var spentOn: [String: String] = [:]
        let counted = cards.filter { paid.contains("card:\($0.uuid)") || $0.paymentMode == .elsewhere }
        for card in counted {
            for name in card.cardGroupNames where spentOn[name] == nil { spentOn[name] = "card:\(card.uuid)" }
        }
        let poolOfCard = Dictionary(cards.map { ($0.persistentModelID, "card:\($0.uuid)") }, uniquingKeysWith: { first, _ in first })
        let countedIDs = Set(counted.map(\.persistentModelID))
        var chargedTo: [UUID: [PersistentIdentifier: Int]] = [:]
        for transaction in transactions where !transaction.isIncome {
            guard let account = transaction.account else { continue }
            for allocation in transaction.allocations ?? [] {
                guard let seriesID = allocation.item?.seriesID else { continue }
                chargedTo[seriesID, default: [:]][account.persistentModelID, default: 0] += allocation.amountCents
            }
        }
        let homes = chargedTo.compactMapValues { accounts in accounts.max { $0.value < $1.value }?.key }
        var itemCards = homes.compactMapValues { countedIDs.contains($0) ? poolOfCard[$0] : nil }
        let everydayItems = currentPlanItems(in: context, current: current).filter { !$0.isFund && $0.dueDay == 0 && !covered.contains($0.seriesID) }
        let homeCounts = Dictionary(grouping: everydayItems.compactMap { homes[$0.seriesID] }) { $0 }.mapValues(\.count)
        var assumed: Set<UUID> = []
        if let top = homeCounts.max(by: { $0.value < $1.value }), top.value * 2 > homeCounts.values.reduce(0, +),
           countedIDs.contains(top.key), let pool = poolOfCard[top.key] {
            for item in everydayItems where homes[item.seriesID] == nil {
                itemCards[item.seriesID] = pool
                assumed.insert(item.seriesID)
            }
        }
        let groupCards = Set(spentOn.values).union(itemCards.values)
        let planNames = Dictionary(currentPlanItems(in: context, current: current).map { ($0.seriesID, $0.name) }, uniquingKeysWith: { first, _ in first })
        for index in cardInfo.indices {
            let mine = itemCards.filter { $0.value == "card:\(cardInfo[index].id)" }
            cardInfo[index].chargedItemNames = mine.keys.filter { !assumed.contains($0) }.compactMap { planNames[$0] }.sorted()
            cardInfo[index].assumedItemNames = mine.keys.filter { assumed.contains($0) }.compactMap { planNames[$0] }.sorted()
        }

        // Spending this month that hasn't been assigned yet still uses up everyday budget, on the card it was charged to.
        let billMerchants = Set(patterns.filter { !$0.isIncome }.map { merchantKey(of: $0.id) })
        func unassigned(_ entries: [CashFlowHistoryEntry]) -> Int {
            entries.filter { entry in
                !entry.isIncome && !entry.isCardPayment && entry.seriesIDs.isEmpty && current.contains(entry.date, calendar: calendar)
                    && !movementCategories.contains(entry.category ?? "")
                    && !billMerchants.contains(Ledger.normalizedMerchant(RecurringDetector.displayName(entry.merchant)))
            }.reduce(0) { $0 + $1.amountCents }
        }
        var unassignedCents: [String: Int] = ["": unassigned(cash)]
        for (id, history) in historyByCard {
            let pool = poolOfCard[id].flatMap { groupCards.contains($0) ? $0 : nil } ?? ""
            unassignedCents[pool, default: 0] += unassigned(history)
        }

        let (bills, spending) = budget(in: context, today: today, end: end, current: current, covered: covered, spentOn: spentOn,
                                       itemCards: itemCards, unassignedCents: unassignedCents, calendar: calendar)
        let everyday = spending[""] ?? []
        for index in cardPayments.indices {
            cardPayments[index].spending = spending[cardPayments[index].id] ?? []
        }
        let inputs = CashFlowInputs(today: today, horizonDays: horizonDays,
                                    startingCents: checking.isEmpty ? manualBalanceCents : checking.reduce(0) { $0 + balance($1) },
                                    cushionCents: cushionCents, schedules: schedules, cards: cardPayments, budgetBills: bills,
                                    everyday: everyday, savingsCents: savings.reduce(0) { $0 + max(0, balance($1)) })
        let forecast = CashFlowForecast.make(inputs, calendar: calendar)
        let paychecks = schedules.filter(\.isIncome)
        let planned = (currentPlan(in: context, current: current)?.sortedGroups ?? []).filter(\.isIncome).flatMap(\.sortedItems)
        let missingIncome = planned.filter { item in
            item.plannedCents > 0 && !paychecks.contains { paycheck in
                abs(paycheck.amountCents - item.plannedCents) * 100 <= item.plannedCents
                    || !significantWords(paycheck.name).isDisjoint(with: significantWords(item.name))
            }
        }.map { MissingIncome(name: $0.name, cents: $0.plannedCents) }
        for index in cardInfo.indices {
            cardInfo[index].payments = forecast.events.filter { $0.id.hasPrefix("card:\(cardInfo[index].id)") }
        }
        return Snapshot(
            forecast: forecast,
            patterns: patterns,
            unreviewedCount: patterns.filter { decisions[$0.id] == nil }.count,
            checkingNames: checking.map(\.displayName),
            usesManualBalance: checking.isEmpty,
            balanceAsOf: checking.compactMap { $0.link?.lastSyncedAt }.min(),
            cards: cardInfo,
            savingsCents: inputs.savingsCents,
            missingIncome: missingIncome)
    }

    /// Budget items with due days become dated bills; the rest of the plan is everyday spending.
    /// Months without a plan borrow the latest earlier one. Funds stay in checking until spent, so they're left out.
    /// Groups in `spentOn` and items in `itemCards` are spent on that card instead, keyed by its payment's ID;
    /// checking's spending is under "".
    static func budget(in context: ModelContext, today: Date, end: Date, current: MonthKey, covered: Set<UUID>, spentOn: [String: String] = [:],
                       itemCards: [UUID: String] = [:], unassignedCents: [String: Int], calendar: Calendar) -> ([BudgetBill], [String: [EverydaySpending]]) {
        let months = (try? context.fetch(FetchDescriptor<BudgetMonth>(sortBy: [SortDescriptor(\.key)]))) ?? []
        var bills: [BudgetBill] = []
        var spending: [String: [EverydaySpending]] = [:]
        var key = current
        let last = MonthKey(date: end, calendar: calendar)
        while key <= last {
            defer { key = key.next }
            let exact = months.first { $0.key == key.id }
            guard let plan = exact ?? months.last(where: { $0.monthKey < key }) else { continue }
            let isThisMonth = key == current && exact != nil
            let start = key == current ? today : key.firstDay(calendar: calendar)
            var pools: [String: Int] = [:]
            var plannedPools: [String: Int] = [:]
            for group in plan.expenseGroups {
                for item in group.sortedItems where !item.isFund && !covered.contains(item.seriesID) {
                    let pool = spentOn[group.name] ?? itemCards[item.seriesID] ?? ""
                    if item.dueDay == 0 { plannedPools[pool, default: 0] += item.plannedCents }
                    let left = isThisMonth ? max(0, item.plannedCents - BudgetMath.activity(of: item)) : item.plannedCents
                    guard left > 0 else { continue }
                    if item.dueDay > 0 {
                        let date = key.day(item.dueDay, calendar: calendar)
                        guard date >= today else { continue }
                        if pool.isEmpty {
                            bills.append(BudgetBill(seriesID: item.seriesID, name: item.name, date: date, amountCents: left, isEstimate: exact == nil))
                        } else {
                            // Charged to the card on its day.
                            spending[pool, default: []].append(EverydaySpending(start: date, end: date, amountCents: left))
                        }
                    } else {
                        pools[pool, default: 0] += left
                    }
                }
            }
            for pool in Set(pools.keys).union([""]) {
                var amount = pools[pool] ?? 0
                if key == current {
                    // What's left this month, but never faster than the plan's usual pace: budget left over on
                    // the last few days is more likely saved than spent all at once.
                    let daysInMonth = calendar.range(of: .day, in: .month, for: today)?.count ?? 30
                    let daysLeft = (calendar.dateComponents([.day], from: today, to: key.lastDay(calendar: calendar)).day ?? 0) + 1
                    amount = min(max(0, amount - (unassignedCents[pool] ?? 0)), (plannedPools[pool] ?? 0) * daysLeft / daysInMonth)
                }
                spending[pool, default: []].append(EverydaySpending(start: start, end: key.lastDay(calendar: calendar), amountCents: amount))
            }
        }
        return (bills, spending)
    }

    /// This month's plan, or the latest one before it.
    public static func currentPlan(in context: ModelContext, current: MonthKey = .current()) -> BudgetMonth? {
        let months = (try? context.fetch(FetchDescriptor<BudgetMonth>(sortBy: [SortDescriptor(\.key)]))) ?? []
        return months.last { $0.monthKey <= current } ?? months.first
    }

    public static func currentPlanItems(in context: ModelContext, current: MonthKey = .current()) -> [BudgetItem] {
        (currentPlan(in: context, current: current)?.expenseGroups ?? []).flatMap(\.sortedItems)
    }

    /// A bill nobody has linked pays for a budget item: first one planned at exactly its amount, or at exactly what one
    /// company's payments add up to (a loan and its escrow); then one named in the bill's name ("Water" in "County
    /// Department of Water"); then the closest within 10% of its amount. Each item is matched once and leaves `items`.
    static func linkByAmount(_ patterns: inout [RecurringPattern], items: inout [BudgetItem], decisions: [String: RecurringFlow]) {
        let linked = Set(patterns.compactMap { covers(decisions[$0.id], $0) })
        items.removeAll { linked.contains($0.seriesID) }
        func amount(_ pattern: RecurringPattern) -> Int {
            decisions[pattern.id].flatMap { $0.amountCents > 0 ? $0.amountCents : nil } ?? pattern.amountCents
        }
        func take(where matches: (BudgetItem) -> Bool, onlyOne: Bool = false) -> UUID? {
            let found = items.indices.filter { matches(items[$0]) }
            guard let index = found.first, !onlyOne || found.count == 1 else { return nil }
            return items.remove(at: index).seriesID
        }
        var open: [Int] {
            patterns.indices.filter { !patterns[$0].isIncome && covers(decisions[patterns[$0].id], patterns[$0]) == nil
                && decisions[patterns[$0].id]?.coversSeriesID == nil }
        }
        for index in open {
            patterns[index].seriesID = take { $0.plannedCents == amount(patterns[index]) }
        }
        let byCompany = Dictionary(grouping: open) { merchantKey(of: patterns[$0].id) }
        for indices in byCompany.values where indices.count > 1 {
            let total = indices.reduce(0) { $0 + amount(patterns[$1]) }
            guard let seriesID = take(where: { $0.plannedCents == total }) else { continue }
            for index in indices { patterns[index].seriesID = seriesID }
        }
        for index in open {
            let words = significantWords(patterns[index].name)
            patterns[index].seriesID = take(where: { !significantWords($0.name).isDisjoint(with: words) }, onlyOne: true)
        }
        for index in open {
            let cents = amount(patterns[index])
            let close = items.filter { abs($0.plannedCents - cents) * 10 <= cents }.map { abs($0.plannedCents - cents) }.sorted()
            guard let nearest = close.first, close.dropFirst().first != nearest else { continue }
            patterns[index].seriesID = take(where: { abs($0.plannedCents - cents) == nearest })
        }
    }

    /// Words that say what a bill or budget item is, without the ones every bill shares.
    static func significantWords(_ name: String) -> Set<String> {
        let common: Set<String> = ["payment", "payments", "bill", "bills", "bank", "card", "credit", "loan", "loans", "monthly",
                                   "service", "services", "company", "department", "county", "city",
                                   "paycheck", "income", "salary", "direct", "deposit", "payroll"]
        return Set(name.lowercased().split { !$0.isLetter }.map(String.init).filter { $0.count >= 4 && !common.contains($0) })
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
