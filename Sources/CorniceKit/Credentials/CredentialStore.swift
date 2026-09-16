import Foundation
import Security

/// Stores secrets. The only secret this app holds is a GitHub token.
///
/// A protocol so tests never touch the real Keychain: hitting the login
/// keychain from a test suite prompts for authorisation, leaves residue on the
/// developer's machine, and fails outright in CI where there is no unlocked
/// keychain.
public protocol CredentialStoring: Sendable {
    func store(_ secret: String, for account: String) async throws
    func read(account: String) async throws -> String?
    func delete(account: String) async throws
}

/// Keychain-backed credential storage.
///
/// Security decisions worth naming:
///
/// - `kSecClassGenericPassword` scoped to this app's service string, so the
///   token is not visible to other applications without user approval.
/// - `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`: readable by background
///   refreshes after the user has unlocked once, but never synced to iCloud and
///   never restored onto a different machine from a backup.
/// - Tokens are never logged. Where a log line must identify *which* credential
///   was involved, it logs `Redaction.fingerprint`, which is a one-way hash.
public actor KeychainCredentialStore: CredentialStoring {
    /// Keychain service string. Distinct per build configuration so a debug
    /// build cannot clobber the token belonging to a release install.
    private let service: String

    public init(service: String = "dev.cornice.app.credentials") {
        self.service = service
    }

    public func store(_ secret: String, for account: String) async throws {
        guard let data = secret.data(using: .utf8), !data.isEmpty else {
            throw ServiceError.invalidConfiguration(reason: "empty credential")
        }

        // Delete-then-add rather than SecItemUpdate: update fails when no item
        // exists yet, so this is one code path instead of two plus a race.
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)

        var attributes = query
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else {
            Log.keychain.error("SecItemAdd failed: \(status)")
            throw Self.error(for: status)
        }
        Log.keychain.notice(
            "stored credential \(Redaction.fingerprint(secret), privacy: .public) for \(account, privacy: .public)"
        )
    }

    public func read(account: String) async throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)

        switch status {
        case errSecSuccess:
            guard let data = item as? Data, let secret = String(data: data, encoding: .utf8) else {
                throw ServiceError.unreadableOutput(tool: "keychain", hint: "credential is not UTF-8")
            }
            return secret
        case errSecItemNotFound:
            // Not an error: the app simply has not been connected yet.
            return nil
        default:
            Log.keychain.error("SecItemCopyMatching failed: \(status)")
            throw Self.error(for: status)
        }
    }

    public func delete(account: String) async throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw Self.error(for: status)
        }
        Log.keychain.notice("deleted credential for \(account, privacy: .public)")
    }

    /// Maps an OSStatus to something a user can act on.
    private static func error(for status: OSStatus) -> ServiceError {
        switch status {
        case errSecUserCanceled, errSecAuthFailed, errSecInteractionNotAllowed:
            .unauthorized(detail: "Keychain access was denied. Unlock the login keychain and try again.")
        default:
            .unreadableOutput(
                tool: "keychain",
                hint: SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
            )
        }
    }
}

/// Non-persistent credential store for tests and previews.
public actor EphemeralCredentialStore: CredentialStoring {
    private var items: [String: String] = [:]

    public init(seed: [String: String] = [:]) { items = seed }

    public func store(_ secret: String, for account: String) async throws { items[account] = secret }
    public func read(account: String) async throws -> String? { items[account] }
    public func delete(account: String) async throws { items.removeValue(forKey: account) }
}
