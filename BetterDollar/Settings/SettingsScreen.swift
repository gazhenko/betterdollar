import BetterDollarCore
import SwiftData
import SwiftUI

struct SettingsScreen: View {
    @Environment(AppModel.self) private var app
    @Environment(\.modelContext) private var context
    @Environment(\.webAuthenticationSession) private var webAuth
    @Query(sort: \BankLink.createdAt) private var banks: [BankLink]
    @Query private var accounts: [BankAccount]
    @AppStorage("appLock") private var appLock = false
    @State private var isImporting = false
    @State private var confirmingErase = false
    @State private var confirmingSampleRemoval = false

    var body: some View {
        @Bindable var bank = app.bank
        NavigationStack {
            Form {
                Section {
                    if app.bank.isConfigured {
                        ForEach(banks) { link in
                            NavigationLink { BankDetailView(link: link) } label: { BankRow(link: link) }
                        }
                        Button {
                            Task { await app.bank.connect(using: webAuth, context: context) }
                        } label: {
                            Label(app.bank.isWorking ? "Connecting…" : "Connect a bank", systemImage: "building.columns")
                        }
                        .disabled(app.bank.isWorking)
                        .accessibilityIdentifier("connect-bank")
                        if app.bank.pendingLinkToken != nil {
                            Button("Finish connecting", systemImage: "arrow.clockwise") {
                                Task { await app.bank.finishPendingLink(context: context) }
                            }
                            .disabled(app.bank.isWorking)
                        }
                        NavigationLink("Plaid keys") { PlaidSetupView() }
                    } else {
                        NavigationLink { PlaidSetupView() } label: {
                            Label("Set up bank sync with Plaid", systemImage: "building.columns")
                        }
                        .accessibilityIdentifier("setup-plaid")
                    }
                } header: {
                    Text("Banks")
                } footer: {
                    Text("BetterDollar uses your own free Plaid account. Requests go from this iPhone straight to Plaid; there is no BetterDollar server.")
                }

                Section("Your data") {
                    Button("Import a CSV from your bank", systemImage: "doc.text") { isImporting = true }
                    NavigationLink { BackupView() } label: {
                        Label("Back up and restore", systemImage: "lock.doc")
                    }
                    if accounts.contains(where: DemoData.isSample) {
                        Button("Remove sample data", systemImage: "trash") { confirmingSampleRemoval = true }
                            .accessibilityIdentifier("remove-sample-data")
                    }
                }

                Section {
                    Toggle(isOn: $appLock) { Label("Lock with Face ID", systemImage: "faceid") }
                    NavigationLink { PrivacyView() } label: { Label("What stays on this iPhone", systemImage: "hand.raised") }
                } header: {
                    Text("Privacy")
                }

                Section("Coach") {
                    NavigationLink { CoachModelsView() } label: {
                        Label("On-device AI models", systemImage: "cpu")
                    }
                }

                Section {
                    LabeledContent("Version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0")
                    Link(destination: URL(string: "https://github.com/gazhenko/betterdollar")!) {
                        Label("Source code (MIT License)", systemImage: "chevron.left.forwardslash.chevron.right")
                    }
                } header: {
                    Text("About")
                } footer: {
                    Text("BetterDollar is free and open source. It has no ads, no accounts and no analytics.")
                }

                Section {
                    Button("Erase all data", role: .destructive) { confirmingErase = true }
                }
            }
            .scrollContentBackground(.hidden)
            .paperBackground()
            .navigationTitle("Settings")
            .sheet(isPresented: $isImporting) { CSVImportView() }
            .alert("Bank sync", isPresented: Binding(get: { bank.message != nil }, set: { if !$0 { bank.message = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(bank.message ?? "")
            }
            .confirmationDialog("Remove sample data?", isPresented: $confirmingSampleRemoval, titleVisibility: .visible) {
                Button("Remove sample data", role: .destructive) {
                    withAnimation(.snappy) { DemoData.remove(from: context) }
                }
            } message: {
                Text("This deletes the sample accounts, their transactions and the sample budget. Your bank connections and their transactions stay.")
            }
            .confirmationDialog("Erase everything?", isPresented: $confirmingErase, titleVisibility: .visible) {
                Button("Erase all data", role: .destructive, action: eraseAll)
            } message: {
                Text("This deletes every budget, transaction and coach message on this iPhone and forgets your Plaid keys. Make a backup first if you might want them back.")
            }
        }
    }

    private func eraseAll() {
        app.bank.invalidateSyncs()
        Task {
            for link in banks { await app.bank.remove(link, context: context) }
            try? BackupArchive.eraseAll(in: context)
            app.bank.save(nil)
        }
    }
}

struct BankRow: View {
    let link: BankLink
    @Environment(AppModel.self) private var app

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(link.institutionName).font(.body.weight(.medium))
                if app.bank.isSyncing(link) { ProgressView().controlSize(.small) }
            }
            Text(status)
                .font(.caption)
                .foregroundStyle(link.needsReconnect || link.lastError != nil ? Ink.seal : Ink.secondary)
        }
    }

