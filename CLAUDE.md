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
- **BcryptPBKDF.swift**: Blowfish + `bcrypt_pbkdf` (from scratch; not in CryptoKit), used to key OpenSSH key decryption
- **OpenSSHKeyDecryptor.swift**: decrypts encrypted `openssh-key-v1` private sections (AES-CTR/CBC/GCM)

## Private key support

NIOSSH 0.13.0 can only use **Ed25519** and **ECDSA P-256/384/521** — its
`NIOSSHPrivateKey` is a closed type with no public custom-key API, so the app can
only ever feed it those algorithms. **RSA and DSA are impossible to add in-app**:
they require new signature algorithms negotiated/signed/encoded *inside* NIOSSH
(RSA would need an upstream contribution or a fork; DSA is obsolete — removed in
OpenSSH 10.0 — and should not be added anywhere). Anything that is just *parsing*
a supported algorithm into a CryptoKit key, however, belongs in the app.

Supported private-key formats (all for Ed25519 / ECDSA only):

| Format | Plain | Encrypted |
|---|---|---|
| OpenSSH (`openssh-key-v1`) | ✅ | ✅ bcrypt + aes128/192/256 ctr/cbc/gcm |
| PKCS#8 (`BEGIN PRIVATE KEY`) | ✅ (EC + Ed25519) | ✅ EC + Ed25519, PBES2/PBKDF2-SHA256/AES-256-CBC |
| SEC1 (`BEGIN EC PRIVATE KEY`) | ✅ | — |

Known gaps (not yet implemented): the `chacha20-poly1305@openssh.com` and
`3des-cbc` OpenSSH ciphers (chacha20 is a non-standard construction absent from
CryptoKit); broader PKCS#8 ciphers/KDFs.

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

## Swift 6 Language Mode Migration (2026-06-15)

Branch `refactor/swift6-language-mode`. The app target was still on the Swift 5
language mode while the test target had already moved to Swift 6; this brings the
app target to full Swift 6 compliance and aligns the two targets' concurrency
settings.

**Build settings (app target, Debug + Release):**
- `SWIFT_VERSION` `5.0` → `6.0`
- `SWIFT_APPROACHABLE_CONCURRENCY` → `YES`
- `SWIFT_UPCOMING_FEATURE_MEMBER_IMPORT_VISIBILITY` → `YES`

**Source fixes (only three — the prior `@Observable`/`@MainActor` work meant
strict concurrency surfaced almost nothing):**
- `SSHManager.swift` — `connectionTimeoutSeconds` marked `nonisolated(unsafe) static var`
  (config knob set at most once, never mutated concurrently).
- `KeychainService.swift` — added `Sendable` conformance (only immutable `let`
  state; Keychain APIs are thread-safe), fixing the `static let shared` error.
- `SSHManager.swift` — added `import NIOFoundationCompat`; member-import-visibility
  now requires the explicit import for `ByteBuffer(data:)`.

**NIO handler concurrency warnings (10, all in `SSHManager`):** the language-mode
bump surfaced strict-concurrency *warnings* (not errors) in the relay/handler code.
Fixed so the app target is warning-free:
- `GenericRelayHandler` — marked `@unchecked Sendable` (event-loop-confined,
  immutable stored state), constrained `OutboundType: Sendable`, and the
  `eventLoop.execute { }` closures now capture `peer`/`outboundData` instead of
  `self`. `onBytes`/`transform` (and the `received`/`sent` call sites) are now
  `@Sendable`.
- `channelInitializer` — replaced the `addHandler(...).flatMap { addHandler(...) }`
  chain (which captured non-`Sendable` handlers in an escaping `@Sendable` closure)
  with `eventLoop.makeCompletedFuture { try pipeline.syncOperations.addHandlers([...]) }`.

Both targets build clean (regular + build-for-testing) with **zero warnings**
(verified via per-file diagnostics). The test suite was not re-run — still blocked
by the Swift Testing runner crash below, so the SSH data-path changes are
compile-validated but not behaviourally tested on this toolchain.

---

## Known Issues

### Open bugs (to fix)

- [x] **New/edited connection name not shown in the sidebar until app restart (2026-06-16) — FIXED**
  - **Symptom:** After creating or renaming a connection, the sidebar row's
    **name didn't update** (showed blank/stale) until the app was relaunched and
    re-fetched from CloudKit. Not data loss — the record always persisted.
  - **Root cause:** `Connection` is `@Observable` but `Equatable`/`Hashable` by
    `id` only (`Connection.swift:88-95`). `upsertConnection` did
    `connections[index] = newInstance` — a *different* object with the same `id`
    — so SwiftUI's `List`/`ForEach` treated it as unchanged and never swapped the
    instance into `ConnectionRow` (or `selectedConnection`).
  - **Fix (`ConnectionStore.swift`):** `upsertConnection` now **mutates the
    existing instance in place** (`existing.connectionInfo = …`/`tunnelInfo = …`)
    so the change is observed; this also preserves live `state`/byte counters that
    a replacement would have reset. Additionally `createConnectionAsync` now
    upserts straight from the `save()` echo record instead of issuing a second
    `record(for:)` fetch (removes a round-trip and a read-back race that could
    surface a blank name on create). Verified live: rename updated the sidebar
    immediately, no relaunch.

- [ ] **Detail pane (view mode) renders blank for a connection that has data (2026-06-16)**
  - **Symptom:** Selecting a connection sometimes shows the `MainView` detail with
    a blank name/status and empty fields, even though the data exists (the **Edit**
    form for the same connection shows the real values, and the sidebar shows the
    name). Resolves on reselect/relaunch in some cases.
  - **Pre-existing / separate** from the sidebar fix above — reproduced on a clean
    checkout with the fix stashed. **Not data loss.**
  - **Likely area:** `MainView`'s view-mode bindings read
    `selectedConnection?.connectionInfo[keyPath:]` via `.constant(...)`
    (`MainView.swift:214-224`); investigate whether `body` re-evaluates / re-reads
    the selected `@Observable` instance's `connectionInfo` when selection changes
    (especially right after an edit, where `selectedConnection = tempConnection`).

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
partway through. We chose **not** to ship a flaky partial workaround.

**Action:** Revisit when the Xcode/macOS toolchain updates (re-run the full
suite; if it's green by default, this entry can be removed).

> **EC-key-parsing crash — root-caused and fixed (2026-06-15).** The `AuthDelegate`
> EC crashes were a genuine parser bug, *not* the runner instability:
> `ASN1Parser` indexed `data[offset]` from 0, but every sub-parser was built from
> a Foundation `Data` **slice**, which keeps its parent's indices — so the first
> read on any sub-parser indexed below `startIndex` and trapped. Fixed by rebasing
> the input to a zero-based copy in `ASN1Parser.init` (`Data(data)`). The same fix
> enabled top-level SEC1 `EC PRIVATE KEY` parsing (see `parseSEC1ECPrivateKey`).
> Verified via `RunCodeSnippet`: OpenSSH Ed25519/ECDSA, PKCS#8 EC (plain +
> encrypted), and SEC1 P-256/384/521 all parse.
