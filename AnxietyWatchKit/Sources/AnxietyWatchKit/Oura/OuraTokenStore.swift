import Foundation
import Security

// MARK: - OuraTokenStore

/// Persistent OAuth2 token storage backed by the system Keychain.
///
/// Stores the Oura Ring API access token, refresh token, and expiry.
/// Keychain item uses `kSecClassGenericPassword` scoped to this app's
/// keychain access group, with `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`
/// so it's available shortly after boot but never leaves the device.
public struct OuraTokenStore: Sendable {

    public struct Token: Sendable, Equatable, Codable {
        public var accessToken: String
        public var refreshToken: String
        public var expiresAt: Date
        public var tokenType: String   // typically "Bearer"

        public init(accessToken: String, refreshToken: String,
                    expiresAt: Date, tokenType: String = "Bearer") {
            self.accessToken = accessToken
            self.refreshToken = refreshToken
            self.expiresAt = expiresAt
            self.tokenType = tokenType
        }

        public var isExpired: Bool {
            Date() >= expiresAt.addingTimeInterval(-60) // 60 s grace
        }
    }

    private let service: String
    private let account: String

    public init(service: String = "com.anxietywatch.oura",
                account: String = "oauth2") {
        self.service = service
        self.account = account
    }

    // MARK: - Read / Write

    public func read() throws -> Token? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)

        guard status == errSecSuccess,
              let data = item as? Data else {
            if status == errSecItemNotFound { return nil }
            throw OuraTokenStoreError.keychainError(status: status)
        }

        return try JSONDecoder().decode(Token.self, from: data)
    }

    public func write(_ token: Token) throws {
        let encoded = try JSONEncoder().encode(token)

        // First try to update an existing item
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
        ]

        let attrs: [CFString: Any] = [
            kSecValueData: encoded,
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]

        var status = SecItemUpdate(query as CFDictionary, attrs as CFDictionary)

        if status == errSecItemNotFound {
            // Create new item
            var createQuery = query
            createQuery[kSecValueData] = encoded
            createQuery[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = SecItemAdd(createQuery as CFDictionary, nil)
        }

        guard status == errSecSuccess else {
            throw OuraTokenStoreError.keychainError(status: status)
        }
    }

    public func delete() throws {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw OuraTokenStoreError.keychainError(status: status)
        }
    }
}

public enum OuraTokenStoreError: Error, Equatable {
    case keychainError(status: OSStatus)
}
