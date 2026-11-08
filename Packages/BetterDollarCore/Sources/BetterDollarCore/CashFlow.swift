import Foundation

// Cash flow maps known bills onto paydays and walks the checking balance forward day by day,
// so a dip below zero shows up before it happens. Everything here is plain values, so it runs
// the same in the app, in tests and against exported history.

// MARK: - Schedules

/// How often a paycheck or bill repeats. A one-time payment is added by hand; history never finds one.
public enum Cadence: String, Codable, Sendable, CaseIterable, Identifiable {
    case once, weekly, biweekly, semimonthly, monthly

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .once: "Just once"
        case .weekly: "Every week"
        case .biweekly: "Every 2 weeks"
        case .semimonthly: "Twice a month"
        case .monthly: "Every month"
        }
    }

    /// Roughly how many days apart occurrences are.
    var interval: Int {
        switch self {
        case .once: 0
        case .weekly: 7
        case .biweekly: 14
        case .semimonthly: 15
        case .monthly: 30
        }
    }
}

/// A repeating paycheck or bill: its next date and how it continues.
public struct CashFlowSchedule: Sendable, Hashable, Identifiable {
    public var id: String
    public var name: String
    public var isIncome: Bool
    public var amountCents: Int
    public var cadence: Cadence
    /// The next expected date. It can be in the past when a payment hasn't shown up yet.
    public var nextDate: Date
    /// Days of the month for monthly (one) and twice-a-month (two) schedules.
    public var monthDays: [Int]
    /// The amount changes from time to time, so this is a typical figure.
    public var isEstimate: Bool
    /// The budget item series this pays, so that item isn't counted a second time.
    public var coversSeriesID: UUID?

    public init(id: String, name: String, isIncome: Bool, amountCents: Int, cadence: Cadence, nextDate: Date,
                monthDays: [Int] = [], isEstimate: Bool = false, coversSeriesID: UUID? = nil) {
        self.id = id
        self.name = name
        self.isIncome = isIncome
        self.amountCents = amountCents
        self.cadence = cadence
        self.nextDate = nextDate
        self.monthDays = monthDays
        self.isEstimate = isEstimate
        self.coversSeriesID = coversSeriesID
    }

    /// Occurrences from `nextDate` through `end`.
    public func dates(through end: Date, calendar: Calendar = .current) -> [Date] {
        var dates: [Date] = []
        var date = calendar.startOfDay(for: nextDate)
        while date <= end, dates.count < 500 {
            dates.append(date)
            date = Self.following(date, cadence: cadence, monthDays: monthDays, calendar: calendar)
        }
        return dates
    }

    /// The occurrence after `date`.
    public static func following(_ date: Date, cadence: Cadence, monthDays: [Int], calendar: Calendar = .current) -> Date {
        let day = calendar.startOfDay(for: date)
        switch cadence {
        case .once:
            return .distantFuture
        case .weekly:
            return calendar.date(byAdding: .day, value: 7, to: day) ?? day
        case .biweekly:
            return calendar.date(byAdding: .day, value: 14, to: day) ?? day
        case .monthly, .semimonthly:
            let tomorrow = calendar.date(byAdding: .day, value: 1, to: day) ?? day
            return first(onOrAfter: tomorrow, monthDays: monthDays.isEmpty ? [calendar.component(.day, from: day)] : monthDays, calendar: calendar)
        }
    }

    /// The first of `monthDays` (clamped to short months) on or after `date`.
    public static func first(onOrAfter date: Date, monthDays: [Int], calendar: Calendar = .current) -> Date {
        let day = calendar.startOfDay(for: date)
        let days = monthDays.isEmpty ? [1] : monthDays.sorted()
        var month = MonthKey(date: day, calendar: calendar)
        for _ in 0..<3 {
            for candidate in days.map({ month.day($0, calendar: calendar) }) where candidate >= day { return candidate }
            month = month.next
        }
        return month.day(days[0], calendar: calendar)
    }
}

public extension MonthKey {
    /// The given day in this month, clamped to the month's length (the 31st of November is the 30th).
    func day(_ day: Int, calendar: Calendar = .current) -> Date {
        let first = firstDay(calendar: calendar)
        let count = calendar.range(of: .day, in: .month, for: first)?.count ?? 28
        return calendar.date(from: DateComponents(year: year, month: month, day: min(max(1, day), count))) ?? first
    }

    func lastDay(calendar: Calendar = .current) -> Date {
        day(31, calendar: calendar)
    }
}

// MARK: - Finding paychecks and bills in history

/// A past transaction, reduced to what cash flow needs.
public struct CashFlowHistoryEntry: Sendable, Hashable {
    public var date: Date
    public var amountCents: Int
    public var isIncome: Bool
    public var merchant: String
    public var category: String?
    /// Budget item series the transaction was assigned to.
    public var seriesIDs: [UUID]
    /// Money sent to pay a credit card. The forecast counts the card's payment instead.
    public var isCardPayment: Bool

    public init(date: Date, amountCents: Int, isIncome: Bool, merchant: String, category: String? = nil,
                seriesIDs: [UUID] = [], isCardPayment: Bool = false) {
        self.date = date
        self.amountCents = amountCents
        self.isIncome = isIncome
        self.merchant = merchant
        self.category = category
        self.seriesIDs = seriesIDs
        self.isCardPayment = isCardPayment
    }
}

