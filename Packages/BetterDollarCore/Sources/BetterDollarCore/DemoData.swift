import Foundation
import SwiftData

/// A fictional household used for "Explore with sample data", screenshots and UI tests.
@MainActor public enum DemoData {
    private static let plan: [(group: String, isIncome: Bool, items: [(String, Int, fund: (start: Int, goal: Int)?)])] = [
        ("Income", true, [("Paycheck 1", 3_150_00, nil), ("Paycheck 2", 3_150_00, nil)]),
        ("Giving", false, [("Charity", 630_00, nil)]),
        ("Savings", false, [("Emergency Fund", 700_00, (6_200_00, 15_000_00))]),
        ("Housing", false, [("Rent", 1_850_00, nil), ("Water", 60_00, nil), ("Electricity", 110_00, nil),
                            ("Natural Gas", 45_00, nil), ("Internet", 70_00, nil)]),
        ("Transportation", false, [("Gas", 180_00, nil), ("Car Maintenance", 75_00, (300_00, 1_200_00)), ("Parking", 40_00, nil)]),
        ("Food", false, [("Groceries", 650_00, nil), ("Restaurants", 220_00, nil)]),
        ("Personal", false, [("Phone", 85_00, nil), ("Clothing", 100_00, nil), ("Fun Money", 150_00, nil), ("Subscriptions", 45_00, nil)]),
        ("Lifestyle", false, [("Entertainment", 90_00, nil), ("Gifts", 60_00, (180_00, 600_00)), ("Miscellaneous", 80_00, nil)]),
        ("Health", false, [("Gym", 40_00, nil), ("Medicine", 25_00, nil), ("Doctor Visits", 50_00, nil)]),
        ("Insurance", false, [("Auto Insurance", 120_00, nil), ("Renters Insurance", 18_00, nil)]),
        ("Debt", false, [("Car Payment", 380_00, nil), ("Student Loan", 427_00, nil)])
    ]

    /// (day, merchant, cents, isIncome, splits by item name, account index)
    private static let pattern: [(Int, String, Int, Bool, [(String, Int)], Int)] = [
        (1, "Oak Street Apartments", 1_850_00, false, [("Rent", 1_850_00)], 0),
        (1, "Acme Corp Payroll", 3_150_00, true, [("Paycheck 1", 3_150_00)], 0),
        (2, "Grace Community Church", 315_00, false, [("Charity", 315_00)], 0),
        (2, "Trader Joe's", 94_37, false, [("Groceries", 94_37)], 1),
        (3, "Spotify", 11_99, false, [("Subscriptions", 11_99)], 1),
        (4, "Shell", 48_20, false, [("Gas", 48_20)], 1),
        (5, "Blue Bottle Coffee", 7_45, false, [("Fun Money", 7_45)], 1),
        (5, "Toyota Financial", 380_00, false, [("Car Payment", 380_00)], 0),
        (6, "Target", 86_40, false, [("Groceries", 52_10), ("Miscellaneous", 34_30)], 1),
        (7, "Verizon Wireless", 85_00, false, [("Phone", 85_00)], 0),
        (8, "Chipotle", 23_85, false, [("Restaurants", 23_85)], 1),
        (9, "Whole Foods Market", 112_64, false, [("Groceries", 112_64)], 1),
        (10, "Planet Fitness", 40_00, false, [("Gym", 40_00)], 1),
        (10, "City Water Utility", 58_12, false, [("Water", 58_12)], 0),
        (11, "Netflix", 15_49, false, [("Subscriptions", 15_49)], 1),
        (12, "Geico", 120_00, false, [("Auto Insurance", 120_00)], 0),
        (12, "Chevron", 52_75, false, [("Gas", 52_75)], 1),
        (14, "Thai Basil", 41_30, false, [("Restaurants", 41_30)], 1),
        (15, "Acme Corp Payroll", 3_150_00, true, [("Paycheck 2", 3_150_00)], 0),
        (15, "Pacific Gas & Electric", 151_88, false, [("Electricity", 106_40), ("Natural Gas", 45_48)], 0),
        (16, "Grace Community Church", 315_00, false, [("Charity", 315_00)], 0),
        (16, "Trader Joe's", 88_19, false, [("Groceries", 88_19)], 1),
        (17, "AMC Theatres", 32_50, false, [("Entertainment", 32_50)], 1),
        (18, "Nelnet Student Loan", 427_00, false, [("Student Loan", 427_00)], 0),
        (19, "Xfinity", 70_00, false, [("Internet", 70_00)], 0),
        (20, "CVS Pharmacy", 18_42, false, [("Medicine", 18_42)], 1),
        (21, "Shell", 45_10, false, [("Gas", 45_10)], 1),
        (22, "Whole Foods Market", 104_77, false, [("Groceries", 104_77)], 1),
        (23, "Lemonade Insurance", 18_00, false, [("Renters Insurance", 18_00)], 0),
        (24, "Uniqlo", 64_90, false, [("Clothing", 64_90)], 1),
        (25, "Jiffy Lube", 89_99, false, [("Car Maintenance", 89_99)], 1),
        (26, "Sweetgreen", 16_25, false, [("Restaurants", 16_25)], 1),
        (27, "Trader Joe's", 76_58, false, [("Groceries", 76_58)], 1),
        (28, "City Parking Garage", 24_00, false, [("Parking", 24_00)], 1),
        (29, "Amazon", 38_14, false, [("Gifts", 38_14)], 1)
    ]

