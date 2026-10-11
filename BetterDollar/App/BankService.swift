import AuthenticationServices
import BetterDollarCore
import Foundation
import Observation
import SwiftData
import SwiftUI

/// Connects banks through the user's own Plaid keys and keeps them in sync.
/// Requests go straight from this iPhone to Plaid; BetterDollar runs no server.
@Observable final class BankService {
    let vault = PlaidVault()
    private(set) var credentials: PlaidCredentials?
    private(set) var isWorking = false
    private(set) var syncingItemIDs: Set<String> = []
    var message: String?
    /// A Link session that finished in the browser but whose bank Plaid hadn't reported yet.
    /// Kept so the user can finish without linking again (each new link uses one of Plaid's 10 free Items).
    private(set) var pendingLinkToken: String? = Keychain().string("plaid.pending_link_token") {
        didSet { vault.keychain.set(pendingLinkToken, for: "plaid.pending_link_token") }
    }
    /// Bumped when data is erased or restored so in-flight syncs don't write into the new store.
    private var generation = 0

    init() { credentials = vault.credentials }

    /// Call before erasing or restoring: running syncs drop their results.
    func invalidateSyncs() {
        generation += 1
        pendingLinkToken = nil
    }

    var isConfigured: Bool { credentials?.isComplete == true }

    func save(_ credentials: PlaidCredentials?) {
        vault.save(credentials)
        self.credentials = credentials
    }

    private var client: PlaidClient? { credentials.map { PlaidClient(credentials: $0) } }

    // MARK: Connecting

    /// Opens Plaid Hosted Link in a private browser session and adds every bank the user finishes connecting.
    func connect(using webAuth: WebAuthenticationSession, context: ModelContext) async {
        guard let client else { message = "Add your Plaid keys first."; return }
        isWorking = true
        defer { isWorking = false }
        do {
            let link = try await client.createHostedLink(userID: vault.userID)
            guard let url = link.hostedLinkUrl.flatMap(URL.init(string:)) else {
                message = "Plaid didn't return a Hosted Link page. Check that Hosted Link is enabled for your Plaid team."
                return
            }
            await openLink(url, webAuth: webAuth)
            pendingLinkToken = link.linkToken
            await finishLink(link.linkToken, client: client, context: context)
        } catch {
            message = error.localizedDescription
        }
    }

    /// Checks a pending Link session again, for when Plaid was slow to report the bank.
    func finishPendingLink(context: ModelContext) async {
        guard let client, let token = pendingLinkToken else { return }
        isWorking = true
        defer { isWorking = false }
        await finishLink(token, client: client, context: context)
    }

    private func finishLink(_ linkToken: String, client: PlaidClient, context: ModelContext) async {
        let started = generation
        do {
            var status = try await client.linkTokenStatus(linkToken)
            // Plaid can take a few seconds to record a just-finished session.
            for (attempt, delay) in [1, 2, 3, 4].enumerated() {
                guard status.completedItems.isEmpty, !status.didExit, status.hasSessions || attempt == 0 else { break }
                try await Task.sleep(for: .seconds(delay))
                status = try await client.linkTokenStatus(linkToken)
            }
            guard started == generation else { return }
            let completed = status.completedItems
            if completed.isEmpty {
                if status.didExit || !status.hasSessions {
                    // Closed without connecting a bank.
                    pendingLinkToken = nil
                    if let error = status.exitError { message = error.localizedDescription }
                } else {
                    message = "Plaid hasn't confirmed the connection yet. If you finished linking your bank, tap Finish connecting in a minute; there's no need to link it again."
                }
                return
            }
            pendingLinkToken = nil
            var names: [String] = []
            for result in completed {
                let exchange = try await client.exchange(publicToken: result.publicToken)
                vault.setAccessToken(exchange.accessToken, itemID: exchange.itemId)
                let bank = BankLink(itemID: exchange.itemId, institutionName: result.institution?.name ?? "Bank",
                                    institutionID: result.institution?.institutionId ?? "")
                bank.environmentRaw = client.credentials.environment.rawValue
                context.insert(bank)
                let accounts = try await client.accounts(accessToken: exchange.accessToken)
                if bank.institutionName == "Bank", let name = accounts.item.institutionName { bank.institutionName = name }
                PlaidSyncApplier.upsertAccounts(accounts.accounts, link: bank, in: context)
                try? context.save()
                names.append(bank.institutionName)
                await sync(bank, context: context)
            }
            message = "Connected \(names.joined(separator: " and ")). New transactions are waiting in your tray."
        } catch {
            message = error.localizedDescription
        }
    }

