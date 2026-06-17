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

import SwiftUI

/// App-wide menu commands operating on the shared `ConnectionStore`.
///
/// Selection lives in the store (`selectedConnection`), so these commands stay
/// in sync with the sidebar. Import/export are triggered indirectly: the command
/// sets `store.transferRequest`, which `ContentView` observes to run the
/// passphrase prompt and file dialog.
struct AppCommands: Commands {
    var store: ConnectionStore

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
