import BetterDollarCore
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

struct BudgetGroupSection: View {
    @Environment(\.modelContext) private var context
    let group: BudgetGroup
    let column: BudgetColumn
    let funds: FundLedger
    var focusedItem: FocusState<PersistentIdentifier?>.Binding
    let onOpen: (BudgetItem) -> Void

    @State private var isRenaming = false
    @State private var isAddingItem = false
    @State private var draftName = ""
    @State private var confirmingDelete = false

    var body: some View {
        let totals = BudgetMath.groupTotals(for: group, funds: funds)
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text(group.name)
                    .font(Typeface.groupTitle)
                    .foregroundStyle(Ink.text)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                AmountText(cents: groupFigure(totals), font: Typeface.amountSmall, color: Ink.secondary)
                Menu {
                    Button("Add item", systemImage: "plus") { draftName = ""; isAddingItem = true }
                    Button("Rename group", systemImage: "pencil") { draftName = group.name; isRenaming = true }
                    if !group.isIncome {
                        Button("Delete group", systemImage: "trash", role: .destructive) { confirmingDelete = true }
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .frame(width: 36, height: 30)
                        .contentShape(.rect)
                }
                .foregroundStyle(Ink.secondary)
                .accessibilityLabel("\(group.name) options")
            }
            .padding(.top, 26)
            .padding(.bottom, 6)
            DoubleRule(color: Ink.rule)
                .padding(.bottom, 2)

            ForEach(group.sortedItems) { item in
                BudgetItemRow(item: item, column: column, totals: BudgetMath.totals(for: item, funds: funds),
                              focusedItem: focusedItem, onOpen: { onOpen(item) })
            }
            Button {
                draftName = ""
                isAddingItem = true
            } label: {
                Label(group.isIncome ? "Add income" : "Add item", systemImage: "plus")
                    .font(.subheadline.weight(.medium))
                    .padding(.vertical, 10)
            }
            .foregroundStyle(Ink.primary)
            .accessibilityIdentifier("add-item-\(group.name)")
        }
        .alert("New \(group.isIncome ? "income" : "item") in \(group.name)", isPresented: $isAddingItem) {
            TextField("Name", text: $draftName)
            Button("Add") {
                let name = draftName.trimmingCharacters(in: .whitespaces)
                if !name.isEmpty { BudgetPlanner.addItem(named: name, to: group, in: context) }
            }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Rename group", isPresented: $isRenaming) {
            TextField("Name", text: $draftName)
            Button("Save") {
                let name = draftName.trimmingCharacters(in: .whitespaces)
                if !name.isEmpty { group.name = name }
            }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog("Delete \(group.name)?", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Delete group", role: .destructive) { BudgetPlanner.delete(group, in: context) }
        } message: {
            Text("Transactions assigned to its items go back to your tray.")
        }
    }

    private func groupFigure(_ totals: ItemTotals) -> Int {
        switch column {
        case .planned: totals.plannedCents
        case .spent: totals.activityCents
        case .remaining: (group.items ?? []).reduce(0) { $0 + BudgetMath.totals(for: $1, funds: funds).remainingCents }
        }
    }
}

struct BudgetItemRow: View {
    @Environment(\.modelContext) private var context
    let item: BudgetItem
    let column: BudgetColumn
    let totals: ItemTotals
    var focusedItem: FocusState<PersistentIdentifier?>.Binding
    let onOpen: () -> Void

