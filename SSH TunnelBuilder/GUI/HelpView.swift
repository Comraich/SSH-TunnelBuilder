//
//  HelpView.swift
//  SSH TunnelBuilder
//
//  In-app help window. Backs the Help menu so users have substantive,
//  offline-readable documentation without leaving the app.
//

import SwiftUI

/// The Help window. Sidebar of topics on the left, scrolling detail on the right.
struct HelpView: View {
    @State private var selection: HelpTopic? = .quickStart

    var body: some View {
        NavigationSplitView {
            List(HelpTopic.allCases, selection: $selection) { topic in
                Label(topic.title, systemImage: topic.icon).tag(topic)
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 220)
        } detail: {
            if let topic = selection {
                HelpDetailView(topic: topic)
            } else {
                ContentUnavailableView("Select a topic",
                                       systemImage: "questionmark.circle")
            }
        }
        .navigationTitle("SSH Tunnel Builder Help")
        .frame(minWidth: 720, minHeight: 520)
    }
}

enum HelpTopic: String, CaseIterable, Identifiable, Hashable {
    case quickStart
    case connections
    case privateKeys
    case importExport
    case privacy
    case troubleshooting
    case acknowledgments

    var id: String { rawValue }

    var title: String {
        switch self {
        case .quickStart: "Quick Start"
        case .connections: "Connections"
        case .privateKeys: "Private Keys"
        case .importExport: "Import & Export"
        case .privacy: "Privacy & Data"
        case .troubleshooting: "Troubleshooting"
        case .acknowledgments: "Acknowledgments"
        }
    }

    var icon: String {
        switch self {
        case .quickStart: "play.circle"
        case .connections: "network"
        case .privateKeys: "key"
        case .importExport: "square.and.arrow.up.on.square"
        case .privacy: "lock.shield"
        case .troubleshooting: "wrench.and.screwdriver"
        case .acknowledgments: "doc.text"
        }
    }
}

