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
    let usualCardPaymentDay: Int?

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
                            ForEach(cards) { CardPaymentEditor(account: $0) }
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
        var text = "Card purchases leave checking when you pay the card. Full balance pays what you owe now, once; after that, card spending counts as everyday spending."
        if let usualCardPaymentDay {
            text += " Card payments usually leave your checking around the \(ordinal(usualCardPaymentDay))."
        }
        return text
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

/// A card's payment day and amount.
private struct CardPaymentEditor: View {
    @Bindable var account: BankAccount
    @State private var usesSetAmount = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(account.displayName).font(.body.weight(.semibold))
                Spacer()
                Text("owes \(Money.format(max(0, account.currentBalanceCents ?? 0)))")
                    .font(Typeface.amountSmall)
                    .foregroundStyle(Ink.secondary)
            }
            Picker("Payment due", selection: $account.paymentDueDay) {
                Text("Not set").tag(0)
                ForEach(1...31, id: \.self) { Text("The \(ordinal($0))").tag($0) }
            }
            Picker("Pay", selection: $usesSetAmount) {
                Text("Full balance").tag(false)
                Text("A set amount").tag(true)
            }
            .pickerStyle(.segmented)
            if usesSetAmount {
                MoneyField(title: "Each month", cents: $account.paymentFixedCents)
            }
        }
        .padding(.vertical, 4)
        .onAppear { usesSetAmount = account.paymentFixedCents > 0 }
        .onChange(of: usesSetAmount) { _, setAmount in
            if !setAmount { account.paymentFixedCents = 0 }
        }
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
