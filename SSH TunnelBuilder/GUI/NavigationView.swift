import SwiftUI

struct NavigationList: View {
    @ObservedObject var connectionStore: ConnectionStore
    @Binding var selectedConnection: Connection?
    @Binding var mode: MainViewMode
    
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
}