/// A paycheck or bill that repeats in the history.
public struct RecurringPattern: Sendable, Hashable, Identifiable {
    /// Stable across syncs: direction, merchant and, when one merchant has several, which amount.
    public var id: String
    public var name: String
    public var isIncome: Bool
    public var cadence: Cadence
    public var amountCents: Int
    public var isVariable: Bool
    public var dates: [Date]
    public var monthDays: [Int]
    public var category: String?
    /// The budget item series it pays: the one its transactions were assigned to most, or one planned at exactly its amount.
    public var seriesID: UUID?

    public var lastDate: Date { dates.last ?? .distantPast }

    /// Paychecks keep their rhythm exactly. Bills drift around a due day, so the next one is the first
    /// due day a few weeks after the last payment.
    public func nextDate(calendar: Calendar = .current) -> Date {
        switch cadence {
        case .once, .weekly, .biweekly:
            return CashFlowSchedule.following(lastDate, cadence: cadence, monthDays: monthDays, calendar: calendar)
        case .monthly, .semimonthly:
            let earliest = calendar.date(byAdding: .day, value: cadence == .monthly ? 20 : 8, to: lastDate) ?? lastDate
            return CashFlowSchedule.first(onOrAfter: earliest, monthDays: monthDays, calendar: calendar)
        }
    }
}

public enum RecurringDetector {
    /// Smaller deposits (interest, cash back) aren't paychecks.
    static let minimumIncomeCents = 50_00
    static let lookbackDays = 200

    public static func detect(_ history: [CashFlowHistoryEntry], today: Date, calendar: Calendar = .current) -> [RecurringPattern] {
        let today = calendar.startOfDay(for: today)
        guard let since = calendar.date(byAdding: .day, value: -lookbackDays, to: today) else { return [] }
        var groups: [String: [CashFlowHistoryEntry]] = [:]
        for entry in history where !entry.isCardPayment && entry.amountCents > 0 && entry.date >= since {
            let merchant = Ledger.normalizedMerchant(displayName(entry.merchant))
            guard !merchant.isEmpty else { continue }
            groups[(entry.isIncome ? "in:" : "out:") + merchant, default: []].append(entry)
        }
        var patterns: [RecurringPattern] = []
        for (key, entries) in groups {
            let streams = streams(in: entries, calendar: calendar)
            for (index, stream) in streams.enumerated() {
                let id = streams.count > 1 ? "\(key)#\(index + 1)" : key
                if let pattern = pattern(id: id, entries: stream, today: today, calendar: calendar) {
                    patterns.append(pattern)
                }
            }
        }
        return patterns.sorted {
            ($0.isIncome ? 0 : 1, $0.nextDate(calendar: calendar), $0.name) < ($1.isIncome ? 0 : 1, $1.nextDate(calendar: calendar), $1.name)
        }
    }

    /// Marks money sent from checking that arrives on a credit card.
    public static func markCardPayments(_ cash: inout [CashFlowHistoryEntry], cardHistory: [CashFlowHistoryEntry], calendar: Calendar = .current) {
        let received = cardHistory.filter(\.isIncome)
        for index in cash.indices where !cash[index].isIncome {
            let sent = cash[index]
            cash[index].isCardPayment = received.contains { arrived(sent, as: $0) }
        }
    }

    /// Money sent from checking that arrived on this card.
    public static func payments(to cardHistory: [CashFlowHistoryEntry], from cash: [CashFlowHistoryEntry]) -> [CashFlowHistoryEntry] {
        let received = cardHistory.filter(\.isIncome)
        return cash.filter { sent in !sent.isIncome && received.contains { arrived(sent, as: $0) } }
    }

    /// A card payment shows up on the card for the same amount within a few days.
    static func arrived(_ sent: CashFlowHistoryEntry, as received: CashFlowHistoryEntry) -> Bool {
        received.amountCents == sent.amountCents && abs(received.date.timeIntervalSince(sent.date)) <= 5 * 86_400
    }

    /// When checking usually pays a card and how much a month: payments in at least two months, the latest recent.
    public static func cardHabit(_ payments: [CashFlowHistoryEntry], today: Date, calendar: Calendar = .current) -> CardHabit? {
        let today = calendar.startOfDay(for: today)
        let days = payments.map { calendar.startOfDay(for: $0.date) }.sorted()
        let months = Dictionary(grouping: payments) { MonthKey(date: $0.date, calendar: calendar) }
        guard months.count >= 2, let last = days.last, (calendar.dateComponents([.day], from: last, to: today).day ?? 0) <= 62 else { return nil }
        // Whole months only; this one isn't over. Counted high, like bills.
        let current = MonthKey(date: today, calendar: calendar)
        let totals = months.filter { $0.key < current }.map { $0.value.reduce(0) { $0 + $1.amountCents } }
        guard !totals.isEmpty else { return nil }
        return CardHabit(day: typicalDay(days, calendar: calendar), monthlyCents: middle(totals, roundingUp: true))
    }

