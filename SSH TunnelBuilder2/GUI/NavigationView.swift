//
//  NavigationView.swift
//  SSH TunnelBuilder2
//
//  Created by Simon Bruce-Cassidy on 31/03/2023.
//

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
                        selectedConnection = selectedConnection
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
        MainView(connectionName: .constant(connection.name),
                 serverAddress: .constant(connection.serverAddress),
                 portNumber: .constant(connection.portNumber),
                 username: .constant(connection.username),
                 password: .constant(connection.password),
                 privateKey: .constant(connection.privateKey),
                 localPort: .constant(connection.localPort),
                 remoteServer: .constant(connection.remoteServer),
                 remotePort: .constant(connection.remotePort),
                 selectedConnection: .constant(connection),
                 tempConnection: .constant(connectionStore.tempConnection))
            .environmentObject(connectionStore)
    }
}
