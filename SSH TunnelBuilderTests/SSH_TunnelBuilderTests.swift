//
//  SSH_TunnelBuilderTests.swift
//  SSH TunnelBuilderTests
//
//  Created by Simon Bruce-Cassidy on 10/04/2023.
//

import XCTest
@testable import SSH_TunnelBuilder

class ConnectionStoreTests: XCTestCase {
    var connectionStore: ConnectionStore!
    
    override func setUp() {
        super.setUp()
        connectionStore = ConnectionStore()
    }
    
    override func tearDown() {
        connectionStore = nil
        super.tearDown()
    }
    
    func testCreateConnection() {
        // Count existing connections.
        let initialConnectionCount = connectionStore.connections.count
        
        // Create a new connection.
        connectionStore.createConnection(name: "Test Connection", serverAddress: "127.0.0.1", portNumber: "22", username: "testuser", password: "testpass", privateKey: "", localPort: "8080", remoteServer: "127.0.0.1", remotePort: "80")
        
        // Count the connections again.
        let newConnectionCount = connectionStore.connections.count
        
        // Test that the number of connections is incremented by 1.
        XCTAssertEqual(newConnectionCount, initialConnectionCount + 1, "When a new connection is created, the connection count should increment by 1.")
    }
}
