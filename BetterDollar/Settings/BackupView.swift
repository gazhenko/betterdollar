import BetterDollarCore
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    nonisolated static let betterDollarBackup = UTType(exportedAs: "dev.gazhenko.betterdollar.backup")
}

nonisolated struct BackupDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.betterDollarBackup] }
    var data: Data

    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}

/// Encrypted backups the user saves wherever they like, including iCloud Drive through the Files app.
struct BackupView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.modelContext) private var context
    @State private var passphrase = ""
    @State private var confirmation = ""
    @State private var includeBanks = true
    @State private var isWorking = false
    @State private var document: BackupDocument?
    @State private var isExporting = false
    @State private var isPickingFile = false
    @State private var pendingData: Data?
    @State private var restorePassphrase = ""
    @State private var opened: BackupArchive?
    @State private var status: (ok: Bool, text: String)?

    var body: some View {
        Form {
            Section {
                SecureField("Passphrase (8+ characters)", text: $passphrase)
                    .accessibilityIdentifier("backup-passphrase")
                SecureField("Repeat passphrase", text: $confirmation)
                    .accessibilityIdentifier("backup-passphrase-confirm")
                Toggle("Include bank connections", isOn: $includeBanks)
                Button {
                    Task { await export() }
                } label: {
                    HStack { Text("Create encrypted backup"); if isWorking { Spacer(); ProgressView() } }
                }
                .disabled(passphrase.count < 8 || passphrase != confirmation || isWorking)
                .accessibilityIdentifier("create-backup")
            } header: {
                Text("Back up")
            } footer: {
                Text("The file is encrypted with AES-256 using your passphrase. Save it to iCloud Drive or anywhere in Files. There is no way to recover a forgotten passphrase. Bank connections include your Plaid keys and access tokens, so a restore keeps syncing.")
            }

            Section {
                Button("Choose a backup file", systemImage: "folder") { isPickingFile = true }
                if pendingData != nil && opened == nil {
                    SecureField("Backup passphrase", text: $restorePassphrase)
                    Button("Unlock backup") { Task { await unlock() } }
                        .disabled(restorePassphrase.isEmpty || isWorking)
                }
                if let opened {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Backup from \(opened.exportedAt.formatted(date: .abbreviated, time: .shortened))")
                            .font(.body.weight(.medium))
                        Text("\(opened.monthCount) months, \(opened.transactionCount) transactions, \(opened.links.count) bank connections")
                            .font(.caption).foregroundStyle(Ink.secondary)
                    }
                    Button("Replace everything on this iPhone", role: .destructive, action: restore)
                }
            } header: {
                Text("Restore")
            } footer: {
                Text("Restoring replaces every budget and transaction on this iPhone with the backup's contents.")
            }

            if let status {
                Label(status.text, systemImage: status.ok ? "checkmark.seal" : "exclamationmark.triangle")
                    .foregroundStyle(status.ok ? Ink.primary : Ink.seal)
            }
        }
        .scrollContentBackground(.hidden)
        .paperBackground()
        .navigationTitle("Back up and restore")
        .fileExporter(isPresented: $isExporting, document: document, contentType: .betterDollarBackup,
                      defaultFilename: "BetterDollar \(Date().formatted(.iso8601.year().month().day()))") { result in
            switch result {
            case .success: status = (true, "Backup saved.")
            case .failure(let error): status = (false, error.localizedDescription)
            }
            passphrase = ""; confirmation = ""
        }
        .fileImporter(isPresented: $isPickingFile, allowedContentTypes: [.betterDollarBackup, .data]) { result in
            opened = nil
            restorePassphrase = ""
            do {
                let url = try result.get()
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                pendingData = try Data(contentsOf: url)
                status = nil
            } catch {
                status = (false, error.localizedDescription)
            }
        }
    }

    private func export() async {
        isWorking = true
        defer { isWorking = false }
        do {
            let archive = try BackupArchive.make(from: context, vault: app.bank.vault, includeBankConnections: includeBanks)
            let phrase = passphrase
            let data = try await Task.detached { try BackupCrypto.seal(archive, passphrase: phrase) }.value
            document = BackupDocument(data: data)
            isExporting = true
        } catch {
            status = (false, error.localizedDescription)
        }
    }

    private func unlock() async {
        guard let data = pendingData else { return }
        isWorking = true
        defer { isWorking = false }
        let phrase = restorePassphrase
        do {
            opened = try await Task.detached { try BackupCrypto.open(data, passphrase: phrase) }.value
            status = nil
        } catch {
            status = (false, error.localizedDescription)
        }
    }

    private func restore() {
        guard let opened else { return }
        app.bank.invalidateSyncs()
        do {
            try opened.restore(into: context, vault: app.bank.vault)
            app.bank.save(app.bank.vault.credentials)
            status = (true, "Restored \(opened.transactionCount) transactions and \(opened.monthCount) months.")
            self.opened = nil
            pendingData = nil
        } catch {
            status = (false, error.localizedDescription)
        }
    }
}