    @State private var isTargeted = false
    @State private var plannedText = ""
    @State private var droppedCount = 0

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Button(action: onOpen) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.name)
                        .font(.body)
                        .foregroundStyle(Ink.text)
                        .lineLimit(1)
                    if let caption {
                        Text(caption)
                            .font(.caption)
                            .foregroundStyle(totals.isOverspent && !item.isIncomeItem ? Ink.seal : Ink.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)

            if column == .planned {
                TextField("0.00", text: $plannedText)
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
                    .font(Typeface.amount)
                    .foregroundStyle(Ink.text)
                    .frame(width: 118)
                    .padding(.vertical, 6)
                    .padding(.horizontal, 8)
                    .background(Ink.track.opacity(0.55), in: .rect(cornerRadius: 8))
                    .focused(focusedItem, equals: item.persistentModelID)
                    .accessibilityLabel("Planned for \(item.name)")
                    .accessibilityIdentifier("planned-\(item.name)")
                    .onAppear { plannedText = Money.editableText(item.plannedCents) }
                    .onChange(of: item.plannedCents) { _, cents in
                        if focusedItem.wrappedValue != item.persistentModelID { plannedText = Money.editableText(cents) }
                    }
                    .onChange(of: focusedItem.wrappedValue) { _, focused in
                        if focused != item.persistentModelID { commitPlanned() }
                    }
                    .onSubmit(commitPlanned)
                    .onDisappear(perform: commitPlanned)
            } else {
                AmountText(cents: figure, flagsNegative: column == .remaining && !item.isIncomeItem)
            }
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 10)
        .background {
            RoundedRectangle(cornerRadius: 12)
                .fill(isTargeted ? Ink.primary.opacity(0.12) : .clear)
                .overlay {
                    if isTargeted { RoundedRectangle(cornerRadius: 12).strokeBorder(Ink.primary, style: StrokeStyle(lineWidth: 1.5, dash: [5, 4])) }
                }
        }
        .padding(.horizontal, -10)
        .overlay(alignment: .bottom) {
            if column != .planned {
                SpendRule(progress: totals.progress, overspent: totals.isOverspent && !item.isIncomeItem,
                          tint: item.isIncomeItem ? Ink.income : Ink.primary)
                    .padding(.bottom, 2)
            }
        }
        .dropDestination(for: String.self) { identifiers, _ in
            assign(identifiers)
        } isTargeted: { targeted in
            withAnimation(.snappy(duration: 0.15)) { isTargeted = targeted }
        }
        .sensoryFeedback(.success, trigger: droppedCount)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("item-\(item.name)")
        .contextMenu {
            Button("Edit", systemImage: "pencil", action: onOpen)
            if !item.isIncomeItem {
                Button(item.isFund ? "Make a regular item" : "Make a fund (rolls over)",
                       systemImage: item.isFund ? "arrow.uturn.backward" : "arrow.trianglehead.2.clockwise") {
                    BudgetPlanner.setFund(item, !item.isFund, in: context)
                }
            }
            Button("Delete", systemImage: "trash", role: .destructive) { BudgetPlanner.delete(item, in: context) }
        }
    }

    private var figure: Int {
        switch column {
        case .planned: item.plannedCents
        case .spent: totals.activityCents
        case .remaining: totals.remainingCents
        }
    }

    private var caption: String? {
        if item.isFund {
            let balance = Money.format(totals.remainingCents, showsCents: false)
            if item.fundGoalCents > 0 { return "Fund balance \(balance) of \(Money.format(item.fundGoalCents, showsCents: false))" }
            return "Fund balance \(balance)"
        }
        if column == .planned && totals.activityCents > 0 {
            return "\(Money.format(totals.activityCents)) \(item.isIncomeItem ? "received" : "spent")"
        }
        if item.isIncomeItem && column == .remaining && totals.plannedCents > 0 {
            return totals.remainingCents > 0 ? "left to receive" : "received"
        }
        if !item.isIncomeItem && totals.isOverspent { return "Overspent" }
        if item.dueDay > 0 { return "Due on the \(ordinal(item.dueDay))" }
        return nil
    }

    private func commitPlanned() {
        let cents = Money.parse(plannedText) ?? 0
        if cents != item.plannedCents { withAnimation(.snappy) { item.plannedCents = max(0, cents) } }
        plannedText = Money.editableText(item.plannedCents)
    }

    private func assign(_ identifiers: [String]) -> Bool {
        var assigned = false
        for identifier in identifiers {
            guard let uuid = UUID(uuidString: identifier) else { continue }
            var descriptor = FetchDescriptor<LedgerTransaction>(predicate: #Predicate { $0.uuid == uuid })
            descriptor.fetchLimit = 1
            guard let transaction = try? context.fetch(descriptor).first else { continue }
            withAnimation(.snappy) { Ledger.assign(transaction, to: item, in: context) }
            assigned = true
        }
        if assigned { droppedCount += 1 }
        return assigned
    }
}

func ordinal(_ day: Int) -> String {
    let suffix: String
    switch (day % 10, day % 100) {
    case (1, let t) where t != 11: suffix = "st"
    case (2, let t) where t != 12: suffix = "nd"
    case (3, let t) where t != 13: suffix = "rd"
    default: suffix = "th"
    }
    return "\(day)\(suffix)"
}