    private var status: String {
        if link.needsReconnect { return "Needs you to sign in again" }
        if let error = link.lastError { return error }
        let count = link.accounts?.count ?? 0
        let accounts = count == 1 ? "1 account" : "\(count) accounts"
        guard let synced = link.lastSyncedAt else { return accounts }
        return "\(accounts), synced \(synced.formatted(.relative(presentation: .named)))"
    }
}

struct BankDetailView: View {
    @Bindable var link: BankLink
    @Environment(AppModel.self) private var app
    @Environment(\.modelContext) private var context
    @Environment(\.webAuthenticationSession) private var webAuth
    @Environment(\.dismiss) private var dismiss
    @State private var confirmingRemove = false

    var body: some View {
        Form {
            Section("Accounts") {
                ForEach(link.accounts ?? []) { account in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(account.displayName)
                            Spacer()
                            if let balance = account.currentBalanceCents {
                                AmountText(cents: balance, font: Typeface.amountSmall, color: account.isLiability ? Ink.seal : Ink.text)
                            }
                        }
                        Text(account.subtype.isEmpty ? account.type.capitalized : account.subtype.capitalized)
                            .font(.caption).foregroundStyle(Ink.secondary)
                    }
                }
            }
            Section {
                Button("Sync now", systemImage: "arrow.triangle.2.circlepath") {
                    Task { await app.bank.sync(link, context: context) }
                }
                .disabled(app.bank.isSyncing(link))
                if link.needsReconnect {
                    Button("Reconnect", systemImage: "key") {
                        Task { await app.bank.reconnect(link, using: webAuth, context: context) }
                    }
                }
                if let error = link.lastError { Text(error).font(.callout).foregroundStyle(Ink.seal) }
            } footer: {
                Text("New bank transactions arrive in your tray. BetterDollar never assigns them for you.")
            }
            Section {
                Button("Disconnect \(link.institutionName)", role: .destructive) { confirmingRemove = true }
            } footer: {
                Text("Transactions already imported stay in your budget. On Plaid's Trial plan a removed connection still counts toward your 10.")
            }
        }
        .scrollContentBackground(.hidden)
        .paperBackground()
        .navigationTitle(link.institutionName)
        .confirmationDialog("Disconnect \(link.institutionName)?", isPresented: $confirmingRemove, titleVisibility: .visible) {
            Button("Disconnect", role: .destructive) {
                Task {
                    await app.bank.remove(link, context: context)
                    dismiss()
                }
            }
        }
    }
}

struct PrivacyView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                fact("Your budget", "Plans, transactions and coach conversations are stored on this iPhone only. Nothing syncs to a BetterDollar server, because there isn't one.")
                fact("Bank connections", "Your Plaid keys and bank access tokens live in this iPhone's Keychain and are never synced to iCloud Keychain. The app talks to Plaid directly with your keys.")
                fact("The coach", "Answers come from Apple Intelligence or a model you download, running on this iPhone. Your numbers are never sent to a cloud AI.")
                fact("Backups", "Backups are encrypted with a passphrase you choose (AES-256). Save them anywhere, including iCloud Drive; without the passphrase they can't be read.")
                fact("No tracking", "No analytics, no ads, no account. The code is open source so anyone can check.")
            }
            .padding(20)
        }
        .paperBackground()
        .navigationTitle("What stays on this iPhone")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func fact(_ title: String, _ body: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(Typeface.groupTitle).foregroundStyle(Ink.text)
            Text(body).foregroundStyle(Ink.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}
