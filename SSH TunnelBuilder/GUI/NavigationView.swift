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
        .frame(minWidth: 230)
        .navigationTitle("Navigation")
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Button(action: {
                    connectionStore.mode = .create
                    selectedConnection = nil
                }) {
                    Label("Create new connection", systemImage: "plus")
                }
                .help("Create new connection")
            }
            
            ToolbarItem(placement: .automatic) {
                if selectedConnection != nil {
                    Button(action: {
                        mode = .edit
                        if let connection = selectedConnection {
                            connectionStore.updateTempConnection(with: connection)
                        }
                    }) {
                        Label("Edit selected connection", systemImage: "pencil")
                    }
                    .help("Edit selected connection")
                }
            }
            
            ToolbarItem(placement: .automatic) {
                if let connection = selectedConnection {
                    Button(action: {
                        connectionStore.deleteConnection(connection)
                        selectedConnection = nil
                    }) {
                        Label("Delete selected connection", systemImage: "trash")
                    }
                    .help("Delete selected connection")
                }
            }
        }
    }
}
