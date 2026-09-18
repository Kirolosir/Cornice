import Foundation
import Security

/// Where the refresh token lives.
///
/// The refresh token is the only durable secret Cornice holds: it is worth more
/// than an access token, because it mints them. It goes in the Keychain rather
/// than in preferences, with
/// `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`. Readable by a background
/// app after the Mac has been unlocked once, and never carried to another
/// machine by a backup or by iCloud.
///
/// The client ID is *not* stored here. Under PKCE it is a public identifier,
/// not a credential, so it lives in preferences where the user can see and
/// change it.
public protocol SpotifyTokenStoring: Sendable {
    func loadRefreshToken() -> String?
    func save(refreshToken: String)
    func clear()
}

public struct KeychainTokenStore: SpotifyTokenStoring {

    private let service: String
    private let account: String

    public init(service: String = "dev.cornice.app.spotify", account: String = "refresh-token") {
        self.service = service
        self.account = account
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    public func loadRefreshToken() -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public func save(refreshToken: String) {
        let data = Data(refreshToken.utf8)
        // Update in place when an item already exists; SecItemAdd would fail
        // with errSecDuplicateItem rather than overwrite.
        let attributes: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(baseQuery as CFDictionary, attributes as CFDictionary)
        guard status == errSecItemNotFound else { return }

        var insert = baseQuery
        insert[kSecValueData as String] = data
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(insert as CFDictionary, nil)
    }

    public func clear() {
        SecItemDelete(baseQuery as CFDictionary)
    }
}

/// An in-memory store, for tests and for probes that must not touch the real
/// Keychain.
public final class EphemeralTokenStore: SpotifyTokenStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var token: String?

    public init(token: String? = nil) { self.token = token }

    public func loadRefreshToken() -> String? {
        lock.withLock { token }
    }

    public func save(refreshToken: String) {
        lock.withLock { token = refreshToken }
    }

    public func clear() {
        lock.withLock { token = nil }
    }
}
