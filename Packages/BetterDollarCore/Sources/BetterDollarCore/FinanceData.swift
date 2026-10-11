import Foundation
import SwiftData

/// A read-only, Sendable copy of the user's finances for the on-device coach.
/// It is built on demand, handed to a local model, and never leaves the device.
public struct FinanceData: Sendable, Codable, Equatable {
    public struct Item: Sendable, Codable, Equatable {
        public var name: String
        public var group: String
        public var isIncome: Bool
        public var isFund: Bool
        public var plannedCents: Int
        public var activityCents: Int
        public var remainingCents: Int
        public var fundGoalCents: Int
        public var fundTargetDate: Date?
        public var monthlyToGoalCents: Int?
        public var dueDay: Int
    }

    public struct Group: Sendable, Codable, Equatable {
        public var name: String
        public var isIncome: Bool
        public var plannedCents: Int
        public var activityCents: Int
        public var items: [Item]
    }

    public struct Transaction: Sendable, Codable, Equatable {
        public var date: Date
        public var merchant: String
        public var amountCents: Int
        public var isIncome: Bool
        public var status: String
        public var items: [String]
        public var account: String?
        public var isPending: Bool
    }

    public struct Account: Sendable, Codable, Equatable {
        public var name: String
        public var institution: String
        public var type: String
        public var currentBalanceCents: Int?
        public var availableBalanceCents: Int?
    }

    public struct MonthHistory: Sendable, Codable, Equatable {
        public var month: MonthKey
        public var totals: MonthTotals
        /// Spending per expense group.
        public var spentByGroup: [String: Int]
    }

    public var month: MonthKey
    public var today: Date
    public var hasPlan: Bool
    public var totals: MonthTotals
    public var groups: [Group]
    public var newTransactionCount: Int
    /// This month and last month, newest first.
    public var transactions: [Transaction]
    public var accounts: [Account]
    /// Up to six earlier months, oldest first.
    public var history: [MonthHistory]

    public var items: [Item] { groups.flatMap(\.items) }
    public var funds: [Item] { items.filter(\.isFund) }

    public init(month: MonthKey, today: Date = Date(), hasPlan: Bool = false, totals: MonthTotals = MonthTotals(),
                groups: [Group] = [], newTransactionCount: Int = 0, transactions: [Transaction] = [],
                accounts: [Account] = [], history: [MonthHistory] = []) {
        self.month = month
        self.today = today
        self.hasPlan = hasPlan
        self.totals = totals
        self.groups = groups
        self.newTransactionCount = newTransactionCount
        self.transactions = transactions
        self.accounts = accounts
        self.history = history
    }
}

// MARK: - Building

public extension FinanceData {
    @MainActor static func build(month key: MonthKey, context: ModelContext, today: Date = Date()) -> FinanceData {
        let months = BudgetPlanner.allMonths(in: context)
        let funds = FundLedger(months: months)
        var data = FinanceData(month: key, today: today)

        if let month = months.first(where: { $0.key == key.id }) {
            data.hasPlan = true
            data.totals = BudgetMath.totals(for: month)
            data.groups = month.sortedGroups.map { group in
                let items = group.sortedItems.map { item -> Item in
                    let t = BudgetMath.totals(for: item, funds: funds)
                    return Item(name: item.name, group: group.name, isIncome: group.isIncome, isFund: item.isFund,
                                plannedCents: t.plannedCents, activityCents: t.activityCents, remainingCents: t.remainingCents,
                                fundGoalCents: item.fundGoalCents, fundTargetDate: item.fundTargetDate,
                                monthlyToGoalCents: item.isFund ? BudgetMath.monthlyToReachGoal(
                                    balanceCents: t.carryInCents, goalCents: item.fundGoalCents, from: key, target: item.fundTargetDate) : nil,
                                dueDay: item.dueDay)
                }
                return Group(name: group.name, isIncome: group.isIncome,
                             plannedCents: items.reduce(0) { $0 + $1.plannedCents },
                             activityCents: items.reduce(0) { $0 + $1.activityCents }, items: items)
            }
        }

        let recent = Ledger.transactions(in: key, context: context) + Ledger.transactions(in: key.previous, context: context)
        data.newTransactionCount = recent.filter { $0.status == .new && key.contains($0.date) }.count
        data.transactions = recent.filter { $0.status != .deleted }.prefix(250).map { t in
            Transaction(date: t.date, merchant: t.merchant, amountCents: t.amountCents, isIncome: t.isIncome,
                        status: t.status.rawValue, items: (t.allocations ?? []).compactMap { $0.item?.name },
                        account: t.account?.displayName, isPending: t.isPending)
        }

        let accounts = (try? context.fetch(FetchDescriptor<BankAccount>())) ?? []
        data.accounts = accounts.filter { !$0.isHidden }.map {
            Account(name: $0.displayName, institution: $0.link?.institutionName ?? "", type: $0.subtype.isEmpty ? $0.type : $0.subtype,
                    currentBalanceCents: $0.currentBalanceCents, availableBalanceCents: $0.availableBalanceCents)
        }

        data.history = months.filter { MonthKey($0.key).map { $0 < key && $0 >= key.adding(months: -6) } ?? false }.map { month in
            var spent: [String: Int] = [:]
            for group in month.expenseGroups {
                spent[group.name] = (group.items ?? []).reduce(0) { $0 + BudgetMath.activity(of: $1) }
            }
            return MonthHistory(month: month.monthKey, totals: BudgetMath.totals(for: month), spentByGroup: spent)
        }
        return data
    }
}