    /// One stream per merchant, unless the same merchant takes several payments on the same days
    /// (a mortgage and its escrow, say). Then each amount is its own stream, largest first.
    static func streams(in entries: [CashFlowHistoryEntry], calendar: Calendar) -> [[CashFlowHistoryEntry]] {
        var unique: [CashFlowHistoryEntry] = []
        for entry in entries.sorted(by: { $0.date < $1.date })
        where !unique.contains(where: { $0.amountCents == entry.amountCents && calendar.isDate($0.date, inSameDayAs: entry.date) }) {
            unique.append(entry)
        }
        let sharedDays = Dictionary(grouping: unique) { calendar.startOfDay(for: $0.date) }.values.filter { $0.count > 1 }.count
        guard sharedDays >= 2 else { return [unique] }
        var clusters: [[CashFlowHistoryEntry]] = []
        for entry in unique.sorted(by: { $0.amountCents < $1.amountCents }) {
            if let smallest = clusters.last?.first, Double(entry.amountCents) <= Double(smallest.amountCents) * 1.6 {
                clusters[clusters.count - 1].append(entry)
            } else {
                clusters.append([entry])
            }
        }
        return clusters
            .map { $0.sorted { $0.date < $1.date } }
            .sorted { middle($0.map(\.amountCents), roundingUp: true) > middle($1.map(\.amountCents), roundingUp: true) }
    }

    static func pattern(id: String, entries: [CashFlowHistoryEntry], today: Date, calendar: Calendar) -> RecurringPattern? {
        var days: [Date] = []
        for entry in entries {
            let day = calendar.startOfDay(for: entry.date)
            if days.last != day { days.append(day) }
        }
        guard days.count >= 2, let last = days.last, let (cadence, monthDays) = classify(days, calendar: calendar) else { return nil }
        let isIncome = entries[0].isIncome
        let amounts = entries.map(\.amountCents)
        // Paychecks are counted low and bills high, so the forecast errs on the safe side.
        let amount = middle(Array(amounts.suffix(3)), roundingUp: !isIncome)
        guard amount > 0, !(isIncome && amount < minimumIncomeCents) else { return nil }
        // Amounts that swing a lot aren't one bill. With only two payments, ask for more agreement.
        guard let low = amounts.min(), let high = amounts.max(),
              Double(high) <= Double(max(low, 1)) * (days.count == 2 ? 1.5 : 3) else { return nil }
        // Stopped repeating.
        let sinceLast = calendar.dateComponents([.day], from: last, to: today).day ?? 0
        guard Double(sinceLast) <= Double(cadence.interval) * 1.5 + 7 else { return nil }
        let recent = amounts.suffix(3)
        let spread = Double((recent.max() ?? 0) - (recent.min() ?? 0)) / Double(amount)
        return RecurringPattern(id: id, name: displayName(entries[entries.count - 1].merchant), isIncome: isIncome, cadence: cadence,
                                amountCents: amount, isVariable: spread > 0.15, dates: days, monthDays: monthDays,
                                category: mostCommon(entries.compactMap(\.category)), seriesID: mostCommon(entries.flatMap(\.seriesIDs)))
    }

    static func classify(_ days: [Date], calendar: Calendar) -> (Cadence, [Int])? {
        let gaps = zip(days, days.dropFirst()).compactMap { calendar.dateComponents([.day], from: $0, to: $1).day }
        guard !gaps.isEmpty else { return nil }
        let median = gaps.sorted()[(gaps.count - 1) / 2]
        func share(_ fits: (Int) -> Bool) -> Double { Double(gaps.filter(fits).count) / Double(gaps.count) }
        switch median {
        case 6...8 where days.count >= 4 && share({ (6...8).contains($0) || (13...15).contains($0) }) >= 0.75:
            return (.weekly, [])
        case 12...17 where days.count >= 3:
            if share({ $0 == 14 || $0 == 28 }) >= 0.75 { return (.biweekly, []) }
            if let pair = semimonthlyDays(days, calendar: calendar) { return (.semimonthly, pair) }
            if share({ (12...16).contains($0) || (26...30).contains($0) }) >= 0.75 { return (.biweekly, []) }
            return nil
        // Monthly, or once in each of several months in a row even when one was paid early or late.
        case 24...38 where share({ (24...38).contains($0) || (52...70).contains($0) }) >= 0.75 || oncePerMonth(days, calendar: calendar):
            return (.monthly, [typicalDay(days, calendar: calendar)])
        default:
            return nil
        }
    }

    /// One payment in each of at least three months in a row.
    static func oncePerMonth(_ days: [Date], calendar: Calendar) -> Bool {
        let months = days.map { MonthKey(date: $0, calendar: calendar) }
        return months.count >= 3 && zip(months, months.dropFirst()).allSatisfy { $1 == $0.next }
    }

    /// Two tight clusters of days of the month, such as the 1st and 15th or the 15th and the last day.
    static func semimonthlyDays(_ days: [Date], calendar: Calendar) -> [Int]? {
        let values = days.map { calendar.component(.day, from: $0) }.sorted()
        guard values.count >= 3 else { return nil }
        var split = 0
        var widest = -1
        for index in 1..<values.count where values[index] - values[index - 1] > widest {
            widest = values[index] - values[index - 1]
            split = index
        }
        let early = values[..<split]
        let late = values[split...]
        guard widest >= 8, let earlyLow = early.first, let earlyHigh = early.last, let lateLow = late.first, let lateHigh = late.last,
              earlyHigh - earlyLow <= 4, lateHigh - lateLow <= 4 else { return nil }
        let first = early[early.startIndex + (early.count - 1) / 2]
        let second = late[late.startIndex + (late.count - 1) / 2]
        return [first, second >= 28 ? 31 : second]
    }

