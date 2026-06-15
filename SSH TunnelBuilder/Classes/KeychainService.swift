import Foundation
import Security

// MARK: - Protocol

protocol CredentialsStore {
    func savePassword(_ password: String, for id: UUID)
    func savePrivateKey(_ key: String, for id: UUID)
    func loadPassword(for id: UUID) -> String?
    func loadPrivateKey(for id: UUID) -> String?
    func deleteCredentials(for id: UUID)
}

// MARK: - Keychain Implementation

final class KeychainService: CredentialsStore, Sendable {
    static let shared = KeychainService()
    private init() {}

    private let service = "SSH Tunnel Manager"

    // MARK: - Public API

    func savePassword(_ password: String, for id: UUID) {
        saveString(password, account: "password:\(id.uuidString)")
    }

    func savePrivateKey(_ key: String, for id: UUID) {
        saveString(key, account: "privateKey:\(id.uuidString)")
    }

    func loadPassword(for id: UUID) -> String? {
        loadString(account: "password:\(id.uuidString)")
    }

    func loadPrivateKey(for id: UUID) -> String? {
        loadString(account: "privateKey:\(id.uuidString)")
    }

    func deleteCredentials(for id: UUID) {
        deleteItem(account: "password:\(id.uuidString)")
        deleteItem(account: "privateKey:\(id.uuidString)")
    }

    // MARK: - Low-level helpers

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
        storage["password:\(id.uuidString)"] = password
    }
    
    func savePrivateKey(_ key: String, for id: UUID) {
        storage["privateKey:\(id.uuidString)"] = key
    }
    
    func loadPassword(for id: UUID) -> String? {
        storage["password:\(id.uuidString)"]
    }
    
    func loadPrivateKey(for id: UUID) -> String? {
        storage["privateKey:\(id.uuidString)"]
    }
    
    func deleteCredentials(for id: UUID) {
        storage.removeValue(forKey: "password:\(id.uuidString)")
        storage.removeValue(forKey: "privateKey:\(id.uuidString)")
    }
}

