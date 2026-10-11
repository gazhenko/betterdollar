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
                .foregroundStyle(Ink.text)
            Text(months.isEmpty
                 ? "Give every dollar of this month's income a job, one budget item at a time. Your plan stays on this iPhone."
                 : "Each month gets its own plan. Funds keep their balances from month to month.")
                .font(.body)
                .foregroundStyle(Ink.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let previous {
                Button("Copy \(previous.monthKey.monthName)'s plan") {
                    withAnimation(.snappy) { _ = BudgetPlanner.createByCopying(previous, to: month, in: context) }
                }
                .buttonStyle(InkButtonStyle())
                .accessibilityIdentifier("copy-plan")
            }
            Button("Start with common budget items") {
                withAnimation(.snappy) { _ = BudgetPlanner.createFromTemplate(month, in: context) }
            }
            .buttonStyle(InkButtonStyle(prominent: previous == nil))
            .accessibilityIdentifier("start-template")
            Button("Start blank") {
                withAnimation(.snappy) { _ = BudgetPlanner.createBlank(month, in: context) }
            }
            .buttonStyle(InkButtonStyle(prominent: false))

            if months.isEmpty {
                Button("Explore with sample data") {
                    withAnimation(.snappy) { DemoData.seed(into: context) }
                }
                .font(.subheadline.weight(.medium))
                .frame(maxWidth: .infinity)
                .padding(.top, 6)
                .accessibilityIdentifier("sample-data")
            }
        }
        .padding(22)
        .background(Ink.sheet, in: .rect(cornerRadius: 22))
        .overlay {
            RoundedRectangle(cornerRadius: 22).strokeBorder(Ink.rule, lineWidth: 1)
        }
        .padding(.top, 8)
    }
}
