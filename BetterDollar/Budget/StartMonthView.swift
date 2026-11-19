import BetterDollarCore
import SwiftData
import SwiftUI

/// Shown for a month without a plan: copy the last plan, start from the standard layout, or start blank.
struct StartMonthView: View {
    let month: MonthKey
    @Environment(\.modelContext) private var context
    @Query(sort: \BudgetMonth.key) private var months: [BudgetMonth]

    private var previous: BudgetMonth? { months.last { MonthKey($0.key).map { $0 < month } ?? false } }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(months.isEmpty ? "Plan your first month" : "Plan \(month.monthName)")
                .font(Typeface.title(26))
                .foregroundStyle(Ink.onPlate)
                // Leaves the corner to the rosette.
                .padding(.trailing, 84)
                .fixedSize(horizontal: false, vertical: true)
            Text(months.isEmpty
                 ? "Give every dollar of this month's income a job, one budget item at a time. Your plan stays on this iPhone."
                 : "Each month gets its own plan. Funds keep their balances from month to month.")
                .font(.body)
                .foregroundStyle(Ink.onPlate.opacity(0.8))
                .fixedSize(horizontal: false, vertical: true)

            if let previous {
                Button("Copy \(previous.monthKey.monthName)'s plan") {
                    withAnimation(.snappy) { _ = BudgetPlanner.createByCopying(previous, to: month, in: context) }
                }
                .buttonStyle(InkButtonStyle(onPlate: true))
                .accessibilityIdentifier("copy-plan")
            }
            Button("Start with common budget items") {
                withAnimation(.snappy) { _ = BudgetPlanner.createFromTemplate(month, in: context) }
            }
            .buttonStyle(InkButtonStyle(prominent: previous == nil, onPlate: true))
            .accessibilityIdentifier("start-template")
            Button("Start blank") {
                withAnimation(.snappy) { _ = BudgetPlanner.createBlank(month, in: context) }
            }
            .buttonStyle(InkButtonStyle(prominent: false, onPlate: true))

            if months.isEmpty {
                Button("Explore with sample data") {
                    withAnimation(.snappy) { DemoData.seed(into: context) }
                }
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Ink.onPlate)
                .frame(maxWidth: .infinity)
                .padding(.top, 6)
                .accessibilityIdentifier("sample-data")
            }
        }
        .padding(22)
        .padding(.bottom, 16)
        // A plate nothing has been engraved on yet: the lathe work is only a ghost until there's a plan.
        .engravedPlate(completion: 0, rosetteRadius: 78, animates: false)
        .padding(.top, 8)
    }
}
