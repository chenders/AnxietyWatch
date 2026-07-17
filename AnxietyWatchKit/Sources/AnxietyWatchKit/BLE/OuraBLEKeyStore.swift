import Foundation
import Security

// MARK: - OuraBLEKeyStore

/// Persistent storage for the 16-byte Oura Ring BLE shared key.
///
/// ## Background
/// The Oura Ring uses a 16-byte shared key generated at first pairing with
/// the official Oura app. Each connection performs an AES-ECB encrypted
/// nonce challenge using this key. There is no universal master key — each
/// ring-app pairing produces a unique key.
///
/// ## Key acquisition (all require user action — expert-only path)
/// - **Android:** Extract via ADB from the official app's encrypted DB.
/// - **iOS (jailbroken):** Extract from the Oura app sandbox.
/// - **BLE sniffing:** Capture during initial pairing with Ubertooth or
///   similar hardware.
/// - **Import:** This store supports importing a key from any of these
///   sources as a hex-encoded string or raw 16-byte `Data`.
///
/// ## Storage
/// Uses the system Keychain with `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`.
/// The key never leaves the device and is never included in backups.
///
/// ## Single-client contention
/// The ring can only serve one BLE client at a time. If the official Oura
/// app is connected, the custom client will fail to connect. The user must
/// force-kill the official app before using AnxietyWatch's BLE connection.
public struct OuraBLEKeyStore: Sendable {

    // MARK: - Keychain config

    private let service: String
    private let account: String

    public init(service: String = "com.anxietywatch.oura.ble",
                account: String = "shared_key") {
        self.service = service
        self.account = account
    }

    // MARK: - Read / Write / Delete

    /// Read the stored 16-byte key, or `nil` if not yet provisioned.
    public func read() throws -> Data? {
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

        guard status == errSecSuccess, let data = item as? Data else {
            if status == errSecItemNotFound { return nil }
            throw OuraBLEKeyStoreError.keychainError(status: status)
        }

        return data
    }

    /// Store a 16-byte shared key. Validates length before persisting.
    public func write(_ key: Data) throws {
        guard key.count == OuraBLEProtocol.sharedKeyLength else {
            throw OuraBLEKeyStoreError.invalidKeyLength(key.count)
        }

        // Update existing or create new
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
        ]

        let attrs: [CFString: Any] = [
            kSecValueData: key,
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]

        var status = SecItemUpdate(query as CFDictionary, attrs as CFDictionary)

        if status == errSecItemNotFound {
            var createQuery = query
            createQuery[kSecValueData] = key
            createQuery[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = SecItemAdd(createQuery as CFDictionary, nil)
        }

        guard status == errSecSuccess else {
            throw OuraBLEKeyStoreError.keychainError(status: status)
        }
    }

    /// Import a hex-encoded key string (32 hex chars → 16 bytes).
    /// Accepts uppercase, lowercase, and optional "0x" prefix.
    public func importHex(_ hex: String) throws {
        var cleaned = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.hasPrefix("0x") || cleaned.hasPrefix("0X") {
            cleaned = String(cleaned.dropFirst(2))
        }

        guard cleaned.count == OuraBLEProtocol.sharedKeyLength * 2 else {
            throw OuraBLEKeyStoreError.invalidHexLength(cleaned.count)
        }

        var bytes = Data()
        var index = cleaned.startIndex
        while index < cleaned.endIndex {
            let next = cleaned.index(index, offsetBy: 2)
            guard let byte = UInt8(cleaned[index ..< next], radix: 16) else {
                throw OuraBLEKeyStoreError.invalidHexCharacters
            }
            bytes.append(byte)
            index = next
        }

        try write(bytes)
    }

    /// Remove the stored key.
    public func delete() throws {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw OuraBLEKeyStoreError.keychainError(status: status)
        }
    }

    /// Returns `true` if a key is currently stored.
    public var isProvisioned: Bool {
        (try? read()) != nil
    }
}

// MARK: - Errors

public enum OuraBLEKeyStoreError: Error, Equatable {
    case keychainError(status: OSStatus)
    case invalidKeyLength(Int)
    case invalidHexLength(Int)
    case invalidHexCharacters
}
