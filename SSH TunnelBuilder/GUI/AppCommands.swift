// Copyright 2020-2026 Comraich ANS
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

import AppKit
import SwiftUI

/// App-wide menu commands operating on the shared `ConnectionStore`.
///
/// Selection lives in the store (`selectedConnection`), so these commands stay
/// in sync with the sidebar. Import/export are triggered indirectly: the command
/// sets `store.transferRequest`, which `ContentView` observes to run the
/// passphrase prompt and file dialog.
struct AppCommands: Commands {
    var store: ConnectionStore

    // `openWindow(id:)` brings the main window back if it has been closed.
    // SwiftUI's `Window` scene does not always populate the Window menu with a
    // re-open entry on its own, so we add one explicitly below.
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        // App ▸ override the default About item so the standard macOS panel
        // surfaces the license, source-code URL, and primary third-party
        // attribution alongside the name / version / copyright the panel
        // already reads from Info.plist.
        CommandGroup(replacing: .appInfo) {
            Button("About SSH TunnelBuilder") {
                Self.showAboutPanel()
            }
        }

        // File ▸ swap the default "New Window" for "New Connection", and add the
        // import / export items beneath it.
        CommandGroup(replacing: .newItem) {
            Button("New Connection") {
                store.selectedConnection = nil
                store.mode = .create
            }
            .keyboardShortcut("n", modifiers: .command)

            Divider()

            Button("Import Connections…") {
                store.transferRequest = .importConnections
            }
            .keyboardShortcut("i", modifiers: .command)

            Menu("Export") {
                Button("Export All…") {
                    store.transferRequest = .exportAll
                }
                .disabled(store.connections.isEmpty)

                Button("Export Selected…") {
                    store.transferRequest = .exportSelected
                }
                .disabled(store.selectedConnection == nil)
            }
        }

        // Connection ▸ lifecycle plus edit / delete on the current selection.
        CommandMenu("Connection") {
            Button("Connect") {
                if let connection = store.selectedConnection { store.connect(connection) }
            }
            .keyboardShortcut("k", modifiers: .command)
            .disabled(!canConnect)

            Button("Disconnect") {
                if let connection = store.selectedConnection { store.disconnect(connection) }
            }
            .keyboardShortcut("k", modifiers: [.command, .shift])
            .disabled(!canDisconnect)

            Divider()

            Button("Edit Connection…") {
                if let connection = store.selectedConnection {
                    store.updateTempConnection(with: connection)
                    store.mode = .edit
                }
            }
            .keyboardShortcut("e", modifiers: .command)
            .disabled(store.selectedConnection == nil)

            Button("Delete Connection") {
                if let connection = store.selectedConnection {
                    store.deleteConnection(connection)
                    store.selectedConnection = nil
                }
            }
            .keyboardShortcut(.delete, modifiers: .command)
            .disabled(store.selectedConnection == nil)
        }

        // Window ▸ a guaranteed re-open entry. With our single-`Window` scene
        // and `AppDelegate` keeping the app alive after the window is closed,
        // this is the canonical macOS way to bring it back from the menu bar.
        CommandGroup(before: .windowArrangement) {
            Button("Open main window") {
                openWindow(id: "main")
            }
            .keyboardShortcut("1", modifiers: .command)

            Divider()
        }
    }

    @MainActor private var canConnect: Bool {
        guard let connection = store.selectedConnection else { return false }
        return !connection.isActive && !connection.isConnecting
    }

    @MainActor private var canDisconnect: Bool {
        guard let connection = store.selectedConnection else { return false }
        return connection.isActive || connection.isConnecting
    }

    /// Presents the standard macOS About panel with rich credits showing the
    /// copyright, license, source-code URL, and primary third-party attribution.
    /// The copyright is rendered inside the credits area (rather than relying on
    /// `NSHumanReadableCopyright`) so the displayed text is controlled directly
    /// by this method regardless of how the build's Info.plist is configured.
    @MainActor
    private static func showAboutPanel() {
        let credits = NSMutableAttributedString()
        let bodyFont = NSFont.systemFont(ofSize: 11)
        let boldFont = NSFont.boldSystemFont(ofSize: 11)
        let centered = NSMutableParagraphStyle()
        centered.alignment = .center

        func append(_ text: String, link: String? = nil, bold: Bool = false) {
            var attrs: [NSAttributedString.Key: Any] = [
                .font: bold ? boldFont : bodyFont,
                .paragraphStyle: centered
            ]
            if let link, let url = URL(string: link) {
                attrs[.link] = url
            }
            credits.append(NSAttributedString(string: text, attributes: attrs))
        }

        append("Copyright © 2020-2026 Comraich ANS\n\n", bold: true)
        append("Licensed under the Apache License, Version 2.0\n")
        append("https://www.apache.org/licenses/LICENSE-2.0\n\n",
               link: "https://www.apache.org/licenses/LICENSE-2.0")
        append("Source code and third-party attributions:\n")
        append("https://github.com/Comraich/SSH-TunnelBuilder\n\n",
               link: "https://github.com/Comraich/SSH-TunnelBuilder")
        append("Built on Apple's SwiftNIO and NIOSSH.")

        NSApplication.shared.orderFrontStandardAboutPanel(options: [
            .credits: credits
        ])
    }
}
