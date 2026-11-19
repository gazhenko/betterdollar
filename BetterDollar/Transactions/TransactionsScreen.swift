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
                // The same heading as the other tabs, scrolling with the list, instead of a system bar.
                VStack(alignment: .leading, spacing: 14) {
                    ScreenHeader(title: "Transactions") { addMenu }
                    SearchField(text: $search, prompt: "Merchant or budget item")
                    LedgerTabs(selection: $status, options: TransactionStatus.allCases.map { status in
                        (status, "\(label(status)) \(count(status))".trimmingCharacters(in: .whitespaces))
                    })
                }
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 0, leading: Layout.margin, bottom: 4, trailing: Layout.margin))
                .listRowSeparator(.hidden)

                if app.bank.isSyncingAny {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Checking your banks…")
                            .font(.caption)
                            .foregroundStyle(Ink.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 6, trailing: 0))
                    .accessibilityIdentifier("bank-syncing")
                }
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
                            // Register lines printed on the page, not rows on a card.
                            .listRowBackground(Color.clear)
                            .listRowSeparatorTint(Ink.rule)
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
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .contentMargins(.top, 0, for: .scrollContent)
            .scrollDismissesKeyboard(.immediately)
            .statusBarShield()
            .paperBackground()
            .navigationTitle("Transactions")
            .toolbar(.hidden, for: .navigationBar)
            .refreshable { await app.bank.syncAll(context: context) }
            .sheet(item: $assigning) { AssignSheet(transaction: $0) }
            .sheet(item: $editing) { TransactionEditor(transaction: $0) }
            .sheet(isPresented: $isAdding) { TransactionEditor(transaction: nil) }
            .sheet(isPresented: $isImporting) { CSVImportView() }
        }
    }

    /// Tap to add a transaction; hold for importing and syncing.
    private var addMenu: some View {
        Menu {
            Button("Add transaction", systemImage: "plus") { isAdding = true }
            Button("Import CSV", systemImage: "doc.text") { isImporting = true }
            if !banks.isEmpty {
                Button("Sync banks", systemImage: "arrow.triangle.2.circlepath") {
                    Task { await app.bank.syncAll(context: context) }
                }
            }
        } label: {
            HeaderButtonLabel(systemImage: "plus")
        } primaryAction: {
            isAdding = true
        }
        .accessibilityLabel("Add transaction")
        .accessibilityIdentifier("add-transaction")
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
                     : "Every transaction has a home. Your banks are checked whenever you open the app; pull down to check again now.")
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

/// A search field on the page itself, for lists that draw their own heading.
struct SearchField: View {
    @Binding var text: String
    let prompt: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(Ink.secondary)
                .accessibilityHidden(true)
            TextField(prompt, text: $text)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
            if !text.isEmpty {
                Button { text = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain)
                    .foregroundStyle(Ink.secondary)
                    .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 40)
        .background(Ink.track, in: .capsule)
    }
}
