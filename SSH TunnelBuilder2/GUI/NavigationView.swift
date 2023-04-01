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
            NavigationLink(destination: mainViewForConnection(connection), tag: connection, selection: $selectedConnection) {
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
                        print("Selected connection: \(String(describing: selectedConnection ?? nil))")
                        mode = .edit
                        selectedConnection = selectedConnection
                    }) {
                        Image(systemName: "pencil")
                    }
                    .help("Edit selected connection")
                }
            }
            
            ToolbarItem(placement: .automatic) {
                if let selectedConnection = selectedConnection {
                    Button(action: {
                        // Delete action
                        connectionStore.deleteConnection(selectedConnection)
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
    
    func mainViewForConnection(_ connection: Connection) -> some View {
        MainView(connection: connection,
                 connectionStore: connectionStore,
                 mode: Binding.constant(.view),
                 connectionName: Binding.constant(connection.name),
                 serverAddress: Binding.constant(connection.serverAddress),
                 portNumber: Binding.constant(connection.portNumber),
                 username: Binding.constant(connection.username),
                 password: Binding.constant(connection.password),
                 privateKey: Binding.constant(connection.privateKey),
                 localPort: Binding.constant(connection.localPort),
                 remoteServer: Binding.constant(connection.remoteServer),
                 remotePort: Binding.constant(connection.remotePort),
                 selectedConnection: Binding.constant(connection.self))
    }
}
