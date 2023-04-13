import SwiftUI

struct MainView: View {
    @EnvironmentObject var connectionStore: ConnectionStore
    @State private var connectionState: ConnectionState = .disconnected
    @Environment(\.connection) private var connection
    
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
    
    @Binding var tempConnection: Connection?
    
    var body: some View {
        if connectionStore.mode == .loading {
            Text("Loading connections...")
                .font(.largeTitle)
                .padding()
        } else {
            VStack {
                connectionNameRow(label: "Connection Name:", value: connectionStore.mode == .edit ? Binding(get: { connectionStore.tempConnection?.connectionInfo.name ?? "" }, set: { newValue in connectionStore.tempConnection?.connectionInfo.name = newValue }) : $connectionName)
                    .padding()
                HStack {
                    if connectionStore.mode == .view {
                        Text("Connection Status:")
                        Spacer()
                        connectionIndicator
                            .padding(.trailing)
                    }
                    
                }
                .padding(.horizontal)
                if connectionStore.mode == .view {
                    if let connection = selectedConnection {
                        DataCounterView(connection: connection)
                            .padding()
                    } else {
                        Text("")
                    }
                    Spacer()
                }
                
                VStack(alignment: .leading) {
                    Group {
                        infoRow(label: "Server Address:", value: connectionStore.mode == .edit ? Binding(get: { connectionStore.tempConnection?.connectionInfo.serverAddress ?? "" }, set: { newValue in connectionStore.tempConnection?.connectionInfo.serverAddress = newValue }) : $serverAddress)
                        infoRow(label: "Port Number:", value: connectionStore.mode == .edit ? Binding(get: { connectionStore.tempConnection?.connectionInfo.portNumber ?? "" }, set: { newValue in connectionStore.tempConnection?.connectionInfo.portNumber = newValue }) : $portNumber)
                        infoRow(label: "User Name:", value: connectionStore.mode == .edit ? Binding(get: { connectionStore.tempConnection?.connectionInfo.username ?? "" }, set: { newValue in connectionStore.tempConnection?.connectionInfo.username = newValue }) : $username)
                        infoRow(label: "Password:", value: connectionStore.mode == .edit ? Binding(get: { connectionStore.tempConnection?.connectionInfo.password ?? "" }, set: { newValue in connectionStore.tempConnection?.connectionInfo.password = newValue }) : $password, isSecure: true)
                        infoRow(label: "Private Key:", value: connectionStore.mode == .edit ? Binding(get: { connectionStore.tempConnection?.connectionInfo.privateKey ?? "" }, set: { newValue in connectionStore.tempConnection?.connectionInfo.privateKey = newValue }) : $privateKey, isSecure: true)
                        infoRow(label: "Local Port:", value: connectionStore.mode == .edit ? Binding(get: { connectionStore.tempConnection?.tunnelInfo.localPort ?? "" }, set: { newValue in connectionStore.tempConnection?.tunnelInfo.localPort = newValue }) : $localPort)
                        infoRow(label: "Remote Server:", value: connectionStore.mode == .edit ? Binding(get: { connectionStore.tempConnection?.tunnelInfo.remoteServer ?? "" }, set: { newValue in connectionStore.tempConnection?.tunnelInfo.remoteServer = newValue }) : $remoteServer)
                        infoRow(label: "Remote Port:", value: connectionStore.mode == .edit ? Binding(get: { connectionStore.tempConnection?.tunnelInfo.remotePort ?? "" }, set: { newValue in connectionStore.tempConnection?.tunnelInfo.remotePort = newValue }) : $remotePort)
                    }
                    
                    HStack {
                        Button(action: {
                            if connectionStore.mode == .create {
                                connectionStore.createConnection(name: connectionName, serverAddress: serverAddress, portNumber: portNumber, username: username, password: password, privateKey: privateKey, localPort: localPort, remoteServer: remoteServer, remotePort: remotePort)
                                connectionStore.mode = .view
                            } else if connectionStore.mode == .view {
                                // Connect action
                            } else if connectionStore.mode == .edit {
                                if let tempConnection = connectionStore.tempConnection {
                                    connectionStore.saveConnection(tempConnection, connectionToUpdate: selectedConnection)
                                    selectedConnection = tempConnection
                                    connectionStore.mode = .view
                                }
                            }
                        }) {
                            Text(connectionStore.mode == .create ? "Create" : connectionStore.mode == .view ? "Connect" : "Save")
                        }
                        .padding()
                    }
                    .padding(.bottom)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .toolbar {
                ToolbarItemGroup {
                    if connectionStore.mode == .create {
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
            if connectionStore.mode == .view {
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
    
    private func connectionNameRow(label: String, value: Binding<String>) -> some View {
        HStack {
            Text(label)
                .font(.largeTitle)
            Spacer()
            if connectionStore.mode == .view {
                Text(value.wrappedValue)
                    .font(.largeTitle)
            } else {
                TextField("Enter connection name", text: value)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
                    // .font(.largeTitle)
            }
        }
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
        connectionStore.mode = newMode
    }
    
    private func customBinding(for keyPath: ReferenceWritableKeyPath<Connection, String>) -> Binding<String> {
        Binding<String>(
            get: { tempConnection?[keyPath: keyPath] ?? "" },
            set: { newValue in tempConnection?[keyPath: keyPath] = newValue }
        )
    }
    
    func updateTempConnection(connection: Connection) {
        tempConnection = connection
    }
}

struct ConnectionEnvironmentKey: EnvironmentKey {
    static var defaultValue: Connection?
}

extension EnvironmentValues {
    var connection: Connection? {
        get { self[ConnectionEnvironmentKey.self] }
        set { self[ConnectionEnvironmentKey.self] = newValue }
    }
}
