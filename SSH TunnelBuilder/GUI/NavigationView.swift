import SwiftUI

struct NavigationList: View {
    @ObservedObject var connectionStore: ConnectionStore
    @Binding var selectedConnection: Connection?
    @Binding var mode: MainViewMode
    
    var body: some View {
        List(connectionStore.connections) { connection in
            NavigationLink(
                destination: mainViewForConnection(connection: connection),
                tag: connection,
                selection: $selectedConnection
            ) {
                ConnectionRow(connection: connection, isSelected: selectedConnection == connection)
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
                        // selectedConnection = selectedConnection
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
                if selectedConnection != nil {
                    Button(action: {
                        // Delete action
                        connectionStore.deleteConnection(selectedConnection!)
                        self.selectedConnection = nil
                    }) {
                        Image(systemName: "trash")
                    }
                    .help("Delete selected connection")
                }
            }
        }
    }
    
    func deleteConnection(_ connection: Connection) {
        connectionStore.deleteConnection(connection)
    }
    
    private func mainViewForConnection(connection: Connection) -> some View {
        MainView(connectionName: .constant(connection.connectionInfo.name),
                 serverAddress: .constant(connection.connectionInfo.serverAddress),
                 portNumber: .constant(connection.connectionInfo.portNumber),
                 username: .constant(connection.connectionInfo.username),
                 password: .constant(connection.connectionInfo.password),
                 privateKey: .constant(connection.connectionInfo.privateKey),
                 localPort: .constant(connection.tunnelInfo.localPort),
                 remoteServer: .constant(connection.tunnelInfo.remoteServer),
                 remotePort: .constant(connection.tunnelInfo.remotePort),
                 selectedConnection: .constant(connection),
                 tempConnection: .constant(connectionStore.tempConnection))
            .environmentObject(connectionStore)
    }
}
