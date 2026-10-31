import BetterDollarCore
import SwiftUI

/// Layout C: the weeks ahead as a calendar, each day showing where checking ends up.
struct CashFlowCalendar: View {
    let forecast: CashFlowForecast
    @State private var selected: Date?
    private let calendar = Calendar.current

    private var shownDay: CashFlowDay? {
        if let selected, let day = forecast.day(selected) { return day }
        return forecast.dip.flatMap { forecast.day($0.start) } ?? forecast.days.first
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(months()) { month in
                Text(month.title)
                    .font(Typeface.groupTitle)
                    .foregroundStyle(Ink.text)
                    .padding(.top, 10)
                    .accessibilityAddTraits(.isHeader)
                weekdayHeader
                ForEach(Array(month.weeks.enumerated()), id: \.offset) { _, week in
                    HStack(spacing: 4) {
                        ForEach(Array(week.enumerated()), id: \.offset) { _, date in
                            if let date {
                                let day = forecast.day(date)
                                Button { selected = date } label: {
                                    CalendarDayCell(date: date, day: day, cushion: forecast.cushionCents,
                                                    isToday: calendar.isDateInToday(date), isSelected: shownDay?.date == date && day != nil)
                                }
                                .buttonStyle(.plain)
                                .disabled(day == nil)
                            } else {
                                Color.clear.frame(maxWidth: .infinity, minHeight: 60)
                            }
                        }
                    }
                }
            }
            legend.padding(.top, 8)
            if let shownDay {
                DayDetail(day: shownDay, cushion: forecast.cushionCents)
                    .padding(.top, 10)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("cash-flow-calendar")
    }

    private var weekdayHeader: some View {
        HStack(spacing: 4) {
            ForEach(Array(calendar.veryShortStandaloneWeekdaySymbols.rotated(by: calendar.firstWeekday - 1).enumerated()), id: \.offset) { _, symbol in
                Text(symbol)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Ink.secondary)
                    .frame(maxWidth: .infinity)
            }
        }
        .accessibilityHidden(true)
    }

    private struct MonthGrid: Identifiable {
        let id: String
        let title: String
        /// Seven slots a week; empty slots belong to the neighboring month.
        let weeks: [[Date?]]
    }

    /// One grid per month: this month from the current week, later months whole, through the forecast's last week.
    private func months() -> [MonthGrid] {
        let thisWeek = calendar.dateInterval(of: .weekOfYear, for: forecast.today)?.start ?? forecast.today
        let lastWeek = calendar.dateInterval(of: .weekOfYear, for: forecast.end)?.start ?? forecast.end
        let stop = calendar.date(byAdding: .day, value: 6, to: lastWeek) ?? forecast.end
        var grids: [MonthGrid] = []
        var key = MonthKey(date: forecast.today, calendar: calendar)
        while key.firstDay(calendar: calendar) <= stop {
            defer { key = key.next }
            let first = max(key.firstDay(calendar: calendar), thisWeek)
            let last = min(key.lastDay(calendar: calendar), stop)
            guard first <= last else { continue }
            let leading = (calendar.component(.weekday, from: first) - calendar.firstWeekday + 7) % 7
            var weeks: [[Date?]] = []
            var week = [Date?](repeating: nil, count: leading)
            var day = first
            while day <= last {
                week.append(day)
                if week.count == 7 {
                    weeks.append(week)
                    week = []
                }
                day = calendar.date(byAdding: .day, value: 1, to: day) ?? last.addingTimeInterval(86_400)
            }
            if !week.isEmpty { weeks.append(week + [Date?](repeating: nil, count: 7 - week.count)) }
            grids.append(MonthGrid(id: key.id, title: key.firstDay(calendar: calendar).formatted(.dateTime.month(.wide)), weeks: weeks))
        }
        return grids
    }