    /// The day a monthly bill is due. Payments on the 31st and the 2nd are both "around the 1st",
    /// so late-month days count as the start of the next month when both appear. Ties go earlier.
    static func typicalDay(_ days: [Date], calendar: Calendar) -> Int {
        let values = days.map { calendar.component(.day, from: $0) }
        let wraps = values.contains { $0 <= 7 } && values.contains { $0 >= 24 }
        let adjusted = values.map { wraps && $0 >= 24 ? $0 - 31 : $0 }.sorted()
        let median = adjusted[(adjusted.count - 1) / 2]
        return median <= 0 ? 31 + median : median
    }

    /// "Direct deposit from Acme" reads better as "Acme".
    static func displayName(_ merchant: String) -> String {
        let trimmed = merchant.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowered = trimmed.lowercased()
        for prefix in ["direct deposit from ", "deposit from ", "from ", "to "] where lowered.hasPrefix(prefix) && trimmed.count > prefix.count + 2 {
            return String(trimmed.dropFirst(prefix.count))
        }
        return trimmed
    }

    static func middle(_ values: [Int], roundingUp: Bool) -> Int {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return 0 }
        return sorted[roundingUp ? sorted.count / 2 : (sorted.count - 1) / 2]
    }

    static func mostCommon<T: Hashable>(_ values: [T]) -> T? {
        Dictionary(grouping: values) { $0 }.max { $0.value.count < $1.value.count }?.key
    }
}

// MARK: - The forecast

/// How a credit card gets paid from checking.
public enum CardPaymentMode: String, CaseIterable, Identifiable, Sendable {
    case statement, balance, minimum, usual, fixed, elsewhere

    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .statement: "Statement balance"
        case .balance: "Full balance"
        case .minimum: "Minimum payment"
        case .usual: "What I usually pay"
        case .fixed: "A set amount"
        case .elsewhere: "Not from checking"
        }
    }
}

/// When checking usually pays a card, and how much in a month, from past payments.
public struct CardHabit: Sendable, Hashable {
    public var day: Int
    /// A typical whole month's payments.
    public var monthlyCents: Int
}

/// A credit card's payments. Card purchases leave checking only when the card is paid: what's owed today,
/// plus budget spending from the groups paid with the card as it builds up. Other card spending after today
/// is counted as everyday spending.
public struct CardPayment: Sendable, Hashable, Identifiable {
    /// One due date's payment and how much of it is budget spending charged after today.
    public struct Payment: Sendable, Hashable {
        public var date: Date
        public var cents: Int
        public var spendingCents: Int
    }

    public enum Plan: Sendable, Hashable {
        /// Everything owed on each due date.
        case balance
        /// What's left of the last statement on the next due date, then each later statement in full.
        case statement(remainingCents: Int)
        /// The same amount each due date, while anything is owed.
        case monthly(Int)
    }

    public var id: String
    public var name: String
    public var dueDay: Int
    /// What's owed today.
    public var owedCents: Int
    public var plan: Plan
    /// Pay in parts on the paydays before each due date.
    public var splitsWithPay: Bool
    /// The day or the amount is a guess.
    public var isEstimate: Bool
    /// Shown with each payment, such as where its day came from.
    public var note: String?
    /// Budget spending charged to the card from today on.
    public var spending: [EverydaySpending]
    /// The day of the month the statement closes, 0 when not set.
    public var closeDay: Int

    public init(id: String, name: String, dueDay: Int, owedCents: Int, plan: Plan, splitsWithPay: Bool = false,
                isEstimate: Bool = false, note: String? = nil, spending: [EverydaySpending] = [], closeDay: Int = 0) {
        self.id = id
        self.name = name
        self.dueDay = dueDay
        self.owedCents = owedCents
        self.plan = plan
        self.splitsWithPay = splitsWithPay
        self.isEstimate = isEstimate
        self.note = note
        self.spending = spending
        self.closeDay = closeDay
    }

