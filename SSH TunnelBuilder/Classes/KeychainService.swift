// Copyright 2020-2026 Comraich ANS
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

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
    /// Default no-op: stores without OS-level credential protection (e.g. the
    /// mock used in tests) have no items to re-key. `KeychainService` overrides.
    func setCredentialProtection(enabled _: Bool, for _: [UUID]) {
        // Intentionally empty — no-op default for stores without OS-level protection.
    }

    /// Default: read each secret independently. Stores without OS-level
    /// authentication (e.g. the mock) don't prompt, so the context is ignored.
    /// `KeychainService` overrides this to read with the authenticated context.
    func loadCredentials(for id: UUID, authenticatedContext _: LAContext?) -> (password: String?, privateKey: String?) {
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
    private init() {
        // Singleton: prevent external instantiation. No initialization state to set up —
        // service identifier is a constant, and Keychain access is performed lazily.
    }

    private let service = "SSH Tunnel Manager"

    /// `UserDefaults` key backing the "require Touch ID / password to use saved
    /// credentials" setting. Shared with the `@AppStorage` binding in Settings.
    /// The toggle is enforced *app-side* by `ConnectionStore.authenticateForCredentialUse()`
    /// — Keychain items themselves are no longer gated with `.userPresence`
    /// because that flag prompts on every read regardless of `LAContext` state,
    /// which defeats the single-prompt-per-grace-window model the user expects.
    static let protectionEnabledKey = "RequireAuthForStoredCredentials"

    /// Default prompt shown when the OS asks the user to authenticate before a
    /// legacy `.userPresence`-protected credential is read during lazy migration.
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

    /// Reads each stored secret and re-saves it without the legacy `.userPresence`
    /// access control flag, using a single reusable `LAContext` so the migration
    /// authenticates at most once. After this runs every item is gated solely by
    /// the app-side `evaluatePolicy` check in `ConnectionStore`, which means a
    /// single Touch ID per grace window covers every connect/edit/export. Safe
    /// to call repeatedly: items already saved without access control just
    /// round-trip a re-save (cheap, idempotent).
    ///
    /// The `enabled` parameter is accepted for source compatibility with the
    /// old toggle-driven re-key call site but no longer affects how items are
    /// stored — they are always stored without `.userPresence`.
    func setCredentialProtection(enabled _: Bool, for ids: [UUID]) {
        let context = makeAuthContext(
            reason: "Authenticate to unlock your saved SSH credentials.",
            reuseDuration: 30
        )

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
        // Delete existing item first to avoid duplicates and to strip any legacy
        // `.userPresence` access-control attribute the item may have carried.
        deleteItem(account: account)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            // Items stay on this Mac and require login (no `.userPresence`):
            // the app-side `evaluatePolicy` gate in `ConnectionStore` is what
            // governs the Touch ID prompt, honoured once per grace window.
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        if status != errSecSuccess {
            Logger.error("Failed to save item for account '\(account)'. OSStatus: \(status)", log: Logger.keychain)
        }
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

    /// Reads a stored string. New items have no access-control flag so reads are
    /// silent. Legacy items saved under the previous `.userPresence` regime
    /// prompt the OS on read; on first successful read we transparently re-save
    /// them without the flag (lazy migration) so subsequent reads are silent.
    private func loadString(account: String, context: LAContext? = nil) -> String? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        if let context { query[kSecUseAuthenticationContext as String] = context }

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess,
              let dict = item as? [String: Any],
              let data = dict[kSecValueData as String] as? Data,
              let value = String(data: data, encoding: .utf8) else { return nil }

        // Lazy migration: items with `kSecAttrAccessControl` present in their
        // returned attributes are legacy `.userPresence`-protected items. Re-save
        // them without the flag now that we've successfully read the plaintext,
        // so future reads no longer trigger per-item OS prompts.
        if dict[kSecAttrAccessControl as String] != nil {
            saveString(value, account: account)
        }
        return value
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

