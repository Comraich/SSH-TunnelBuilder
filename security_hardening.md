# Security Hardening — Pre-App-Store

Five items surfaced by the 2026-06-17 whole-app security audit. None rose to a
reportable vulnerability under a strict false-positive filter, but each is a
defense-in-depth fix worth landing before submission. They are independent and
can be implemented in any order.

---

## 1. ASN.1 parser slice underflow

**File:** `SSH TunnelBuilder/Classes/PEMDecryptor.swift:370`

`ASN1Parser.readAny()` computes its returned slice as
`data[(offset-2-length)..<(offset+length)]`. The lower bound subtracts `length`
a second time, so any value where `length > offset - 2` produces a negative
`Data.Index` and Swift's bounds-checked subscript traps the process. Reachable
from `decryptEncryptedPKCS8PEM` via:

- the PBES2/PBKDF2 PRF `parameters` field (`PEMDecryptor.swift:62`)
- the trailing-data drain on `PrivateKeyInfo` (`PEMDecryptor.swift:103`)

Both call sites discard the returned parser (`_ = try? prfAlg.readAny()`), so the
fix is to slice only the value bytes and match the existing `readOID` /
`readInteger` pattern.

**Fix:** replace the slice expression at line 370 with
`data[offset..<(offset + length)]`. Wrap in `Data(...)` if the call sites ever
re-enter `ASN1Parser` on the result (the previously-fixed parent-slice indexing
bug applies here too).

## 2. KDF iteration count clamping

**File:** `SSH TunnelBuilder/Classes/ConnectionTransfer.swift:198`

`UInt32(envelope.iterations)` traps on negative values or values exceeding
`UInt32.max`. The iteration count is taken from the on-disk envelope before any
authentication runs, so a crafted `.sshtunnels` file deterministically crashes
the importer the moment the user provides a passphrase.

This is DoS-only (the importer doesn't expose anything to the attacker on
crash), but it's a one-line guard that prevents a hard-crash on a user-initiated
operation.

**Fix:** validate `envelope.iterations` against a sane range
(`100_000…10_000_000`) in `ConnectionTransfer.decrypt` and throw
`ConnectionTransferError.malformed("iterations out of range")` for anything
outside. Also clamp `salt.count` to `8…64` bytes (current code accepts any
length).

## 3. `"SHA256:UNAVAILABLE"` sentinel guard

**File:** `SSH TunnelBuilder/Classes/SSHManager.swift:213, 224`

If `serialize(key:)` returns nil, `fingerprint` falls back to the literal
`"SHA256:UNAVAILABLE"` string. Today no code path persists that literal into
`knownHostKey` (the pre-fix bug stored `""`, not the sentinel), so this is not
exploitable on current data. But the comparison `knownHostKey == fingerprint`
has no defensive sentinel check — if any future NIOSSH host-key type breaks
`serialize()` and any other code path ever wrote that literal, the comparison
silently trusts any host that triggers the nil-serialize path.

**Fix:** in `handleHostKeyValidation`, skip the comparison branch entirely
when `keyData == nil` (i.e. when `fingerprint == "SHA256:UNAVAILABLE"`).
Two-line change: gate both equality checks on `keyData != nil`, or early-return
`isMismatch = true` so the user re-confirms instead of auto-trusting.

## 4. Drop blanket `privacy: .public` on log messages

**File:** `SSH TunnelBuilder/Classes/Logger.swift:23, 27, 31`

Every log level forces `\(message, privacy: .public)`. Call sites interpolate
SSH server hostnames, tunnel target hosts, and connection nicknames — all of
which end up in the unified log buffer and any `sysdiagnose` tarball the user
shares with Apple, IT, or vendor support. No passwords or key material are
logged anywhere (verified via repo-wide grep), but the operational metadata is
the user's private/corporate inventory and shouldn't ship verbatim.

**Fix:** drop the blanket `.public` annotation in `Logger.debug` / `.info` /
`.error`. The os.log default (`.private`) shows full values to a developer
attached via Xcode but redacts them to `<private>` in archived logs. Touched
call sites that genuinely need a public correlator can switch to interpolation
with `privacy: .public` at the use site (preferring `.private(mask: .hash)`
where a stable but non-reversible marker is enough).

Specific call sites that interpolate sensitive metadata into the format string —
worth a follow-up audit even after the central fix:

- `SSHManager.swift:183` — error description on connect failure (may embed `host:port`)
- `SSHManager.swift:333` — `tunnelInfo.remoteServer:remotePort` + originator
- `SSHManager.swift:358` — forwarding-channel failure with remote target
- `ConnectionStore.swift:453, 455, 459` — `connection.connectionInfo.name`

## 5. Clear `knownHostKey` on import

**File:** `SSH TunnelBuilder/Classes/ConnectionStore.swift:864`

`importConnections(from:)` copies the imported `knownHostKey` verbatim into the
new `ConnectionInfo`. Because the SSH client treats any non-empty
`knownHostKey` as a previously trusted user pin, a malicious `.sshtunnels`
bundle can quietly pre-pin a host key the attacker controls — and on first
connect to that hostname the TOFU prompt is silently skipped.

The threat model here is narrow (the import is a full secrets backup, so an
attacker who can deliver a malicious bundle and persuade the user to open it
already controls everything inside it), but the silent TOFU bypass violates a
documented user-facing security promise.

**Fix:** in `importConnections`, force `knownHostKey: ""` so the user sees the
TOFU fingerprint prompt on first connect to each imported host. One-line change.

---

## Verification plan

- Build the project: zero warnings, zero errors.
- The existing test suite (currently blocked by the Swift Testing runner bug on
  the beta toolchain — see `CLAUDE.md`) is not relied on for verification.
  Where possible, behavioural checks are done in place via `XcodeRefreshCodeIssuesInFile`.
