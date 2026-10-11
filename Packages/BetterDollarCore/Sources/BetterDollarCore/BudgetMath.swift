import Foundation
import SwiftData

/// Totals for one budget item in one month.
public struct ItemTotals: Equatable, Sendable {
    public var plannedCents: Int
    /// Spending for expense items, money received for income items (refunds count against spending).
    public var activityCents: Int
    /// Fund balance carried in from earlier months (zero for ordinary items).
    public var carryInCents: Int
    public var isFund: Bool

    /// Ordinary items: planned minus spent. Funds: the balance available to spend.
    public var remainingCents: Int { isFund ? carryInCents + plannedCents - activityCents : plannedCents - activityCents }
    public var isOverspent: Bool { remainingCents < 0 }
    /// Share of the plan already used, clamped to 0...1 for progress bars.
    public var progress: Double {
        let base = isFund ? carryInCents + plannedCents : plannedCents
        guard base > 0 else { return activityCents > 0 ? 1 : 0 }
        return min(1, max(0, Double(activityCents) / Double(base)))
    }
}

/// Totals for a whole month's plan.
public struct MonthTotals: Equatable, Sendable, Codable {
    public init() {}
    public var plannedIncomeCents = 0
    public var plannedExpenseCents = 0
    public var receivedCents = 0
    public var spentCents = 0
    /// Zero-based budgeting: every planned dollar of income gets a job.
    public var leftToBudgetCents: Int { plannedIncomeCents - plannedExpenseCents }
    public var isZeroBased: Bool { plannedIncomeCents > 0 && leftToBudgetCents == 0 }
}

public enum BudgetMath {
    /// What moved against an item: allocations from transactions in the same direction add, opposite ones subtract.
    public static func activity(of item: BudgetItem) -> Int {
        let incomeItem = item.isIncomeItem
        return (item.allocations ?? []).reduce(0) { sum, allocation in
            guard let transaction = allocation.transaction, transaction.status == .tracked else { return sum }
            return sum + (transaction.isIncome == incomeItem ? allocation.amountCents : -allocation.amountCents)
        }
    }

    public static func totals(for item: BudgetItem, funds: FundLedger? = nil) -> ItemTotals {
        ItemTotals(plannedCents: item.plannedCents,
                   activityCents: activity(of: item),
                   carryInCents: item.isFund ? (funds?.carryIn(for: item) ?? item.fundStartingCents + item.fundAdjustmentCents) : 0,
                   isFund: item.isFund)
    }

    public static func totals(for month: BudgetMonth) -> MonthTotals {
        var totals = MonthTotals()
        for group in month.groups ?? [] {
            for item in group.items ?? [] {
                if group.isIncome {
                    totals.plannedIncomeCents += item.plannedCents
                    totals.receivedCents += activity(of: item)
                } else {
                    totals.plannedExpenseCents += item.plannedCents
                    totals.spentCents += activity(of: item)
                }
            }
        }
        return totals
    }

    public static func groupTotals(for group: BudgetGroup, funds: FundLedger? = nil) -> ItemTotals {
        (group.items ?? []).reduce(ItemTotals(plannedCents: 0, activityCents: 0, carryInCents: 0, isFund: false)) { sum, item in
            let t = totals(for: item, funds: funds)
            return ItemTotals(plannedCents: sum.plannedCents + t.plannedCents,
                              activityCents: sum.activityCents + t.activityCents,
                              carryInCents: sum.carryInCents + t.carryInCents,
                              isFund: false)
        }
    }

    /// Monthly amount needed to reach a fund's goal by its target date, counting the current month.
    public static func monthlyToReachGoal(balanceCents: Int, goalCents: Int, from month: MonthKey, target: Date?) -> Int? {
        guard goalCents > 0, let target else { return nil }
        let remaining = goalCents - balanceCents
        guard remaining > 0 else { return 0 }
        let targetMonth = MonthKey(date: target)
        let months = (targetMonth.year - month.year) * 12 + (targetMonth.month - month.month) + 1
        guard months > 0 else { return remaining }
        return Int((Double(remaining) / Double(months)).rounded(.up))
    }
}

/// Running balances for funds across every month, keyed by the item's series.
public struct FundLedger: Sendable {
    public struct Entry: Equatable, Sendable {
        public var month: MonthKey
        public var carryInCents: Int
        public var plannedCents: Int
        public var activityCents: Int
        public var endingCents: Int { carryInCents + plannedCents - activityCents }
    }

    private var entries: [UUID: [Entry]] = [:]

    /// - Parameter excluding: an item to leave out, to see balances as they'd be without it.
    public init(months: [BudgetMonth], excluding: PersistentIdentifier? = nil) {
        var raw: [UUID: [(MonthKey, BudgetItem)]] = [:]
        for month in months {
            for item in month.allItems where item.isFund && item.persistentModelID != excluding {
                raw[item.seriesID, default: []].append((month.monthKey, item))
            }
        }
        for (series, list) in raw {
            var running: Int?
            var result: [Entry] = []
            for (key, item) in list.sorted(by: { $0.0 < $1.0 }) {
                let carryIn = (running ?? item.fundStartingCents) + item.fundAdjustmentCents
                let entry = Entry(month: key, carryInCents: carryIn, plannedCents: item.plannedCents,
                                  activityCents: BudgetMath.activity(of: item))
                result.append(entry)
                running = entry.endingCents
            }
            entries[series] = result
        }
    }

    public func carryIn(for item: BudgetItem) -> Int {
        guard let key = item.monthKey, let entry = entries[item.seriesID]?.first(where: { $0.month == key }) else {
            return item.fundStartingCents + item.fundAdjustmentCents
        }
        return entry.carryInCents
    }

    public func balance(for item: BudgetItem) -> Int {
        guard let key = item.monthKey, let entry = entries[item.seriesID]?.first(where: { $0.month == key }) else {
            return item.fundStartingCents + item.fundAdjustmentCents + item.plannedCents - BudgetMath.activity(of: item)
        }
        return entry.endingCents
    }

    public func history(for item: BudgetItem) -> [Entry] { entries[item.seriesID] ?? [] }
}
