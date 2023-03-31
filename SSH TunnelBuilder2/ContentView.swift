//
//  ContentView.swift
//  SSH TunnelBuilder2
//
//  Created by Simon Bruce-Cassidy on 14/03/2022.
//

import SwiftUI

struct ContentView: View {
    @StateObject private var connectionStore = ConnectionStore()
    @State private var selectedConnection: Connection?
    // @State private var mode: MainViewMode = .create
    
    @State private var connectionName = ""
    @State private var serverAddress = ""
    @State private var portNumber = ""
    @State private var username = ""
    @State private var password = ""
    @State private var privateKey = ""
    @State private var localPort = ""
    @State private var remoteServer = ""
    @State private var remotePort = ""
    
    var body: some View {
        NavigationView {
            NavigationList(connectionStore: connectionStore, selectedConnection: $selectedConnection)
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
        }
    }
}

struct NavigationList: View {
    @ObservedObject var connectionStore: ConnectionStore
    @Binding var selectedConnection: Connection?
    
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
                        connectionStore.mode = .edit
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

struct ConnectionRow: View {
    let connection: Connection
    let isSelected: Bool
    
    var body: some View {
        Text(connection.name)
            .background(isSelected ? Color.blue.opacity(0.3) : Color.clear)
            .cornerRadius(5)
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

struct MainView: View {
    var connection: Connection?
    @ObservedObject var connectionStore: ConnectionStore
    @Binding var mode: MainViewMode
    
    @State private var connectionState: ConnectionState = .disconnected
    
    @Binding var connectionName: String
    @Binding var serverAddress: String
    @Binding var portNumber: String
    @Binding var username: String
    @Binding var password: String
    @Binding var privateKey: String
    @Binding var localPort: String
    @Binding var remoteServer: String
    @Binding var remotePort: String
    @Binding var selectedConnection: Connection?
    
    init(connection: Connection? = nil, connectionStore: ConnectionStore, mode: Binding<MainViewMode>, connectionName: Binding<String>, serverAddress: Binding<String>, portNumber: Binding<String>, username: Binding<String>, password: Binding<String>, privateKey: Binding<String>, localPort: Binding<String>, remoteServer: Binding<String>, remotePort: Binding<String>, selectedConnection: Binding<Connection?>) {
        self.connection = connection
        self.connectionStore = connectionStore
        _mode = mode
        _connectionName = connectionName
        _serverAddress = serverAddress
        _portNumber = portNumber
        _username = username
        _password = password
        _privateKey = privateKey
        _localPort = localPort
        _remoteServer = remoteServer
        _remotePort = remotePort
        _selectedConnection = selectedConnection
    }
    
    var body: some View {
        if mode == .loading {
            Text("Loading connections...")
                .font(.largeTitle)
                .padding()
        } else {
            VStack {
                if mode == .create {
                    Text("New Connection")
                        .font(.largeTitle)
                        .padding()
                }
                if mode == .view {
                    Text(connectionName)
                        .font(.largeTitle)
                        .padding()
                } else {
                    HStack {
                        Text("Connection name:")
                        Spacer()
                        TextField("Enter connection name", text: $connectionName)
                            .textFieldStyle(RoundedBorderTextFieldStyle())
                    }
                    .padding()
                }
                
                HStack {
                    if mode == .view {
                        Text("Connection Status:")
                        Spacer()
                        connectionIndicator
                            .padding(.trailing)
                    }
                    
                }
                .padding(.horizontal)
                
                if mode == .view {
                    Spacer()
                }
                
                VStack(alignment: .leading) {
                    Group {
                        infoRow(label: "Server Address:", value: $serverAddress)
                        infoRow(label: "Port Number:", value: $portNumber)
                        infoRow(label: "Username:", value: $username)
                        infoRow(label: "Password:", value: $password, isSecure: true)
                        infoRow(label: "Private Key:", value: $privateKey, isSecure: true)
                        infoRow(label: "Local Port:", value: $localPort)
                        infoRow(label: "Remote Server:", value: $remoteServer)
                        infoRow(label: "Remote Port:", value: $remotePort)
                    }
                    
                    HStack {
                        Button(action: {
                            if mode == .create {
                                connectionStore.createConnection(name: connectionName, serverAddress: serverAddress, portNumber: portNumber, username: username, password: password, privateKey: privateKey, localPort: localPort, remoteServer: remoteServer, remotePort: remotePort)
                                mode = .view
                            } else if mode == .view {
                                // Connect action
                            } else if mode == .edit {
                                if let connection = connection {
                                    let updatedConnection = Connection(id: connection.id, recordID: connection.recordID, name: $connectionName.wrappedValue, serverAddress: $serverAddress.wrappedValue, portNumber: $portNumber.wrappedValue, username: $username.wrappedValue, password: $password.wrappedValue, privateKey: $privateKey.wrappedValue, localPort: $localPort.wrappedValue, remoteServer: $remoteServer.wrappedValue, remotePort: $remotePort.wrappedValue)
                                    connectionStore.saveConnection(updatedConnection, recordID: connection.recordID)
                                    mode = .view
                                }
                            }
                        }) {
                            Text(mode == .create ? "Create" : mode == .view ? "Connect" : "Save")
                        }
                        .padding()
                        
                        Spacer()
                        if mode == .edit {
                            Text("Edit mode")
                        }
                    }
                    .padding(.bottom)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .toolbar {
                ToolbarItemGroup {
                    if mode == .create {
                        Button(action: {
                            connectionStore.mode = .view
                            if let firstConnection = connectionStore.connections.first {
                                selectedConnection = firstConnection
                            }
                        }) {
                            Text("Cancel")
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func infoRow(label: String, value: Binding<String>, isSecure: Bool = false) -> some View {
        HStack {
            Text(label)
            Spacer()
            if mode == .view {
                if isSecure {
                    if value.wrappedValue.isEmpty {
                        Text("")
                    } else {
                        Text("<obfuscated>")
                    }
                } else {
                    Text(value.wrappedValue)
                }
            } else {
                if isSecure {
                    SecureField("Enter \(label.lowercased())", text: value)
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                } else {
                    TextField("Enter \(label.lowercased())", text: value)
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                }
            }
        }
        .padding(.horizontal)
    }
    
    private var connectionIndicator: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(connectionStateColor)
                .frame(width: 10, height: 10)
            
            Text(connectionStateText)
        }
    }
    
    private var connectionStateText: String {
        switch connectionState {
        case .connected:
            return "Connected"
        case .disconnected:
            return "Disconnected"
        case .connecting:
            return "Connecting..."
        }
    }
    
    private var connectionStateColor: Color {
        switch connectionState {
        case .connected:
            return .green
        case .disconnected:
            return .red
        case .connecting:
            return .orange
        }
    }
    
    func changeMode(to newMode: MainViewMode) {
        self.mode = newMode
    }
}



struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
    }
}
