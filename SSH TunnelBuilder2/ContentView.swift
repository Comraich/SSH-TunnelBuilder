//
//  ContentView.swift
//  SSH TunnelBuilder2
//
//  Created by Simon Bruce-Cassidy on 14/03/2022.
//

import SwiftUI

struct ContentView: View {
    @StateObject private var connectionStore = ConnectionStore()

    var body: some View {
        NavigationView {
            NavigationList(connectionStore: connectionStore)
            MainView(connectionStore: connectionStore)
        }
    }
}


struct NavigationList: View {
    @ObservedObject var connectionStore: ConnectionStore
    
    var body: some View {
        List {
            ForEach(connectionStore.connections) { connection in
                NavigationLink(destination: MainView(connectionStore: connectionStore, connection: connection)) {
                    Text(connection.name)
                }
            }
        }
        .listStyle(SidebarListStyle())
        .frame(minWidth: 220)
        .navigationTitle("Navigation")
        .toolbar {
            Button(action: {
                // Connect action
            }) {
                Text("➕")
            }
            
            Button(action: {
                // Edit action
            }) {
                Text("📝")
            }
            
            Button(action: {
                // Delete action
            }) {
                Text("❌")
            }
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
}

struct MainView: View {
    @ObservedObject var connectionStore: ConnectionStore
    var connection: Connection?
    
    @State private var connectionState: ConnectionState = .disconnected
    
    @State private var connectionName = "Connection Name"
    @State private var serverAddress = ""
    @State private var portNumber = ""
    @State private var username = ""
    @State private var password = ""
    @State private var privateKey = ""
    @State private var localPort = ""
    @State private var remoteServer = ""
    @State private var remotePort = ""
    
    var mode: MainViewMode = .view
    
    var body: some View {
        VStack {
            if mode == .view {
                Text(connectionName)
                    .font(.largeTitle)
                    .padding()
            } else {
                TextField("Enter connection name", text: $connectionName)
                    .font(.largeTitle)
                    .padding()
                    .textFieldStyle(RoundedBorderTextFieldStyle())
            }
            
            HStack {
                Text("Connection Status:")
                Spacer()
                connectionIndicator
                    .padding(.trailing)
            }
            .padding(.horizontal)
            
            Spacer()
            
            VStack(alignment: .leading) {
                Group {
                    infoRow(label: "Server Address:", value: $serverAddress)
                    infoRow(label: "Port Number:", value: $portNumber)
                    infoRow(label: "Username:", value: $username)
                    infoRow(label: "Password:", value: $password)
                    infoRow(label: "Private Key:", value: $privateKey)
                    infoRow(label: "Local Port:", value: $localPort)
                    infoRow(label: "Remote Server:", value: $remoteServer)
                    infoRow(label: "Remote Port:", value: $remotePort)
                }
                
                HStack {
                    Button(action: {
                        if mode == .view {
                            // Connect action
                        } else {
                            // Save action
                        }
                    }) {
                        Text(mode == .view ? "Connect" : "Save")
                    }
                    .padding()
                    
                    Spacer()
                }
                .padding(.bottom)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
    
    @ViewBuilder
    private func infoRow(label: String, value: Binding<String>) -> some View {
        HStack {
            Text(label)
            Spacer()
            if mode == .view {
                Text(value.wrappedValue)
            } else {
                TextField("Enter \(label.lowercased())", text: value)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
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
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
    }
}
