import Foundation

/// Talks to Plaid directly from the device with the user's own keys. There is no BetterDollar server.
///
/// Bank linking uses Plaid Hosted Link opened in a web authentication session, so OAuth banks
/// (Chase, Bank of America, …) work without a universal link or an app-specific redirect domain.
public struct PlaidClient: Sendable {
    public static let completionRedirectURI = "betterdollar://plaid/complete"
    public static let callbackScheme = "betterdollar"

    public let credentials: PlaidCredentials
    private let session: URLSession

    public init(credentials: PlaidCredentials, session: URLSession = .shared) {
        self.credentials = credentials
        self.session = session
    }

    // MARK: Link

    /// Creates a Hosted Link session. Pass `accessToken` to reconnect an existing bank (update mode).
    public func createHostedLink(userID: String, daysRequested: Int = 180, accessToken: String? = nil) async throws -> PlaidLinkToken {
        var body: [String: Any] = [
            "client_name": "BetterDollar",
            "language": "en",
            "country_codes": ["US", "CA"],
            "user": ["client_user_id": userID],
            "hosted_link": ["completion_redirect_uri": Self.completionRedirectURI]
        ]
        if let accessToken {
            body["access_token"] = accessToken
        } else {
            body["products"] = ["transactions"]
            body["transactions"] = ["days_requested": daysRequested]
        }
        return try await post("/link/token/create", body)
    }

    public func linkTokenStatus(_ linkToken: String) async throws -> PlaidLinkTokenStatus {
        try await post("/link/token/get", ["link_token": linkToken])
    }

    public func exchange(publicToken: String) async throws -> PlaidTokenExchange {
        try await post("/item/public_token/exchange", ["public_token": publicToken])
    }

    // MARK: Data

    public func accounts(accessToken: String) async throws -> PlaidAccountsResponse {
        try await post("/accounts/get", ["access_token": accessToken])
    }

    /// Pulls every change since `cursor`, following `has_more` pages.
    /// If the data changes mid-pagination Plaid asks us to restart from the original cursor.
    public func syncTransactions(accessToken: String, cursor: String?) async throws -> PlaidSyncResult {
        var attempts = 0
        while true {
            do {
                var result = PlaidSyncResult()
                var next = cursor
                repeat {
                    var body: [String: Any] = ["access_token": accessToken, "count": 500,
                                               "options": ["include_personal_finance_category": true]]
                    if let next, !next.isEmpty { body["cursor"] = next }
                    let page: PlaidSyncPage = try await post("/transactions/sync", body)
                    result.added += page.added
                    result.modified += page.modified
                    result.removed += page.removed
                    if let accounts = page.accounts { result.accounts = accounts }
                    result.updateStatus = page.transactionsUpdateStatus
                    next = page.nextCursor
                    result.cursor = page.nextCursor
                    if !page.hasMore { break }
                } while true
                return result
            } catch let error as PlaidError where error.errorCode == "TRANSACTIONS_SYNC_MUTATION_DURING_PAGINATION" && attempts < 3 {
                attempts += 1
            }
        }
    }

    public func removeItem(accessToken: String) async throws {
        let _: EmptyResponse = try await post("/item/remove", ["access_token": accessToken])
    }

    // MARK: Transport

    private struct EmptyResponse: Decodable {}

    private func post<Response: Decodable>(_ path: String, _ body: [String: Any]) async throws -> Response {
        var payload = body
        payload["client_id"] = credentials.clientID
        payload["secret"] = credentials.secret
        var request = URLRequest(url: credentials.environment.baseURL.appending(path: path))
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("2020-09-14", forHTTPHeaderField: "Plaid-Version")
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        let (data, response) = try await session.data(for: request)
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            if let error = try? decoder.decode(PlaidError.self, from: data), error.errorCode != nil { throw error }
            throw PlaidError(errorCode: "HTTP_\((response as? HTTPURLResponse)?.statusCode ?? 0)",
                             errorMessage: String(data: data, encoding: .utf8))
        }
        return try decoder.decode(Response.self, from: data)
    }
}
