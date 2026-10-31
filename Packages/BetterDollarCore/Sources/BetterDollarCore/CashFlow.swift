import Foundation

// Cash flow maps known bills onto paydays and walks the checking balance forward day by day,
// so a dip below zero shows up before it happens. Everything here is plain values, so it runs
// the same in the app, in tests and against exported history.

// MARK: - Schedules

/// How often a paycheck or bill repeats.
public enum Cadence: String, Codable, Sendable, CaseIterable, Identifiable {
    case weekly, biweekly, semimonthly, monthly

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .weekly: "Every week"
        case .biweekly: "Every 2 weeks"
        case .semimonthly: "Twice a month"
        case .monthly: "Every month"
        }
    }

    /// Roughly how many days apart occurrences are.
    var interval: Int {
        switch self {
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
    /// The budget item series its transactions were assigned to most, if any.
    public var seriesID: UUID?

    public var lastDate: Date { dates.last ?? .distantPast }

    /// Paychecks keep their rhythm exactly. Bills drift around a due day, so the next one is the first
    /// due day a few weeks after the last payment.
    public func nextDate(calendar: Calendar = .current) -> Date {
        switch cadence {
        case .weekly, .biweekly:
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

    /// Marks money sent from checking that arrives on a credit card (same amount within a few days).
    public static func markCardPayments(_ cash: inout [CashFlowHistoryEntry], cardHistory: [CashFlowHistoryEntry], calendar: Calendar = .current) {
        let received = cardHistory.filter(\.isIncome)
        for index in cash.indices where !cash[index].isIncome {
            let sent = cash[index]
            cash[index].isCardPayment = received.contains { payment in
                payment.amountCents == sent.amountCents && abs(payment.date.timeIntervalSince(sent.date)) <= 5 * 86_400
            }
        }
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
        case 24...38 where share({ (24...38).contains($0) || (52...70).contains($0) }) >= 0.75:
            return (.monthly, [typicalDay(days, calendar: calendar)])
        default:
            return nil
        }
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

/// A credit card's payment. Card purchases leave checking only when the card is paid.
public struct CardPayment: Sendable, Hashable, Identifiable {
    public var id: String
    public var name: String
    public var dueDay: Int
    public var amountCents: Int
    /// A fixed amount repeats monthly. Paying the balance happens once: later card spending is part of everyday spending.
    public var repeats: Bool

    public init(id: String, name: String, dueDay: Int, amountCents: Int, repeats: Bool) {
        self.id = id
        self.name = name
        self.dueDay = dueDay
        self.amountCents = amountCents
        self.repeats = repeats
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
        func add(id: String, on date: Date, name: String, cents: Int, kind: CashFlowEvent.Kind, isEstimate: Bool) {
            guard date <= end else { return }
            if date >= today {
                events.append(CashFlowEvent(id: "\(id)@\(date.timeIntervalSinceReferenceDate)", date: date, name: name, amountCents: cents,
                                            kind: kind, isEstimate: isEstimate, expectedDate: nil))
            } else if (calendar.dateComponents([.day], from: date, to: today).day ?? 0) <= graceDays {
                events.append(CashFlowEvent(id: "\(id)@\(date.timeIntervalSinceReferenceDate)", date: today, name: name, amountCents: cents,
                                            kind: kind, isEstimate: isEstimate, expectedDate: date))
            }
        }
        for schedule in inputs.schedules where schedule.amountCents > 0 {
            for date in schedule.dates(through: end, calendar: calendar) {
                add(id: schedule.id, on: date, name: schedule.name, cents: schedule.isIncome ? schedule.amountCents : -schedule.amountCents,
                    kind: schedule.isIncome ? .payday : .bill, isEstimate: schedule.isEstimate)
            }
        }
        for card in inputs.cards where card.dueDay > 0 && card.amountCents > 0 {
            let first = CashFlowSchedule.first(onOrAfter: today, monthDays: [card.dueDay], calendar: calendar)
            let dates = card.repeats
                ? CashFlowSchedule(id: card.id, name: card.name, isIncome: false, amountCents: card.amountCents, cadence: .monthly,
                                   nextDate: first, monthDays: [card.dueDay]).dates(through: end, calendar: calendar)
                : [first]
            for date in dates {
                add(id: card.id, on: date, name: card.name, cents: -card.amountCents, kind: .card, isEstimate: false)
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