    /// What each due date through `end` pays, in order.
    public func payments(from today: Date, through end: Date, calendar: Calendar = .current) -> [Payment] {
        guard dueDay > 0 else { return [] }
        let today = calendar.startOfDay(for: today)
        var dates: [Date] = []
        var date = CashFlowSchedule.first(onOrAfter: today, monthDays: [dueDay], calendar: calendar)
        while date <= end {
            dates.append(date)
            date = CashFlowSchedule.following(date, cadence: .monthly, monthDays: [dueDay], calendar: calendar)
        }
        /// Budget spending charged after `after` (or from today) through `last`.
        func charged(after: Date?, through last: Date) -> Int {
            guard !spending.isEmpty else { return 0 }
            var total = 0
            var day = max(today, after.flatMap { calendar.date(byAdding: .day, value: 1, to: $0) } ?? today)
            while day <= min(last, end) {
                total += spending.reduce(0) { $0 + CashFlowForecast.share(of: $1, on: day, calendar: calendar) }
                guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
                day = next
            }
            return total
        }
        var payments: [Payment] = []
        switch plan {
        case .balance:
            var previous: Date?
            for (index, date) in dates.enumerated() {
                let new = charged(after: previous, through: date)
                payments.append(Payment(date: date, cents: (index == 0 ? owedCents : 0) + new, spendingCents: new))
                previous = date
            }
        case .statement(let remaining):
            // Each statement holds what was charged before it closed.
            let first = min(max(0, remaining), owedCents)
            var previousClose: Date?
            for (index, date) in dates.enumerated() {
                let close = Self.statementClose(before: date, closeDay: closeDay, calendar: calendar)
                let new = charged(after: previousClose, through: close)
                let older = index == 0 ? first : index == 1 ? owedCents - first : 0
                payments.append(Payment(date: date, cents: older + new, spendingCents: new))
                previousClose = close
            }
        case .monthly(let cents):
            var owed = owedCents
            var previous: Date?
            for date in dates {
                owed += charged(after: previous, through: date)
                let paid = min(max(0, cents), owed)
                owed -= paid
                payments.append(Payment(date: date, cents: paid, spendingCents: 0))
                previous = date
            }
        }
        return payments.filter { $0.cents > 0 }
    }

    /// Card payments arrive as these; other credits (refunds, rewards) lower the next statement.
    static let paymentCategories: Set<String> = ["LOAN_PAYMENTS", "TRANSFER_IN"]

    /// What's still owed on the statement the next due date pays: what's owed now, less what was charged after it
    /// closed. When it hasn't closed yet, everything owed now is on it.
    public static func statementRemaining(owedCents: Int, cardHistory: [CashFlowHistoryEntry], dueDay: Int, closeDay: Int,
                                          today: Date, calendar: Calendar = .current) -> Int {
        let today = calendar.startOfDay(for: today)
        let due = CashFlowSchedule.first(onOrAfter: today, monthDays: [dueDay], calendar: calendar)
        let close = statementClose(before: due, closeDay: closeDay, calendar: calendar)
        guard close < today else { return owedCents }
        let newer = cardHistory
            .filter { calendar.startOfDay(for: $0.date) > close && !($0.isIncome && paymentCategories.contains($0.category ?? "")) }
            .reduce(0) { $0 + ($1.isIncome ? -$1.amountCents : $1.amountCents) }
        return min(max(0, owedCents - newer), owedCents)
    }

    /// Statements close about 25 days before the due date, or on the card's closing day at least three weeks before it.
    static func statementClose(before due: Date, closeDay: Int, calendar: Calendar) -> Date {
        guard closeDay > 0, let latest = calendar.date(byAdding: .day, value: -21, to: due) else {
            return calendar.date(byAdding: .day, value: -25, to: due) ?? due
        }
        let month = MonthKey(date: latest, calendar: calendar)
        let close = month.day(closeDay, calendar: calendar)
        return close <= latest ? close : month.previous.day(closeDay, calendar: calendar)
    }

    /// Most cards ask for about 1% of the balance plus interest, and at least $40: roughly 3%, in whole dollars.
    public static func estimatedMinimum(owedCents: Int) -> Int {
        guard owedCents > 40_00 else { return max(0, owedCents) }
        return max(40_00, (owedCents * 3 / 100 + 99) / 100 * 100)
    }
}

/// A budget item with a due day, for one month.
public struct BudgetBill: Sendable, Hashable {
    public var seriesID: UUID
    public var name: String
    public var date: Date
    public var amountCents: Int
    public var isEstimate: Bool

    public init(seriesID: UUID, name: String, date: Date, amountCents: Int, isEstimate: Bool = false) {
        self.seriesID = seriesID
        self.name = name
        self.date = date
        self.amountCents = amountCents
        self.isEstimate = isEstimate
    }
}

/// Budgeted spending without a due day (groceries, gas), spread evenly from `start` through `end`.
public struct EverydaySpending: Sendable, Hashable {
    public var start: Date
    public var end: Date
    public var amountCents: Int

    public init(start: Date, end: Date, amountCents: Int) {
        self.start = start
        self.end = end
        self.amountCents = amountCents
    }
}

public struct CashFlowInputs: Sendable {
    public var today: Date
    public var horizonDays: Int
    public var startingCents: Int
    /// Warn when checking would drop below this, not just below zero.
    public var cushionCents: Int
    public var schedules: [CashFlowSchedule]
    public var cards: [CardPayment]
    public var budgetBills: [BudgetBill]
    public var everyday: [EverydaySpending]
    /// Money in savings that could cover a dip.
    public var savingsCents: Int

    public init(today: Date, horizonDays: Int = 60, startingCents: Int, cushionCents: Int = 0, schedules: [CashFlowSchedule] = [],
                cards: [CardPayment] = [], budgetBills: [BudgetBill] = [], everyday: [EverydaySpending] = [], savingsCents: Int = 0) {
        self.today = today
        self.horizonDays = horizonDays
        self.startingCents = startingCents
        self.cushionCents = cushionCents
        self.schedules = schedules
        self.cards = cards
        self.budgetBills = budgetBills
        self.everyday = everyday
        self.savingsCents = savingsCents
    }
}

public struct CashFlowEvent: Sendable, Hashable, Identifiable {
    public enum Kind: String, Sendable { case payday, bill, card }

