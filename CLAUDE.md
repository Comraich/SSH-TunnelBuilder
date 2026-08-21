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
- **PEMDecryptor.swift**: PKCS#8 key decryption with PBKDF2. DER parsing uses
  **SwiftASN1** (linked to the app target); the hand-rolled `ASN1Parser` was
  deleted 2026-08-21 — don't reintroduce one
- **BcryptPBKDF.swift**: Blowfish + `bcrypt_pbkdf` (from scratch; not in CryptoKit), used to key OpenSSH key decryption
- **OpenSSHKeyDecryptor.swift**: decrypts encrypted `openssh-key-v1` private sections (AES-CTR/CBC/GCM)
- **ConnectionTransfer.swift**: encrypted import/export codec (see below)
- **ExportDocument.swift**: `.sshtunnels` `UTType` + `FileDocument` for the file dialogs
- **PassphrasePromptView.swift**: reusable encrypt/decrypt passphrase sheet
- **AppCommands.swift**: app menu bar commands (`Commands`) operating on the shared store

## Import / Export

Connections can be exported to and imported from an encrypted `.sshtunnels` file
via the **File** menu (`File ▸ Export ▸ Export All… / Export Selected…`, and
`File ▸ Import Connections…`).

- **Format:** a plaintext JSON envelope (format/version + KDF params) wrapping a
  base64 AES-256-GCM blob. No secret ever touches disk in cleartext — only the
  ciphertext does. On-disk type is a branded `.sshtunnels` UTI conforming to
  `public.json` (declared in `SSH-TunnelBuilder-Info.plist`).
- **Crypto:** passphrase → PBKDF2-HMAC-SHA256 (600k iterations, 16-byte random
  salt) → 256-bit key → `AES.GCM`. A wrong passphrase fails as a GCM tag
  mismatch and surfaces a friendly error. All in `ConnectionTransfer` (pure,
  `nonisolated`); the heavy KDF runs off the main actor.
- **Secrets:** an export is a *full* backup. `ConnectionStore.makeExportPayload`
  reads passwords / private keys from the Keychain (may prompt for Touch ID);
  `importConnections` mints **fresh ids** (so imports never overwrite existing
  CloudKit records) and writes secrets back through the normal save path.
  `privateKeyPassphrase` is never persisted, so it always exports empty.
- **UI plumbing:** menu commands set `ConnectionStore.transferRequest`;
  `ContentView` observes it and runs the passphrase sheet + `fileExporter` /
  `fileImporter`. Selection is hoisted into the store (`selectedConnection`) so
  the commands can act on it. The file dialogs require the sandbox file-access
  build settings (`ENABLE_APP_SANDBOX` + `ENABLE_USER_SELECTED_FILES = readwrite`).
  Each presentation sits on its own `.background` host — macOS SwiftUI only drives
  one presentation per view.

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

- [x] `SSHManager` connect/disconnect flows — `SSHManagerLifecycleTests.swift`
      (2026-08-21, 8 tests). Covers `missingCredentials`, `keyParsingFailed`,
      handshake timeout against a silent TCP peer, refused connection,
      `disconnect()` idempotency, counter reset, the already-connected no-op, and
      a connect/disconnect concurrency stress over the refactored lock.
      **Still uncovered** (needs a real SSH server): successful session
      establishment, `startLocalListener` / port-forwarding, `invalidPort`, and
      the host-key prompt's pause/re-arm of the handshake deadline.
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

## Swift API Modernization — Round 2 (2026-08-21)

