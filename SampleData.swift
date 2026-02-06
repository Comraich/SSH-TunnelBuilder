import Foundation
import CloudKit

@MainActor
enum SampleData {
    
    // MARK: - Sample Connections
    
    static var webServerConnection: Connection {
        let connectionInfo = ConnectionInfo(
            name: "Web Server",
            serverAddress: "web.example.com",
            portNumber: "22",
            username: "webadmin",
            password: "secure123",
            privateKey: "",
            privateKeyPassphrase: "",
            knownHostKey: ""
        )
        let tunnelInfo = TunnelInfo(
            localPort: "8080",
            remoteServer: "localhost",
            remotePort: "80"
        )
        return Connection(connectionInfo: connectionInfo, tunnelInfo: tunnelInfo)
    }
    
    static var databaseConnection: Connection {
        let connectionInfo = ConnectionInfo(
            name: "Production Database",
            serverAddress: "db.example.com",
            portNumber: "22",
            username: "dbadmin",
            password: "",
            privateKey: samplePrivateKey,
            privateKeyPassphrase: "",
            knownHostKey: ""
        )
        let tunnelInfo = TunnelInfo(
            localPort: "5432",
            remoteServer: "db-internal.example.com",
            remotePort: "5432"
        )
        return Connection(connectionInfo: connectionInfo, tunnelInfo: tunnelInfo)
    }
    
    static var devServerConnection: Connection {
        let connectionInfo = ConnectionInfo(
            name: "Development Server",
            serverAddress: "dev.example.com",
            portNumber: "2222",
            username: "developer",
            password: "devpass",
            privateKey: "",
            privateKeyPassphrase: "",
            knownHostKey: ""
        )
        let tunnelInfo = TunnelInfo(
            localPort: "3000",
            remoteServer: "localhost",
            remotePort: "3000"
        )
        return Connection(connectionInfo: connectionInfo, tunnelInfo: tunnelInfo)
    }
    
    static var allSamples: [Connection] {
        [webServerConnection, databaseConnection, devServerConnection]
    }
    
    // MARK: - Sample Private Key (for preview purposes only - not a real key)
    
    static let samplePrivateKey = """
    -----BEGIN PRIVATE KEY-----
    MIIEvQIBADANBgkqhkiG9w0BAQEFAASCBKcwggSjAgEAAoIBAQC7VJTUt9Us8cKj
    MzEfYyjiWA4R4/M2bS1+fWIcPm15j9TnXg8pqQl+l/6M4g3TQ7G8mLvN0nOqhRmP
    -----END PRIVATE KEY-----
    """
}

// MARK: - Mock ConnectionStore

extension ConnectionStore {
    
    /// Creates a mock ConnectionStore pre-populated with sample data for previews
    @MainActor
    static func mockWithSampleData() -> ConnectionStore {
        return ConnectionStore(
            mode: .view,
            connections: SampleData.allSamples
        )
    }
}
