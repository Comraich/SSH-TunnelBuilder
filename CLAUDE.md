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

### 2026-02-06: Error Alert Implementation

**Issue**: Errors were only logged to console, not shown to users in alert dialogs

**Root Cause**: Standard SwiftUI `.alert()` modifiers were not reliably presenting on macOS

**Fixed**:
- Added `errorCallback` property to `SSHManager` to propagate errors to UI
- Wired up `errorCallback` in `ConnectionStore.connect()` to call `showError()`
- Updated all critical error paths in `SSHManager` to invoke `errorCallback`:
  - Key parsing failures (`FlexibleAuthDelegate` initialization)
  - Missing credentials errors
  - Forwarding channel setup failures
  - Local port bind failures
  - Connection initialization errors
- **Replaced invisible `.alert()` with visible `.sheet()` presentation**:
  - Created `ErrorSheetView` with large red warning icon
  - Used `.onChange(of: errorAlert)` to detect errors and show sheet
  - Sheet is modal and impossible to miss (vs. alerts which could be invisible)
- Made `ErrorAlert` conform to `Equatable` for `.onChange()` compatibility

**Files Modified**:
- `SSHManager.swift:474` - Added `errorCallback` property
- `SSHManager.swift:509-521` - Captured errorCallback outside Task.detached to ensure availability
- `SSHManager.swift:525-536` - Made initialization errors fatal (throw immediately)
- `SSHManager.swift:540,603,732` - Added `errorCallback` invocations
- `SSHManager.swift:697-702` - Added error reporting for forwarding channel failures
- `ConnectionStore.swift:20-26` - Made `ErrorAlert` conform to `Equatable`
- `ConnectionStore.swift:159` - Simplified `showError()` implementation
- `ConnectionStore.swift:191-196` - Configured `errorCallback` in `connect()`
- `ConnectionStore.swift:203-210` - Enhanced catch block with proper MainActor handling
- `ContentView.swift:45-53` - Added `.onChange()` to detect errors and trigger sheet
- `ContentView.swift:54-56` - Added `.sheet()` to present error modal
- `ContentView.swift:75-98` - Created `ErrorSheetView` with visible error UI

### 2026-02-06: CloudKit Query Fix

**Issue**: CloudKit error on app launch: "Field 'recordName' is not marked queryable"

**Root Cause**: CKQuery with sortDescriptors requires fields to be marked as queryable in CloudKit schema. Using sortDescriptors on custom fields or recordName can fail if indexes aren't configured.

**Fixed**:
- Removed `query.sortDescriptors` from CloudKit fetch operations
- Added in-memory sorting after all connections are fetched: `connections.sort { ... }`
- Uses `localizedCaseInsensitiveCompare` for proper alphabetical sorting

**Files Modified**:
- `ConnectionStore.swift:272-274` - Removed sortDescriptors from CKQuery
- `ConnectionStore.swift:337-338` - Added in-memory sorting after fetch completes

---

## Swift API Modernization (2026-06-15)

Full details and per-task notes live in [`MODERNIZATION_ROADMAP.md`](MODERNIZATION_ROADMAP.md).
Each task ships on its own branch off `Development` with its own PR. Listed in
priority order (impact, high → low):

All eight tasks are merged into `Development`:

- [x] **1. Adopt Observation framework (`@Observable`)** — `refactor/observable-macro` — *High* — merged (PR #43)
- [x] **2. Native async CloudKit APIs** — `refactor/cloudkit-async-apis` — *High* — merged (PR #42), using `recordZoneChanges(inZoneWith:since:)` (kept the zone-changes approach to avoid the queryable-index bug)
- [x] **3. `Task.sleep(for:)` with `Duration`** — `refactor/task-sleep-duration` — *Medium* — merged (PR #35)
- [x] **4. `@Entry` macro for environment key** — `refactor/entry-macro-environment` — *Medium* — merged (PR #36)
- [x] **5. `ByteCountFormatStyle` (`.formatted`)** — `refactor/bytecount-format-style` — *Medium* — merged (PR #38)
- [x] **6. Replace `DispatchQueue.main.asyncAfter`** — `refactor/async-error-clear` — *Low* — merged (PR #39)
- [x] **7. NIO singleton event-loop group** — `refactor/nio-singleton-eventloop` — *Low* — merged (PR #41)
- [x] **8. Remove dead `connection` environment value** — `refactor/remove-dead-connection-env` — *Low (cleanup)* — merged (PR #40)

---

## Known Issues

### Test suite cannot run reliably on the macOS 26/27 beta toolchain (2026-06-15)

**Symptom:** Running the test bundle crashes the test host in Swift Testing's
`Runner._applyScopingTraits(for:testCase:_:)`. With the default (parallel)
configuration *no* tests run at all — every suite reports
`Crash: ... Runner._applyScopingTraits` before any test body executes, and the
host hits "Exceeded max restart count". No `.ips` crash report is produced.

**Diagnosis:** This is a Swift Testing **runtime** bug in the current
Xcode-beta / macOS 27.0 (26A5353q) toolchain, not a defect in the test code or
target configuration:
- The test code is plain, idiomatic Swift Testing (no custom/scoping traits).
- The test target settings are standard (`SWIFT_DEFAULT_ACTOR_ISOLATION = nonisolated`, Swift 6, hosted by the app).
- It reproduces on a clean `Development` checkout, independent of the `@Observable`/CloudKit modernization work.
- Behaviour scales with concurrency: 1–6 tests run fine in isolation; the full 30-test run crashes. It is also non-deterministic — the crashing test moves between runs.

**Attempted workarounds (not adopted):** Serializing every suite (`.serialized`
roots) plus disabling `SWIFT_APPROACHABLE_CONCURRENCY` on the test target raised
the pass count from 0 to ~20–28/30, but runs still aborted non-deterministically
partway through. We chose **not** to ship a flaky partial workaround. A couple of
P256 EC-key-parsing `AuthDelegate` tests also appear to crash in isolation —
possibly a genuine parser bug, but it's entangled with the runtime instability
and can't be cleanly isolated while the runner itself is unstable.

**Action:** Revisit when the Xcode/macOS toolchain updates (re-run the full
suite; if it's green by default, this entry can be removed). If the EC-parsing
tests still crash once the runner is stable, investigate
`FlexibleAuthDelegate.parsePrivateKey` / `PEMDecryptor` for the `EC PRIVATE KEY`
(SEC1) path as a separate bug.
