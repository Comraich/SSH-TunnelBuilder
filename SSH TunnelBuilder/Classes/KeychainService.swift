import Foundation
import Security

// MARK: - Protocol

protocol CredentialsStore {
    func savePassword(_ password: String, for id: UUID)
    func savePrivateKey(_ key: String, for id: UUID)
    func loadPassword(for id: UUID) -> String?
    func loadPrivateKey(for id: UUID) -> String?
    func deleteCredentials(for id: UUID)

    /// Whether a password is stored for `id`, checked *without* reading the
    /// secret value. Lets the UI know credentials exist without holding them in
    /// memory (and, once items are access-control protected, without prompting).
    func hasPassword(for id: UUID) -> Bool
    /// Whether a private key is stored for `id`. See `hasPassword(for:)`.
    func hasPrivateKey(for id: UUID) -> Bool
}

// MARK: - Account Keys

/// Single source of truth for the account strings under which credentials are
/// stored. Shared by the real and mock stores so their key formats can't drift.
enum CredentialAccount {
    static func password(for id: UUID) -> String { "password:\(id.uuidString)" }
    static func privateKey(for id: UUID) -> String { "privateKey:\(id.uuidString)" }
}

// MARK: - Keychain Implementation

final class KeychainService: CredentialsStore, Sendable {
    static let shared = KeychainService()
    private init() {}

    private let service = "SSH Tunnel Manager"

    // MARK: - Public API

    func savePassword(_ password: String, for id: UUID) {
        saveString(password, account: CredentialAccount.password(for: id))
    }

    func savePrivateKey(_ key: String, for id: UUID) {
        saveString(key, account: CredentialAccount.privateKey(for: id))
    }

    func loadPassword(for id: UUID) -> String? {
        loadString(account: CredentialAccount.password(for: id))
    }

    func loadPrivateKey(for id: UUID) -> String? {
        loadString(account: CredentialAccount.privateKey(for: id))
    }

    func deleteCredentials(for id: UUID) {
        deleteItem(account: CredentialAccount.password(for: id))
        deleteItem(account: CredentialAccount.privateKey(for: id))
    }

    func hasPassword(for id: UUID) -> Bool {
        containsItem(account: CredentialAccount.password(for: id))
    }

    func hasPrivateKey(for id: UUID) -> Bool {
        containsItem(account: CredentialAccount.privateKey(for: id))
    }

    // MARK: - Low-level helpers

    /// Existence check that queries for a match without requesting the item's
    /// data. Reading attributes (not `kSecValueData`) never triggers an
    /// authentication prompt, even for access-control-protected items.
    private func containsItem(account: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: false,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    private func saveString(_ string: String, account: String) {
        guard let data = string.data(using: .utf8) else { return }
        // Delete existing item first to avoid duplicates
        deleteItem(account: account)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        if status != errSecSuccess {
            Logger.error("Failed to save item for account '\(account)'. OSStatus: \(status)", log: Logger.keychain)
        }
    }

    private func loadString(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func deleteItem(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }
}
// MARK: - Mock Implementation for Testing

final class MockCredentialsStore: CredentialsStore {
    private var storage: [String: String] = [:]
    
    func savePassword(_ password: String, for id: UUID) {
        storage[CredentialAccount.password(for: id)] = password
    }

    func savePrivateKey(_ key: String, for id: UUID) {
        storage[CredentialAccount.privateKey(for: id)] = key
    }

    func loadPassword(for id: UUID) -> String? {
        storage[CredentialAccount.password(for: id)]
    }

    func loadPrivateKey(for id: UUID) -> String? {
        storage[CredentialAccount.privateKey(for: id)]
    }

    func deleteCredentials(for id: UUID) {
        storage.removeValue(forKey: CredentialAccount.password(for: id))
        storage.removeValue(forKey: CredentialAccount.privateKey(for: id))
    }

    func hasPassword(for id: UUID) -> Bool {
        storage[CredentialAccount.password(for: id)]?.isEmpty == false
    }

    func hasPrivateKey(for id: UUID) -> Bool {
        storage[CredentialAccount.privateKey(for: id)]?.isEmpty == false
    }
}

