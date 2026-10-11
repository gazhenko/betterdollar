import CommonCrypto
import CryptoKit
import Foundation
import SwiftData

/// A complete, versioned copy of the user's data. It is only ever written encrypted (see `BackupCrypto`).
public struct BackupArchive: Codable, Sendable {
    public static let currentVersion = 1

    public struct Item: Codable, Sendable {
        var uuid: UUID, name: String, plannedCents: Int, sortIndex: Int, seriesID: UUID
        var isFund: Bool, fundGoalCents: Int, fundTargetDate: Date?, fundStartingCents: Int, dueDay: Int, note: String
        var fundAdjustmentCents: Int?
    }
    public struct Group: Codable, Sendable { var name: String, isIncome: Bool, sortIndex: Int, items: [Item] }
    public struct Month: Codable, Sendable { var key: String, createdAt: Date, groups: [Group] }
    public struct Link: Codable, Sendable {
        var itemID: String, institutionName: String, institutionID: String, cursor: String?, lastSyncedAt: Date?
        var accessToken: String?
        var environment: String?
    }
    public struct Account: Codable, Sendable {
        var uuid: UUID, externalID: String, name: String, officialName: String, mask: String, type: String, subtype: String
        var currentBalanceCents: Int?, availableBalanceCents: Int?, isHidden: Bool, linkItemID: String?
    }
    public struct Split: Codable, Sendable { var itemUUID: UUID, amountCents: Int }
    public struct Transaction: Codable, Sendable {
        var uuid: UUID, date: Date, amountCents: Int, isIncome: Bool, merchant: String, note: String
        var status: String, source: String, externalID: String?, bankCategory: String?, isPending: Bool, createdAt: Date
        var accountUUID: UUID?, splits: [Split]
        var merchantEdited: Bool?
    }
    public struct Message: Codable, Sendable { var role: String, text: String, engine: String, createdAt: Date }

    public var version: Int
    public var exportedAt: Date
    public var months: [Month]
    public var links: [Link]
    public var accounts: [Account]
    public var transactions: [Transaction]
    public var coach: [Message]
    /// Present only when the user chose to include bank connections.
    public var plaidCredentials: PlaidCredentials?

    public var transactionCount: Int { transactions.count }
    public var monthCount: Int { months.count }
}

@MainActor public extension BackupArchive {
    static func make(from context: ModelContext, vault: PlaidVault?, includeBankConnections: Bool) throws -> BackupArchive {
        let months = try context.fetch(FetchDescriptor<BudgetMonth>(sortBy: [SortDescriptor(\.key)]))
        let links = try context.fetch(FetchDescriptor<BankLink>())
        let accounts = try context.fetch(FetchDescriptor<BankAccount>())
        let transactions = try context.fetch(FetchDescriptor<LedgerTransaction>(sortBy: [SortDescriptor(\.date)]))
        let messages = try context.fetch(FetchDescriptor<CoachMessage>(sortBy: [SortDescriptor(\.createdAt)]))
        return BackupArchive(
            version: currentVersion,
            exportedAt: Date(),
            months: months.map { month in
                Month(key: month.key, createdAt: month.createdAt, groups: month.sortedGroups.map { group in
                    Group(name: group.name, isIncome: group.isIncome, sortIndex: group.sortIndex, items: group.sortedItems.map { item in
                        Item(uuid: item.uuid, name: item.name, plannedCents: item.plannedCents, sortIndex: item.sortIndex,
                             seriesID: item.seriesID, isFund: item.isFund, fundGoalCents: item.fundGoalCents,
                             fundTargetDate: item.fundTargetDate, fundStartingCents: item.fundStartingCents,
                             dueDay: item.dueDay, note: item.note, fundAdjustmentCents: item.fundAdjustmentCents)
                    })
                })
            },
            links: links.map { link in
                Link(itemID: link.itemID, institutionName: link.institutionName, institutionID: link.institutionID,
                     cursor: includeBankConnections ? link.cursor : nil, lastSyncedAt: link.lastSyncedAt,
                     accessToken: includeBankConnections ? vault?.accessToken(itemID: link.itemID) : nil,
                     environment: link.environmentRaw)
            },
            accounts: accounts.map { a in
                Account(uuid: a.uuid, externalID: a.externalID, name: a.name, officialName: a.officialName, mask: a.mask,
                        type: a.type, subtype: a.subtype, currentBalanceCents: a.currentBalanceCents,
                        availableBalanceCents: a.availableBalanceCents, isHidden: a.isHidden, linkItemID: a.link?.itemID)
            },
            transactions: transactions.map { t in
                Transaction(uuid: t.uuid, date: t.date, amountCents: t.amountCents, isIncome: t.isIncome, merchant: t.merchant,
                            note: t.note, status: t.statusRaw, source: t.sourceRaw, externalID: t.externalID,
                            bankCategory: t.bankCategory, isPending: t.isPending, createdAt: t.createdAt,
                            accountUUID: t.account?.uuid,
                            splits: (t.allocations ?? []).compactMap { a in a.item.map { Split(itemUUID: $0.uuid, amountCents: a.amountCents) } },
                            merchantEdited: t.merchantEdited)
            },
            coach: messages.map { Message(role: $0.roleRaw, text: $0.text, engine: $0.engine, createdAt: $0.createdAt) },
            plaidCredentials: includeBankConnections ? vault?.credentials : nil
        )
    }

