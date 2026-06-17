[![CodeFactor](https://www.codefactor.io/repository/github/comraich/ssh-tunnelbuilder/badge)](https://www.codefactor.io/repository/github/comraich/ssh-tunnelbuilder)

# SSH Tunnel Manager

A SwiftUI app for creating, viewing, editing, and persisting SSH connection profiles (including local port forwarding) and establishing tunnels using SwiftNIO + NIOSSH. Connection records are stored in your private iCloud database via CloudKit, with sensitive credentials secured in the Keychain.

## Features
- Create, edit, and delete SSH connection profiles
- Store connection details in iCloud (Private Database, custom zone)
- Securely store passwords and private keys in the Keychain
- Automatic, one-time migration of secrets from CloudKit to Keychain for older records
- Password or private-key authentication, including **encrypted (passphrase-protected) keys** — see [Private key authentication](#private-key-authentication)
- Host-key verification with trust-on-first-use: unknown hosts prompt for confirmation, and the trusted key is pinned for later connections. If a pinned host's key later changes, a clearly-marked "Host Key Changed" prompt lets you re-trust the new key (e.g. after a legitimate server rekey) or cancel (possible MITM).
- Local port forwarding (DirectTCPIP) to a remote host:port
- A connection state machine (`idle` → `connecting` → `connected` → `disconnecting`, plus `failed`) driving consistent status UI
- Live byte counters (sent/received) per connection
- A menu bar traffic indicator ("SSH" above two dots — green TX blinks on data sent, red RX blinks on data received) that appears only while a tunnel is connected
- Optional, opt-in Spotlight indexing of connection **names** (off by default; never indexes hosts, usernames, ports, or credentials)
- SwiftUI `NavigationSplitView` interface with a navigation sidebar
- Clear error reporting via a modal error sheet

## Private key authentication

Keys are parsed in-app and handed to NIOSSH, which supports **Ed25519** and **ECDSA (P-256 / P-384 / P-521)**. RSA and DSA are **not** supported (NIOSSH has no RSA/DSA implementation; DSA is also obsolete). Unsupported keys are detected with clear guidance to convert them.

Supported formats (Ed25519 / ECDSA):

| Format | Unencrypted | Encrypted |
|---|---|---|
| OpenSSH (`BEGIN OPENSSH PRIVATE KEY`) | ✅ | ✅ `bcrypt` KDF + AES-128/192/256 in ctr/cbc/gcm |
| PKCS#8 (`BEGIN PRIVATE KEY`) | ✅ EC + Ed25519 | ✅ EC + Ed25519 (PBES2 / PBKDF2-SHA256 / AES-256-CBC) |
| SEC1 (`BEGIN EC PRIVATE KEY`) | ✅ ECDSA | — |

Passphrases are requested when needed and are **never persisted** — they must be re-entered each session. Not yet supported: the `chacha20-poly1305@openssh.com` and `3des-cbc` OpenSSH ciphers, and broader PKCS#8 cipher/KDF combinations.

## Architecture
- Model: `Connection` (with a `ConnectionState` machine), `ConnectionInfo`, `TunnelInfo`
- Persistence: `ConnectionStore` (CloudKit for metadata, Keychain for secrets) — credentials are accessed through a `CredentialsStore` protocol (`KeychainService`, with an in-memory mock for tests)
- Networking: `SSHManager` (SwiftNIO + NIOSSH, direct TCP/IP forwarding, host-key verification)
- Key parsing/decryption:
  - `PEMDecryptor` — PKCS#8 (PBES2/PBKDF2) and SEC1 parsing, plus a minimal ASN.1 reader
  - `OpenSSHKeyDecryptor` — decrypts encrypted `openssh-key-v1` private sections (AES-CTR/CBC/GCM)
  - `BcryptPBKDF` — Blowfish + `bcrypt_pbkdf` implemented from scratch (neither is in CryptoKit), used to key OpenSSH decryption
- Cross-cutting: `SSHTunnelError` (unified error type), `Logger` (`os.Logger` categories), `SpotlightIndexer` (opt-in)
- UI: `ContentView`, `NavigationList`, `MainView`, `DataCounterView`, `ConnectionRow`, `SettingsView`, `MenuBarTrafficView` (menu bar indicator)
- Testing: Unit tests built with the Swift Testing framework.

## Requirements
- macOS 14 (Sonoma) or newer
- Xcode 16+ (Swift 6 language mode)
- iCloud capability enabled (CloudKit, Private Database)
- Internet access for SSH connections

## Setup
1. Open the project in Xcode.
2. Enable iCloud & CloudKit on the app target:
   - Targets → Signing & Capabilities → "+ Capability" → iCloud → check "CloudKit".
   - Ensure an iCloud container is selected (usually the default).
3. Sign in with your Apple ID in Xcode Preferences.
4. Resolve Swift Package dependencies if prompted (SwiftNIO / NIOSSH).

CloudKit Notes:
- Uses a custom private record zone: `ConnectionZone`.
- Record type: `Connection` with fields for connection metadata.

## Build & Run
- Select the app scheme and press **Run** (⌘R).
- To run tests, press **Test** (⌘U).
- On first launch, the app creates the custom CloudKit zone and fetches existing connections.
- If no records are found, the UI opens in Create mode.

## Usage
- Create: Click the + button, fill in fields, and click "Create".
- Edit: Select a connection, click the pencil icon, modify fields, and click "Save".
- Delete: Select a connection and click the trash icon.
- Connect: Select a connection and click the "Connect" button to establish a tunnel. If no credentials are saved, a sheet prompts for a password and/or private key (with a passphrase field for encrypted keys). The first time you connect to an unknown host, you're asked to confirm its key, which is then pinned for future connections. If the server later presents a different key, a "Host Key Changed" warning surfaces the new fingerprint and lets you re-trust it (the action button is marked destructive) or cancel.

## Security
- Passwords and private keys are securely stored in the system Keychain; only non-sensitive metadata is kept in CloudKit.
- Private-key passphrases are never persisted — they're entered per session and used only in memory.
- Host keys are verified: unknown hosts require explicit confirmation (trust-on-first-use). A changed host key for a known host blocks the connection and triggers a distinct "Host Key Changed" prompt — you must explicitly re-trust the new key (via a destructive-styled action) before the new fingerprint is pinned; cancelling leaves the original pinned key intact.
- The app includes logic to migrate any credentials previously stored insecurely in CloudKit to the Keychain, after which they are removed from CloudKit.
- Opt-in Spotlight indexing covers only connection names — never hosts, usernames, ports, or credentials.

## Third-Party Licenses
This project uses third-party components:
- SwiftNIO and SwiftNIO-SSH by Apple Inc., licensed under the Apache License 2.0.

See NOTICE.txt for attributions and licensing details.

## Getting Help
- CloudKit setup
  - Ensure iCloud and CloudKit are enabled in Signing & Capabilities and an iCloud container is selected.
  - If records don’t appear, try signing out/in of iCloud on the device/simulator and re-run.
- Swift Package dependencies
  - File → Packages → Reset Package Caches, then Resolve Package Versions.
- Build issues
  - Product → Clean Build Folder, then rebuild.
- SSH connectivity
  - Verify host, port, and credentials independently (e.g., using ssh in Terminal).
  - Check firewall/VPN settings that may block connections.

## Recent improvements
- **Encrypted private keys** end-to-end: OpenSSH (bcrypt + AES-CTR/CBC/GCM, with a from-scratch Blowfish/`bcrypt_pbkdf`), encrypted PKCS#8 (PBES2/PBKDF2), and a passphrase collection flow. Ed25519 and ECDSA across OpenSSH, PKCS#8, and SEC1 formats. Fixed a SEC1 parsing bug and a latent ASN.1 slice-indexing crash.
- **Connection state machine** (`ConnectionState`) driving consistent status UI.
- **Modernization to Swift 6** language mode, `@Observable`, native async CloudKit (`recordZoneChanges`), `@Entry`, `ByteCountFormatStyle`, and the NIO singleton event-loop group.
- **`CredentialsStore` protocol** with a Keychain implementation and an in-memory mock for tests; deleting a connection now also clears its Keychain secrets.
- **Unified error handling** (`SSHTunnelError`) surfaced through a modal error sheet; `os.Logger` categories replaced `print`.
- **Opt-in Spotlight indexing** of connection names.
- **Menu bar traffic indicator** (`MenuBarExtra`): an "SSH" label above a green TX / red RX dot that blink as data flows, shown only while a tunnel is connected.

## Roadmap

Possible future work, roughly by area:

- **Networking & UI:** throttle live byte-counter updates (~100ms); continue moving NIO event-loop bridging toward async/await for cleaner cancellation; richer error differentiation (CloudKit vs. SSH) with optional "Details…".
- **Key support (optional polish):** the `chacha20-poly1305@openssh.com` and `3des-cbc` OpenSSH ciphers, and broader PKCS#8 cipher/KDF combinations.
- **Testing:** `SSHManager` connect/disconnect flows; CloudKit failure paths (mock `CKDatabase`, missing required fields); UI tests for create/edit/delete/connect.
- **Dependency hygiene:** prefer SPM resolution for `swift-collections` / `swift-system` over vendored manifests unless intentionally forked.
- **Docs:** add screenshots under `docs/images/` and reference them here.

## Contributing
Issues and pull requests are welcome. Please describe your changes and testing steps.

## License
See LICENSE.TXT for the full license text.