    public var id: String
    public var date: Date
    public var name: String
    /// Positive for money in, negative for money out.
    public var amountCents: Int
    public var kind: Kind
    public var isEstimate: Bool
    /// When a payment that hasn't shown up yet was expected. It's counted today.
    public var expectedDate: Date?
    /// A line to show with it, such as which part of a split payment it is.
    public var detail: String?
}

public struct CashFlowDay: Sendable, Hashable, Identifiable {
    public var date: Date
    public var events: [CashFlowEvent]
    /// Everyday spending spread onto this day.
    public var everydayCents: Int
    public var startCents: Int
    public var endCents: Int

    public var id: Date { date }
    public var hasPayday: Bool { events.contains { $0.kind == .payday } }
}

public struct CashFlowSuggestion: Sendable, Hashable, Identifiable {
    public enum Kind: String, Sendable { case moveSavings, moveBill, splitPayment, spendLess, needMore }

    public var kind: Kind
    public var title: String
    public var detail: String
    public var id: String { kind.rawValue + title }
}

public struct CashFlowForecast: Sendable {
    /// A stretch below the cushion: when it starts, its lowest day and when it's over.
    public struct Dip: Sendable, Hashable {
        public var start: Date
        public var lowest: CashFlowDay
        public var recovery: Date?
        /// What it takes to keep the lowest day at the cushion.
        public var neededCents: Int
    }

    public var today: Date
    public var startingCents: Int
    public var cushionCents: Int
    public var days: [CashFlowDay]
    public var suggestions: [CashFlowSuggestion]

    public var events: [CashFlowEvent] { days.flatMap(\.events) }
    public var end: Date { days.last?.date ?? today }
    public var lowest: CashFlowDay? { days.min { $0.endCents < $1.endCents } }
    public var dips: [Dip] { Self.dips(in: days, cushion: cushionCents) }
    public var dip: Dip? { dips.first }
    public var deepestDip: Dip? { dips.min { $0.lowest.endCents < $1.lowest.endCents } }
    public var nextPayday: CashFlowEvent? { events.first { $0.kind == .payday } }
    public func day(_ date: Date) -> CashFlowDay? { days.first { $0.date == date } }

    public static func make(_ inputs: CashFlowInputs, calendar: Calendar = .current) -> CashFlowForecast {
        let today = calendar.startOfDay(for: inputs.today)
        let end = calendar.date(byAdding: .day, value: max(1, inputs.horizonDays) - 1, to: today) ?? today
        let events = events(for: inputs, today: today, end: end, calendar: calendar)
        let days = simulate(startingCents: inputs.startingCents, events: events, everyday: inputs.everyday, from: today, through: end, calendar: calendar)
        var forecast = CashFlowForecast(today: today, startingCents: inputs.startingCents, cushionCents: inputs.cushionCents,
                                        days: days, suggestions: [])
        forecast.suggestions = suggestions(for: forecast, events: events, inputs: inputs, calendar: calendar)
        return forecast
    }

    // MARK: Building the days

    /// Payments a few days late are still expected, so they count today. Older misses are dropped.
    static let graceDays = 5

    static func events(for inputs: CashFlowInputs, today: Date, end: Date, calendar: Calendar) -> [CashFlowEvent] {
        var events: [CashFlowEvent] = []
        func add(id: String, on date: Date, name: String, cents: Int, kind: CashFlowEvent.Kind, isEstimate: Bool, detail: String? = nil) {
            guard date <= end else { return }
            if date >= today {
                events.append(CashFlowEvent(id: "\(id)@\(date.timeIntervalSinceReferenceDate)", date: date, name: name, amountCents: cents,
                                            kind: kind, isEstimate: isEstimate, expectedDate: nil, detail: detail))
            } else if (calendar.dateComponents([.day], from: date, to: today).day ?? 0) <= graceDays {
                events.append(CashFlowEvent(id: "\(id)@\(date.timeIntervalSinceReferenceDate)", date: today, name: name, amountCents: cents,
                                            kind: kind, isEstimate: isEstimate, expectedDate: date, detail: detail))
            }
        }
        for schedule in inputs.schedules where schedule.amountCents > 0 {
            for date in schedule.dates(through: end, calendar: calendar) {
                add(id: schedule.id, on: date, name: schedule.name, cents: schedule.isIncome ? schedule.amountCents : -schedule.amountCents,
                    kind: schedule.isIncome ? .payday : .bill, isEstimate: schedule.isEstimate)
            }
        }
        let paydays = Set(inputs.schedules.filter { $0.isIncome && $0.amountCents > 0 }.flatMap { $0.dates(through: end, calendar: calendar) })
            .filter { $0 >= today }.sorted()
        for card in inputs.cards {
            for payment in card.payments(from: today, through: end, calendar: calendar) {
                // Split evenly over the paydays since the last due date; any odd cents go with the last part.
                let since = calendar.date(byAdding: .month, value: -1, to: payment.date) ?? payment.date
                let parts = card.splitsWithPay ? paydays.filter { $0 > since && $0 <= payment.date } : []
                let includes = payment.spendingCents > 0 ? "Includes about \(Money.format(payment.spendingCents, showsCents: false)) of budget spending" : nil
                guard parts.count > 0 else {
                    add(id: card.id, on: payment.date, name: card.name, cents: -payment.cents, kind: .card,
                        isEstimate: card.isEstimate || includes != nil,
                        detail: [card.note, includes].compactMap { $0 }.joined(separator: ". ").nonEmptyText)
                    continue
                }
                let share = payment.cents / parts.count
                let due = payment.date.formatted(.dateTime.month(.abbreviated).day())
                for (index, date) in parts.enumerated() {
                    let cents = index == parts.count - 1 ? payment.cents - share * (parts.count - 1) : share
                    let detail = parts.count > 1 ? "Part \(index + 1) of \(parts.count), due \(due)"
                        : date == payment.date ? [card.note, includes].compactMap { $0 }.joined(separator: ". ").nonEmptyText
                        : "Paid on payday, due \(due)"
                    add(id: "\(card.id)#\(index + 1)", on: date, name: card.name, cents: -cents, kind: .card,
                        isEstimate: card.isEstimate || includes != nil, detail: detail)
                }
            }
        }
        for bill in inputs.budgetBills where bill.amountCents > 0 && bill.date >= today {
            add(id: "budget:\(bill.seriesID)", on: calendar.startOfDay(for: bill.date), name: bill.name, cents: -bill.amountCents,
                kind: .bill, isEstimate: bill.isEstimate)
        }
        return events
    }