    public static func seed(into context: ModelContext, today: Date = Date(), calendar: Calendar = .current) {
        let checking = BankAccount(externalID: "demo-checking", name: "Everyday Checking")
        checking.mask = "4821"; checking.type = "depository"; checking.subtype = "checking"
        checking.currentBalanceCents = 4_382_16; checking.availableBalanceCents = 4_382_16
        let card = BankAccount(externalID: "demo-card", name: "Rewards Card")
        card.mask = "9014"; card.type = "credit"; card.subtype = "credit card"
        card.currentBalanceCents = 612_48; card.availableBalanceCents = 7_387_52
        context.insert(checking)
        context.insert(card)
        let accounts = [checking, card]

        let current = MonthKey(date: today, calendar: calendar)
        let todayDay = calendar.component(.day, from: today)
        var series: [String: UUID] = [:]
        for offset in (0...2).reversed() {
            let key = current.adding(months: -offset)
            let month = BudgetMonth(key: key)
            context.insert(month)
            var items: [String: BudgetItem] = [:]
            for (groupIndex, groupPlan) in plan.enumerated() {
                let group = BudgetGroup(name: groupPlan.group, isIncome: groupPlan.isIncome, sortIndex: groupIndex)
                group.month = month
                context.insert(group)
                for (itemIndex, entry) in groupPlan.items.enumerated() {
                    let id = series[entry.0] ?? UUID()
                    series[entry.0] = id
                    let item = BudgetItem(name: entry.0, plannedCents: entry.1, sortIndex: itemIndex, seriesID: id)
                    if let fund = entry.fund {
                        item.isFund = true
                        item.fundStartingCents = fund.start
                        item.fundGoalCents = fund.goal
                        if entry.0 == "Gifts" {
                            item.fundTargetDate = calendar.date(from: DateComponents(year: current.year, month: 12, day: 15))
                        }
                    }
                    if entry.0 == "Rent" { item.dueDay = 1 }
                    if entry.0 == "Car Payment" { item.dueDay = 5 }
                    item.group = group
                    context.insert(item)
                    items[entry.0] = item
                }
            }

            let daysInMonth = calendar.range(of: .day, in: .month, for: key.firstDay(calendar: calendar))?.count ?? 28
            let visible = pattern.filter { offset > 0 || $0.0 <= todayDay }
            for (index, row) in visible.enumerated() {
                let day = min(row.0, daysInMonth)
                // Vary amounts a little from month to month so history looks real.
                let wobble = row.3 || row.4.count > 1 || row.2 >= 300_00 ? 0 : ((index * 37 + offset * 53) % 11 - 5) * row.2 / 100
                let cents = row.2 + wobble
                let date = calendar.date(from: DateComponents(year: key.year, month: key.month, day: day, hour: 12)) ?? today
                let transaction = LedgerTransaction(date: date, amountCents: cents, isIncome: row.3, merchant: row.1, source: .manual)
                transaction.account = accounts[row.5]
                context.insert(transaction)
                // The latest few in the current month wait in the tray, like fresh bank activity.
                if offset == 0 && index >= visible.count - 4 { continue }
                if row.4.count == 1, let item = items[row.4[0].0] {
                    Ledger.assign(transaction, to: item, in: context)
                } else {
                    let parts = row.4.compactMap { split in items[split.0].map { (item: $0, amountCents: split.1) } }
                    try? Ledger.split(transaction, into: parts, in: context)
                }
            }
        }
        try? context.save()
    }

    /// The sample's accounts are the only ones without a bank link whose IDs start with "demo-".
    public static func isSample(_ account: BankAccount) -> Bool {
        account.link == nil && account.externalID.hasPrefix("demo-")
    }

    /// Removes the sample household: its accounts, their transactions and the budget months it planned.
    /// Bank and imported transactions stay; any assigned to a sample month go back to the tray.
    public static func remove(from context: ModelContext) {
        let accounts = ((try? context.fetch(FetchDescriptor<BankAccount>())) ?? []).filter(isSample)
        let accountIDs = Set(accounts.map(\.persistentModelID))
        let transactions = (try? context.fetch(FetchDescriptor<LedgerTransaction>())) ?? []
        let sample = transactions.filter { $0.account.map { accountIDs.contains($0.persistentModelID) } ?? false }
        let sampleIDs = Set(sample.map(\.persistentModelID))

        // Sample data is only offered before any month is planned, so the months created while it was seeded are its own.
        var months: [BudgetMonth] = []
        if let first = sample.map(\.createdAt).min(), let last = sample.map(\.createdAt).max() {
            let seeding = first.addingTimeInterval(-1)...last.addingTimeInterval(1)
            months = ((try? context.fetch(FetchDescriptor<BudgetMonth>())) ?? []).filter { seeding.contains($0.createdAt) }
        }
        let itemIDs = Set(months.flatMap { ($0.groups ?? []).flatMap { $0.items ?? [] } }.map(\.persistentModelID))
        for transaction in transactions where !sampleIDs.contains(transaction.persistentModelID) {
            let assignedToSample = (transaction.allocations ?? []).contains { $0.item.map { itemIDs.contains($0.persistentModelID) } ?? false }
            if assignedToSample { Ledger.unassign(transaction, in: context) }
        }
        sample.forEach(context.delete)
        accounts.forEach(context.delete)
        months.forEach(context.delete)
        try? context.save()
    }
}