// MARK: - Text for prompts and tools

public extension FinanceData {
    /// A compact summary that fits comfortably in a small model's context.
    func overview() -> String {
        var lines: [String] = []
        lines.append("Today is \(today.formatted(date: .complete, time: .omitted)). Budget month: \(month.title).")
        guard hasPlan else {
            lines.append("There is no budget plan for \(month.title) yet.")
            lines.append(accountsText())
            return lines.joined(separator: "\n")
        }
        let t = totals
        lines.append("Planned income \(Money.format(t.plannedIncomeCents)), received so far \(Money.format(t.receivedCents)).")
        lines.append("Planned spending \(Money.format(t.plannedExpenseCents)), spent so far \(Money.format(t.spentCents)).")
        lines.append(BudgetFacts.cashFlow(t))
        if t.leftToBudgetCents == 0 {
            lines.append("Left to budget: $0.00. Zero-based: every planned dollar has a job.")
        } else if t.leftToBudgetCents > 0 {
            lines.append("Left to budget: \(Money.format(t.leftToBudgetCents)) of income has no job yet.")
        } else {
            lines.append("Over-planned: expenses exceed planned income by \(Money.format(-t.leftToBudgetCents)).")
        }
        lines.append("Transactions waiting to be assigned: \(newTransactionCount).")
        lines.append("Budget by group:")
        for group in groups {
            lines.append("- \(group.name)\(group.isIncome ? " (income)" : "")")
            for item in group.items {
                var line: String
                if item.isIncome {
                    line = "  • \(item.name): expected \(Money.format(item.plannedCents)), received \(Money.format(item.activityCents)), \(Money.format(max(0, item.remainingCents))) still to come"
                } else if item.isFund {
                    line = "  • \(item.name) (fund): planned this month \(Money.format(item.plannedCents)), spent \(Money.format(item.activityCents)), fund balance \(Money.format(item.remainingCents))"
                    if item.fundGoalCents > 0 { line += ", goal \(Money.format(item.fundGoalCents, showsCents: false))" }
                    if let date = item.fundTargetDate { line += " by \(date.formatted(.dateTime.month(.abbreviated).year()))" }
                } else {
                    line = "  • \(item.name): planned \(Money.format(item.plannedCents)), spent \(Money.format(item.activityCents)), "
                    line += item.remainingCents < 0 ? "OVERSPENT by \(Money.format(-item.remainingCents))" : "\(Money.format(item.remainingCents)) left"
                }
                lines.append(line)
            }
        }
        return lines.joined(separator: "\n")
    }

    func accountsText() -> String {
        guard !accounts.isEmpty else { return "No bank accounts are connected." }
        return "Accounts:\n" + accounts.map { account in
            let balance = account.currentBalanceCents.map { Money.format($0) } ?? "unknown"
            return "- \(account.name) (\(account.institution.isEmpty ? account.type : account.institution + ", " + account.type)): \(balance)"
        }.joined(separator: "\n")
    }

    func fundsText() -> String {
        guard !funds.isEmpty else { return "There are no funds (savings goals) in this budget." }
        return "Funds and goals:\n" + funds.map { fund in
            var line = "- \(fund.name): balance \(Money.format(fund.remainingCents)), planned this month \(Money.format(fund.plannedCents))"
            if fund.fundGoalCents > 0 {
                let percent = Int((Double(max(0, fund.remainingCents)) / Double(fund.fundGoalCents) * 100).rounded())
                line += ", goal \(Money.format(fund.fundGoalCents)) (\(percent)% there)"
            }
            if let date = fund.fundTargetDate { line += ", target \(date.formatted(.dateTime.month(.wide).year()))" }
            if let monthly = fund.monthlyToGoalCents { line += ", needs \(Money.format(monthly))/month to hit it" }
            return line
        }.joined(separator: "\n")
    }

