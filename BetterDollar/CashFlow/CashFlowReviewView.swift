import BetterDollarCore
import SwiftData
import SwiftUI

/// Paychecks, bills and card payments the forecast uses: check what was found, change it, or add more.
struct CashFlowReviewView: View {
    enum Focus: String, Identifiable {
        case all, cards, addPaycheck
        var id: String { rawValue }
    }

    let focus: Focus
    let patterns: [RecurringPattern]
    let cardInfo: [CashFlowPlanner.Card]

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \RecurringFlow.createdAt) private var flows: [RecurringFlow]
    @Query private var accounts: [BankAccount]
    @AppStorage("cashFlowCushion") private var cushionCents = 0
    @State private var editing: FlowEditor.Target?

    private var cards: [BankAccount] { accounts.filter { $0.type == "credit" && !$0.isHidden }.sorted { $0.displayName < $1.displayName } }

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                Form {
                    flowSection(income: true)
                    flowSection(income: false)
                    if !cards.isEmpty {
                        Section {
                            ForEach(cards) { account in
                                let info = cardInfo.first { $0.id == account.uuid }
                                NavigationLink {
                                    CardPaymentDetail(account: account)
                                } label: {
                                    FlowRow(name: account.displayName, detail: cardDetail(account, info),
                                            cents: info?.payments.first.map { -$0.amountCents } ?? max(0, account.currentBalanceCents ?? 0),
                                            isOff: account.paymentMode == .elsewhere)
                                }
                            }
                        } header: {
                            Text("Credit cards")
                        } footer: {
                            Text(cardFooter)
                        }
                        .id(Focus.cards)
                    }
                    Section {
                        MoneyField(title: "Warn me below", cents: $cushionCents)
                    } footer: {
                        Text("Days when checking would end lower than this are flagged. Leave it empty to flag only days below zero.")
                    }
                }
                .scrollContentBackground(.hidden)
                .paperBackground()
                .onAppear {
                    if focus == .cards { proxy.scrollTo(Focus.cards, anchor: .top) }
                    if focus == .addPaycheck { editing = .new(isIncome: true) }
                }
            }
            .navigationTitle("Paychecks and bills")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        CashFlowPlanner.markReviewed(patterns, in: context)
                        dismiss()
                    }
                }
            }
            .sheet(item: $editing) { FlowEditor(target: $0) }
        }
    }

    @ViewBuilder private func flowSection(income: Bool) -> some View {
        let found = patterns.filter { $0.isIncome == income }
        let added = flows.filter { $0.isManual && $0.isIncome == income }
        Section {
            ForEach(found) { pattern in
                NavigationLink {
                    PatternDetailView(pattern: pattern)
                } label: {
                    FlowRow(name: decision(pattern)?.name.nonEmpty ?? pattern.name,
                            detail: rowDetail(pattern),
                            cents: (decision(pattern)?.amountCents).flatMap { $0 > 0 ? $0 : nil } ?? pattern.amountCents,
                            isOff: decision(pattern)?.isIgnored ?? false)
                }
            }
            ForEach(added) { flow in
                Button { editing = .existing(flow) } label: {
                    FlowRow(name: flow.name.nonEmpty ?? (income ? "Paycheck" : "Bill"),
                            detail: "Added by you, \(flow.cadence.title.lowercased())\(flow.nextDate.map { ", from \(CashFlowFormat.short($0))" } ?? "")",
                            cents: flow.amountCents, isOff: flow.isIgnored)
                }
                .tint(Ink.text)
            }
            .onDelete { offsets in
                for index in offsets { context.delete(added[index]) }
            }
            Button(income ? "Add a paycheck" : "Add a bill", systemImage: "plus") { editing = .new(isIncome: income) }
        } header: {
            Text(income ? "Paychecks" : "Bills")
        } footer: {
            if found.isEmpty {
                Text(income ? "Nothing regular found in checking deposits yet." : "No repeating charges found in checking yet.")
            } else {
                Text(income ? "Found in your checking deposits over the last six months."
                            : "Charges that repeat in checking. Turn off anything that has stopped, and link bills to the budget item they pay so they aren't counted twice.")
            }
        }
    }

    private func decision(_ pattern: RecurringPattern) -> RecurringFlow? { flows.first { $0.key == pattern.id } }

    private func rowDetail(_ pattern: RecurringPattern) -> String {
        if decision(pattern)?.isIgnored == true { return "Turned off" }
        return "\(pattern.cadence.title), next \(CashFlowFormat.short(pattern.nextDate()))\(pattern.isVariable ? ", amount varies" : "")"
    }

    private var cardFooter: String {
        "Card purchases leave checking when you pay the card. Pick the budget groups you pay with a card so that spending leaves checking with the card payment, not day by day."
    }

    private func cardDetail(_ account: BankAccount, _ info: CashFlowPlanner.Card?) -> String {
        let mode = account.paymentMode
        if mode == .elsewhere { return "Not paid from checking" }
        guard account.paymentDueDay > 0 || info?.habit != nil else { return "No due day set" }
        let next = info?.payments.first.map { ", next \(CashFlowFormat.short($0.date))" } ?? ""
        return mode.title + next + (info?.usesUsualDay == true ? ", usual day" : "")
    }
}