struct HelpDetailView: View {
    let topic: HelpTopic

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text(topic.title)
                    .font(.largeTitle.bold())
                    .padding(.bottom, 4)
                content
            }
            .frame(maxWidth: 640, alignment: .leading)
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    @ViewBuilder private var content: some View {
        switch topic {
        case .quickStart: quickStart
        case .connections: connections
        case .privateKeys: privateKeys
        case .importExport: importExport
        case .privacy: privacy
        case .troubleshooting: troubleshooting
        case .acknowledgments: acknowledgments
        }
    }

    // MARK: - Sections

    @ViewBuilder private var quickStart: some View {
        HelpParagraph("Welcome. SSH Tunnel Builder sets up local **SSH port forwarding** so you can reach services on a remote network through an SSH connection.")

        HelpHeader("Set up a tunnel")
        HelpStep(1, "**Add a connection** — click **+** in the sidebar.")
        HelpStep(2, "**Configure the SSH server** — host, port (usually 22), and username.")
        HelpStep(3, "**Choose authentication** — password, or a private key (with passphrase if required).")
        HelpStep(4, "**Set forwarding** — a **local port** on your Mac, plus the **remote host and port** the tunnel should reach via the SSH server.")
        HelpStep(5, "**Connect** — select the connection and press ⌘K, or use the Connection menu.")

        HelpParagraph("Once connected, point your tools at `localhost:<local-port>` to reach the remote service.")
    }

    @ViewBuilder private var connections: some View {
        HelpParagraph("Each connection bundles an SSH login and a single port-forwarding rule.")

        HelpBullet("**Name** — display name shown in the sidebar.")
        HelpBullet("**Host / Port / Username** — the SSH server you're connecting to.")
        HelpBullet("**Authentication** — password, or a private key (optional passphrase).")
        HelpBullet("**Local port** — the port on your Mac that the tunnel listens on.")
        HelpBullet("**Remote host / Remote port** — the destination as seen from the SSH server (e.g. `localhost:5432` for a database running on the remote machine).")

        HelpHeader("Status")
        HelpParagraph("The indicator next to each connection shows: idle, connecting, connected (with live traffic counters), disconnecting, or failed. While connected, the menu bar displays a small SSH indicator with TX/RX dots that blink with traffic.")

        HelpHeader("iCloud sync")
        HelpParagraph("Connections sync between your Macs via iCloud if you're signed in and have iCloud Drive enabled in System Settings. Secrets stay in the Keychain — only the connection metadata syncs.")
    }

    @ViewBuilder private var privateKeys: some View {
        HelpParagraph("Supported key algorithms: **Ed25519** and **ECDSA** (P-256 / P-384 / P-521).")
        HelpParagraph("RSA and DSA are **not** supported. DSA was removed from OpenSSH 10.0; RSA support depends on upstream work in NIOSSH that isn't yet available.")

        HelpHeader("Supported file formats")
        HelpBullet("**OpenSSH** (`openssh-key-v1`) — plain and encrypted (bcrypt + AES-CTR/CBC/GCM).")
        HelpBullet("**PKCS#8** (`BEGIN PRIVATE KEY`) — plain, and encrypted with PBES2 / PBKDF2-SHA256 / AES-256-CBC.")
        HelpBullet("**SEC1** (`BEGIN EC PRIVATE KEY`) — plain only.")

        HelpHeader("Passphrases")
        HelpParagraph("If your key is encrypted, you'll be prompted for the passphrase each time you connect. **Passphrases are never saved** — they live only in memory during a connect.")
    }

    @ViewBuilder private var importExport: some View {
        HelpParagraph("Back up and restore your connections with an encrypted `.sshtunnels` file.")

        HelpBullet("**File ▸ Export ▸ Export All…** or **Export Selected…** — write a backup.")
        HelpBullet("**File ▸ Import Connections…** — read one back.")

        HelpHeader("What's inside")
        HelpParagraph("An export is a **full backup**: passwords and private keys are read from the Keychain and included in the encrypted blob. Connection metadata travels with them.")

        HelpHeader("Encryption")
        HelpParagraph("You choose a passphrase. The app derives a key with **PBKDF2-HMAC-SHA256 (600,000 iterations)** over a fresh 16-byte salt, then encrypts the payload with **AES-256-GCM**.")
        HelpParagraph("**Don't lose the passphrase** — the file is unreadable without it. A wrong passphrase fails as a GCM tag mismatch and surfaces a friendly error.")

        HelpHeader("On import")
        HelpParagraph("Imported connections get fresh IDs, so importing never overwrites your existing entries.")
    }

    @ViewBuilder private var privacy: some View {
        HelpBullet("**Credentials in Keychain** — passwords and private keys are stored in the macOS Keychain and only accessed when you connect or export. Touch ID may prompt to authorize access.")
        HelpBullet("**iCloud sync (optional)** — non-secret connection metadata (name, host, port, etc.) syncs to your iCloud account if iCloud Drive is enabled. Secrets never leave the Keychain.")
        HelpBullet("**Host keys pinned on first use** — the app prompts the first time it sees a server's host key. After you trust it, the key is remembered. If the key later changes, the connection fails until you confirm again (this protects against man-in-the-middle attacks).")
        HelpBullet("**No analytics, no telemetry** — the app makes no external network calls beyond the SSH connections you configure.")
    }

    @ViewBuilder private var troubleshooting: some View {
        HelpHeader("Connection hangs in “Connecting…”")
        HelpParagraph("The host is reachable, but the SSH handshake or authentication isn't completing. Click **Disconnect**, double-check the username and key/password, and try again.")

        HelpHeader("“Wrong passphrase” or can't decrypt key")
        HelpParagraph("Confirm the key's format is supported (see **Private Keys**) and re-enter the passphrase carefully. Passphrases are not saved, so they must be entered each time.")

        HelpHeader("“Connection refused” when using the tunnel")
        HelpParagraph("The local port may already be in use, or the remote `host:port` can't be reached from the SSH server. Try a different local port, and confirm the remote service is up.")

        HelpHeader("Connections don't appear on another Mac")
        HelpParagraph("Both Macs must be signed in to the same iCloud account with iCloud Drive enabled. Sync can take a moment after the first save.")

        HelpHeader("Still stuck?")
        HelpParagraph("Choose **Help ▸ Report a Problem…** to open the issue tracker.")
    }

    @ViewBuilder private var acknowledgments: some View {
        HelpParagraph("SSH Tunnel Builder is built on the following open-source projects, all distributed under the Apache License, Version 2.0:")

        HelpBullet("**SwiftNIO** — networking foundation. © Apple Inc.")
        HelpBullet("**SwiftNIO SSH** — SSH protocol implementation. © Apple Inc.")
        HelpBullet("**Swift Crypto** — cryptographic primitives. © Apple Inc.")
        HelpBullet("**Swift ASN.1** — ASN.1 parsing for PKCS#8 / SEC1 keys. © Apple Inc.")
        HelpBullet("**Swift Atomics**, **Swift Collections**, **Swift System** — supporting libraries. © Apple Inc.")

        HelpParagraph("Full license text: <https://www.apache.org/licenses/LICENSE-2.0>")

        HelpParagraph("SSH Tunnel Builder itself is © 2020–2026 Comraich ANS.")
    }
}

// MARK: - Layout helpers

private struct HelpHeader: View {
    let title: String

    init(_ title: String) { self.title = title }

    var body: some View {
        Text(title)
            .font(.title3.bold())
            .padding(.top, 8)
    }
}

private struct HelpParagraph: View {
    let text: LocalizedStringKey

    init(_ text: LocalizedStringKey) { self.text = text }

    var body: some View {
        Text(text)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct HelpBullet: View {
    let text: LocalizedStringKey

    init(_ text: LocalizedStringKey) { self.text = text }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("•").foregroundStyle(.secondary)
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct HelpStep: View {
    let number: Int
    let text: LocalizedStringKey

    init(_ number: Int, _ text: LocalizedStringKey) {
        self.number = number
        self.text = text
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(number).")
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 20, alignment: .trailing)
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
    }
}

#Preview {
    HelpView()
}