Branch `refactor/swift-api-modernization-round2` (off `Development`, which now
includes the macOS 14 deployment-target change from PR #90). Tasks 9–13 in
[`MODERNIZATION_ROADMAP.md`](MODERNIZATION_ROADMAP.md), shipped as one branch.

- [x] **9. `Task.detached` → `@concurrent`** (Swift 6.2)
  - `ConnectionTransfer` gained `encryptInBackground`/`decryptInBackground`
    `@concurrent` wrappers around the existing pure sync `encrypt`/`decrypt`
    (kept as-is so the tests still call them synchronously).
  - `SSHManager.makeAuthDelegate` is now a `@concurrent` method replacing the
    `Task.detached { … }.value` that built `FlexibleAuthDelegate`.
  - **Why `@concurrent` and not plain `nonisolated async`:** with
    `SWIFT_APPROACHABLE_CONCURRENCY = YES`, `nonisolated(nonsending)` is the
    default — a plain `nonisolated async func` *stays on the caller's actor*, so
    a main-actor caller would run PBKDF2/bcrypt on the main thread. `@concurrent`
    is what actually forces the hop.

- [x] **10. `NSLock` → `OSAllocatedUnfairLock<State>`** (`SSHManager.swift`)
  - All seven mutable fields moved into a `private struct State` owned by the
    lock, so there is no longer any way to *spell* an unguarded access.
  - **This closed a real race**, not just a style change: `sessionReadyPromise`
    and `sessionReadyCompleted` were previously plain stored properties that the
    timeout/shutdown paths guarded but the connect path and channel initializer
    touched unguarded (the 2026-02-05 "fixed" race was only half-fixed).
  - Promise completion now always follows the same shape: claim-and-clear inside
    the critical section, `fail()` outside it (NIO hops completion to the
    promise's own event loop, so holding the lock across it is pointless).

- [x] **11. Legacy `Alert` → `alert(_:isPresented:presenting:actions:message:)`**
  - `ContentView.swift` host-key prompt. The old `.alert(item:)` + `Alert(...)`
    API has been deprecated since macOS 12.
  - **Ordering hazard worth remembering:** the derived `isPresented` binding
    setter must *only* clear `hostKeyRequest`, never answer it. `ConnectionStore`'s
    `decide` closure latches the first answer (`hasResumed`), so a setter that
    also answered `false` could race a "Trust" tap and silently turn it into a
    rejection. The buttons answer using the `request` value SwiftUI passes to the
    `presenting:` closures, which stays valid after the store's optional clears.

- [x] **12. Last `NSError` removed** — `ConnectionStore.UnconfiguredDatabase` now
  throws `SSHTunnelError.internalError`.

- [x] **13. `SecRandomCopyBytes` + `String(format:)` cleanup**
  - `ConnectionTransfer.randomBytes` uses `SymmetricKey(size:)` (system CSPRNG),
    so it no longer throws or force-unwraps `baseAddress`.
    `ConnectionTransferError.randomGenerationFailed` is now unreachable but kept
    — the error-equality test still references it.
  - `PEMDecryptor`'s four `String(format:"0x%02X")` sites use a new
    `UInt8.asn1TagDescription` helper. Verified byte-for-byte identical output
    across `0x00…0xFF` edge values.

**Verification:** both targets build clean with **zero warnings**
(`buildForTesting`). Behaviour spot-checked via `RunCodeSnippet`: export/import
round-trips through the new `@concurrent` entry points, salts differ between
encryptions, wrong passphrase still yields `wrongPassphraseOrCorruptFile`, and
the hex helper matches the old format string.

**Test suite: 86/86 passing** (verified after the fact on 2026-08-21 — the
Swift Testing runner bug that had blocked it is fixed, see Known Issues). The
relevant coverage for this round:
- `Connection Transfer Tests` (7) + `Connection Transfer Multi Tests` (1) —
  exercise the new `SymmetricKey(size:)` salt path via round-trip and
  wrong-passphrase assertions.
- `Host Key Trust Flow Tests` (4) + `Host Key Request Tests` (3) — cover the
  trust/mismatch/cancel/supersede flow the rewritten alert drives, including the
  first-answer-latching behaviour the alert's binding setter has to respect.
- `SSHTunnelError Description Coverage` (2) — `everyCaseHasMessage` covers the
  `internalError` case now used by `UnconfiguredDatabase`.

**The lock refactor is now covered too** — `SSHManagerLifecycleTests.swift`
(2026-08-21) closed that gap; see Test Coverage Gaps above. The suite is
**94/94**, green across three consecutive full runs.

**Task 14 (SwiftASN1) is also done** — see `MODERNIZATION_ROADMAP.md` §14 for the
outcome, the `DER.sequence` strict-consumption gotcha, and a **pre-existing**
AES-CBC padding issue found while validating it (wrong passphrases are not
rejected by `decryptEncryptedPKCS8PEM` alone; callers must parse the result).

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

- [x] **Connection hangs forever in `.connecting` — two spinners never stop (2026-06-16) — FIXED**
  - **Symptom:** A connection whose SSH handshake/auth never resolves (e.g. wrong
    credentials that the server silently stalls on, or a host that accepts the TCP
    socket but never speaks SSH) sat in `.connecting` indefinitely. The two
    by-design `.connecting` spinners (`ConnectionIndicatorView` + `DataCounterView`)
    spun forever with no error and no way out but Disconnect.
  - **Root cause:** the only deadline was `ChannelOptions.connectTimeout`
    (`connectionTimeoutSeconds`, `SSHManager.swift`), which bounds **only the TCP
    connect**. The await on `sessionReadyPromise` — covering the SSH handshake and
    authentication — had **no timeout**, so a non-resolving handshake never failed.
  - **Fix (`SSHManager.swift`):** added `handshakeTimeoutSeconds` (default 15) and a
    scheduled task that fails `sessionReadyPromise` with `.connectionTimeout` if the
    handshake/auth phase overruns. Armed before connecting, cancelled on
    success/failure/shutdown. Crucially it is **paused while the host-key (TOFU)
    prompt is up** (cancel on prompt, re-arm on trust) so a deliberating user is
    never timed out. Completing an already-resolved NIO promise is a no-op, so the
    timeout races safely against a session that becomes ready first.
  - **Verified:** against a silent TCP listener (handshake hangs), `connect()` threw
    `.connectionTimeout` after exactly the configured deadline and the state went to
    `.failed(...)` — leaving `.connecting`, so the spinners stop.

- [x] **Host-key trust-on-first-use does not actually pin — re-prompts every connect (2026-06-16) — FIXED**
  - **Symptom:** Connecting to a host showed the "Unknown Host" prompt (good), but
    after trusting it, **every subsequent connect re-prompted** — the trusted key
    was never remembered. Verified live against `127.0.0.1:22`: trusted, disconnected,
    reconnected → prompted again. The prompt's fingerprint always read
    `SHA256:UNAVAILABLE`.
  - **Root cause:** `SSHManager.serialize(key:)` returned `nil` (believed NIOSSH
    exposed no public host-key serialization API). So in `handleHostKeyValidation`
    the key bytes were empty: the fingerprint fell back to the **constant**
    `"SHA256:UNAVAILABLE"` (not host-specific), and on trust the stored value was
    `base64(Data())` = `""`. On reconnect `knownHostKey.isEmpty` was true, the match
    block was skipped, and the handler was invoked again.
  - **Fix (`SSHManager.swift`):** NIOSSH *does* expose the canonical OpenSSH
    public-key string via `String(openSSHPublicKey:)`. `serialize(key:)` now parses
    its `"<algorithm-id> <base64-wire-bytes>"` form and returns the decoded wire-format
    blob — the same bytes OpenSSH hashes for its fingerprint, stable and host-unique.
    The fingerprint is now OpenSSH-style (SHA256, base64 **without** padding) so it
    matches `ssh-keygen -l` / `ssh-keyscan`.
  - **Verified live:** prompt now shows a real fingerprint
    (`SHA256:wZGdCznz9+/IDVQD+QDJmYrtlOvs+qL8Mt8KX/rbVXs`) matching `ssh-keyscan`
    exactly; trusting pins a real 68-char key blob to CloudKit; reconnect no longer
    prompts. The **mismatch / MITM-detection** path now has a real pinned value to
    compare against.

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

### `decryptEncryptedPKCS8PEM` does not detect a wrong passphrase on its own (2026-08-21)

**Not a regression** — found while validating the SwiftASN1 swap, and confirmed
present on the pre-change code too by swapping the old file back in.

`AESCBC.decrypt` passes `kCCOptionPKCS7Padding`, which would normally make a
wrong key fail with a padding error. It doesn't: **200/200** wrong passphrases
were accepted, returning garbage plaintext, on both old and new parsers. Expected
behaviour would be ~199/200 rejected (padding valid by luck ≈ 1/256).

So `decryptEncryptedPKCS8PEM` is **not** a passphrase check. A wrong passphrase is
only caught when the returned DER is subsequently parsed, which fails. Every
current caller does parse it — `SSHKeyParsing.swift:146`, `KeyValidation.swift:62`,
and the tests — so **there is no live bug**. But the guarantee is implicit: a
future caller that treats a successful decrypt as "passphrase correct" would be
wrong, and `KeyValidation` returning `.decryptionFailed` relies on the parse step.

Options if this is worth closing: validate the PKCS#7 padding explicitly after
`CCCrypt`, or document the contract on the function so the parse step is
understood as load-bearing. Left alone deliberately — it's a separate concern
from the parser swap and touches the crypto path.

---

### ~~Two files have wrong target membership~~ — RESOLVED (2026-08-21)

Two mirror-image misconfigurations, both now **fixed**. Kept on record because the
symptom of #1 is extremely misleading and the mechanism is worth knowing before
adding test files.

The project uses Xcode 16+ **file-system synchronized groups**
(`PBXFileSystemSynchronizedRootGroup`), so there is no per-target Compile Sources
list to inspect: a folder maps to a target and files are members automatically.
That's also why new files added under `SSH TunnelBuilderTests/` need no
`project.pbxproj` change at all.

The duplication comes from two `PBXFileSystemSynchronizedBuildFileExceptionSet`
entries, which *add* a file to a target that doesn't own its folder:

| File | Owning folder/target | Had also been added to |
|---|---|---|
| `Classes/SSHTunnelError.swift` | `SSH TunnelBuilder` → app | `SSH TunnelBuilderTests` |
| `SSHManagerTests.swift` | `SSH TunnelBuilderTests` → tests | `SSH TunnelBuilder` |

Fix for either: select the file in Xcode and uncheck the extra target under
**File Inspector ▸ Target Membership** (not Build Phases). Likely origin of #1:
someone hit "cannot find SSHTunnelError in scope" in a test and added the file to
the test target, which silently traded that error for the much subtler one below.

**1. `SSHTunnelError.swift` was compiled into the *test* module as well as the app.**

So the test module has a *second, independent* copy of the enum. Consequence:

```swift
// In test code, `SSHTunnelError` resolves to the TEST module's copy…
let thrown: Error? = // …but SSHManager throws the APP module's copy
thrown as? SSHTunnelError        // ← always nil. Two unrelated runtime types.
thrown as? SSH_TunnelBuilder.SSHTunnelError  // ← works
```

This is genuinely baffling to debug because both copies print identically as
`"SSH_TunnelBuilder.SSHTunnelError.missingCredentials"`, so the failure message
reads "expected an SSHTunnelError, got …SSHTunnelError". The existing
`SSHTunnelErrorDescriptionTests` never noticed because they construct the error in
the test module and only read `localizedDescription` — they never cast a value
that crossed the module boundary.

**Fixed 2026-08-21.** The test target was unchecked for this file, and the
`AppTunnelError` typealias workaround in `SSHManagerLifecycleTests.swift` was
removed — the tests now cast to a plain `SSHTunnelError` and pass (94/94).

**2. `SSHManagerTests.swift` was compiled into the *app* module too.**

So it couldn't `import Testing` (the app target doesn't link it) — which is why
its entire contents were commented out.

**Fixed 2026-08-21.** The app target was unchecked, and the file — dead
commented-out XCTest code superseded by `OpenSSHKeyParserTests.swift` — was
deleted. The live SSHManager tests are in `SSHManagerLifecycleTests.swift`.

**Check membership when adding test files.** `GetFileCompilerFlags` is the
authoritative probe: it errors with "is not a member of a Compile Sources build
phase" for non-members and returns an empty string for members. Note that
`project.pbxproj` is *not* a reliable place to look — under synchronized groups a
correctly-configured file appears nowhere in it.

---

### ~~Test suite cannot run reliably on the macOS 26/27 beta toolchain~~ — RESOLVED (2026-08-21)

**The test suite runs clean. Run it. Do not skip testing on this basis.**

Re-verified 2026-08-21 on macOS 27.0 (**26A5416b**) / Xcode 27.0 (27A5237l) /
Swift 6.4: **86 tests in 24 suites, 86 passed**, five consecutive full runs, no
crashes and no restarts. (Now **94 tests in 25 suites** after
`SSHManagerLifecycleTests` was added the same day — also green, three runs.)

Confirmed the pass is genuine and not a workaround masking the bug:
- Default **parallel** configuration — no `--serialized` flag, no test-plan changes.
- At the time of verification, no `.serialized` trait anywhere in the test sources
  (all 24 `@Suite` declarations were plain names). **`SSHManagerLifecycleTests` is
  now `.serialized`**, but for an unrelated and specific reason — it mutates
  `SSHManager`'s `static var` timeout knobs — and the other 24 suites remain
  parallel. Do not read that one trait as a revival of the old workaround.
- Test target still has `SWIFT_APPROACHABLE_CONCURRENCY = YES` — the setting the
  2026-06-15 investigation had considered disabling as a workaround.

So the `Runner._applyScopingTraits(for:testCase:_:)` crash was indeed a Swift
Testing **runtime** bug in the older beta toolchain (macOS 27.0 26A5353q), fixed
upstream by the OS/Xcode update. No code or project change was needed.

<details>
<summary>Original 2026-06-15 report (kept for history)</summary>

**Symptom:** Running the test bundle crashes the test host in Swift Testing's
`Runner._applyScopingTraits(for:testCase:_:)`. With the default (parallel)
configuration *no* tests run at all — every suite reports
`Crash: ... Runner._applyScopingTraits` before any test body executes, and the
host hits "Exceeded max restart count". No `.ips` crash report is produced.

**Diagnosis:** A Swift Testing runtime bug in the then-current Xcode-beta /
macOS 27.0 (26A5353q) toolchain, not a defect in the test code or target config:
- The test code is plain, idiomatic Swift Testing (no custom/scoping traits).
- The test target settings are standard (`SWIFT_DEFAULT_ACTOR_ISOLATION = nonisolated`, Swift 6, hosted by the app).
- It reproduced on a clean `Development` checkout, independent of the `@Observable`/CloudKit modernization work.
- Behaviour scaled with concurrency: 1–6 tests ran fine in isolation; the full 30-test run crashed. Non-deterministic — the crashing test moved between runs.

**Attempted workarounds (not adopted):** Serializing every suite (`.serialized`
roots) plus disabling `SWIFT_APPROACHABLE_CONCURRENCY` on the test target raised
the pass count from 0 to ~20–28/30, but runs still aborted non-deterministically
partway through. We chose not to ship a flaky partial workaround — which turned
out to be the right call, since the fix arrived upstream.

</details>

> **Note on the suite's size:** the 2026-06-15 entry refers to a "30-test run";
> the suite is now **86 tests in 24 suites**. Any future report should quote the
> current count rather than trusting the older figure.

> **EC-key-parsing crash — root-caused and fixed (2026-06-15).** The `AuthDelegate`
> EC crashes were a genuine parser bug, *not* the runner instability:
> `ASN1Parser` indexed `data[offset]` from 0, but every sub-parser was built from
> a Foundation `Data` **slice**, which keeps its parent's indices — so the first
> read on any sub-parser indexed below `startIndex` and trapped. Fixed by rebasing
> the input to a zero-based copy in `ASN1Parser.init` (`Data(data)`). The same fix
> enabled top-level SEC1 `EC PRIVATE KEY` parsing (see `parseSEC1ECPrivateKey`).
> Verified via `RunCodeSnippet`: OpenSSH Ed25519/ECDSA, PKCS#8 EC (plain +
> encrypted), and SEC1 P-256/384/521 all parse.
