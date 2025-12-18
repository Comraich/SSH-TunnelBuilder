[![CodeFactor](https://www.codefactor.io/repository/github/comraich/ssh-tunnelbuilder/badge)](https://www.codefactor.io/repository/github/comraich/ssh-tunnelbuilder)

# SSH Tunnel Manager

A SwiftUI app for creating, viewing, editing, and persisting SSH connection profiles (including local port forwarding) and establishing tunnels using SwiftNIO + NIOSSH. Connection records are stored in your private iCloud database via CloudKit, with sensitive credentials secured in the Keychain.

## Features
- Create, edit, and delete SSH connection profiles
- Store connection details in iCloud (Private Database, custom zone)
- Securely store passwords and private keys in the Keychain
- Automatic, one-time migration of secrets from CloudKit to Keychain for older records
- Password or private key (PEM) authentication
- Local port forwarding (DirectTCPIP) to a remote host:port
- Live byte counters (sent/received) per connection
- SwiftUI split-view interface with a navigation sidebar

## Architecture
- Model: `Connection`, `ConnectionInfo`, `TunnelInfo`
- Persistence: `ConnectionStore` (CloudKit for metadata, Keychain for secrets)
- Networking: `SSHManager` (SwiftNIO + NIOSSH, direct TCP/IP forwarding)
- UI: `ContentView`, `NavigationList`, `MainView`, `DataCounterView`, `ConnectionRow`
- Testing: Unit tests built with the Swift Testing framework.

## Requirements
- Xcode 15+ (or newer)
- Swift 5.9+ (or newer)
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
- Connect: Select a connection and click the "Connect" button to establish a tunnel.

## Security
- Passwords and private keys are securely stored in the system Keychain.
- The app includes logic to migrate any credentials previously stored insecurely in CloudKit to the Keychain, after which they are removed from CloudKit.

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

## Roadmap

The following items consolidate the current review feedback into actionable tasks. They are grouped by area to help with prioritization.

### SwiftUI Architecture & UI
- Migrate the split view from `NavigationView` to `NavigationSplitView` (iOS 17+/macOS 14+) for a more robust two-column layout and native selection handling.
- Standardize on environment injection for `ConnectionStore` where appropriate; pass bindings explicitly for selected items. Avoid mixing direct parameters and `environmentObject` unless necessary.
- Extract the error alert into a reusable view modifier (e.g., `.errorAlert(using:)`) to reduce duplication and keep `ContentView` focused.
- Scope UI-only enums to their owners (e.g., `MainView.Mode`) and consider `CaseIterable`/`Codable` if useful.
- Add richer SwiftUI previews using a mock store and sample data (`ConnectionStore.mockWithSampleData`).
- Provide helpful empty states in detail when `selectedConnection == nil` or when in `loading` mode.

### Testing
- Abstract `KeychainService` behind a `CredentialsStore` protocol; add an in-memory mock and update unit tests to use it. Keep one integration test that exercises the real Keychain.
- Add tests for edge cases in the authentication delegate:
  - When available methods are empty or unsupported, ensure we fail gracefully.
  - Verify ordering preference (public key first, then password) remains correct.
- Expand CloudKit mapping tests to include failure paths:
  - Missing required fields (e.g., `serverAddress`).
  - Legacy records with embedded secrets: ensure migration removes secrets from the record and stores them in the Keychain.
- Harden the `ByteCountFormatter` test to avoid locale fragility by setting a fixed locale or loosening exact string matches.

### Persistence & Security
- Ensure deleting a `Connection` also deletes credentials from the Keychain via `keychain.deleteCredentials(for:)` along the UI delete path.
- Private key handling:
  - If encrypted PEMs are not supported, detect and communicate this clearly in the UI.
  - If we plan to support encrypted PEMs, design a passphrase collection flow and error messaging.

### Networking & SSH
- Move networking to Swift Concurrency (async/await) where feasible, or provide clear bridging from NIO event loops to async tasks for UI-friendly cancellation and error handling.
- Introduce a small connection state machine:
  - States: `idle`, `connecting`, `connected`, `failed(error)`, `disconnecting`.
  - Events: `connect`, `disconnect`, `retry`, `error`.
  - Use this to drive consistent UI and prevent stuck states.
- Throttle live byte counter updates (e.g., ~100ms) and ensure UI updates occur on the main actor to reduce re-rendering overhead.

### Package & Dependency Hygiene
- Prefer SPM dependencies for `swift-collections` and `swift-system` rather than vendored manifests in the repo, unless we intentionally maintain forks.
- Remove or isolate experimental/"9999" availability manifests from the main app workspace to avoid toolchain conflicts if they are not required.

### UX & Error Handling
- Differentiate error surfaces:
  - CloudKit errors (account, network, permissions) with actionable suggestions.
  - SSH errors (authentication failed, host unreachable) with guidance and optional "Details…".
- Provide clear user messaging for unsupported key types or encrypted keys.

### Code Hygiene & Modeling
- Scope enums/helpers to logical owners to reduce global namespace pollution.
- Use `private(set)` on observable properties in `ConnectionStore` to enforce mutation via methods and preserve invariants.
- Evaluate whether `Connection` and nested types should be value types (`struct`) vs. reference types. If keeping classes, ensure `copy()` semantics are correct (already covered by tests).
- Add a `SampleData.swift` with a couple of sample `Connection`s to power previews and documentation screenshots.

### Nice-to-Haves
- Add UI tests for basic flows (create, edit, delete, connect) where feasible.
- Provide a troubleshooting guide section in the README with common CloudKit/SSH issues and resolutions.
- Add screenshots under `docs/images/` and reference them in the README.

## Contributing
Issues and pull requests are welcome. Please describe your changes and testing steps.

## License
See LICENSE.TXT for the full license text.
