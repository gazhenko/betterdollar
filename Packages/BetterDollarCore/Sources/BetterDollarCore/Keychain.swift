import Foundation
import Security

/// Secrets (Plaid keys and bank access tokens) live only in this device's Keychain.
/// They are never synced to iCloud Keychain and are excluded from device backups.
public struct Keychain: Sendable {
    public let service: String

    public init(service: String = "dev.gazhenko.betterdollar") { self.service = service }

    public func string(_ key: String) -> String? {
        var query = base(key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    public func set(_ value: String?, for key: String) -> Bool {
        guard let value else { return remove(key) }
        let data = Data(value.utf8)
        let update = SecItemUpdate(base(key) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecSuccess { return true }
        var query = base(key)
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(query as CFDictionary, nil) == errSecSuccess
    }

    @discardableResult
    public func remove(_ key: String) -> Bool {
        let status = SecItemDelete(base(key) as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    public func removeAll() {
        SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service] as CFDictionary)
    }

    private func base(_ key: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: key,
         kSecAttrSynchronizable as String: false]
    }
}

/// Typed access to the Plaid secrets stored in the Keychain.
public struct PlaidVault: Sendable {
    public let keychain: Keychain

    public init(keychain: Keychain = Keychain()) { self.keychain = keychain }

    public var credentials: PlaidCredentials? {
        guard let id = keychain.string("plaid.client_id"), let secret = keychain.string("plaid.secret") else { return nil }
        let environment = keychain.string("plaid.environment").flatMap(PlaidEnvironment.init(rawValue:)) ?? .sandbox
        return PlaidCredentials(clientID: id, secret: secret, environment: environment)
    }

    public func save(_ credentials: PlaidCredentials?) {
        keychain.set(credentials?.clientID, for: "plaid.client_id")
        keychain.set(credentials?.secret, for: "plaid.secret")
        keychain.set(credentials?.environment.rawValue, for: "plaid.environment")
    }

    public func accessToken(itemID: String) -> String? { keychain.string("plaid.access.\(itemID)") }
    public func setAccessToken(_ token: String?, itemID: String) { keychain.set(token, for: "plaid.access.\(itemID)") }

    /// A random per-install id sent to Plaid as `client_user_id` (never anything personal).
    public var userID: String {
        if let id = keychain.string("plaid.user_id") { return id }
        let id = UUID().uuidString
        keychain.set(id, for: "plaid.user_id")
        return id
    }
}
