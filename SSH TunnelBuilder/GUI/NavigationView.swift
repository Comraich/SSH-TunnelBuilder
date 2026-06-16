import SwiftUI

struct NavigationList: View {
    var connectionStore: ConnectionStore
    @Binding var selectedConnection: Connection?
    @Binding var mode: ConnectionStore.Mode
    
    var body: some View {
        List(selection: $selectedConnection) {
            ForEach(connectionStore.connections) { connection in
                ConnectionRow(connection: connection, isSelected: selectedConnection == connection)
                    .tag(connection)
                    .onTapGesture {
                        selectedConnection = connection
                    }
            }
        }
        .listStyle(SidebarListStyle())
        .frame(minWidth: 230)
        .navigationTitle("Navigation")
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Button(action: {
                    connectionStore.mode = .create
                    selectedConnection = nil
                }) {
                    Image(systemName: "plus")
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
                        Image(systemName: "pencil")
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
                        Image(systemName: "trash")
                    }
                    .help("Delete selected connection")
                }
            }
        }
    }
}