    /// Replaces everything in `context` with this archive.
    func restore(into context: ModelContext, vault: PlaidVault?) throws {
        guard version <= Self.currentVersion else { throw BackupError.newerVersion }
        try BackupArchive.eraseAll(in: context)

        var itemsByUUID: [UUID: BudgetItem] = [:]
        for m in months {
            guard let key = MonthKey(m.key) else { continue }
            let month = BudgetMonth(key: key)
            month.createdAt = m.createdAt
            context.insert(month)
            for g in m.groups {
                let group = BudgetGroup(name: g.name, isIncome: g.isIncome, sortIndex: g.sortIndex)
                group.month = month
                context.insert(group)
                for i in g.items {
                    let item = BudgetItem(name: i.name, plannedCents: i.plannedCents, sortIndex: i.sortIndex, seriesID: i.seriesID)
                    item.uuid = i.uuid
                    item.isFund = i.isFund
                    item.fundGoalCents = i.fundGoalCents
                    item.fundTargetDate = i.fundTargetDate
                    item.fundStartingCents = i.fundStartingCents
                    item.dueDay = i.dueDay
                    item.note = i.note
                    item.fundAdjustmentCents = i.fundAdjustmentCents ?? 0
                    item.group = group
                    context.insert(item)
                    itemsByUUID[i.uuid] = item
                }
            }
        }

        var linksByID: [String: BankLink] = [:]
        for l in links {
            let link = BankLink(itemID: l.itemID, institutionName: l.institutionName, institutionID: l.institutionID)
            link.cursor = l.cursor
            link.lastSyncedAt = l.lastSyncedAt
            link.environmentRaw = l.environment ?? ""
            link.needsReconnect = l.accessToken == nil && vault?.accessToken(itemID: l.itemID) == nil
            context.insert(link)
            linksByID[l.itemID] = link
            if let token = l.accessToken { vault?.setAccessToken(token, itemID: l.itemID) }
        }

        var accountsByUUID: [UUID: BankAccount] = [:]
        for a in accounts {
            let account = BankAccount(externalID: a.externalID, name: a.name)
            account.uuid = a.uuid
            account.officialName = a.officialName
            account.mask = a.mask
            account.type = a.type
            account.subtype = a.subtype
            account.currentBalanceCents = a.currentBalanceCents
            account.availableBalanceCents = a.availableBalanceCents
            account.isHidden = a.isHidden
            account.link = a.linkItemID.flatMap { linksByID[$0] }
            context.insert(account)
            accountsByUUID[a.uuid] = account
        }

        for t in transactions {
            let transaction = LedgerTransaction(date: t.date, amountCents: t.amountCents, isIncome: t.isIncome, merchant: t.merchant,
                                                note: t.note, source: TransactionSource(rawValue: t.source) ?? .manual,
                                                externalID: t.externalID)
            transaction.uuid = t.uuid
            transaction.statusRaw = t.status
            transaction.bankCategory = t.bankCategory
            transaction.isPending = t.isPending
            transaction.merchantEdited = t.merchantEdited ?? false
            transaction.createdAt = t.createdAt
            transaction.account = t.accountUUID.flatMap { accountsByUUID[$0] }
            context.insert(transaction)
            for split in t.splits {
                guard let item = itemsByUUID[split.itemUUID] else { continue }
                let allocation = Allocation(amountCents: split.amountCents)
                allocation.transaction = transaction
                allocation.item = item
                context.insert(allocation)
            }
            if transaction.status == .tracked && transaction.allocatedCents != transaction.amountCents {
                Ledger.unassign(transaction, in: context)
            }
        }

        for m in coach {
            let message = CoachMessage(role: m.role, text: m.text, engine: m.engine)
            message.createdAt = m.createdAt
            context.insert(message)
        }
        if let plaidCredentials { vault?.save(plaidCredentials) }
        try context.save()
    }

