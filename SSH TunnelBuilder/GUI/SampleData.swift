import Foundation

@MainActor
struct SampleData {
    static let connections: [Connection] = [
        {
            let info = ConnectionInfo(
                name: "Staging Server",
                serverAddress: "staging.example.com",
                portNumber: "22",
                username: "deploy",
                password: "",
                privateKey: "",
                privateKeyPassphrase: ""
            )
            let tunnel = TunnelInfo(
                localPort: "8080",
                remoteServer: "localhost",
                remotePort: "80"
            )
            return Connection(id: UUID(), connectionInfo: info, tunnelInfo: tunnel)
        }(),
        {
            let info = ConnectionInfo(
                name: "Production Server",
                serverAddress: "prod.example.com",
                portNumber: "22",
                username: "admin",
                password: "",
                privateKey: "",
                privateKeyPassphrase: ""
            )
            let tunnel = TunnelInfo(
                localPort: "8080",
                remoteServer: "localhost",
                remotePort: "80"
            )
            return Connection(id: UUID(), connectionInfo: info, tunnelInfo: tunnel)
        }()
    ]
}