    /// Update mode: the bank asked the user to sign in again.
    func reconnect(_ bank: BankLink, using webAuth: WebAuthenticationSession, context: ModelContext) async {
        guard let client, let token = vault.accessToken(itemID: bank.itemID) else {
            message = "This bank's connection key isn't on this iPhone. Remove it and connect again."
            return
        }
        isWorking = true
        defer { isWorking = false }
        do {
            let link = try await client.createHostedLink(userID: vault.userID, accessToken: token)
            guard let url = link.hostedLinkUrl.flatMap(URL.init(string:)) else { return }
            await openLink(url, webAuth: webAuth)
            bank.needsReconnect = false
            await sync(bank, context: context)
        } catch {
            message = error.localizedDescription
        }
    }

    private func openLink(_ url: URL, webAuth: WebAuthenticationSession) async {
        // Cancelling still falls through: Plaid may have finished even if the redirect didn't fire.
        _ = try? await webAuth.authenticate(using: url, callback: .customScheme(PlaidClient.callbackScheme),
                                            preferredBrowserSession: .ephemeral, additionalHeaderFields: [:])
    }

    // MARK: Syncing

    func syncAll(context: ModelContext) async {
        let banks = (try? context.fetch(FetchDescriptor<BankLink>())) ?? []
        for bank in banks where !bank.needsReconnect { await sync(bank, context: context) }
    }

    func sync(_ bank: BankLink, context: ModelContext) async {
        guard let client, let token = vault.accessToken(itemID: bank.itemID) else {
            bank.lastError = "Missing connection key. Reconnect this bank."
            bank.needsReconnect = true
            return
        }
        if !bank.environmentRaw.isEmpty && bank.environmentRaw != client.credentials.environment.rawValue {
            let connected = PlaidEnvironment(rawValue: bank.environmentRaw)?.title ?? bank.environmentRaw
            bank.lastError = "Connected with your \(connected) keys. Switch back under Plaid keys, or disconnect it and connect again."
            return
        }
        let itemID = bank.itemID
        guard !syncingItemIDs.contains(itemID) else { return }
        syncingItemIDs.insert(itemID)
        defer { syncingItemIDs.remove(itemID) }
        let started = generation
        do {
            let result = try await client.syncTransactions(accessToken: token, cursor: bank.cursor)
            let accounts = try await client.accounts(accessToken: token)
            // The bank may have been disconnected, or the data erased or restored, while we waited.
            guard started == generation, !bank.isDeleted, bank.modelContext != nil else { return }
            PlaidSyncApplier.upsertAccounts(accounts.accounts, link: bank, in: context)
            let summary = PlaidSyncApplier.apply(result, to: bank, in: context)
            try? context.save()
            if result.updateStatus == "NOT_READY" && summary.added == 0 {
                bank.lastError = "\(bank.institutionName) is still preparing your history. Sync again in a minute."
            }
        } catch let error as PlaidError {
            guard started == generation, !bank.isDeleted else { return }
            bank.lastError = error.localizedDescription
            bank.needsReconnect = error.needsReconnect
        } catch {
            guard started == generation, !bank.isDeleted else { return }
            bank.lastError = error.localizedDescription
        }
    }

    func isSyncing(_ bank: BankLink) -> Bool { syncingItemIDs.contains(bank.itemID) }
    var isSyncingAny: Bool { !syncingItemIDs.isEmpty }

    /// Disconnects the bank at Plaid and forgets its key. Its transactions stay in the budget.
    func remove(_ bank: BankLink, context: ModelContext) async {
        syncingItemIDs.remove(bank.itemID)
        if let client, let token = vault.accessToken(itemID: bank.itemID) {
            try? await client.removeItem(accessToken: token)
        }
        vault.setAccessToken(nil, itemID: bank.itemID)
        for account in bank.accounts ?? [] {
            for transaction in account.transactions ?? [] { transaction.account = nil }
        }
        context.delete(bank)
        try? context.save()
    }
}
