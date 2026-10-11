import BetterDollarCore
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

/// For people who'd rather not use Plaid: import a CSV export from any bank. Rows land in the tray.
struct CSVImportView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \BankAccount.name) private var accounts: [BankAccount]
    @State private var text: String?
    @State private var fileName = ""
    @State private var expensesArePositive = false
    @State private var account: BankAccount?
    @State private var isPicking = false
    @State private var message: (ok: Bool, text: String)?

    private var parsed: Result<CSVImport, Error>? {
        text.map { text in Result { try CSVImport(text: text, expensesArePositive: expensesArePositive) } }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Button(text == nil ? "Choose a CSV file" : fileName, systemImage: "doc.text") { isPicking = true }
                } footer: {
                    Text("Download a CSV from your bank's website. BetterDollar looks for date, description and amount columns (or debit and credit).")
                }
                if let parsed {
                    switch parsed {
                    case .success(let csv):
                        Section {
                            Toggle("Purchases are positive numbers", isOn: $expensesArePositive)
                            if !accounts.isEmpty {
                                Picker("Account", selection: $account) {
                                    Text("None").tag(BankAccount?.none)
                                    ForEach(accounts) { Text($0.displayName).tag(BankAccount?.some($0)) }
                                }
                            }
                        } footer: {
                            Text("Most checking exports show purchases as negative numbers. Many credit card exports show them as positive.")
                        }
                        Section("Preview") {
                            ForEach(Array(csv.rows.prefix(5).enumerated()), id: \.offset) { _, row in
                                HStack {
                                    VStack(alignment: .leading) {
                                        Text(row.merchant).lineLimit(1)
                                        Text(row.date.formatted(date: .abbreviated, time: .omitted)).font(.caption).foregroundStyle(Ink.secondary)
                                    }
                                    Spacer()
                                    Text((row.signedCents > 0 ? "+" : "−") + Money.format(abs(row.signedCents)))
                                        .font(Typeface.amount)
                                        .foregroundStyle(row.signedCents > 0 ? Ink.income : Ink.text)
                                }
                            }
                            if csv.rows.count > 5 { Text("and \(csv.rows.count - 5) more").foregroundStyle(Ink.secondary) }
                            if csv.skippedLines > 0 { Text("\(csv.skippedLines) lines couldn't be read and will be skipped.").foregroundStyle(Ink.secondary) }
                        }
                        Section {
                            Button("Import \(csv.rows.count) transactions") {
                                let added = csv.insert(into: context, account: account)
                                message = (true, added == 0 ? "These transactions were already imported." : "Added \(added) transactions to your tray.")
                                text = nil
                            }
                        }
                    case .failure(let error):
                        Section { Text(error.localizedDescription).foregroundStyle(Ink.seal) }
                    }
                }
                if let message {
                    Label(message.text, systemImage: message.ok ? "checkmark.seal" : "exclamationmark.triangle")
                        .foregroundStyle(message.ok ? Ink.primary : Ink.seal)
                }
            }
            .scrollContentBackground(.hidden)
            .paperBackground()
            .navigationTitle("Import CSV")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .fileImporter(isPresented: $isPicking, allowedContentTypes: [.commaSeparatedText, .plainText, .text]) { result in
                do {
                    let url = try result.get()
                    let scoped = url.startAccessingSecurityScopedResource()
                    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                    let data = try Data(contentsOf: url)
                    text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1)
                    fileName = url.lastPathComponent
                    message = nil
                } catch {
                    message = (false, error.localizedDescription)
                }
            }
        }
    }
}
