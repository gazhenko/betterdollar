import Foundation
import SwiftData

/// Applies Plaid changes to the local ledger without ever assigning anything on the user's behalf.
/// New bank transactions land in the tray; edits keep the user's assignments where they still fit.
@MainActor public enum PlaidSyncApplier {
    public struct Summary: Equatable, Sendable {
        public var added = 0
        public var updated = 0
        public var removed = 0
        public init() {}
    }

    public static func upsertAccounts(_ accounts: [PlaidAccount], link: BankLink, in context: ModelContext) {
        let existing = Dictionary((link.accounts ?? []).map { ($0.externalID, $0) }, uniquingKeysWith: { first, _ in first })
        for remote in accounts {
            let account = existing[remote.accountId] ?? {
                let created = BankAccount(externalID: remote.accountId, name: remote.name)
                created.link = link
                context.insert(created)
                return created
            }()
            account.name = remote.name
            account.officialName = remote.officialName ?? ""
            account.mask = remote.mask ?? ""
            account.type = remote.type
            account.subtype = remote.subtype ?? ""
            account.currentBalanceCents = remote.balances.current.map(Money.cents(from:))
            account.availableBalanceCents = remote.balances.available.map(Money.cents(from:))
        }
    }

    @discardableResult
    public static func apply(_ result: PlaidSyncResult, to link: BankLink, in context: ModelContext,
                             calendar: Calendar = .current) -> Summary {
        if !result.accounts.isEmpty { upsertAccounts(result.accounts, link: link, in: context) }
        let accounts = Dictionary((link.accounts ?? []).map { ($0.externalID, $0) }, uniquingKeysWith: { first, _ in first })
        var summary = Summary()

        // Index existing Plaid transactions for this bank by id.
        let plaid = TransactionSource.plaid.rawValue
        let all = (try? context.fetch(FetchDescriptor<LedgerTransaction>(predicate: #Predicate { $0.sourceRaw == plaid }))) ?? []
        var byID = Dictionary(all.compactMap { t in t.externalID.map { ($0, t) } }, uniquingKeysWith: { first, _ in first })

        for remote in result.added {
            if let local = byID[remote.transactionId] {
                update(local, from: remote, accounts: accounts, calendar: calendar, context: context)
                summary.updated += 1
            } else if let pendingID = remote.pendingTransactionId, let pending = byID[pendingID] {
                // A pending charge posted: keep the user's assignment and move it to the posted id.
                byID[pendingID] = nil
                pending.externalID = remote.transactionId
                byID[remote.transactionId] = pending
                update(pending, from: remote, accounts: accounts, calendar: calendar, context: context)
                summary.updated += 1
            } else {
                let created = LedgerTransaction(date: date(remote, calendar: calendar), amountCents: Money.cents(from: remote.amount),
                                                isIncome: remote.amount < 0, merchant: merchant(remote),
                                                source: .plaid, externalID: remote.transactionId)
                created.isPending = remote.pending
                created.bankCategory = remote.personalFinanceCategory?.primary
                created.account = accounts[remote.accountId]
                context.insert(created)
                byID[remote.transactionId] = created
                summary.added += 1
            }
        }
        for remote in result.modified {
            guard let local = byID[remote.transactionId] else { continue }
            update(local, from: remote, accounts: accounts, calendar: calendar, context: context)
            summary.updated += 1
        }
        for removed in result.removed {
            guard let local = byID[removed.transactionId] else { continue }
            context.delete(local)
            byID[removed.transactionId] = nil
            summary.removed += 1
        }
        if let cursor = result.cursor { link.cursor = cursor }
        link.lastSyncedAt = Date()
        link.lastError = nil
        link.needsReconnect = false
        return summary
    }

    private static func update(_ local: LedgerTransaction, from remote: PlaidTransaction, accounts: [String: BankAccount],
                               calendar: Calendar, context: ModelContext) {
        let oldMonth = MonthKey(date: local.date, calendar: calendar)
        local.date = date(remote, calendar: calendar)
        Ledger.dateChanged(local, from: oldMonth, in: context)
        if !local.merchantEdited { local.merchant = merchant(remote) }
        local.isPending = remote.pending
        local.bankCategory = remote.personalFinanceCategory?.primary ?? local.bankCategory
        if let account = accounts[remote.accountId] { local.account = account }
        let cents = Money.cents(from: remote.amount)
        let isIncome = remote.amount < 0
        if abs(cents) != local.amountCents || isIncome != local.isIncome {
            local.amountCents = abs(cents)
            if isIncome != local.isIncome {
                local.isIncome = isIncome
                if local.status == .tracked { Ledger.unassign(local, in: context) }
            } else {
                Ledger.amountChanged(local, in: context)
            }
        }
    }

    private static func merchant(_ remote: PlaidTransaction) -> String {
        let merchant = remote.merchantName?.trimmingCharacters(in: .whitespaces) ?? ""
        return merchant.isEmpty ? remote.name : merchant
    }

    /// Plaid dates are calendar days; anchor them at noon so time zones never move them to another day.
    static func date(_ remote: PlaidTransaction, calendar: Calendar) -> Date {
        let parts = remote.date.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return Date() }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2], hour: 12)) ?? Date()
    }
}