private struct FlowRow: View {
    let name: String
    let detail: String
    let cents: Int
    let isOff: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .foregroundStyle(isOff ? Ink.secondary : Ink.text)
                    .strikethrough(isOff, color: Ink.secondary)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(Ink.secondary)
            }
            Spacer(minLength: 8)
            Text(Money.format(cents))
                .font(Typeface.amountSmall)
                .foregroundStyle(isOff ? Ink.secondary : Ink.text)
        }
    }
}

/// One detected paycheck or bill: whether it counts, its amount, and which budget item it pays.
private struct PatternDetailView: View {
    let pattern: RecurringPattern
    @Environment(\.modelContext) private var context
    @Query private var flows: [RecurringFlow]
    @Query(sort: \BudgetMonth.key) private var months: [BudgetMonth]

    private var saved: RecurringFlow? { flows.first { $0.key == pattern.id } }
    private var choice: RecurringFlow { CashFlowPlanner.decision(for: pattern, in: context) }
    private var items: [BudgetItem] {
        let current = MonthKey.current()
        let plan = months.last { $0.monthKey <= current } ?? months.first
        return (plan?.expenseGroups ?? []).flatMap(\.sortedItems)
    }

    var body: some View {
        Form {
            Section {
                Toggle("Count in the forecast", isOn: Binding(get: { !(saved?.isIgnored ?? false) }, set: { choice.isIgnored = !$0 }))
            }
            Section {
                MoneyField(title: "Amount", cents: Binding(get: { saved?.amountCents ?? 0 }, set: { choice.amountCents = $0 }),
                           prompt: Money.editableText(pattern.amountCents))
            } footer: {
                Text("Usually \(Money.format(pattern.amountCents))\(pattern.isVariable ? ", but it varies" : ""). Leave the amount empty to keep using that.")
            }
            if !pattern.isIncome {
                Section {
                    Picker("Pays for", selection: Binding(get: { CashFlowPlanner.covers(saved, pattern) },
                                                          set: { choice.coversSeriesID = $0 ?? RecurringFlow.notInBudget })) {
                        Text("Not in my budget").tag(UUID?.none)
                        ForEach(items) { item in Text(item.name).tag(UUID?.some(item.seriesID)) }
                    }
                } footer: {
                    Text("Linking it to a budget item keeps that item from being counted a second time.")
                }
            }
            Section("Seen in checking") {
                LabeledContent(pattern.cadence.title, value: "\(pattern.dates.count) times")
                Text(pattern.dates.suffix(6).map(CashFlowFormat.short).formatted(.list(type: .and)))
                    .font(.subheadline)
                    .foregroundStyle(Ink.secondary)
                LabeledContent("Next expected", value: CashFlowFormat.weekday(pattern.nextDate()))
            }
        }
        .scrollContentBackground(.hidden)
        .paperBackground()
        .navigationTitle(saved?.name.nonEmpty ?? pattern.name)
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// One card: how much is paid and when, and what that puts in the forecast.
private struct CardPaymentDetail: View {
    @Bindable var account: BankAccount
    @Environment(\.modelContext) private var context
    @Query private var accounts: [BankAccount]
    @AppStorage("cashFlowCushion") private var cushionCents = 0
    @AppStorage("cashFlowManualBalance") private var manualBalanceCents = 0

    var body: some View {
        // Worked out here so the forecast below follows every change.
        let info = CashFlowPlanner.snapshot(in: context, cushionCents: cushionCents, manualBalanceCents: manualBalanceCents)
            .cards.first { $0.id == account.uuid }
        let mode = account.paymentMode
        Form {
            Section {
                Picker("Pay", selection: $account.paymentMode) {
                    ForEach(CardPaymentMode.allCases) { Text($0.title).tag($0) }
                }
                .accessibilityIdentifier("card-pay-mode")
                if mode == .minimum {
                    MoneyField(title: "Minimum due", cents: $account.paymentFixedCents,
                               prompt: Money.editableText(info?.estimatedMinimumCents ?? 0))
                } else if mode == .fixed {
                    MoneyField(title: "Each month", cents: $account.paymentFixedCents)
                }
            } footer: {
                Text(modeFooter(mode, info))
            }
            if mode != .elsewhere {
                Section {
                    Picker("Due", selection: $account.paymentDueDay) {
                        Text(info?.habit.map { "Usual day, the \(ordinal($0.day))" } ?? "Not set").tag(0)
                        ForEach(1...31, id: \.self) { Text("The \(ordinal($0))").tag($0) }
                    }
                    if mode == .statement {
                        Picker("Statement closes", selection: $account.statementCloseDay) {
                            Text("About 25 days before").tag(0)
                            ForEach(1...31, id: \.self) { Text("The \(ordinal($0))").tag($0) }
                        }
                    }
                    Toggle("Pay in parts on paydays", isOn: $account.paymentSplitsWithPay)
                } footer: {
                    Text(dayFooter(info))
                }
            }
            Section {
                if groupNames.isEmpty {
                    Text("Plan a budget to choose its groups.").foregroundStyle(Ink.secondary)
                }
                ForEach(groupNames, id: \.self) { name in
                    Toggle(name, isOn: Binding(get: { account.cardGroupNames.contains(name) }, set: { setGroup(name, paidByCard: $0) }))
                }
            } header: {
                Text("Paid with this card")
            } footer: {
                Text(groupsFooter(mode, info))
            }
            if mode != .elsewhere {
                Section {
                    Picker("Pays for", selection: Binding(get: { info?.coversSeriesID },
                                                          set: { account.paymentCoversSeriesID = $0 ?? RecurringFlow.notInBudget })) {
                        Text("Not in my budget").tag(UUID?.none)
                        ForEach(CashFlowPlanner.currentPlanItems(in: context)) { item in Text(item.name).tag(UUID?.some(item.seriesID)) }
                    }
                } footer: {
                    Text("Linking it to the budget item for this card keeps that item from being counted a second time.")
                }
                Section("In the forecast") {
                    if let payments = info?.payments, !payments.isEmpty {
                        ForEach(payments) { payment in
                            VStack(alignment: .leading, spacing: 2) {
                                LedgerLine(label: CashFlowFormat.weekday(payment.date), cents: payment.amountCents)
                                if let detail = payment.detail {
                                    Text(detail).font(.caption).foregroundStyle(Ink.secondary)
                                }
                            }
                        }
                    } else {
                        Text(account.paymentDueDay == 0 && info?.habit == nil ? "Set a due day to add this card." : "Nothing to pay in the next 60 days.")
                            .foregroundStyle(Ink.secondary)
                    }
                }
            }
            if let habit = info?.habit {
                Section {
                    LabeledContent("Usually around", value: "the \(ordinal(habit.day))")
                    LabeledContent("A typical month", value: Money.format(habit.monthlyCents))
                } header: {
                    Text("Paid from checking before")
                } footer: {
                    Text("From payments that left checking and showed up on this card.")
                }
            }
        }
        .scrollContentBackground(.hidden)
        .paperBackground()
        .navigationTitle(account.displayName)
        .navigationBarTitleDisplayMode(.inline)
    }

    private func modeFooter(_ mode: CardPaymentMode, _ info: CashFlowPlanner.Card?) -> String {
        let owed = Money.format(info?.balanceCents ?? max(0, account.currentBalanceCents ?? 0))
        switch mode {
        case .statement:
            let statement = info?.statementCents.map { " About \(Money.format($0)) is still owed on the last one." } ?? ""
            return "Pays the last statement on the due date, then each new statement in full.\(statement)"
        case .balance:
            return "Pays everything owed on each due date: \(owed) now, plus spending from the groups paid with this card."
        case .minimum:
            return "Pays the minimum each month while anything is owed. Enter the minimum from your statement, or leave it empty to use an estimate."
        case .usual:
            guard let habit = info?.habit else {
                return "There aren't enough payments from checking to this card yet, so the statement balance is used for now."
            }
            return "Pays \(Money.format(habit.monthlyCents)) a month, what checking usually sends this card, while anything is owed."
        case .fixed:
            return "Pays this amount each month while anything is owed. Anything more stays on the card."
        case .elsewhere:
            return "Leaves this card out of the forecast, for a card you pay from another account."
        }
    }

    private func groupsFooter(_ mode: CardPaymentMode, _ info: CashFlowPlanner.Card?) -> String {
        var text = mode == .elsewhere
            ? "Spending in these budget groups stays out of checking, since this card is paid from another account."
            : "Spending in these budget groups builds up on the card and leaves checking with the card payment instead of day by day."
        if let names = info?.chargedItemNames, !names.isEmpty {
            text += " \(names.formatted(.list(type: .and))) already count here, since that's where you've charged them."
        }
        return text
    }

    private var groupNames: [String] {
        (CashFlowPlanner.currentPlan(in: context)?.expenseGroups ?? []).map(\.name)
    }

    /// A group is paid with one card at most.
    private func setGroup(_ name: String, paidByCard: Bool) {
        guard paidByCard else {
            account.cardGroupNames.remove(name)
            return
        }
        for other in accounts where other.uuid != account.uuid && other.cardGroupNames.contains(name) {
            other.cardGroupNames.remove(name)
        }
        account.cardGroupNames.insert(name)
    }

    private func dayFooter(_ info: CashFlowPlanner.Card?) -> String {
        let parts = account.paymentSplitsWithPay ? " Each payment is split evenly across the paychecks before it's due." : ""
        guard account.paymentDueDay == 0 else { return "The day the payment leaves checking.\(parts)" }
        guard let habit = info?.habit else { return "Pick the day you pay this card to add it to the forecast.\(parts)" }
        return "Checking usually pays this card around the \(ordinal(habit.day)). Pick a day to change it.\(parts)"
    }
}

/// Adds or edits a paycheck or bill the person enters by hand.
private struct FlowEditor: View {
    enum Target: Identifiable {
        case new(isIncome: Bool)
        case existing(RecurringFlow)

        var id: String {
            switch self {
            case .new(let isIncome): isIncome ? "new-pay" : "new-bill"
            case .existing(let flow): flow.uuid.uuidString
            }
        }
    }

    let target: Target
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \BudgetMonth.key) private var months: [BudgetMonth]
    @State private var name = ""
    @State private var amountCents = 0
    @State private var cadence: Cadence = .monthly
    @State private var nextDate = Date()
    @State private var coversSeriesID: UUID?
    @State private var isIncome = false

    private var items: [BudgetItem] {
        let plan = months.last { $0.monthKey <= MonthKey.current() } ?? months.first
        return (plan?.expenseGroups ?? []).flatMap(\.sortedItems)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(isIncome ? "Employer" : "Name", text: $name)
                    MoneyField(title: "Amount", cents: $amountCents)
                    Picker("How often", selection: $cadence) {
                        ForEach(Cadence.allCases) { Text($0.title).tag($0) }
                    }
                    DatePicker(isIncome ? "Next payday" : "Next due", selection: $nextDate, displayedComponents: .date)
                }
                if !isIncome {
                    Section {
                        Picker("Pays for", selection: $coversSeriesID) {
                            Text("Not in my budget").tag(UUID?.none)
                            ForEach(items) { item in Text(item.name).tag(UUID?.some(item.seriesID)) }
                        }
                    } footer: {
                        Text("Linking it to a budget item keeps that item from being counted a second time.")
                    }
                }
                if case .existing(let flow) = target {
                    Section {
                        Button("Delete", role: .destructive) {
                            context.delete(flow)
                            dismiss()
                        }
                    }
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save).disabled(amountCents <= 0)
                }
            }
            .onAppear(perform: load)
        }
        .presentationDetents([.medium, .large])
    }

    private var title: String {
        switch target {
        case .new(let isIncome): isIncome ? "Add a paycheck" : "Add a bill"
        case .existing(let flow): flow.isIncome ? "Paycheck" : "Bill"
        }
    }

    private func load() {
        switch target {
        case .new(let income):
            isIncome = income
            cadence = income ? .biweekly : .monthly
        case .existing(let flow):
            isIncome = flow.isIncome
            name = flow.name
            amountCents = flow.amountCents
            cadence = flow.cadence
            nextDate = flow.nextDate ?? Date()
            coversSeriesID = flow.coversSeriesID
        }
    }

    private func save() {
        let flow: RecurringFlow
        switch target {
        case .new:
            flow = RecurringFlow(name: "", isIncome: isIncome)
            context.insert(flow)
        case .existing(let existing):
            flow = existing
        }
        flow.name = name.trimmingCharacters(in: .whitespaces)
        flow.amountCents = amountCents
        flow.cadence = cadence
        flow.nextDate = Calendar.current.startOfDay(for: nextDate)
        flow.coversSeriesID = isIncome ? nil : coversSeriesID
        try? context.save()
        dismiss()
    }
}

extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
