import BetterDollarCore
import Charts
import SwiftUI

/// Layout A: the balance as a line running forward, with a register of what's coming.
struct RunwayView: View {
    let forecast: CashFlowForecast
    @State private var selected: Date?
    @State private var showsAll = false

    private var selectedDay: CashFlowDay? {
        selected.flatMap { date in forecast.days.first { Calendar.current.isDate($0.date, inSameDayAs: date) } }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 12) {
                readout(selectedDay ?? forecast.dip?.lowest ?? forecast.lowest)
                chart
            }
            register
        }
    }

    private func readout(_ day: CashFlowDay?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            if let day {
                Text(day.date.formatted(.dateTime.weekday(.wide).month(.wide).day()))
                    .font(.caption)
                    .foregroundStyle(Ink.secondary)
                Text("Ends the day at \(Money.format(day.endCents))")
                    .font(.subheadline.weight(.semibold).monospacedDigit())
                    .foregroundStyle(day.endCents < forecast.cushionCents ? Ink.seal : Ink.text)
                if !day.events.isEmpty {
                    Text(day.events.map { "\($0.name) \(CashFlowFormat.signed($0.amountCents))" }.joined(separator: ", "))
                        .font(.caption)
                        .foregroundStyle(Ink.secondary)
                        .lineLimit(2)
                }
            }
        }
        .frame(minHeight: 52, alignment: .topLeading)
        .accessibilityElement(children: .combine)
    }

    private var chart: some View {
        let lowest = forecast.lowest
        return Chart {
            ForEach(forecast.days) { day in
                AreaMark(x: .value("Day", day.date, unit: .day), yStart: .value("Zero", 0.0),
                         yEnd: .value("Balance", dollars(max(day.endCents, 0))), series: .value("Part", "above"))
                    .foregroundStyle(Ink.primary.opacity(0.13))
                    .interpolationMethod(.stepEnd)
                AreaMark(x: .value("Day", day.date, unit: .day), yStart: .value("Zero", 0.0),
                         yEnd: .value("Balance", dollars(min(day.endCents, 0))), series: .value("Part", "below"))
                    .foregroundStyle(Ink.seal.opacity(0.22))
                    .interpolationMethod(.stepEnd)
                LineMark(x: .value("Day", day.date, unit: .day), y: .value("Balance", dollars(day.endCents)), series: .value("Part", "line"))
                    .foregroundStyle(Ink.primary)
                    .lineStyle(StrokeStyle(lineWidth: 2))
                    .interpolationMethod(.stepEnd)
            }
            RuleMark(y: .value("Zero", 0.0))
                .foregroundStyle(Ink.seal.opacity(0.7))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
            if forecast.cushionCents > 0 {
                RuleMark(y: .value("Warn below", dollars(forecast.cushionCents)))
                    .foregroundStyle(Ink.secondary.opacity(0.6))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [2, 3]))
            }
            ForEach(forecast.days.filter(\.hasPayday)) { day in
                PointMark(x: .value("Day", day.date, unit: .day), y: .value("Balance", dollars(day.endCents)))
                    .symbolSize(46)
                    .foregroundStyle(ChartInk.income)
            }
            if let lowest {
                PointMark(x: .value("Day", lowest.date, unit: .day), y: .value("Balance", dollars(lowest.endCents)))
                    .symbolSize(70)
                    .foregroundStyle(lowest.endCents < forecast.cushionCents ? Ink.seal : Ink.primary)
                    .annotation(position: lowest.endCents < 0 ? .bottom : .top, spacing: 4) {
                        Text(Money.format(lowest.endCents, showsCents: false))
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(lowest.endCents < forecast.cushionCents ? Ink.seal : Ink.text)
                    }
            }
            if let day = selectedDay {
                RuleMark(x: .value("Day", day.date, unit: .day))
                    .foregroundStyle(Ink.secondary.opacity(0.5))
            }
        }
        .chartXSelection(value: $selected)
        .chartXScale(range: .plotDimension(endPadding: 22))
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 5)) { value in
                AxisGridLine().foregroundStyle(Ink.rule)
                AxisValueLabel { Text(Money.compact(Int((value.as(Double.self) ?? 0) * 100))).foregroundStyle(Ink.secondary) }
            }
        }
        .chartXAxis {
            AxisMarks(values: .stride(by: .day, count: 14)) { _ in
                AxisGridLine().foregroundStyle(Ink.rule.opacity(0.6))
                AxisValueLabel(format: .dateTime.month(.abbreviated).day()).foregroundStyle(Ink.secondary)
            }
        }
        .frame(height: 230)
        .accessibilityLabel("Checking balance for the next \(forecast.days.count) days")
        .accessibilityValue(forecast.lowest.map { "Lowest \(Money.format($0.endCents)) on \(CashFlowFormat.short($0.date))" } ?? "")
        .accessibilityIdentifier("runway-chart")
    }

    private var register: some View {
        let days = forecast.days.filter { !$0.events.isEmpty }
        let shown = showsAll ? days : Array(days.prefix(8))
        let perDay = forecast.days.reduce(0) { $0 + $1.everydayCents } / max(1, forecast.days.count)
        return VStack(alignment: .leading, spacing: 0) {
            Text("Coming up")
                .font(Typeface.groupTitle)
                .foregroundStyle(Ink.text)
                .accessibilityAddTraits(.isHeader)
                .padding(.bottom, 6)
            if days.isEmpty {
                Text("Nothing scheduled in the next \(forecast.days.count) days.")
                    .font(.subheadline)
                    .foregroundStyle(Ink.secondary)
            }
            ForEach(shown) { day in
                RegisterDay(day: day, cushion: forecast.cushionCents)
                Rectangle().fill(Ink.rule).frame(height: 0.5)
            }
            if days.count > shown.count || showsAll && days.count > 8 {
                Button(showsAll ? "Show less" : "Show all \(days.count) days") { withAnimation(.snappy) { showsAll.toggle() } }
                    .font(.subheadline.weight(.semibold))
                    .padding(.top, 12)
            }
            if perDay > 0 {
                Text("Balances include about \(Money.format(perDay)) a day of everyday spending from your budget.")
                    .font(.caption)
                    .foregroundStyle(Ink.secondary)
                    .padding(.top, 12)
            }
        }
    }

    private func dollars(_ cents: Int) -> Double { Double(cents) / 100 }
}

