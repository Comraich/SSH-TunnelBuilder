//
//  ContentView.swift
//  SSH TunnelBuilder2
//
//  Created by Simon Bruce-Cassidy on 14/03/2022.
//

import SwiftUI

struct ContentView: View {
    var body: some View {
        NavigationView {
            NavigationList()
            MainView()
        }
    }
}

struct NavigationList: View {
    var body: some View {
        List {
            NavigationLink(destination: MainView()) {
                Text("Item 1")
            }
            NavigationLink(destination: MainView()) {
                Text("Item 2")
            }
            NavigationLink(destination: MainView()) {
                Text("Item 3")
            }
        }
        .listStyle(SidebarListStyle())
        .frame(minWidth: 150)
        .navigationTitle("Navigation")
    }
}

enum ConnectionState {
    case connected
    case disconnected
    case connecting
}

struct MainView: View {
    @State private var serverAddress = ""
    @State private var portNumber = ""
    @State private var username = ""
    @State private var password = ""
    @State private var privateKey = ""
    
    @State private var connectionState: ConnectionState = .disconnected
    
    var body: some View {
        VStack {
            Text("Main Window")
                .font(.largeTitle)
                .padding()
            
            
            VStack(alignment: .leading) {
                HStack {
                    Text("Server Address:")
                    Spacer()
                    TextField("Enter server address", text: $serverAddress)
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                }
                .padding(.horizontal)
                
                HStack {
                    Text("Port Number:")
                    Spacer()
                    TextField("Enter port number", text: $portNumber)
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                }
                .padding(.horizontal)
                
                HStack {
                    Text("Username:")
                    Spacer()
                    TextField("Enter username", text: $username)
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                }
                .padding(.horizontal)
                
                HStack {
                    Text("Password:")
                    Spacer()
                    SecureField("Enter password", text: $password)
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                }
                .padding(.horizontal)
                
                HStack {
                    Text("Private Key:")
                    Spacer()
                    SecureField("Enter private key", text: $privateKey)
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                }
                .padding(.horizontal)
                
                HStack {
                    Text("Connection Status:")
                    Spacer()
                    connectionIndicator
                        .padding(.trailing)
                }
                .padding(.horizontal)
                
                Spacer()
                
                HStack {
                    Button(action: {
                        // Connect action
                    }) {
                        Text("Connect")
                    }
                    .padding()
                    
                    Button(action: {
                        // Edit action
                    }) {
                        Text("Edit")
                    }
                    .padding()
                    
                    Button(action: {
                        // Delete action
                    }) {
                        Text("Delete")
                    }
                    .padding()
                }
                .padding(.bottom)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
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
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
    }
}
