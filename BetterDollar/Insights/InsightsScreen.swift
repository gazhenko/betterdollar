import BetterDollarCore
import Charts
import SwiftData
import SwiftUI

/// Validated two-series chart colors (OKLCH band, chroma floor, CVD and normal-vision separation)
/// for light (#F2F4EF) and dark (#0D1A15) paper.
nonisolated enum ChartInk {
    static let spending = Ink.dynamic(light: 0x12804F, dark: 0x287A4E)
    static let income = Ink.dynamic(light: 0xBD7F12, dark: 0xC2821C)
}

struct InsightsScreen: View {
    @Environment(AppModel.self) private var app
    @Query(sort: \BudgetMonth.key) private var months: [BudgetMonth]

    private var month: BudgetMonth? { months.first { $0.key == app.month.id } }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    MonthHeader()
                    if let month {
                        let funds = FundLedger(months: months)
                        let totals = BudgetMath.totals(for: month)
                        HStack(spacing: 12) {
                            StatTile(title: "Spent", cents: totals.spentCents, of: totals.plannedExpenseCents, noun: "planned")
                            StatTile(title: "Received", cents: totals.receivedCents, of: totals.plannedIncomeCents, noun: "expected")
                        }
                        GroupSpending(month: month, funds: funds)
                        TrendChart(months: months, current: app.month)
                        FundProgress(month: month, funds: funds)
                    } else {
                        ContentUnavailableView("No plan for \(app.month.monthName)", systemImage: "chart.bar.xaxis",
                                               description: Text("Insights appear once this month has a plan."))
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 30)
            }
            .statusBarShield()
            .paperBackground()
            .toolbar(.hidden, for: .navigationBar)
        }
    }
}

struct StatTile: View {
    let title: String
    let cents: Int
    let of: Int
    let noun: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.subheadline.weight(.medium)).foregroundStyle(Ink.secondary)
            AmountText(cents: cents, font: Typeface.figure(24), showsCents: false)
            Text("of \(Money.format(of, showsCents: false)) \(noun)")
                .font(.caption).foregroundStyle(Ink.secondary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Ink.sheet, in: .rect(cornerRadius: 18))
        .accessibilityElement(children: .combine)
    }
}

private struct SectionTitle: View {
    let text: String
    var body: some View {
        Text(text).font(Typeface.groupTitle).foregroundStyle(Ink.text).accessibilityAddTraits(.isHeader)
    }
}

/// One meter per expense group: spent against what was planned.
struct GroupSpending: View {
    let month: BudgetMonth
    let funds: FundLedger

    var body: some View {
        let rows = month.expenseGroups.map { group in
            (id: group.persistentModelID, name: group.name, totals: BudgetMath.groupTotals(for: group, funds: funds))
        }
        .filter { $0.totals.plannedCents > 0 || $0.totals.activityCents > 0 }
        .sorted { $0.totals.activityCents > $1.totals.activityCents }

        VStack(alignment: .leading, spacing: 14) {
            SectionTitle(text: "Where it went")
            if rows.isEmpty {
                Text("Plan some spending to see it here.").foregroundStyle(Ink.secondary)
            }
            ForEach(rows, id: \.id) { row in
                let over = row.totals.activityCents - row.totals.plannedCents
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(row.name).foregroundStyle(Ink.text)
                        Spacer()
                        Text("\(Money.format(row.totals.activityCents, showsCents: false)) of \(Money.format(row.totals.plannedCents, showsCents: false))")
                            .font(Typeface.amountSmall).foregroundStyle(Ink.secondary)
                    }
                    Meter(fraction: row.totals.plannedCents > 0 ? Double(row.totals.activityCents) / Double(row.totals.plannedCents) : 1,
                          tint: over > 0 ? Ink.seal : ChartInk.spending)
                    if over > 0 {
                        Label("Over by \(Money.format(over))", systemImage: "exclamationmark.circle")
                            .font(.caption.weight(.medium)).foregroundStyle(Ink.seal)
                    }
                }
                .accessibilityElement(children: .combine)
            }
        }
    }
}

/// A rounded meter on a track from the same ink.
struct Meter: View {
    let fraction: Double
    var tint: Color = ChartInk.spending

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 4).fill(Ink.track)
                RoundedRectangle(cornerRadius: 4).fill(tint)
                    .frame(width: max(fraction > 0 ? 4 : 0, proxy.size.width * min(1, max(0, fraction))))
            }
        }
        .frame(height: 10)
        .accessibilityHidden(true)
    }
}