    static func simulate(startingCents: Int, events: [CashFlowEvent], everyday: [EverydaySpending], from today: Date, through end: Date,
                         calendar: Calendar) -> [CashFlowDay] {
        let byDay = Dictionary(grouping: events, by: \.date)
        var balance = startingCents
        var days: [CashFlowDay] = []
        var date = today
        while date <= end {
            let dayEvents = (byDay[date] ?? []).sorted {
                ($0.kind == .payday ? 0 : 1, $0.amountCents, $0.name) < ($1.kind == .payday ? 0 : 1, $1.amountCents, $1.name)
            }
            let spread = everyday.reduce(0) { $0 + share(of: $1, on: date, calendar: calendar) }
            let start = balance
            balance += dayEvents.reduce(0) { $0 + $1.amountCents } - spread
            days.append(CashFlowDay(date: date, events: dayEvents, everydayCents: spread, startCents: start, endCents: balance))
            guard let next = calendar.date(byAdding: .day, value: 1, to: date) else { break }
            date = next
        }
        return days
    }

    /// Spreads evenly to the cent; leftover cents land on the earliest days.
    static func share(of spending: EverydaySpending, on date: Date, calendar: Calendar) -> Int {
        let start = calendar.startOfDay(for: spending.start)
        let end = calendar.startOfDay(for: spending.end)
        guard spending.amountCents > 0, date >= start, date <= end,
              let count = calendar.dateComponents([.day], from: start, to: end).day.map({ $0 + 1 }),
              let index = calendar.dateComponents([.day], from: start, to: date).day else { return 0 }
        return spending.amountCents / count + (index < spending.amountCents % count ? 1 : 0)
    }

    /// Every stretch below the cushion, in order.
    static func dips(in days: [CashFlowDay], cushion: Int) -> [Dip] {
        var dips: [Dip] = []
        var index = 0
        while index < days.count {
            guard days[index].endCents < cushion else {
                index += 1
                continue
            }
            let start = days[index].date
            var lowest = days[index]
            while index < days.count, days[index].endCents < cushion {
                if days[index].endCents < lowest.endCents { lowest = days[index] }
                index += 1
            }
            dips.append(Dip(start: start, lowest: lowest, recovery: index < days.count ? days[index].date : nil,
                            neededCents: cushion - lowest.endCents))
        }
        return dips
    }

    // MARK: Getting ahead of a dip

    /// Ways to avoid the first dip and, when a later one is deeper, that one too.
    static func suggestions(for forecast: CashFlowForecast, events: [CashFlowEvent], inputs: CashFlowInputs, calendar: Calendar) -> [CashFlowSuggestion] {
        let dips = forecast.dips
        guard let first = dips.first else { return [] }
        var targets = [first]
        if let deepest = dips.min(by: { $0.lowest.endCents < $1.lowest.endCents }), deepest.start != first.start { targets.append(deepest) }
        var result: [CashFlowSuggestion] = []
        for dip in targets {
            for suggestion in fixes(for: dip, forecast: forecast, events: events, inputs: inputs, calendar: calendar).prefix(2)
            where !result.contains(where: { $0.title == suggestion.title }) {
                result.append(suggestion)
            }
        }
        return Array(result.prefix(4))
    }