    static func eraseAll(in context: ModelContext) throws {
        for allocation in try context.fetch(FetchDescriptor<Allocation>()) { context.delete(allocation) }
        for transaction in try context.fetch(FetchDescriptor<LedgerTransaction>()) { context.delete(transaction) }
        for month in try context.fetch(FetchDescriptor<BudgetMonth>()) { context.delete(month) }
        for group in try context.fetch(FetchDescriptor<BudgetGroup>()) { context.delete(group) }
        for item in try context.fetch(FetchDescriptor<BudgetItem>()) { context.delete(item) }
        for account in try context.fetch(FetchDescriptor<BankAccount>()) { context.delete(account) }
        for link in try context.fetch(FetchDescriptor<BankLink>()) { context.delete(link) }
        for message in try context.fetch(FetchDescriptor<CoachMessage>()) { context.delete(message) }
        try context.save()
    }
}

public enum BackupError: LocalizedError, Equatable {
    case notABackup
    case wrongPassphrase
    case newerVersion
    case weakPassphrase

    public var errorDescription: String? {
        switch self {
        case .notABackup: "This file isn't a BetterDollar backup."
        case .wrongPassphrase: "That passphrase doesn't unlock this backup."
        case .newerVersion: "This backup was made by a newer version of BetterDollar. Update the app and try again."
        case .weakPassphrase: "Use a passphrase of at least 8 characters."
        }
    }
}

/// AES-256-GCM with a key stretched from the user's passphrase (PBKDF2-HMAC-SHA256).
/// File layout: "BDBK" | version (1 byte) | iterations (UInt32, big-endian) | salt (16 bytes) | nonce+ciphertext+tag.
public enum BackupCrypto {
    public static let fileExtension = "betterdollar"
    public static let defaultIterations: UInt32 = 600_000
    private static let magic = Data("BDBK".utf8)
    private static let formatVersion: UInt8 = 1

    public static func seal(_ archive: BackupArchive, passphrase: String, iterations: UInt32 = defaultIterations) throws -> Data {
        guard passphrase.count >= 8 else { throw BackupError.weakPassphrase }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let plaintext = try encoder.encode(archive)
        var salt = Data(count: 16)
        let status = salt.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 16, $0.baseAddress!) }
        guard status == errSecSuccess else { throw CocoaError(.fileWriteUnknown) }
        let key = try deriveKey(passphrase: passphrase, salt: salt, iterations: iterations)
        guard let box = try AES.GCM.seal(plaintext, using: key).combined else { throw CocoaError(.fileWriteUnknown) }
        var output = magic
        output.append(formatVersion)
        withUnsafeBytes(of: iterations.bigEndian) { output.append(contentsOf: $0) }
        output.append(salt)
        output.append(box)
        return output
    }

    public static func open(_ data: Data, passphrase: String) throws -> BackupArchive {
        let header = magic.count + 1 + 4 + 16
        guard data.count > header, data.prefix(magic.count) == magic else { throw BackupError.notABackup }
        var offset = data.startIndex + magic.count
        guard data[offset] == formatVersion else { throw BackupError.newerVersion }
        offset += 1
        let iterations = data[offset..<offset + 4].reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        offset += 4
        let salt = data[offset..<offset + 16]
        offset += 16
        let key = try deriveKey(passphrase: passphrase, salt: Data(salt), iterations: iterations)
        let plaintext: Data
        do {
            plaintext = try AES.GCM.open(AES.GCM.SealedBox(combined: data[offset...]), using: key)
        } catch {
            throw BackupError.wrongPassphrase
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(BackupArchive.self, from: plaintext)
    }

    static func deriveKey(passphrase: String, salt: Data, iterations: UInt32) throws -> SymmetricKey {
        let password = Array(passphrase.utf8)
        var derived = [UInt8](repeating: 0, count: 32)
        let status = salt.withUnsafeBytes { saltBytes in
            password.withUnsafeBufferPointer { passwordBytes in
                CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2),
                                     passwordBytes.baseAddress.map { UnsafeRawPointer($0).assumingMemoryBound(to: CChar.self) },
                                     password.count,
                                     saltBytes.bindMemory(to: UInt8.self).baseAddress, salt.count,
                                     CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), iterations,
                                     &derived, derived.count)
            }
        }
        guard status == kCCSuccess else { throw CocoaError(.fileReadUnknown) }
        return SymmetricKey(data: derived)
    }
}
