import Foundation
import SwiftData
import Testing
@testable import BetterDollarCore

/// Serves canned Plaid responses so the client can be tested without network or keys.
final class PlaidStub: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var responses: [String: [(Int, String)]] = [:]
    nonisolated(unsafe) static var requests: [(path: String, body: [String: Any])] = []
    private static let lock = NSLock()

    static func reset() { lock.withLock { responses = [:]; requests = [] } }
    static func enqueue(_ path: String, status: Int = 200, _ json: String) {
        lock.withLock { responses[path, default: []].append((status, json)) }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let path = request.url?.path ?? ""
        var bodyData = request.httpBody ?? Data()
        if bodyData.isEmpty, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 65_536)
            while stream.hasBytesAvailable {
                let read = stream.read(&buffer, maxLength: buffer.count)
                if read <= 0 { break }
                bodyData.append(buffer, count: read)
            }
        }
        let body = (try? JSONSerialization.jsonObject(with: bodyData)) as? [String: Any] ?? [:]
        let next: (Int, String)? = Self.lock.withLock {
            Self.requests.append((path, body))
            guard var queue = Self.responses[path], !queue.isEmpty else { return nil }
            let first = queue.removeFirst()
            Self.responses[path] = queue
            return first
        }
        let (status, json) = next ?? (404, #"{"error_code":"NOT_STUBBED","error_type":"TEST"}"#)
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(json.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@Suite(.serialized) @MainActor struct PlaidTests {
    let container: ModelContainer
    let client: PlaidClient
    var context: ModelContext { container.mainContext }

    init() throws {
        container = try BetterDollarSchema.container(inMemory: true)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PlaidStub.self]
        client = PlaidClient(credentials: PlaidCredentials(clientID: "client", secret: "secret", environment: .sandbox),
                             session: URLSession(configuration: configuration))
        PlaidStub.reset()
    }

    private func transaction(_ id: String, amount: String, date: String = "2026-10-09", name: String = "SHELL OIL 123",
                             merchant: String? = "Shell", pending: Bool = false, pendingID: String? = nil) -> String {
        """
        {"transaction_id":"\(id)","account_id":"acc-1","amount":\(amount),"iso_currency_code":"USD","date":"\(date)",
         "name":"\(name)","merchant_name":\(merchant.map { "\"\($0)\"" } ?? "null"),"pending":\(pending),
         "pending_transaction_id":\(pendingID.map { "\"\($0)\"" } ?? "null"),
         "personal_finance_category":{"primary":"TRANSPORTATION","detailed":"TRANSPORTATION_GAS"}}
        """
    }

    private let accountsJSON = """
    [{"account_id":"acc-1","name":"Plaid Checking","official_name":"Plaid Gold Standard","mask":"0000","type":"depository",
      "subtype":"checking","balances":{"available":100.5,"current":110.25,"iso_currency_code":"USD"}}]
    """

    @Test func hostedLinkFlowSendsCredentialsAndReadsPublicTokens() async throws {
        PlaidStub.enqueue("/link/token/create", #"{"link_token":"link-sandbox-1","hosted_link_url":"https://secure.plaid.com/hl/abc","expiration":"2026-10-11T00:00:00Z","request_id":"r"}"#)
        PlaidStub.enqueue("/link/token/get", """
        {"link_token":"link-sandbox-1","link_sessions":[{"link_session_id":"s1","finished_at":"2026-10-11T00:00:00Z",
          "results":{"item_add_results":[{"public_token":"public-sandbox-1","institution":{"name":"First Platypus Bank","institution_id":"ins_109508"},"accounts":[]}]}}]}
        """)
        PlaidStub.enqueue("/item/public_token/exchange", #"{"access_token":"access-sandbox-1","item_id":"item-1","request_id":"r"}"#)

        let link = try await client.createHostedLink(userID: "user-1")
        #expect(link.hostedLinkUrl == "https://secure.plaid.com/hl/abc")
        let status = try await client.linkTokenStatus(link.linkToken)
        #expect(status.completedItems.map(\.publicToken) == ["public-sandbox-1"])
        #expect(status.completedItems.first?.institution?.name == "First Platypus Bank")
        let exchange = try await client.exchange(publicToken: "public-sandbox-1")
        #expect(exchange.accessToken == "access-sandbox-1")

        let create = try #require(PlaidStub.requests.first { $0.path == "/link/token/create" })
        #expect(create.body["client_id"] as? String == "client")
        #expect(create.body["secret"] as? String == "secret")
        #expect((create.body["hosted_link"] as? [String: Any])?["completion_redirect_uri"] as? String == PlaidClient.completionRedirectURI)
        #expect(create.body["products"] as? [String] == ["transactions"])
    }

    @Test func errorsAreDecoded() async {
        PlaidStub.enqueue("/accounts/get", status: 400, #"{"error_type":"ITEM_ERROR","error_code":"ITEM_LOGIN_REQUIRED","error_message":"login required","display_message":null,"request_id":"r"}"#)
        do {
            _ = try await client.accounts(accessToken: "access")
            Issue.record("expected an error")
        } catch let error as PlaidError {
            #expect(error.needsReconnect)
            #expect(error.errorDescription?.contains("Reconnect") == true)
        } catch {
            Issue.record("unexpected \(error)")
        }
    }

    @Test func syncFollowsPagesAndLandsInTheTray() async throws {
        PlaidStub.enqueue("/transactions/sync", """
        {"added":[\(transaction("t1", amount: "48.20", pending: true))],"modified":[],"removed":[],"next_cursor":"c1","has_more":true,"accounts":\(accountsJSON)}
        """)
        PlaidStub.enqueue("/transactions/sync", """
        {"added":[\(transaction("t2", amount: "-2500", name: "ACME PAYROLL", merchant: nil))],"modified":[],"removed":[],"next_cursor":"c2","has_more":false}
        """)
        let result = try await client.syncTransactions(accessToken: "access", cursor: nil)
        #expect(result.added.count == 2)
        #expect(result.cursor == "c2")
        #expect(PlaidStub.requests.last?.body["cursor"] as? String == "c1")

        let link = BankLink(itemID: "item-1", institutionName: "First Platypus Bank")
        context.insert(link)
        let summary = PlaidSyncApplier.apply(result, to: link, in: context)
        #expect(summary.added == 2)
        #expect(link.cursor == "c2")
        #expect(link.accounts?.first?.currentBalanceCents == 110_25)

        let all = try context.fetch(FetchDescriptor<LedgerTransaction>())
        let gas = try #require(all.first { $0.externalID == "t1" })
        #expect(gas.amountCents == 48_20 && !gas.isIncome && gas.isPending && gas.status == .new)
        #expect(gas.merchant == "Shell")
        let pay = try #require(all.first { $0.externalID == "t2" })
        #expect(pay.isIncome && pay.amountCents == 2_500_00 && pay.merchant == "ACME PAYROLL")
    }

    @Test func pendingToPostedKeepsTheAssignment() throws {
        let key = MonthKey(year: 2026, month: 10)
        let month = BudgetPlanner.createFromTemplate(key, in: context)
        let gas = month.allItems.first { $0.name == "Gas" }!
        let link = BankLink(itemID: "item-1", institutionName: "Bank")
        context.insert(link)

        var first = PlaidSyncResult()
        first.added = [try decode(transaction("pending-1", amount: "40.00", pending: true))]
        PlaidSyncApplier.apply(first, to: link, in: context)
        let local = try #require(try context.fetch(FetchDescriptor<LedgerTransaction>()).first)
        Ledger.assign(local, to: gas, in: context)

        // The posted version arrives with a tip added; Plaid removes the pending one.
        var posted = PlaidSyncResult()
        posted.added = [try decode(transaction("posted-1", amount: "46.00", pendingID: "pending-1"))]
        posted.removed = [PlaidRemovedTransaction(transactionId: "pending-1")]
        let summary = PlaidSyncApplier.apply(posted, to: link, in: context)
        #expect(summary.updated == 1 && summary.removed == 0)

        let all = try context.fetch(FetchDescriptor<LedgerTransaction>())
        #expect(all.count == 1)
        #expect(all[0].externalID == "posted-1")
        #expect(all[0].status == .tracked)
        #expect(!all[0].isPending)
        #expect(BudgetMath.activity(of: gas) == 46_00)
    }

    @Test func removedTransactionsDisappear() throws {
        let link = BankLink(itemID: "item-1", institutionName: "Bank")
        context.insert(link)
        var first = PlaidSyncResult()
        first.added = [try decode(transaction("t1", amount: "12.00"))]
        PlaidSyncApplier.apply(first, to: link, in: context)
        var second = PlaidSyncResult()
        second.removed = [PlaidRemovedTransaction(transactionId: "t1")]
        PlaidSyncApplier.apply(second, to: link, in: context)
        #expect(try context.fetch(FetchDescriptor<LedgerTransaction>()).isEmpty)
    }

    private func decode(_ json: String) throws -> PlaidTransaction {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(PlaidTransaction.self, from: Data(json.utf8))
    }

    @Test func renamesSurviveSyncAndPostedChargesFollowTheirMonth() throws {
        let september = MonthKey(year: 2026, month: 9)
        let sepPlan = BudgetPlanner.createFromTemplate(september, in: context)
        let octPlan = BudgetPlanner.createByCopying(sepPlan, to: september.next, in: context)
        let sepGroceries = sepPlan.allItems.first { $0.name == "Groceries" }!
        let link = BankLink(itemID: "item-1", institutionName: "Bank")
        context.insert(link)

        var first = PlaidSyncResult()
        first.added = [try decode(transaction("p1", amount: "60.00", date: "2026-09-30", name: "SQ *MARKET 123", merchant: nil, pending: true))]
        PlaidSyncApplier.apply(first, to: link, in: context)
        let local = try #require(try context.fetch(FetchDescriptor<LedgerTransaction>()).first)
        local.merchant = "Farmers market"
        local.merchantEdited = true
        Ledger.assign(local, to: sepGroceries, in: context)

        // It posts on October 2nd.
        var posted = PlaidSyncResult()
        posted.added = [try decode(transaction("t1", amount: "60.00", date: "2026-10-02", name: "SQ *MARKET 123", merchant: nil, pendingID: "p1"))]
        PlaidSyncApplier.apply(posted, to: link, in: context)
        #expect(local.merchant == "Farmers market")
        #expect(local.status == .tracked)
        #expect(local.allocations?.first?.item?.monthKey == september.next)
        #expect(local.allocations?.first?.item?.seriesID == octPlan.allItems.first { $0.name == "Groceries" }!.seriesID)
        #expect(BudgetMath.activity(of: sepGroceries) == 0)
    }
}
