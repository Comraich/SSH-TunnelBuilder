# Swift API Modernization Roadmap

Opportunities to adopt newer Swift / SwiftUI / Foundation / CloudKit APIs.
Deployment target is **macOS 14.0**. Check availability before adopting an API — anything gated at macOS 15+ needs an `@available` fallback, not a bump to the deployment target.

## Workflow

- **Base branch:** `Development` (protected — never push directly).
- Each task gets its **own branch off `Development`**, its own PR.
- Branch naming follows the project convention (`refactor/...`).
- Tasks are listed in priority order (impact, high → low). They are independent
  and can be merged in any order, but if doing several at once the low-risk,
  self-contained ones (#3, #4, #5) are the safest to start with, followed by
  #2 and #1, then #6 and #7.

| # | Task | Branch | Impact | Status |
|---|------|--------|--------|--------|
| 1 | Adopt Observation framework (`@Observable`) | `refactor/observable-macro` | High | Merged (PR #43) |
| 2 | Native async CloudKit APIs | `refactor/cloudkit-async-apis` | High | Merged (PR #42) |
| 3 | `Task.sleep(for:)` with `Duration` | `refactor/task-sleep-duration` | Medium | Merged (PR #35) |
| 4 | `@Entry` macro for environment key | `refactor/entry-macro-environment` | Medium | Merged (PR #36) |
| 5 | `ByteCountFormatStyle` (`.formatted`) | `refactor/bytecount-format-style` | Medium | Merged (PR #38) |
| 6 | Replace `DispatchQueue.main.asyncAfter` | `refactor/async-error-clear` | Low | Merged (PR #39) |
| 7 | NIO singleton event-loop group | `refactor/nio-singleton-eventloop` | Low | Merged (PR #41) |
| 8 | Remove dead `connection` environment value | `refactor/remove-dead-connection-env` | Low | Merged (PR #40) |

> **All tasks complete.** Note: task #2 was implemented with the async
> `recordZoneChanges(inZoneWith:since:)` rather than `records(matching:)` — the
> fetch path uses CloudKit zone changes specifically to avoid the queryable-index
> requirement, so `records(matching:)` would have reintroduced that bug.

---

## 1. Adopt the Observation framework (`@Observable`)
**Branch:** `refactor/observable-macro` · **Impact:** High

Replace `ObservableObject` + `@Published` with the `@Observable` macro (macOS 14+).
Gives finer-grained view updates and removes the Combine dependency.

- `Connection.swift:63` — `class Connection: ... ObservableObject` → `@Observable @MainActor class Connection`; drop all `@Published`; remove `import Combine` (line 3).
- `ConnectionStore.swift:42` — convert to `@Observable`; drop `@Published` from the ~15 published properties.
- View property-wrapper migration:
  - `@EnvironmentObject` → `@Environment` (`MainView.swift`, `ContentView.swift`)
  - `@ObservedObject` → plain `let` or `@Bindable` (`ConnectionRow.swift`, `DataCounterView.swift`, `ConnectionIndicatorView`, `ConnectButtonView`)
  - `@StateObject` → `@State` (`ContentView.swift:18`, `SSH_TunnelBuilderApp.swift:5`)

**Note on `SSHManager` (`SSHManager.swift:453`):** it is `@unchecked Sendable` and mutated
off the main actor, so it is **not** a good `@Observable` fit. Its `@Published var
lastErrorMessage` (line 469) appears unobserved by any view — drop the
`ObservableObject`/`@Published` there rather than convert it. Also remove its
`import Combine` (line 5) once done.

**Risk:** Touches many view files; mechanical but broad. Verify previews and all
view updates still fire after conversion.

---

## 2. Native async CloudKit APIs
**Branch:** `refactor/cloudkit-async-apis` · **Impact:** High

`ConnectionStore.swift` hand-wraps every CloudKit call in `withCheckedContinuation`.
macOS 12+ provides native `async` equivalents — removes ~120 lines of bridging.

| Current (manual bridge) | Modern async API |
|---|---|
| `createCustomZoneAsync` + `CKModifyRecordZonesOperation` (278–304) | `try await database.modifyRecordZones(saving:deleting:)` |
| `fetchRecord` wrapper (429–441) | `try await database.record(for:)` |
| `saveRecord` wrapper (444–456) | `try await database.save(_:)` |
| `deleteRecord` wrapper (459–471) | `try await database.deleteRecord(for:)` |
| `fetchConnectionsAsync` + `CKQueryOperation` (312–365) | `try await database.records(matching:inZoneWith:desiredKeys:resultsLimit:)` → `(matchResults, queryCursor)`, paged via `records(continuingMatchFrom:)` |

The three private wrappers (`fetchRecord`, `saveRecord`, `deleteRecord`) and the
`CloudKitOperationError` enum can be deleted entirely.

**Risk:** Preserve existing behavior — in-memory sorting after fetch
(`ConnectionStore.swift:395`), per-record error logging, and the `desiredKeys`
list. Test against the real CloudKit container.

---

## 3. `Task.sleep(for:)` with `Duration`
**Branch:** `refactor/task-sleep-duration` · **Impact:** Medium

- `ConnectionStore.swift:154` — `Task.sleep(nanoseconds: loadingFallbackSeconds * 1_000_000_000)` → `Task.sleep(for: .seconds(loadingFallbackSeconds))`.
- Simplify `loadingFallbackSeconds` (line 140) from `UInt64` to a plain `Int`.

**Risk:** Trivial.

---

## 4. `@Entry` macro for the custom environment key
**Branch:** `refactor/entry-macro-environment` · **Impact:** Medium

- `MainView.swift:1004–1013` — replace the `ConnectionEnvironmentKey` struct +
  `EnvironmentValues` extension with:
  ```swift
  extension EnvironmentValues {
      @Entry var connection: Connection?
  }
  ```
- Also fixes the latent Swift 6 mutable-static-`defaultValue` issue (line 1005).

**Risk:** Trivial. Confirm the `connection` environment value has no other readers.

---

## 5. `ByteCountFormatStyle` instead of `ByteCountFormatter`
**Branch:** `refactor/bytecount-format-style` · **Impact:** Medium

- `DataCounterView.swift:18-19` — use `connection.bytesSent.formatted(.byteCount(style: .file))`.
- Remove the `byteCountFormatter` computed property (lines 31-35).

**Risk:** Trivial. Verify formatted output matches the previous `.file` style.

---

## 6. Replace `DispatchQueue.main.asyncAfter`
**Branch:** `refactor/async-error-clear` · **Impact:** Low

- `ContentView.swift:46` — `DispatchQueue.main.asyncAfter(deadline: .now() + 0.1)`
  → `Task { try? await Task.sleep(for: .milliseconds(100)); ... }` (view is already `@MainActor`).

**Risk:** Trivial.

---

## 7. NIO singleton event-loop group
**Branch:** `refactor/nio-singleton-eventloop` · **Impact:** Low (optional)

- `SSHManager.swift:511` creates and later shuts down a fresh
  `MultiThreadedEventLoopGroup` per connection. Consider
  `MultiThreadedEventLoopGroup.singleton` / `NIOSingletons` to avoid per-connection
  thread spin-up/teardown.

**Risk:** Behavioral change — the shared singleton must **not** be shut down in
`shutdown()` (`SSHManager.swift:804-811`). Review lifecycle carefully before adopting.

---

## 8. Remove dead `connection` environment value
**Branch:** `refactor/remove-dead-connection-env` · **Impact:** Low (cleanup)

The custom `connection` environment value in `MainView.swift` (the
`EnvironmentValues.connection` declaration, now expressed via `@Entry` after #4)
is never read or written anywhere in the app — it is dead API. Delete the
`extension EnvironmentValues { @Entry var connection: Connection? }` entirely.

While here, consider a quick sweep for other unused symbols (e.g.
`isOpenSSHKeyEncrypted(_:)` in `MainView.swift`, the deprecated `errorAlert(_:)`
`View` extension in `ContentView.swift`) and remove anything confirmed dead.

> Discovered during #4 — the `@Entry` modernization only restyled code that has
> no callers. Best done **after** #4 merges so the deletion is a clean, separate diff.

**Risk:** Trivial. Confirm zero references before deleting (`XcodeGrep`/`Grep`),
then build to verify.

---

# Round 2 (2026-08-21)

A second survey after the round-1 tasks all merged. Same constraint applies:
deployment target is **macOS 14.0**, so `Synchronization.Mutex` (15),
`Observations` (26), CryptoKit's `RawSpan` overloads (26), `alert(_:item:)` (27),
and the new `Document` protocol (26) are all still out of reach.

| # | Task | Branch | Impact | Status |
|---|------|--------|--------|--------|
| 9 | `Task.detached` → `@concurrent` | `refactor/swift-api-modernization-round2` | High | Done |
| 10 | `NSLock` → `OSAllocatedUnfairLock<State>` | `refactor/swift-api-modernization-round2` | High | Done |
| 11 | Legacy `Alert` → modern alert modifier | `refactor/swift-api-modernization-round2` | Medium | Done |
| 12 | Remove last `NSError` construction | `refactor/swift-api-modernization-round2` | Low | Done |
| 13 | `SecRandomCopyBytes` / `String(format:)` cleanup | `refactor/swift-api-modernization-round2` | Low | Done |
| 14 | **Replace hand-rolled ASN.1 parser with SwiftASN1** | `refactor/swift-api-modernization-round2` | High | Done |
| 15 | `CKSyncEngine` for CloudKit sync | _(not started)_ | High | Deferred |
| 16 | `_CryptoExtras` to retire CommonCrypto | _(not started)_ | Medium | Not recommended yet |

Tasks 9–13 shipped together as one branch — all mechanical, all compile-verified.

---

## 14. Replace the hand-rolled ASN.1 parser with SwiftASN1 — **DONE (2026-08-21)**
**Impact:** High · **Risk:** Medium (crypto parsing path, needs test coverage)

**Outcome:** `SwiftASN1` linked to the app target; `ASN1Parser` (~170 lines),
`parseOID`, and the `UInt8.asn1TagDescription` helper from task 13 all deleted.
`PEMDecryptor.swift` went 438 → ~400 lines while gaining typed OID constants and
structural validation. Public signatures unchanged, so `SSHKeyParsing`,
`KeyValidation`, and the tests were untouched. 94/94 tests pass, zero warnings.

Notes for future readers:
- `DER.sequence` **throws on unconsumed trailing nodes**, which replaces the old
  parser's manual `isAtEnd` checks for free. Where the old code deliberately
  ignored trailing OPTIONAL fields (EC curve OID, PKCS#8 `[0] attributes`, SEC1
  `[0]`/`[1]`), a `drainRemaining` helper keeps that tolerance explicit so
  behaviour didn't silently become stricter.
- OIDs are compared as typed `ASN1ObjectIdentifier` values, not
  `String(describing:)` — SwiftASN1 makes no stability promise about `description`.
- The `prf` DEFAULT is left as RFC 8018's hmacWithSHA1 (the old code defaulted the
  *variable* to SHA-256), so an omitted `prf` is now correctly rejected by the
  SHA-256-only policy check rather than assumed compliant.
- Validated beyond the test suite against independently OpenSSL-generated keys
  (encrypted PKCS#8 Ed25519, plain PKCS#8 Ed25519, PKCS#8 EC P-256, SEC1 P-256):
  byte-identical scalars/seeds vs. the old parser, and malformed input throws
  `PEMDecryptorError` rather than trapping.

**Pre-existing issue found while validating (NOT introduced here, NOT fixed):**
`AESCBC.decrypt` passes `kCCOptionPKCS7Padding`, but a wrong passphrase is
accepted by that layer **every time** — 200/200 wrong passphrases returned
"successfully" with garbage, on both the old and new parser (verified by swapping
the pre-change file back in). So `decryptEncryptedPKCS8PEM` is *not* a passphrase
oracle on its own; wrong passphrases are caught only when the result is
subsequently parsed. Every current caller does parse it (`SSHKeyParsing`,
`KeyValidation`, tests), so there's no live bug — but the guarantee is implicit and
a future caller that trusts the decrypt alone would be wrong. Worth either
validating padding explicitly or documenting the contract on the function.

<details><summary>Original plan</summary>

`PEMDecryptor.swift` carries ~160 lines of hand-written DER parsing
(`private struct ASN1Parser`, plus `parseOID`). This is the code whose
`Data`-slice indexing bug caused the EC-key parsing crash root-caused on
2026-06-15 — the class of bug a maintained parser doesn't have.

**`swift-asn1` is already in the resolved package graph** (transitively, via
swift-crypto ← NIOSSH), so no new dependency is needed. It is *not* linked to
the app target yet — verified: `import SwiftASN1` currently fails with
"no such module". Step one is adding the `SwiftASN1` product to the
**SSH TunnelBuilder** target's frameworks.

Scope:
- Add the `SwiftASN1` product to the app target.
- Replace `ASN1Parser` with `DER.parse` / `ASN1Node` traversal in:
  - `parsePKCS8PrivateKey` / the PBES2 + PBKDF2 parameter decoding
  - `parseSEC1ECPrivateKey`
  - `parseOID` → SwiftASN1's `ASN1ObjectIdentifier`
- Delete `ASN1Parser`, `maxLengthBytes`, and the `asn1TagDescription` helper
  added in task 13 (its only callers are the parser's own error paths).
- Keep `PEMDecryptorError.asn1ParseError` as the app-facing error, mapping
  SwiftASN1's thrown errors into it so UI strings don't change.

**Before starting:** the test suite still can't run reliably on this toolchain
(see the Swift Testing runner crash in `CLAUDE.md`). Since this task rewrites a
crypto parsing path, validate with `RunCodeSnippet` against the full key matrix
— OpenSSH Ed25519/ECDSA, PKCS#8 EC plain + encrypted, SEC1 P-256/384/521 —
exactly as the 2026-06-15 fix was validated.

</details>

> The "before starting" caveat above was written when the test suite was blocked.
> By the time the task ran, the suite was green, so the 19 `AuthDelegateTests`
> covered the key matrix automatically — the snippet validation was done anyway as
> a cross-check against independently generated keys.

---

## 15. `CKSyncEngine` for CloudKit sync
**Impact:** High · **Risk:** High — deferred, not scheduled

`CKSyncEngine` is available at macOS 14 (verified: compiles unguarded at this
target). It would subsume the manual `recordZoneChanges` paging
(`ConnectionStore.swift`), the save loop, the loading watchdog, and the
`NSError`-userInfo CKError triage. Real win, but it's a rewrite of the
persistence layer with migration risk — worth doing deliberately, not as part of
an API-modernization sweep.

## 16. `_CryptoExtras` to retire CommonCrypto
**Impact:** Medium · **Status:** not recommended yet

`swift-crypto`'s `_CryptoExtras` has `KDF.Insecure.PBKDF2` and
`AES._CBC`/`AES._CTR`, which would remove `import CommonCrypto` from
`ConnectionTransfer`, `PEMDecryptor`, and `OpenSSHKeyDecryptor`. Also already in
the resolved graph and also not linked. **But** the module name is underscored
and its API is explicitly not source-stable. CryptoKit itself still has no
PBKDF2 (checked: only HKDF and the HPKE KDFs), so `CommonCrypto` remains the
only non-experimental option here. Revisit if/when swift-crypto promotes these
out of `_CryptoExtras`.
