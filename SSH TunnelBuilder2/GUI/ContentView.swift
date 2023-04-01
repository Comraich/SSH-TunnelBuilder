//
//  ContentView.swift
//  SSH TunnelBuilder2
//
//  Created by Simon Bruce-Cassidy on 14/03/2022.
//

import SwiftUI

struct ContentView: View {
    @ObservedObject var connectionStore: ConnectionStore
    @State private var selectedConnection: Connection?
    
    @State private var connectionName = ""
    @State private var serverAddress = ""
    @State private var portNumber = ""
    @State private var username = ""
    @State private var password = ""
    @State private var privateKey = ""
    @State private var localPort = ""
    @State private var remoteServer = ""
    @State private var remotePort = ""
    
    init(connectionStore: ConnectionStore) {
            self.connectionStore = connectionStore
        }
    
    var body: some View {
        NavigationView {
            NavigationList(connectionStore: connectionStore, selectedConnection: $selectedConnection, mode: $connectionStore.mode)
                .environmentObject(connectionStore)
                .onChange(of: selectedConnection) { connection in
                    if let connection = connection {
                        connectionName = connection.name
                        serverAddress = connection.serverAddress
                        portNumber = connection.portNumber
                        username = connection.username
                        password = connection.password
                        privateKey = connection.privateKey
                        localPort = connection.localPort
                        remoteServer = connection.remoteServer
                        remotePort = connection.remotePort
                    } else {
                        connectionName = ""
                        serverAddress = ""
                        portNumber = ""
                        username = ""
                        password = ""
                        privateKey = ""
                        localPort = ""
                        remoteServer = ""
                        remotePort = ""
                    }
                }
            MainView(connection: selectedConnection, connectionStore: connectionStore, mode: $connectionStore.mode, connectionName: $connectionName, serverAddress: $serverAddress, portNumber: $portNumber, username: $username, password: $password, privateKey: $privateKey, localPort: $localPort, remoteServer: $remoteServer, remotePort: $remotePort, selectedConnection: $selectedConnection)
                .environmentObject(connectionStore)
        }
    }
}

enum ConnectionState {
    case connected
    case disconnected
    case connecting
}

enum MainViewMode {
    case create
    case edit
    case view
    case loading
}

//struct ContentView_Previews: PreviewProvider {
//    static var previews: some View {
//        ContentView()
//    }
//}