    func historyText() -> String {
        guard !history.isEmpty else { return "No earlier months to compare with." }
        return "Earlier months:\n" + history.map { h in
            let top = h.spentByGroup.sorted { $0.value > $1.value }.prefix(4)
                .map { "\($0.key) \(Money.format($0.value, showsCents: false))" }.joined(separator: ", ")
            return "- \(h.month.title): income \(Money.format(h.totals.receivedCents, showsCents: false)), spent \(Money.format(h.totals.spentCents, showsCents: false)) (top: \(top))"
        }.joined(separator: "\n")
    }

    /// Details for one budget item, matched case-insensitively.
    func itemDetail(named name: String) -> String? {
        let needle = name.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty, let item = items.first(where: { $0.name.lowercased() == needle })
                ?? items.first(where: { $0.name.lowercased().contains(needle) || needle.contains($0.name.lowercased()) }) else { return nil }
        var lines = ["\(item.name) (\(item.group)) in \(month.title): planned \(Money.format(item.plannedCents)), \(item.isIncome ? "received" : "spent") \(Money.format(item.activityCents)), remaining \(Money.format(item.remainingCents))."]
        if item.dueDay > 0 { lines.append("Due on day \(item.dueDay) of the month.") }
        let matching = transactions.filter { $0.items.contains(item.name) }.prefix(12)
        if matching.isEmpty {
            lines.append("No transactions assigned to it recently.")
        } else {
            lines.append("Recent transactions:")
            lines += matching.map { "- \(line(for: $0))" }
        }
        return lines.joined(separator: "\n")
    }

    /// Transactions whose merchant or budget item matches `query` (empty query lists the latest ones).
    func searchTransactions(_ query: String, limit: Int = 15) -> String {
        let needle = query.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let matches = transactions.filter { t in
            needle.isEmpty || t.merchant.lowercased().contains(needle) || t.items.contains { $0.lowercased().contains(needle) }
        }
        guard !matches.isEmpty else { return "No transactions in \(month.previous.title) or \(month.title) match \"\(query)\"." }
        let total = matches.reduce(0) { $0 + ($1.isIncome ? -$1.amountCents : $1.amountCents) }
        return (["\(matches.count) matching transactions, net spending \(Money.format(total)):"]
            + matches.prefix(limit).map { "- \(line(for: $0))" }).joined(separator: "\n")
    }

    /// Extra details for items, funds or merchants that the question mentions.
    func relevantContext(for question: String) -> String {
        let words = Set(question.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { $0.count > 2 })
        var parts: [String] = []
        for item in items where item.name.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).contains(where: { words.contains($0) }) {
            if let detail = itemDetail(named: item.name) { parts.append(detail) }
            if parts.count >= 3 { break }
        }
        let merchants = Set(transactions.map(\.merchant)).filter { merchant in
            merchant.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).contains { $0.count > 2 && words.contains($0) }
        }
        for merchant in merchants.prefix(2) { parts.append(searchTransactions(merchant, limit: 8)) }
        if words.contains(where: { ["fund", "funds", "goal", "goals", "save", "saving", "savings", "emergency"].contains($0) }) {
            parts.append(fundsText())
        }
        if words.contains(where: { ["last", "trend", "compare", "history", "previous", "average", "usually"].contains($0) }) {
            parts.append(historyText())
        }
        if words.contains(where: { ["account", "accounts", "balance", "balances", "bank", "checking", "credit", "card"].contains($0) }) {
            parts.append(accountsText())
        }
        return parts.joined(separator: "\n\n")
    }

    private func line(for t: Transaction) -> String {
        let date = t.date.formatted(.dateTime.month(.abbreviated).day())
        let amount = (t.isIncome ? "+" : "-") + Money.format(t.amountCents)
        let assigned = t.items.isEmpty ? "unassigned" : t.items.joined(separator: " + ")
        return "\(date) \(t.merchant) \(amount) → \(assigned)\(t.isPending ? " (pending)" : "")"
    }
}


/// Sentences with figures already worked out, so small models quote them instead of doing arithmetic.
public enum BudgetFacts {
    public static func cashFlow(_ t: MonthTotals) -> String {
        let net = t.receivedCents - t.spentCents
        let flow = net >= 0 ? "\(Money.format(net)) more has come in than gone out" : "\(Money.format(-net)) more has gone out than come in"
        return "Cash flow so far this month: \(flow) (received \(Money.format(t.receivedCents)), spent \(Money.format(t.spentCents))). This is not the same as left to budget."
    }
}
