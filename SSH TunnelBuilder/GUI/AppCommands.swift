import SwiftUI
import AppKit

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

        // Help ▸ replace the default Apple-help-search entry (which would try
        // to look us up in Apple's help system and fail) with an in-app help
        // window and a direct link to the issue tracker.
        CommandGroup(replacing: .help) {
            Button("SSH Tunnel Builder Help") {
                openWindow(id: "help")
            }
            .keyboardShortcut("?", modifiers: .command)

            Divider()

            Button("Report a Problem…") {
                if let url = URL(string: "https://github.com/Comraich/SSH-TunnelBuilder/issues/new") {
                    NSWorkspace.shared.open(url)
                }
            }
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
}
