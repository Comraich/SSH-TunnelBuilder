# SSH TunnelBuilder — Feature Walkthrough

A native **macOS (14+) SwiftUI app** for creating and managing SSH tunnels (local
port forwarding), built on Apple's SwiftNIO / NIOSSH stack. Connection profiles
sync via **iCloud (CloudKit)** while secrets are stored in the **macOS Keychain**.

## The Core Idea

You define named connection profiles. Each profile knows how to reach an SSH
server *and* what tunnel to build through it. When you connect, the app opens a
local listener on `127.0.0.1:<localPort>` and forwards traffic over SSH to
`<remoteServer>:<remotePort>` — classic `ssh -L` local forwarding (`SSHManager`
uses a NIOSSH `directTCPIP` channel and binds the local listener). You then point
your local client at `localhost:<localPort>`.

## Main Interface

A two-pane `NavigationSplitView` (`ContentView.swift`):

| Pane    | Contents                                                                                          |
|---------|---------------------------------------------------------------------------------------------------|
| Sidebar | List of saved connections with live status; toolbar buttons for **＋ new**, **✏️ edit**, **🗑 delete** (`NavigationView.swift`) |
| Detail  | The selected connection's fields, status, data counters, and connect button (`MainView.swift`)    |

A single `ConnectionStore.Mode` (`.loading`, `.view`, `.create`, `.edit`) drives
what the detail pane shows. Form fields rebind dynamically per mode via a
keypath-based `formBinding` helper in `MainView`.

## Feature Breakdown

### 1. Connection Profiles
Each profile (`Connection.swift`) holds connection info (name, server address,
port, username) and tunnel info (local port, remote server, remote port).
Profiles are created/edited through the detail form and persisted to your
**private CloudKit database** in a custom `ConnectionZone`, so they sync across
your Macs.

### 2. Secure Credential Handling
Passwords and private keys are **never stored in CloudKit** — only in the Keychain
(`KeychainService`). The CloudKit fields are written as empty placeholders
(`ConnectionStore.updateRecordFields`). There is also an automatic **migration
path**: if an older record still carries a secret, it is moved to the Keychain,
cleared from iCloud, and the user gets a one-time notice
(`migrateSecretsIfNeeded`).

### 3. Flexible Authentication
Connect with a password **or** a private key. If a connection has no stored
credentials, clicking **Connect** opens a credentials sheet (`ConnectButtonView`)
with rich PEM key handling:

- Detects key type (PKCS#8, EC, OpenSSH, RSA, DSA) and shows a green check or a
  warning.
- **Supported:** Ed25519 & ECDSA (OpenSSH unencrypted, EC PRIVATE KEY, PKCS#8
  including encrypted-with-passphrase).
- **Not supported:** RSA, DSA, encrypted OpenSSH keys — and instead of a cryptic
  failure, a guided dialog (`KeyValidationAlertView`) shows copy-paste
  `ssh-keygen` / `openssl` commands to generate or convert a key.
- Passphrases are used per-session only and are never saved.

### 4. Host Key Verification (TOFU)
On first connect to an unknown host, an alert shows the **fingerprint** and asks
you to trust it (`ContentView` / `hostKeyRequest`). If trusted, the host key is
base64-stored on the profile and synced, so future connections verify against it.

### 5. Live Connection Status & Metrics
A `ConnectionState` enum (`.idle` / `.connecting` / `.connected` /
`.disconnecting` / `.failed`) drives a colored indicator with spinners
(`ConnectionIndicatorView`), and a `DataCounterView` shows live **bytes
sent/received** through the tunnel.

### 6. Error Surfacing
Errors propagate from the NIO layer via callbacks to a modal **error sheet**
(`ErrorSheetView`), chosen over `.alert()` which was found unreliable on macOS.

### 7. Graceful Degradation
If **CloudKit is unavailable**, the app doesn't break — it falls back to
local-only operation with a notice, still using the Keychain for secrets
(`ConnectionStore.init`).

## Architecture at a Glance

- `Connection` / `ConnectionStore` — `@MainActor` data model + CloudKit / Keychain
  / SSHManager lifecycle coordinator.
- `SSHManager` — NIOSSH client that authenticates, builds the `directTCPIP`
  channel, and binds the local listener.
- `PEMDecryptor` / `OpenSSHKeyParser` — key parsing (PKCS#8 with PBKDF2
  decryption, ASN.1 via the vendored `swift-asn1`).
- `KeychainService` — secure storage behind a `CredentialsStore` protocol, with a
  mock implementation for tests.
- `Logger` — `os.log` wrapper with categories (ssh, keychain, cloudKit, crypto).
- `SSHTunnelError` — consolidated typed error enum.

## Requirements

- macOS 14+
- Dependencies via Swift Package Manager: SwiftNIO, NIOSSH (plus vendored
  swift-asn1 / swift-crypto)
- iCloud capability enabled (CloudKit, Private Database)
