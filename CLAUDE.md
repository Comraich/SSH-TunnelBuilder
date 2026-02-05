# SSH TunnelBuilder - Project Notes

## Build & Run
- macOS 14+ required
- Open `SSH TunnelBuilder.xcodeproj` or workspace
- Dependencies: SwiftNIO, NIOSSH (via Swift Package Manager)

## Git Workflow
- **Development branch is protected** - never push directly
- Create feature branches for all changes: `git checkout -b feature/description`
- Push feature branch and create PR to merge into Development
- Branch naming: `feature/...`, `fix/...`, `refactor/...`

## Architecture Overview
- **Connection.swift**: Data model with `@MainActor` isolation
- **ConnectionStore.swift**: CloudKit sync + Keychain + SSHManager lifecycle
- **KeychainService.swift**: Secure credential storage with protocol for testing
- **SSHManager.swift**: NIO-based SSH client with tunneling
- **PEMDecryptor.swift**: PKCS#8 key decryption with PBKDF2

---

## Code Review Issues (2026-02-05)

### Critical

- [x] **Race condition in shutdown()** - `SSHManager.swift:767-778`
  - `sessionReadyPromise` and `sessionReadyCompleted` are set outside the lock
  - Fixed: Moved assignments inside `lock.withLock { }` block

- [x] **Unchecked SecItemAdd result** - `KeychainService.swift:59`
  - `SecItemAdd()` result is ignored, silent failure if Keychain unavailable
  - Fixed: Now checks status and logs error with OSStatus code

### High Priority

- [x] **Duplicate import** - `MainView.swift:1-2`
  - `import SwiftUI` appeared twice
  - Fixed: Removed duplicate line

- [x] **Port validation missing** - `SSHManager.swift:658-667`
  - `Int(tunnelInfo.localPort) ?? 0` silently converted invalid strings to port 0
  - Fixed: Now validates port is 1-65535, throws `SSHConnectionError.tunnelSetupFailed` with clear message

- [x] **Integer overflow in ASN.1 parser** - `PEMDecryptor.swift:413-424`
  - `readInteger()` could overflow on large ASN.1 integers (> 8 bytes)
  - Fixed: Now validates length <= 8 bytes before parsing

### Medium Priority

- [x] **Hardcoded connection timeout** - `SSHManager.swift:465,562`
  - 10-second timeout was hardcoded
  - Fixed: Added `static var connectionTimeoutSeconds: Int64 = 10` for configurability

- [x] **Host key serialization stub** - `SSHManager.swift:655-660`
  - `serialize(key:)` always returns nil
  - Fixed: Updated comments to accurately explain NIOSSH limitation and fingerprint fallback

- [x] **Passphrase not persisted** - `MainView.swift:664-665`
  - `privateKeyPassphrase` is not saved long-term (by design)
  - Fixed: Added note to UI: "Passphrases are never saved and must be re-entered each time."

### Low Priority / Code Quality

- [x] **Typo in comment** - `Connection.swift:54`
  - "Identifiable comfirmity" was wrong on two counts
  - Fixed: Changed to "Equatable conformity" (correct protocol and spelling)

- [x] **Unused function** - `MainView.swift:746-750`
  - `isValidPEMPrivateKey(_:)` was defined but never called
  - Fixed: Removed the unused function

- [x] **Magic numbers in ASN.1 parser** - `PEMDecryptor.swift:283,322`
  - Hardcoded `count <= 4` for length bytes
  - Fixed: Added `private static let maxLengthBytes = 4` with documentation

- [x] **Print statements in production** - Throughout codebase
  - Multiple `print()` calls replaced with `os.log` via new `Logger.swift`
  - Fixed: Created `Logger` enum with categories (ssh, keychain, cloudKit, crypto)

- [x] **Inconsistent error types** - Throughout codebase
  - Mix of `NSError`, custom enums, thrown errors
  - Fixed: Created `SSHTunnelError` enum consolidating all error cases
  - Replaced all `NSError(domain:...)` with typed errors

### Architecture Suggestions

- [x] **Connection state machine**
  - Replaced `isActive`/`isConnecting` booleans with `ConnectionState` enum
  - States: `.idle`, `.connecting`, `.connected`, `.disconnecting`, `.failed(String)`
  - Computed `isActive`/`isConnecting` properties for backward compatibility
  - Updated `ConnectionIndicatorView` to show all states with appropriate colors/spinners

- [x] **Dependency injection for KeychainService**
  - Current: `ConnectionStore` used `KeychainService.shared` directly
  - Fixed: Now accepts `CredentialsStore` via init (defaults to `KeychainService.shared`)
  - Test init defaults to `MockCredentialsStore()` for isolated testing

- [x] **OpenSSH Ed25519 support status**
  - Investigated: Ed25519 IS supported via `NIOSSHPrivateKey(openSSHEd25519PrivateKeyBlob:)`
  - The limitation is encrypted OpenSSH keys, not Ed25519 itself
  - Fixed: Updated UI to accurately show supported formats:
    - Supported: Ed25519, ECDSA (OpenSSH unencrypted, PKCS#8, EC PRIVATE KEY)
    - Not supported: RSA, DSA, encrypted OpenSSH keys
  - Removed misleading `.ed25519` PEMKeyKind case (Ed25519 uses OpenSSH format)

### Test Coverage Gaps

- [ ] `SSHManager` connect/disconnect flows
- [ ] CloudKit operations (mock `CKDatabase`)
- [ ] PEM decryption with various key types
- [ ] Error paths in `ConnectionStore`

---

## Session Notes

_Add notes here during development sessions_
