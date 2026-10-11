import Foundation

/// A calendar month such as October 2026, stored as "2026-10".
public struct MonthKey: Hashable, Comparable, Codable, Sendable, Identifiable, CustomStringConvertible {
    public let year: Int
    public let month: Int

    public init(year: Int, month: Int) {
        let index = year * 12 + (month - 1)
        self.year = Int((Double(index) / 12).rounded(.down))
        self.month = index - self.year * 12 + 1
    }

    public init(date: Date, calendar: Calendar = .current) {
        let parts = calendar.dateComponents([.year, .month], from: date)
        self.init(year: parts.year ?? 2000, month: parts.month ?? 1)
    }

    public init?(_ id: String) {
        let parts = id.split(separator: "-")
        guard parts.count == 2, let year = Int(parts[0]), let month = Int(parts[1]), (1...12).contains(month) else { return nil }
        self.init(year: year, month: month)
    }

    public static func current(calendar: Calendar = .current) -> MonthKey { MonthKey(date: Date(), calendar: calendar) }

    public var id: String { String(format: "%04d-%02d", year, month) }
    public var description: String { id }
    public var next: MonthKey { MonthKey(year: year, month: month + 1) }
    public var previous: MonthKey { MonthKey(year: year, month: month - 1) }
    public func adding(months: Int) -> MonthKey { MonthKey(year: year, month: month + months) }

    public func firstDay(calendar: Calendar = .current) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: 1)) ?? Date()
    }

    /// The month as a half-open interval [first day, first day of next month).
    public func interval(calendar: Calendar = .current) -> DateInterval {
        DateInterval(start: firstDay(calendar: calendar), end: next.firstDay(calendar: calendar))
    }

    public func contains(_ date: Date, calendar: Calendar = .current) -> Bool {
        MonthKey(date: date, calendar: calendar) == self
    }

    /// "October 2026"
    public var title: String { firstDay().formatted(.dateTime.month(.wide).year()) }
    /// "October"
    public var monthName: String { firstDay().formatted(.dateTime.month(.wide)) }
    /// "Oct"
    public var shortName: String { firstDay().formatted(.dateTime.month(.abbreviated)) }

    public static func < (lhs: MonthKey, rhs: MonthKey) -> Bool {
        (lhs.year, lhs.month) < (rhs.year, rhs.month)
    }
}
