import SwiftUI

struct NavigationList: View {
    var connectionStore: ConnectionStore
    @Binding var selectedConnection: Connection?
    @Binding var mode: ConnectionStore.Mode
    
    var body: some View {
        List(selection: $selectedConnection) {
            ForEach(connectionStore.connections) { connection in
                // The List drives selection via its `selection:` binding and the
                // row `.tag`, so no extra tap gesture is needed.
                ConnectionRow(
                    name: connection.connectionInfo.name,
                    isSelected: selectedConnection == connection
                )
                .tag(connection)
            }
        }
        .listStyle(.sidebar)
        // Default the sidebar to a width that comfortably fits the window
        // controls plus all three primary toolbar buttons (Create / Edit /
        // Delete). Without this, macOS pushes the trailing items — Delete
        // first — into the "···" overflow menu at the default split width.
        .navigationSplitViewColumnWidth(min: 230, ideal: 300, max: 500)
        .navigationTitle("Navigation")
        // Use `.primaryAction` rather than `.automatic` so macOS keeps Create /
        // Edit / Delete visible side-by-side instead of pushing the trailing
        // items (Delete first) into the "···" overflow when the sidebar is
        // narrow.
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    connectionStore.mode = .create
                    selectedConnection = nil
                } label: {
                    Label("Create new connection", systemImage: "plus")
                }
                .help("Create new connection")
            }

            if selectedConnection != nil {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        mode = .edit
                        if let connection = selectedConnection {
                            connectionStore.updateTempConnection(with: connection)
                        }
                    } label: {
                        Label("Edit selected connection", systemImage: "pencil")
                    }
                    .help("Edit selected connection")
                }
            }

            if let connection = selectedConnection {
                ToolbarItem(placement: .primaryAction) {
                    Button(role: .destructive) {
                        connectionStore.deleteConnection(connection)
                        selectedConnection = nil
                    } label: {
                        Label("Delete selected connection", systemImage: "trash")
                    }
                    .help("Delete selected connection")
                }
            }
        }
    }
}