    private var legend: some View {
        HStack(spacing: 14) {
            HStack(spacing: 5) { EventMark(kind: .payday); Text("Payday") }
            HStack(spacing: 5) { EventMark(kind: .bill); Text("Bill") }
            HStack(spacing: 5) { EventMark(kind: .card); Text("Card") }
            HStack(spacing: 5) {
                RoundedRectangle(cornerRadius: 3).fill(Ink.seal.opacity(0.18)).frame(width: 14, height: 10)
                Text(forecast.cushionCents > 0 ? "Below \(Money.format(forecast.cushionCents, showsCents: false))" : "Below $0")
            }
        }
        .font(.caption)
        .foregroundStyle(Ink.secondary)
    }
}

private struct CalendarDayCell: View {
    let date: Date
    let day: CashFlowDay?
    let cushion: Int
    let isToday: Bool
    let isSelected: Bool

    private var isShort: Bool { (day?.endCents ?? 0) < cushion && day != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(date.formatted(.dateTime.day()))
                .font(.caption.weight(isToday ? .bold : .semibold))
                .foregroundStyle(day == nil ? Ink.secondary.opacity(0.45) : Ink.text)
            Spacer(minLength: 0)
            if let day {
                HStack(spacing: 2) {
                    ForEach(day.events.prefix(3)) { EventMark(kind: $0.kind) }
                }
                .frame(height: 8)
                Text(Money.compact(day.endCents))
                    .font(.system(size: 10, weight: .semibold).monospacedDigit())
                    .foregroundStyle(isShort ? Ink.seal : Ink.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            }
        }
        .padding(5)
        .frame(maxWidth: .infinity, minHeight: 60, alignment: .topLeading)
        .background(background, in: .rect(cornerRadius: 8))
        .overlay {
            if isSelected || isToday {
                RoundedRectangle(cornerRadius: 8).strokeBorder(Ink.primary.opacity(isSelected ? 1 : 0.45), lineWidth: isSelected ? 2 : 1)
            }
        }
        .contentShape(.rect)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var background: Color {
        guard let day else { return .clear }
        if isShort { return Ink.seal.opacity(0.16) }
        return day.hasPayday ? Ink.income.opacity(0.12) : Ink.sheet
    }

    private var accessibilityText: String {
        guard let day else { return date.formatted(.dateTime.month(.wide).day()) }
        var text = "\(date.formatted(.dateTime.weekday(.wide).month(.wide).day())), ends at \(Money.format(day.endCents))"
        if !day.events.isEmpty { text += ". " + day.events.map { "\($0.name) \(CashFlowFormat.signed($0.amountCents))" }.joined(separator: ", ") }
        return text
    }
}

/// The selected day as a small statement.
private struct DayDetail: View {
    let day: CashFlowDay
    let cushion: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(day.date.formatted(.dateTime.weekday(.wide).month(.wide).day()))
                .font(Typeface.groupTitle)
                .foregroundStyle(Ink.text)
            LedgerLine(label: "Checking at the start", cents: day.startCents, signed: false)
            ForEach(day.events) { event in
                LedgerLine(label: event.name, note: event.expectedDate.map { "expected \(CashFlowFormat.short($0))" } ?? (event.isEstimate ? "varies" : nil),
                           cents: event.amountCents)
            }
            if day.everydayCents > 0 {
                LedgerLine(label: "Everyday spending", note: "estimate", cents: -day.everydayCents)
            }
            if day.events.isEmpty && day.everydayCents == 0 {
                Text("Nothing scheduled.").font(.subheadline).foregroundStyle(Ink.secondary)
            }
            DoubleRule(color: Ink.rule)
            LedgerLine(label: "Checking at the end", cents: day.endCents, signed: false, emphasized: true)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Ink.sheet, in: .rect(cornerRadius: 18))
        .overlay { RoundedRectangle(cornerRadius: 18).strokeBorder(day.endCents < cushion ? Ink.seal.opacity(0.7) : Ink.rule, lineWidth: 1) }
    }
}

private extension Array {
    func rotated(by count: Int) -> [Element] {
        guard !isEmpty else { return self }
        let shift = ((count % self.count) + self.count) % self.count
        return Array(self[shift...] + self[..<shift])
    }
}
