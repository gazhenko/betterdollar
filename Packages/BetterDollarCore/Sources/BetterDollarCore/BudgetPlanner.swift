import Foundation
import SwiftData

/// A starting layout for a first budget. Planned amounts start at zero so nothing is assumed about the user.
public enum BudgetTemplate {
    public struct Group: Sendable {
        public let name: String
        public let isIncome: Bool
        public let items: [String]
        public let funds: Set<String>
    }

    public static let standard: [Group] = [
        Group(name: "Income", isIncome: true, items: ["Paycheck 1", "Paycheck 2"], funds: []),
        Group(name: "Giving", isIncome: false, items: ["Charity"], funds: []),
        Group(name: "Savings", isIncome: false, items: ["Emergency Fund"], funds: ["Emergency Fund"]),
        Group(name: "Housing", isIncome: false, items: ["Mortgage/Rent", "Water", "Electricity", "Natural Gas", "Internet"], funds: []),
        Group(name: "Transportation", isIncome: false, items: ["Gas", "Maintenance", "Parking"], funds: ["Maintenance"]),
        Group(name: "Food", isIncome: false, items: ["Groceries", "Restaurants"], funds: []),
        Group(name: "Personal", isIncome: false, items: ["Phone", "Clothing", "Fun Money", "Subscriptions"], funds: []),
        Group(name: "Lifestyle", isIncome: false, items: ["Entertainment", "Gifts", "Miscellaneous"], funds: ["Gifts"]),
        Group(name: "Health", isIncome: false, items: ["Gym", "Medicine", "Doctor Visits"], funds: []),
        Group(name: "Insurance", isIncome: false, items: ["Health Insurance", "Auto Insurance", "Renters/Home Insurance"], funds: []),
        Group(name: "Debt", isIncome: false, items: ["Credit Card", "Car Payment", "Student Loan"], funds: [])
    ]
}

@MainActor public enum BudgetPlanner {
    public static func month(_ key: MonthKey, in context: ModelContext) -> BudgetMonth? {
        let id = key.id
        var descriptor = FetchDescriptor<BudgetMonth>(predicate: #Predicate { $0.key == id })
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }

    public static func allMonths(in context: ModelContext) -> [BudgetMonth] {
        (try? context.fetch(FetchDescriptor<BudgetMonth>(sortBy: [SortDescriptor(\.key)]))) ?? []
    }

    /// The most recent month before `key` that has a plan.
    public static func latestMonth(before key: MonthKey, in context: ModelContext) -> BudgetMonth? {
        let id = key.id
        var descriptor = FetchDescriptor<BudgetMonth>(predicate: #Predicate { $0.key < id }, sortBy: [SortDescriptor(\.key, order: .reverse)])
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }

    @discardableResult
    public static func createFromTemplate(_ key: MonthKey, in context: ModelContext) -> BudgetMonth {
        let month = BudgetMonth(key: key)
        context.insert(month)
        for (groupIndex, template) in BudgetTemplate.standard.enumerated() {
            let group = BudgetGroup(name: template.name, isIncome: template.isIncome, sortIndex: groupIndex)
            group.month = month
            context.insert(group)
            for (itemIndex, name) in template.items.enumerated() {
                let item = BudgetItem(name: name, sortIndex: itemIndex)
                item.isFund = template.funds.contains(name)
                item.group = group
                context.insert(item)
            }
        }
        return month
    }

    /// Starts a month with the same groups, items and planned amounts as `source`. Funds keep their series so balances roll over.
    @discardableResult
    public static func createByCopying(_ source: BudgetMonth, to key: MonthKey, in context: ModelContext) -> BudgetMonth {
        let month = BudgetMonth(key: key)
        context.insert(month)
        for sourceGroup in source.sortedGroups {
            let group = BudgetGroup(name: sourceGroup.name, isIncome: sourceGroup.isIncome, sortIndex: sourceGroup.sortIndex)
            group.month = month
            context.insert(group)
            for sourceItem in sourceGroup.sortedItems {
                let item = BudgetItem(name: sourceItem.name, plannedCents: sourceItem.plannedCents,
                                      sortIndex: sourceItem.sortIndex, seriesID: sourceItem.seriesID)
                item.isFund = sourceItem.isFund
                item.fundGoalCents = sourceItem.fundGoalCents
                item.fundTargetDate = sourceItem.fundTargetDate
                item.fundStartingCents = sourceItem.fundStartingCents
                item.dueDay = sourceItem.dueDay
                item.note = sourceItem.note
                item.group = group
                context.insert(item)
            }
        }
        return month
    }

    /// Creates an empty month with only an income group.
    @discardableResult
    public static func createBlank(_ key: MonthKey, in context: ModelContext) -> BudgetMonth {
        let month = BudgetMonth(key: key)
        context.insert(month)
        let income = BudgetGroup(name: "Income", isIncome: true, sortIndex: 0)
        income.month = month
        context.insert(income)
        let paycheck = BudgetItem(name: "Paycheck", sortIndex: 0)
        paycheck.group = income
        context.insert(paycheck)
        return month
    }

    @discardableResult
    public static func addGroup(named name: String, to month: BudgetMonth, in context: ModelContext) -> BudgetGroup {
        let group = BudgetGroup(name: name, sortIndex: (month.groups ?? []).map(\.sortIndex).max().map { $0 + 1 } ?? 0)
        group.month = month
        context.insert(group)
        return group
    }

    @discardableResult
    public static func addItem(named name: String, plannedCents: Int = 0, isFund: Bool = false,
                               to group: BudgetGroup, in context: ModelContext) -> BudgetItem {
        let item = BudgetItem(name: name, plannedCents: plannedCents,
                              sortIndex: (group.items ?? []).map(\.sortIndex).max().map { $0 + 1 } ?? 0)
        item.isFund = isFund
        item.group = group
        context.insert(item)
        return item
    }

    /// Deleting an item sends its transactions back to the tray instead of losing them.
    /// A fund's later balances stay the same.
    public static func delete(_ item: BudgetItem, in context: ModelContext) {
        preserveLaterFundBalances(without: item, in: context)
        for allocation in item.allocations ?? [] {
            if let transaction = allocation.transaction {
                Ledger.unassign(transaction, in: context)
            }
        }
        context.delete(item)
    }

    /// Turns an item into a fund or back. Making it regular leaves later months' fund balances unchanged.
    public static func setFund(_ item: BudgetItem, _ isFund: Bool, in context: ModelContext) {
        guard item.isFund != isFund, !(isFund && item.isIncomeItem) else { return }
        if !isFund { preserveLaterFundBalances(without: item, in: context) }
        item.isFund = isFund
    }

    /// When a fund item leaves the chain, the next month's fund gets an adjustment equal to what it loses.
    static func preserveLaterFundBalances(without item: BudgetItem, in context: ModelContext) {
        guard item.isFund, let key = item.monthKey else { return }
        let months = allMonths(in: context)
        let series = item.seriesID
        guard let next = months.filter({ $0.monthKey > key })
                .compactMap({ month in month.allItems.first { $0.seriesID == series && $0.isFund } }).first else { return }
        let before = FundLedger(months: months).carryIn(for: next)
        let after = FundLedger(months: months, excluding: item.persistentModelID).carryIn(for: next)
        next.fundAdjustmentCents += before - after
    }

    public static func delete(_ group: BudgetGroup, in context: ModelContext) {
        for item in group.items ?? [] { delete(item, in: context) }
        context.delete(group)
    }

    public static func move(_ items: [BudgetItem]) {
        for (index, item) in items.enumerated() { item.sortIndex = index }
    }
}
