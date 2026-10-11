import Foundation

/// Plaid environments the user's own keys can target.
public enum PlaidEnvironment: String, Codable, Sendable, CaseIterable, Identifiable {
    case sandbox, production

    public var id: String { rawValue }
    public var baseURL: URL {
        switch self {
        case .sandbox: URL(string: "https://sandbox.plaid.com")!
        case .production: URL(string: "https://production.plaid.com")!
        }
    }
    public var title: String { self == .sandbox ? "Sandbox (test data)" : "Production (real banks)" }
}

/// The user's own Plaid API keys from dashboard.plaid.com → Developers → Keys.
public struct PlaidCredentials: Codable, Sendable, Equatable {
    public var clientID: String
    public var secret: String
    public var environment: PlaidEnvironment

    public init(clientID: String, secret: String, environment: PlaidEnvironment) {
        self.clientID = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        self.secret = secret.trimmingCharacters(in: .whitespacesAndNewlines)
        self.environment = environment
    }

    public var isComplete: Bool { !clientID.isEmpty && !secret.isEmpty }
}

public struct PlaidError: LocalizedError, Codable, Sendable, Equatable {
    public var errorType: String?
    public var errorCode: String?
    public var errorMessage: String?
    public var displayMessage: String?
    public var requestId: String?

    public init(errorType: String? = nil, errorCode: String? = nil, errorMessage: String? = nil,
                displayMessage: String? = nil, requestId: String? = nil) {
        self.errorType = errorType
        self.errorCode = errorCode
        self.errorMessage = errorMessage
        self.displayMessage = displayMessage
        self.requestId = requestId
    }

    /// The bank needs the user to sign in again through Link's update mode.
    public var needsReconnect: Bool {
        ["ITEM_LOGIN_REQUIRED", "PENDING_EXPIRATION", "PENDING_DISCONNECT", "ACCESS_NOT_GRANTED"].contains(errorCode ?? "")
    }

    public var errorDescription: String? {
        switch errorCode {
        case "INVALID_API_KEYS": "Plaid didn't accept these keys. Check the client ID, the secret, and that the secret matches the environment."
        case "ITEM_LOGIN_REQUIRED": "Your bank needs you to sign in again. Tap Reconnect."
        case "PRODUCT_NOT_READY": "Your bank is still preparing transactions. Try syncing again in a minute."
        case "ADDITION_LIMIT", "ITEM_LIMIT": "Your Plaid plan has no more free connections. Plaid's free Trial plan allows 10."
        default: displayMessage ?? errorMessage ?? "Plaid returned an error (\(errorCode ?? "unknown"))."
        }
    }
}

// MARK: - Responses

public struct PlaidLinkToken: Decodable, Sendable {
    public var linkToken: String
    public var hostedLinkUrl: String?
    public var expiration: String?
}

public struct PlaidLinkTokenStatus: Decodable, Sendable {
    public struct Institution: Decodable, Sendable { public var name: String?; public var institutionId: String? }
    public struct ItemAddResult: Decodable, Sendable {
        public var publicToken: String
        public var institution: Institution?
    }
    public struct Results: Decodable, Sendable { public var itemAddResults: [ItemAddResult]? }
    public struct OnSuccess: Decodable, Sendable {
        public struct Metadata: Decodable, Sendable { public var institution: Institution? }
        public var publicToken: String
        public var metadata: Metadata?
    }
    public struct Exit: Decodable, Sendable { public var error: PlaidError? }
    public struct Session: Decodable, Sendable {
        public var linkSessionId: String?
        public var finishedAt: String?
        public var results: Results?
        public var onSuccess: OnSuccess?
        public var exit: Exit?
    }
    public var linkSessions: [Session]?

    /// Every bank the user finished connecting in this Link session.
    public var completedItems: [ItemAddResult] {
        (linkSessions ?? []).flatMap { session -> [ItemAddResult] in
            if let results = session.results?.itemAddResults, !results.isEmpty { return results }
            if let success = session.onSuccess {
                return [ItemAddResult(publicToken: success.publicToken, institution: success.metadata?.institution)]
            }
            return []
        }
    }

    public var exitError: PlaidError? { linkSessions?.compactMap { $0.exit?.error }.first }
    /// The user closed Link (with or without an error) instead of finishing.
    public var didExit: Bool { (linkSessions ?? []).contains { $0.exit != nil } }
    public var hasSessions: Bool { !(linkSessions ?? []).isEmpty }
}

public struct PlaidTokenExchange: Decodable, Sendable {
    public var accessToken: String
    public var itemId: String
}

public struct PlaidAccount: Decodable, Sendable, Equatable {
    public struct Balances: Decodable, Sendable, Equatable {
        public var available: Decimal?
        public var current: Decimal?
        public var isoCurrencyCode: String?
    }
    public var accountId: String
    public var name: String
    public var officialName: String?
    public var mask: String?
    public var type: String
    public var subtype: String?
    public var balances: Balances
}

public struct PlaidItem: Decodable, Sendable {
    public var itemId: String
    public var institutionId: String?
    public var institutionName: String?
}

public struct PlaidAccountsResponse: Decodable, Sendable {
    public var accounts: [PlaidAccount]
    public var item: PlaidItem
}

public struct PlaidTransaction: Decodable, Sendable, Equatable {
    public struct Category: Decodable, Sendable, Equatable { public var primary: String?; public var detailed: String? }
    public var transactionId: String
    public var accountId: String
    /// Positive when money leaves the account, negative when it comes in.
    public var amount: Decimal
    public var isoCurrencyCode: String?
    public var date: String
    public var authorizedDate: String?
    public var name: String
    public var merchantName: String?
    public var pending: Bool
    public var pendingTransactionId: String?
    public var personalFinanceCategory: Category?
}

public struct PlaidRemovedTransaction: Decodable, Sendable, Equatable {
    public var transactionId: String
}

public struct PlaidSyncPage: Decodable, Sendable {
    public var added: [PlaidTransaction]
    public var modified: [PlaidTransaction]
    public var removed: [PlaidRemovedTransaction]
    public var nextCursor: String
    public var hasMore: Bool
    public var accounts: [PlaidAccount]?
    public var transactionsUpdateStatus: String?
}

/// Everything one sync produced, merged across pages.
public struct PlaidSyncResult: Sendable {
    public var added: [PlaidTransaction] = []
    public var modified: [PlaidTransaction] = []
    public var removed: [PlaidRemovedTransaction] = []
    public var accounts: [PlaidAccount] = []
    public var cursor: String?
    public var updateStatus: String?

    public init() {}
}
