# Swift API Modernization Roadmap

Opportunities to adopt newer Swift / SwiftUI / Foundation / CloudKit APIs.
Deployment target is **macOS 15.6**, so all modern APIs below are available.

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
| 1 | Adopt Observation framework (`@Observable`) | `refactor/observable-macro` | High | Not started |
| 2 | Native async CloudKit APIs | `refactor/cloudkit-async-apis` | High | Not started |
| 3 | `Task.sleep(for:)` with `Duration` | `refactor/task-sleep-duration` | Medium | Merged (PR #35) |
| 4 | `@Entry` macro for environment key | `refactor/entry-macro-environment` | Medium | In review (PR #36) |
| 5 | `ByteCountFormatStyle` (`.formatted`) | `refactor/bytecount-format-style` | Medium | Not started |
| 6 | Replace `DispatchQueue.main.asyncAfter` | `refactor/async-error-clear` | Low | Not started |
| 7 | NIO singleton event-loop group | `refactor/nio-singleton-eventloop` | Low | Not started |
| 8 | Remove dead `connection` environment value | `refactor/remove-dead-connection-env` | Low | Not started |

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
