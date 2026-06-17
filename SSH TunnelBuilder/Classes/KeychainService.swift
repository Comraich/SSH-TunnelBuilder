import Foundation
import Security
import LocalAuthentication

// MARK: - Protocol

protocol CredentialsStore {
    func savePassword(_ password: String, for id: UUID)
    func savePrivateKey(_ key: String, for id: UUID)
    func loadPassword(for id: UUID) -> String?
    func loadPrivateKey(for id: UUID) -> String?

    /// Loads both stored secrets for `id` in one call. Pass an `authenticatedContext`
    /// that the caller has *already* authenticated via `LAContext.evaluatePolicy`
    /// so these reads reuse that single authentication instead of prompting per
    /// secret (Keychain-level reuse alone does not suppress per-read prompts).
    /// Declared on the protocol (not just an extension) so the real Keychain
    /// implementation is reached through the protocol-typed store.
    func loadCredentials(for id: UUID, authenticatedContext: LAContext?) -> (password: String?, privateKey: String?)

    func deleteCredentials(for id: UUID)

    /// Whether a password is stored for `id`, checked *without* reading the
    /// secret value. Lets the UI know credentials exist without holding them in
    /// memory (and, once items are access-control protected, without prompting).
    func hasPassword(for id: UUID) -> Bool
    /// Whether a private key is stored for `id`. See `hasPassword(for:)`.
    func hasPrivateKey(for id: UUID) -> Bool

    /// Re-saves the stored credentials for the given connection ids so they
    /// match the current protection preference (access-control on/off). Called
    /// when the user toggles the "require authentication" setting. Stores that
    /// don't support OS-level protection (e.g. the mock) can ignore this.
    func setCredentialProtection(enabled: Bool, for ids: [UUID])
}

extension CredentialsStore {
    func setCredentialProtection(enabled: Bool, for ids: [UUID]) {}

    /// Default: read each secret independently. Stores without OS-level
    /// authentication (e.g. the mock) don't prompt, so the context is ignored.
    /// `KeychainService` overrides this to read with the authenticated context.
    func loadCredentials(for id: UUID, authenticatedContext: LAContext?) -> (password: String?, privateKey: String?) {
        (loadPassword(for: id), loadPrivateKey(for: id))
    }
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

    /// `UserDefaults` key backing the "require Touch ID / password to use saved
    /// credentials" setting. Shared with the `@AppStorage` binding in Settings.
    static let protectionEnabledKey = "RequireAuthForStoredCredentials"

    /// Whether stored credentials should be protected by user-presence
    /// (Touch ID / password). Read fresh on each save so a toggle takes effect
    /// immediately for subsequently re-keyed items.
    private var isProtectionEnabled: Bool {
        UserDefaults.standard.bool(forKey: Self.protectionEnabledKey)
    }

    /// Default prompt shown when the OS asks the user to authenticate before a
    /// protected credential is read.
    private static let useReason = "Authenticate to use your saved SSH credentials."

    // MARK: - Public API

    func savePassword(_ password: String, for id: UUID) {
        saveString(password, account: CredentialAccount.password(for: id))
    }

    func savePrivateKey(_ key: String, for id: UUID) {
        saveString(key, account: CredentialAccount.privateKey(for: id))
    }

    func loadPassword(for id: UUID) -> String? {
        loadString(account: CredentialAccount.password(for: id), context: makeAuthContext(reason: Self.useReason))
    }

    func loadPrivateKey(for id: UUID) -> String? {
        loadString(account: CredentialAccount.privateKey(for: id), context: makeAuthContext(reason: Self.useReason))
    }

    func loadCredentials(for id: UUID, authenticatedContext: LAContext?) -> (password: String?, privateKey: String?) {
        // Reuse the caller's already-authenticated context so neither read
        // re-prompts. If none is supplied (protection off), a fresh context is
        // harmless: unprotected items never prompt.
        let context = authenticatedContext ?? makeAuthContext(reason: Self.useReason)
        let password = loadString(account: CredentialAccount.password(for: id), context: context)
        let privateKey = loadString(account: CredentialAccount.privateKey(for: id), context: context)
        return (password, privateKey)
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

    /// Re-saves every stored secret so its Keychain protection matches the
    /// current `isProtectionEnabled` preference. A single `LAContext` is reused
    /// across the batch so disabling protection (which must *read* the currently
    /// protected items) prompts the user only once.
    func setCredentialProtection(enabled: Bool, for ids: [UUID]) {
        let reason = enabled
            ? "Authenticate to protect your saved SSH credentials with Touch ID or your password."
            : "Authenticate to remove Touch ID / password protection from your saved SSH credentials."
        // One reusable context so the whole re-key pass authenticates at most once.
        let context = makeAuthContext(reason: reason, reuseDuration: 30)

        for id in ids {
            let pwAccount = CredentialAccount.password(for: id)
            if let password = loadString(account: pwAccount, context: context) {
                saveString(password, account: pwAccount)
            }
            let keyAccount = CredentialAccount.privateKey(for: id)
            if let key = loadString(account: keyAccount, context: context) {
                saveString(key, account: keyAccount)
            }
        }
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

        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data
        ]
        // When protection is enabled, gate reads behind user presence
        // (Touch ID / password). `kSecAttrAccessControl` and `kSecAttrAccessible`
        // are mutually exclusive, so set exactly one.
        if isProtectionEnabled, let accessControl = makeUserPresenceAccessControl() {
            query[kSecAttrAccessControl as String] = accessControl
        } else {
            query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        }
        let status = SecItemAdd(query as CFDictionary, nil)
        if status != errSecSuccess {
            Logger.error("Failed to save item for account '\(account)'. OSStatus: \(status)", log: Logger.keychain)
        }
    }

    /// Builds a user-presence access-control object: the item can only be read
    /// after the user authenticates with Touch ID or their login password
    /// (`.userPresence`), and never leaves this device.
    private func makeUserPresenceAccessControl() -> SecAccessControl? {
        var error: Unmanaged<CFError>?
        let accessControl = SecAccessControlCreateWithFlags(
            nil,
            kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            .userPresence,
            &error
        )
        if let error = error?.takeRetainedValue() {
            Logger.error("Failed to create Keychain access control: \(error)", log: Logger.keychain)
            return nil
        }
        return accessControl
    }

    /// Builds an `LAContext` carrying the prompt text shown when the OS asks the
    /// user to authenticate. Passed to the Keychain via `kSecUseAuthenticationContext`
    /// (the supported replacement for the deprecated `kSecUseOperationPrompt`).
    /// A non-zero `reuseDuration` lets several reads share one authentication.
    private func makeAuthContext(reason: String, reuseDuration: TimeInterval = 0) -> LAContext {
        let context = LAContext()
        context.localizedReason = reason
        context.touchIDAuthenticationAllowableReuseDuration = reuseDuration
        return context
    }

    /// Reads a stored string. For access-control-protected items the OS presents
    /// an authentication prompt (using `context.localizedReason`); a shared
    /// `context` lets a batch authenticate once. Unprotected items never prompt.
    private func loadString(account: String, context: LAContext? = nil) -> String? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        if let context { query[kSecUseAuthenticationContext as String] = context }

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

