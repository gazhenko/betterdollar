import Foundation
import SwiftData

public enum LedgerError: LocalizedError, Equatable {
    case splitDoesNotAddUp(expected: Int, actual: Int)
    case emptySplit
    case negativeSplit

    public var errorDescription: String? {
        switch self {
        case let .splitDoesNotAddUp(expected, actual):
            let gap = expected - actual
            return gap > 0 ? "\(Money.format(gap)) is still unassigned." : "The split is \(Money.format(-gap)) more than the transaction."
        case .emptySplit: return "Choose at least one budget item."
        case .negativeSplit: return "Split amounts can't be negative."
        }
    }
}

/// Assigning transactions to budget items. Nothing is assigned until the user does it.
@MainActor public enum Ledger {
    @discardableResult
    public static func addManual(date: Date, amountCents: Int, isIncome: Bool, merchant: String, note: String = "",
                                 account: BankAccount? = nil, in context: ModelContext) -> LedgerTransaction {
        let transaction = LedgerTransaction(date: date, amountCents: amountCents, isIncome: isIncome,
                                            merchant: merchant.trimmingCharacters(in: .whitespacesAndNewlines), note: note)
        transaction.account = account
        context.insert(transaction)
        return transaction
    }

    /// Assigns the whole transaction to one item (drag-and-drop or tap).
    public static func assign(_ transaction: LedgerTransaction, to item: BudgetItem, in context: ModelContext) {
        clearAllocations(of: transaction, in: context)
        let allocation = Allocation(amountCents: transaction.amountCents)
        allocation.transaction = transaction
        allocation.item = item
        context.insert(allocation)
        transaction.status = .tracked
    }

    /// Splits a transaction across items. Amounts must add up to the transaction exactly.
    public static func split(_ transaction: LedgerTransaction, into parts: [(item: BudgetItem, amountCents: Int)],
                             in context: ModelContext) throws {
        let parts = parts.filter { $0.amountCents != 0 }
        guard !parts.isEmpty else { throw LedgerError.emptySplit }
        guard parts.allSatisfy({ $0.amountCents > 0 }) else { throw LedgerError.negativeSplit }
        let total = parts.reduce(0) { $0 + $1.amountCents }
        guard total == transaction.amountCents else {
            throw LedgerError.splitDoesNotAddUp(expected: transaction.amountCents, actual: total)
        }
        clearAllocations(of: transaction, in: context)
        for part in parts {
            let allocation = Allocation(amountCents: part.amountCents)
            allocation.transaction = transaction
            allocation.item = part.item
            context.insert(allocation)
        }
        transaction.status = .tracked
    }

    /// Sends a transaction back to the tray.
    public static func unassign(_ transaction: LedgerTransaction, in context: ModelContext) {
        clearAllocations(of: transaction, in: context)
        transaction.status = .new
    }

    /// Hides a transaction from the budget. It can be restored from the Deleted list.
    public static func delete(_ transaction: LedgerTransaction, in context: ModelContext) {
        clearAllocations(of: transaction, in: context)
        transaction.status = .deleted
    }

    /// A transaction's date moved to another month (for example a pending charge that posted later).
    /// Its assignment follows to the same items in the new month's plan, or it returns to the tray.
    public static func dateChanged(_ transaction: LedgerTransaction, from oldMonth: MonthKey, in context: ModelContext) {
        let newMonth = MonthKey(date: transaction.date)
        guard newMonth != oldMonth, transaction.status == .tracked else { return }
        let allocations = transaction.allocations ?? []
        guard let plan = BudgetPlanner.month(newMonth, in: context) else { unassign(transaction, in: context); return }
        let items = plan.allItems
        let targets = allocations.map { allocation in items.first { $0.seriesID == allocation.item?.seriesID } }
        guard !targets.isEmpty, targets.allSatisfy({ $0 != nil }) else { unassign(transaction, in: context); return }
        for (allocation, target) in zip(allocations, targets) { allocation.item = target }
    }

    public static func restore(_ transaction: LedgerTransaction) {
        guard transaction.status == .deleted else { return }
        transaction.status = .new
    }

    /// Removes a manual transaction for good. Bank transactions are hidden instead so the next sync doesn't bring them back.
    public static func remove(_ transaction: LedgerTransaction, in context: ModelContext) {
        if transaction.source == .manual { context.delete(transaction) } else { delete(transaction, in: context) }
    }

    /// Keeps allocations consistent after a transaction's amount changes (an edit or a bank update).
    public static func amountChanged(_ transaction: LedgerTransaction, in context: ModelContext) {
        let allocations = transaction.allocations ?? []
        guard !allocations.isEmpty else { return }
        if allocations.count == 1 {
            allocations[0].amountCents = transaction.amountCents
        } else if transaction.allocatedCents != transaction.amountCents {
            unassign(transaction, in: context)
        }
    }

    private static func clearAllocations(of transaction: LedgerTransaction, in context: ModelContext) {
        for allocation in transaction.allocations ?? [] {
            allocation.item = nil
            allocation.transaction = nil
            context.delete(allocation)
        }
        transaction.allocations = []
    }

    // MARK: - Suggestions

    /// Lowercased merchant without store numbers, so "SHELL OIL 12345" and "Shell Oil 778" match.
    public static func normalizedMerchant(_ merchant: String) -> String {
        merchant.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty && !$0.allSatisfy(\.isNumber) && $0 != "pos" && $0 != "debit" && $0 != "purchase" }
            .prefix(3)
            .joined(separator: " ")
    }

    /// The item this merchant was assigned to most recently, matched to `month` by series.
    /// Only a hint shown at the top of the picker; it is never applied automatically.
    public static func suggestedItem(for transaction: LedgerTransaction, in month: BudgetMonth, context: ModelContext) -> BudgetItem? {
        let target = normalizedMerchant(transaction.merchant)
        guard !target.isEmpty else { return nil }
        let tracked = TransactionStatus.tracked.rawValue
        let isIncome = transaction.isIncome
        var descriptor = FetchDescriptor<LedgerTransaction>(
            predicate: #Predicate { $0.statusRaw == tracked && $0.isIncome == isIncome },
            sortBy: [SortDescriptor(\.date, order: .reverse)])
        descriptor.fetchLimit = 400
        guard let previous = try? context.fetch(descriptor) else { return nil }
        let items = month.allItems
        for candidate in previous where candidate.persistentModelID != transaction.persistentModelID {
            guard normalizedMerchant(candidate.merchant) == target,
                  let series = candidate.allocations?.max(by: { $0.amountCents < $1.amountCents })?.item?.seriesID,
                  let match = items.first(where: { $0.seriesID == series }) else { continue }
            return match
        }
        return nil
    }

    public static func transactions(in month: MonthKey, status: TransactionStatus? = nil, context: ModelContext) -> [LedgerTransaction] {
        let interval = month.interval()
        let start = interval.start, end = interval.end
        let descriptor = FetchDescriptor<LedgerTransaction>(
            predicate: #Predicate { $0.date >= start && $0.date < end },
            sortBy: [SortDescriptor(\.date, order: .reverse)])
        let all = (try? context.fetch(descriptor)) ?? []
        guard let status else { return all }
        return all.filter { $0.status == status }
    }
}
