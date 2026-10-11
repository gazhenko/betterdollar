import BetterDollarCore
import SwiftData
import SwiftUI

struct TransactionsScreen: View {
    @Environment(AppModel.self) private var app
    @Environment(\.modelContext) private var context
    @Query(sort: \LedgerTransaction.date, order: .reverse) private var transactions: [LedgerTransaction]
    @Query private var banks: [BankLink]
    @State private var status: TransactionStatus = .new
    @State private var search = ""
    @State private var assigning: LedgerTransaction?
    @State private var editing: LedgerTransaction?
    @State private var isAdding = false
    @State private var isImporting = false

    private var filtered: [LedgerTransaction] {
        transactions.filter { $0.status == status && (search.isEmpty || $0.merchant.localizedCaseInsensitiveContains(search)
            || ($0.allocations ?? []).contains { $0.item?.name.localizedCaseInsensitiveContains(search) == true }) }
    }

    private var sections: [(key: Date, items: [LedgerTransaction])] {
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: filtered) { calendar.startOfDay(for: $0.date) }
        return grouped.keys.sorted(by: >).map { ($0, grouped[$0] ?? []) }
    }

    var body: some View {
        NavigationStack {
            List {
                Picker("Show", selection: $status) {
                    ForEach(TransactionStatus.allCases, id: \.self) { status in
                        Text("\(label(status)) \(count(status))").tag(status)
                    }
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))

                if filtered.isEmpty {
                    emptyState
                        .listRowBackground(Color.clear)
                }
                ForEach(sections, id: \.key) { section in
                    Section(section.key.formatted(.dateTime.weekday(.wide).month(.wide).day())) {
                        ForEach(section.items) { transaction in
                            Button {
                                if transaction.status == .new { assigning = transaction } else { editing = transaction }
                            } label: {
                                TransactionRow(transaction: transaction, showsDate: false)
                            }
                            .buttonStyle(.plain)
                            .listRowBackground(Ink.sheet)
                            .swipeActions(edge: .trailing) { trailingActions(transaction) }
                            .swipeActions(edge: .leading) { leadingActions(transaction) }
                            .contextMenu {
                                Button("Edit", systemImage: "pencil") { editing = transaction }
                                if transaction.status != .deleted {
                                    Button("Assign or split", systemImage: "arrow.triangle.branch") { assigning = transaction }
                                }
                            }
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .paperBackground()
            .navigationTitle("Transactions")
            .searchable(text: $search, prompt: "Merchant or budget item")
            .refreshable { await app.bank.syncAll(context: context) }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button("Add transaction", systemImage: "plus") { isAdding = true }
                        Button("Import CSV", systemImage: "doc.text") { isImporting = true }
                        if !banks.isEmpty {
                            Button("Sync banks", systemImage: "arrow.triangle.2.circlepath") {
                                Task { await app.bank.syncAll(context: context) }
                            }
                        }
                    } label: {
                        Image(systemName: "plus")
                    } primaryAction: {
                        isAdding = true
                    }
                    .accessibilityLabel("Add transaction")
                    .accessibilityIdentifier("add-transaction")
                }
            }
            .sheet(item: $assigning) { AssignSheet(transaction: $0) }
            .sheet(item: $editing) { TransactionEditor(transaction: $0) }
            .sheet(isPresented: $isAdding) { TransactionEditor(transaction: nil) }
            .sheet(isPresented: $isImporting) { CSVImportView() }
        }
    }

    private func label(_ status: TransactionStatus) -> String {
        switch status {
        case .new: "New"
        case .tracked: "Tracked"
        case .deleted: "Deleted"
        }
    }

    private func count(_ status: TransactionStatus) -> String {
        let count = transactions.filter { $0.status == status }.count
        return count == 0 ? "" : "(\(count))"
    }

    @ViewBuilder private var emptyState: some View {
        switch status {
        case .new:
            ContentUnavailableView {
                Label("Nothing to assign", systemImage: "checkmark.seal")
            } description: {
                Text(banks.isEmpty ? "Add a transaction, import a CSV from your bank, or connect a bank in Settings."
                     : "Every transaction has a home. Pull down to check your banks for new ones.")
            }
        case .tracked:
            ContentUnavailableView("No tracked transactions", systemImage: "tray",
                                   description: Text("Transactions you assign to budget items appear here."))
        case .deleted:
            ContentUnavailableView("No deleted transactions", systemImage: "trash",
                                   description: Text("Deleted transactions stay here so you can restore them."))
        }
    }

    @ViewBuilder private func trailingActions(_ transaction: LedgerTransaction) -> some View {
        if transaction.status == .deleted {
            if transaction.source == .manual {
                Button("Remove", systemImage: "trash.slash", role: .destructive) {
                    withAnimation { Ledger.remove(transaction, in: context) }
                }
            }
        } else {
            Button("Delete", systemImage: "trash", role: .destructive) {
                withAnimation { Ledger.delete(transaction, in: context) }
            }
        }
    }

    @ViewBuilder private func leadingActions(_ transaction: LedgerTransaction) -> some View {
        switch transaction.status {
        case .new:
            Button("Assign", systemImage: "arrow.down.to.line") { assigning = transaction }.tint(Ink.primary)
        case .tracked:
            Button("Unassign", systemImage: "tray.and.arrow.up") {
                withAnimation { Ledger.unassign(transaction, in: context) }
            }
            .tint(Ink.secondary)
        case .deleted:
            Button("Restore", systemImage: "arrow.uturn.backward") {
                withAnimation { Ledger.restore(transaction) }
            }
            .tint(Ink.primary)
        }
    }
}
