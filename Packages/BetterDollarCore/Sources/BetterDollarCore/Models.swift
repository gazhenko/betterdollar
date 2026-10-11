import Foundation
import SwiftData

// Every property has a default and every relationship is optional so the
// schema stays compatible with CloudKit if sync is turned on later.

public enum TransactionStatus: String, Codable, Sendable, CaseIterable {
    /// Waiting in the tray to be assigned to a budget item.
    case new
    /// Fully assigned to one or more budget items.
    case tracked
    /// Hidden from the budget; can be restored.
    case deleted
}

public enum TransactionSource: String, Codable, Sendable {
    case manual, plaid, csv
}

/// One month's plan.
@Model public final class BudgetMonth {
    public var key: String = ""
    public var createdAt: Date = Date()
    @Relationship(deleteRule: .cascade, inverse: \BudgetGroup.month)
    public var groups: [BudgetGroup]? = []

    public init(key: MonthKey) { self.key = key.id }

    public var monthKey: MonthKey { MonthKey(key) ?? .current() }
    public var sortedGroups: [BudgetGroup] { (groups ?? []).sorted { ($0.sortIndex, $0.name) < ($1.sortIndex, $1.name) } }
    public var incomeGroup: BudgetGroup? { sortedGroups.first(where: \.isIncome) }
    public var expenseGroups: [BudgetGroup] { sortedGroups.filter { !$0.isIncome } }
    public var allItems: [BudgetItem] { sortedGroups.flatMap(\.sortedItems) }
}

/// A heading such as "Food" that holds budget items.
@Model public final class BudgetGroup {
    public var name: String = ""
    public var isIncome: Bool = false
    public var sortIndex: Int = 0
    public var month: BudgetMonth?
    @Relationship(deleteRule: .cascade, inverse: \BudgetItem.group)
    public var items: [BudgetItem]? = []

    public init(name: String, isIncome: Bool = false, sortIndex: Int = 0) {
        self.name = name
        self.isIncome = isIncome
        self.sortIndex = sortIndex
    }

    public var sortedItems: [BudgetItem] { (items ?? []).sorted { ($0.sortIndex, $0.name) < ($1.sortIndex, $1.name) } }
}

/// A line in the budget ("Groceries") that transactions are assigned to.
@Model public final class BudgetItem {
    public var uuid: UUID = UUID()
    public var name: String = ""
    public var plannedCents: Int = 0
    public var sortIndex: Int = 0
    /// The same item in different months shares a series, which is how funds roll over.
    public var seriesID: UUID = UUID()
    /// Funds keep their balance from month to month (sinking funds, savings goals).
    public var isFund: Bool = false
    public var fundGoalCents: Int = 0
    public var fundTargetDate: Date?
    /// Balance the fund started with before its first month in BetterDollar.
    public var fundStartingCents: Int = 0
    /// Balance carried over from a removed month so later balances don't change.
    public var fundAdjustmentCents: Int = 0
    /// Optional day of the month the bill is due.
    public var dueDay: Int = 0
    public var note: String = ""
    public var group: BudgetGroup?
    @Relationship(deleteRule: .cascade, inverse: \Allocation.item)
    public var allocations: [Allocation]? = []

    public init(name: String, plannedCents: Int = 0, sortIndex: Int = 0, seriesID: UUID = UUID()) {
        self.name = name
        self.plannedCents = plannedCents
        self.sortIndex = sortIndex
        self.seriesID = seriesID
    }

    public var isIncomeItem: Bool { group?.isIncome ?? false }
    public var monthKey: MonthKey? { group?.month.flatMap { MonthKey($0.key) } }
}

/// Money moved in or out of an account, entered by hand, imported, or synced from Plaid.
@Model public final class LedgerTransaction {
    public var uuid: UUID = UUID()
    public var date: Date = Date()
    /// Always zero or positive; `isIncome` gives the direction.
    public var amountCents: Int = 0
    public var isIncome: Bool = false
    public var merchant: String = ""
    /// The user renamed a bank transaction; syncs keep their name.
    public var merchantEdited: Bool = false
    public var note: String = ""
    public var statusRaw: String = TransactionStatus.new.rawValue
    public var sourceRaw: String = TransactionSource.manual.rawValue
    public var externalID: String?
    /// Plaid's personal finance category, kept only as a hint.
    public var bankCategory: String?
    public var isPending: Bool = false
    public var createdAt: Date = Date()
    public var account: BankAccount?
    @Relationship(deleteRule: .cascade, inverse: \Allocation.transaction)
    public var allocations: [Allocation]? = []

