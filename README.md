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

## Screenshots
- Sidebar listing saved connections
- Detail view to view/edit connection info
- Status indicator and data counters

(Replace with real screenshots when available. For example, place images in a `docs/images/` folder and reference them like `![Sidebar](docs/images/sidebar.png)`.)

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
- Add user-facing error handling for CloudKit/SSH failures.
- Add more UI and logic tests.

## Contributing
Issues and pull requests are welcome. Please describe your changes and testing steps.

## License
See LICENSE.TXT for the full license text.