/// A register entry: the date, what happens, and where checking ends up.
private struct RegisterDay: View {
    let day: CashFlowDay
    let cushion: Int

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(spacing: 0) {
                Text(day.date.formatted(.dateTime.day()))
                    .font(Typeface.figure(20))
                    .foregroundStyle(Ink.text)
                Text(day.date.formatted(.dateTime.weekday(.abbreviated)))
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Ink.secondary)
            }
            .frame(width: 42)
            VStack(alignment: .leading, spacing: 6) {
                ForEach(day.events) { event in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        EventMark(kind: event.kind)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(event.name)
                                .font(.subheadline)
                                .foregroundStyle(Ink.text)
                                .lineLimit(1)
                            if let expected = event.expectedDate {
                                Text("Expected \(CashFlowFormat.short(expected)), not seen yet")
                                    .font(.caption)
                                    .foregroundStyle(Ink.secondary)
                            } else if let detail = event.detail {
                                Text(detail)
                                    .font(.caption)
                                    .foregroundStyle(Ink.secondary)
                            } else if event.isEstimate {
                                Text("Amount varies")
                                    .font(.caption)
                                    .foregroundStyle(Ink.secondary)
                            }
                        }
                        Spacer(minLength: 8)
                        Text(CashFlowFormat.signed(event.amountCents))
                            .font(Typeface.amountSmall)
                            .foregroundStyle(event.amountCents > 0 ? Ink.income : Ink.text)
                    }
                }
                HStack {
                    Text("Checking after")
                        .font(.caption)
                        .foregroundStyle(Ink.secondary)
                    Spacer()
                    AmountText(cents: day.endCents, font: Typeface.amountSmall.weight(.semibold), color: day.endCents < cushion ? Ink.seal : Ink.text)
                }
            }
        }
        .padding(.vertical, 12)
        .accessibilityElement(children: .combine)
    }
}

/// Paydays are filled coins, bills are open rings, card payments are squares, so kind never depends on color alone.
struct EventMark: View {
    let kind: CashFlowEvent.Kind

    var body: some View {
        Group {
            switch kind {
            case .payday: Circle().fill(Ink.income)
            case .bill: Circle().strokeBorder(Ink.text, lineWidth: 1.5)
            case .card: RoundedRectangle(cornerRadius: 1.5).fill(Ink.text)
            }
        }
        .frame(width: 8, height: 8)
        .accessibilityHidden(true)
    }
}