/// Income and spending for the last six planned months: two series, one axis, legend plus selection readout.
struct TrendChart: View {
    let months: [BudgetMonth]
    let current: MonthKey
    @State private var selected: String?

    private struct Point: Identifiable {
        let month: MonthKey
        let series: String
        let cents: Int
        var id: String { month.id + series }
    }

    var body: some View {
        let window = months.filter { $0.monthKey <= current && $0.monthKey > current.adding(months: -6) }
        let points = window.flatMap { month -> [Point] in
            let totals = BudgetMath.totals(for: month)
            return [Point(month: month.monthKey, series: "Income", cents: totals.receivedCents),
                    Point(month: month.monthKey, series: "Spending", cents: totals.spentCents)]
        }
        VStack(alignment: .leading, spacing: 12) {
            SectionTitle(text: "Income and spending")
            if window.count < 2 {
                Text("Plan a second month to compare.").foregroundStyle(Ink.secondary)
            } else {
                readout(points)
                Chart(points) { point in
                    BarMark(x: .value("Month", point.month.shortName), y: .value("Amount", Double(point.cents) / 100), width: .ratio(0.7))
                        .foregroundStyle(by: .value("Series", point.series))
                        .position(by: .value("Series", point.series), axis: .horizontal, span: .ratio(1))
                        .clipShape(UnevenRoundedRectangle(topLeadingRadius: 4, topTrailingRadius: 4))
                        .opacity(selected == nil || selected == point.month.shortName ? 1 : 0.45)
                }
                .chartForegroundStyleScale(["Income": ChartInk.income, "Spending": ChartInk.spending])
                .chartLegend(position: .top, alignment: .leading)
                .chartXSelection(value: $selected)
                .chartYAxis {
                    AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { value in
                        AxisGridLine().foregroundStyle(Ink.rule)
                        AxisValueLabel { Text(Money.compact(Int((value.as(Double.self) ?? 0) * 100))).foregroundStyle(Ink.secondary) }
                    }
                }
                .chartXAxis {
                    AxisMarks { _ in AxisValueLabel().foregroundStyle(Ink.secondary) }
                }
                .frame(height: 210)
            }
        }
    }

    /// Shows the selected month, or the latest one, as text so values never depend on color.
    private func readout(_ points: [Point]) -> some View {
        let name = selected ?? points.last?.month.shortName
        let income = points.first { $0.month.shortName == name && $0.series == "Income" }?.cents ?? 0
        let spending = points.first { $0.month.shortName == name && $0.series == "Spending" }?.cents ?? 0
        let month = points.first { $0.month.shortName == name }?.month
        return VStack(alignment: .leading, spacing: 2) {
            Text(month?.title ?? "").font(.caption).foregroundStyle(Ink.secondary)
            Text("Income \(Money.format(income, showsCents: false)), spending \(Money.format(spending, showsCents: false))")
                .font(.subheadline.weight(.medium).monospacedDigit()).foregroundStyle(Ink.text)
        }
        .accessibilityElement(children: .combine)
    }
}

struct FundProgress: View {
    let month: BudgetMonth
    let funds: FundLedger

    var body: some View {
        let items = month.allItems.filter(\.isFund)
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 14) {
                SectionTitle(text: "Funds")
                ForEach(items) { item in
                    let balance = funds.balance(for: item)
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(item.name).foregroundStyle(Ink.text)
                            Spacer()
                            Text(item.fundGoalCents > 0
                                 ? "\(Money.format(balance, showsCents: false)) of \(Money.format(item.fundGoalCents, showsCents: false))"
                                 : Money.format(balance, showsCents: false))
                                .font(Typeface.amountSmall).foregroundStyle(Ink.secondary)
                        }
                        if item.fundGoalCents > 0 {
                            Meter(fraction: Double(balance) / Double(item.fundGoalCents), tint: ChartInk.income)
                            if let target = item.fundTargetDate, let key = item.monthKey,
                               let monthly = BudgetMath.monthlyToReachGoal(balanceCents: funds.carryIn(for: item), goalCents: item.fundGoalCents, from: key, target: target) {
                                Text(monthly == 0 ? "Goal reached." : "\(Money.format(monthly)) a month reaches it by \(target.formatted(.dateTime.month(.wide).year())).")
                                    .font(.caption).foregroundStyle(Ink.secondary)
                            }
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }
}