    static func fixes(for dip: Dip, forecast: CashFlowForecast, events: [CashFlowEvent], inputs: CashFlowInputs, calendar: Calendar) -> [CashFlowSuggestion] {
        guard let end = forecast.days.last?.date else { return [] }
        let need = dip.neededCents
        func day(_ date: Date) -> String { date.formatted(.dateTime.month(.abbreviated).day()) }
        func rerun(_ changed: [CashFlowEvent]) -> [CashFlowDay] {
            simulate(startingCents: inputs.startingCents, events: changed, everyday: inputs.everyday, from: forecast.today, through: end, calendar: calendar)
        }
        /// Checking stays at or above the cushion from the dip's start through `date`.
        func clears(_ days: [CashFlowDay], through date: Date) -> Bool {
            days.allSatisfy { $0.date < dip.start || $0.date > date || $0.endCents >= inputs.cushionCents }
        }

        var result: [CashFlowSuggestion] = []
        if inputs.savingsCents >= need {
            result.append(CashFlowSuggestion(kind: .moveSavings, title: "Move \(Money.format(need)) from savings by \(day(dip.start))",
                                             detail: "Savings has \(Money.format(inputs.savingsCents)). That covers the low point on \(day(dip.lowest.date))."))
        }

        /// Pays as much of a big bill as checking allows on its due date and on each following payday,
        /// never so much that a later bill can't be paid. A card can carry what's left; other bills are paid in full.
        func installments(for bill: CashFlowEvent, paydays: [Date]) -> (parts: [(date: Date, cents: Int)], leftover: Int)? {
            let dates = [bill.date] + paydays.filter { $0 > bill.date }.prefix(3)
            guard dates.count >= 2 else { return nil }
            func plan(_ parts: [(date: Date, cents: Int)]) -> [CashFlowEvent] {
                events.filter { $0.id != bill.id } + parts.enumerated().compactMap { index, part in
                    guard part.cents > 0 else { return nil }
                    var event = moved(bill, to: part.date)
                    event.id += "-part\(index)"
                    event.amountCents = -part.cents
                    return event
                }
            }
            var parts: [(date: Date, cents: Int)] = []
            var remaining = -bill.amountCents
            for date in dates where remaining > 0 {
                // The most that can go out now without pushing any later day below the line.
                func works(_ now: Int) -> Bool {
                    clears(rerun(plan(parts + [(date, now)])), through: end)
                }
                // Something else causes the dip; splitting this bill won't fix it.
                guard works(0) else { return nil }
                var low = 0
                var high = remaining
                while low < high {
                    let mid = (low + high + 1) / 2
                    if works(mid) { low = mid } else { high = mid - 1 }
                }
                let now = low == remaining ? low : low / 100 * 100
                if now > 0 {
                    parts.append((date, now))
                    remaining -= now
                }
            }
            guard !parts.isEmpty, remaining == 0 || bill.kind == .card else { return nil }
            return (parts, remaining)
        }

        let paydays = Array(Set(events.filter { $0.kind == .payday }.map(\.date))).sorted()
        if let payday = paydays.first(where: { $0 > dip.start }) {
            // Bills from the pay period the dip starts in, latest first: those need the shortest delay.
            let periodStart = paydays.last { $0 <= dip.start } ?? forecast.today
            let movable = events
                .filter { $0.amountCents < 0 && $0.date >= periodStart && $0.date <= dip.lowest.date && $0.date < payday }
                .sorted { ($0.date, $0.amountCents) > ($1.date, $1.amountCents) }
            if let bill = movable.first(where: { bill in
                clears(rerun(events.map { $0.id == bill.id ? moved($0, to: payday) : $0 }), through: payday)
            }) {
                result.append(CashFlowSuggestion(kind: .moveBill,
                                                 title: "Pay \(bill.name) (\(Money.format(-bill.amountCents))) on \(day(payday)) instead of \(day(bill.date))",
                                                 detail: "That's when your next paycheck arrives. Many companies will move a due date if you ask."))
            } else if let biggest = movable.min(by: { $0.amountCents < $1.amountCents }), let plan = installments(for: biggest, paydays: paydays) {
                let list = plan.parts.map { "\(Money.format($0.cents, showsCents: false)) on \(day($0.date))" }.formatted(.list(type: .and))
                let leftover = plan.leftover > 0 ? " That leaves \(Money.format(plan.leftover)) on the card after \(day(plan.parts.last?.date ?? end))." : ""
                result.append(CashFlowSuggestion(kind: .splitPayment,
                                                 title: plan.parts.count == 1 ? "Pay \(biggest.name) on \(day(plan.parts[0].date)) instead" : "Pay \(biggest.name) in \(plan.parts.count) parts",
                                                 detail: "\(list). Each part is what checking can spare while still covering the other bills.\(leftover)"))
            }
        }

        let window = forecast.days.filter { $0.date <= dip.lowest.date }
        let everyday = window.reduce(0) { $0 + $1.everydayCents }
        if everyday >= need, !window.isEmpty {
            let perDay = (need + window.count - 1) / window.count
            result.append(CashFlowSuggestion(kind: .spendLess, title: "Spend \(Money.format(perDay)) less a day until \(day(dip.lowest.date))",
                                             detail: "This forecast expects about \(Money.format(everyday / window.count)) a day of everyday spending."))
        }
        if result.isEmpty {
            result.append(CashFlowSuggestion(kind: .needMore, title: "Checking needs \(Money.format(need)) more by \(day(dip.start))",
                                             detail: "No bill can move far enough on its own. Lower a bill, add money to checking, or pay part of one later."))
        }
        return result
    }

    static func moved(_ event: CashFlowEvent, to date: Date) -> CashFlowEvent {
        var moved = event
        moved.date = date
        moved.expectedDate = nil
        return moved
    }
}

extension String {
    /// Nil instead of an empty string.
    var nonEmptyText: String? { isEmpty ? nil : self }
}