    public init(date: Date, amountCents: Int, isIncome: Bool, merchant: String, note: String = "",
                source: TransactionSource = .manual, externalID: String? = nil) {
        self.date = date
        self.amountCents = abs(amountCents)
        self.isIncome = isIncome
        self.merchant = merchant
        self.note = note
        self.sourceRaw = source.rawValue
        self.externalID = externalID
    }

    public var status: TransactionStatus {
        get { TransactionStatus(rawValue: statusRaw) ?? .new }
        set { statusRaw = newValue.rawValue }
    }
    public var source: TransactionSource { TransactionSource(rawValue: sourceRaw) ?? .manual }
    public var isSplit: Bool { (allocations ?? []).count > 1 }
    public var allocatedCents: Int { (allocations ?? []).reduce(0) { $0 + $1.amountCents } }
    /// Signed amount: income positive, spending negative.
    public var signedCents: Int { isIncome ? amountCents : -amountCents }
}

/// The part of a transaction assigned to one budget item. Splits have several.
@Model public final class Allocation {
    public var amountCents: Int = 0
    public var transaction: LedgerTransaction?
    public var item: BudgetItem?

    public init(amountCents: Int) { self.amountCents = amountCents }
}

/// A bank login connected through the user's own Plaid keys (a Plaid "Item").
@Model public final class BankLink {
    public var itemID: String = ""
    public var institutionName: String = ""
    public var institutionID: String = ""
    public var cursor: String?
    public var lastSyncedAt: Date?
    public var lastError: String?
    public var needsReconnect: Bool = false
    /// The Plaid environment whose keys created this connection ("sandbox" or "production").
    public var environmentRaw: String = ""
    public var createdAt: Date = Date()
    @Relationship(deleteRule: .cascade, inverse: \BankAccount.link)
    public var accounts: [BankAccount]? = []

    public init(itemID: String, institutionName: String, institutionID: String = "") {
        self.itemID = itemID
        self.institutionName = institutionName
        self.institutionID = institutionID
    }
}

@Model public final class BankAccount {
    public var uuid: UUID = UUID()
    public var externalID: String = ""
    public var name: String = ""
    public var officialName: String = ""
    public var mask: String = ""
    public var type: String = ""
    public var subtype: String = ""
    public var currentBalanceCents: Int?
    public var availableBalanceCents: Int?
    public var isHidden: Bool = false
    public var link: BankLink?
    @Relationship(deleteRule: .nullify, inverse: \LedgerTransaction.account)
    public var transactions: [LedgerTransaction]? = []

    public init(externalID: String, name: String) {
        self.externalID = externalID
        self.name = name
    }

    public var displayName: String { mask.isEmpty ? name : "\(name) ••\(mask)" }
    /// Credit cards and loans report what you owe as a positive balance.
    public var isLiability: Bool { type == "credit" || type == "loan" }
}

/// One turn in the coach conversation, kept on this iPhone only.
@Model public final class CoachMessage {
    public var roleRaw: String = "user"
    public var text: String = ""
    public var engine: String = ""
    public var createdAt: Date = Date()

    public init(role: String, text: String, engine: String = "") {
        self.roleRaw = role
        self.text = text
        self.engine = engine
    }

    public var isUser: Bool { roleRaw == "user" }
}

public enum BetterDollarSchema {
    public static let models: [any PersistentModel.Type] = [
        BudgetMonth.self, BudgetGroup.self, BudgetItem.self, LedgerTransaction.self,
        Allocation.self, BankLink.self, BankAccount.self, CoachMessage.self
    ]

    @MainActor public static func container(inMemory: Bool = false, url: URL? = nil) throws -> ModelContainer {
        let schema = Schema(models)
        let configuration: ModelConfiguration
        if inMemory {
            configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        } else if let url {
            configuration = ModelConfiguration(schema: schema, url: url, cloudKitDatabase: .none)
        } else {
            configuration = ModelConfiguration(schema: schema, cloudKitDatabase: .none)
        }
        return try ModelContainer(for: schema, configurations: [configuration])
    }
}
