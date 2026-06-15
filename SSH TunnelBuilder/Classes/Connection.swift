import Foundation
import CloudKit
import Observation

struct ConnectionInfo {
    var name: String
    var serverAddress: String
    var portNumber: String
    var username: String
    var password: String
    var privateKey: String
    var privateKeyPassphrase: String
    var knownHostKey: String = "" // Base64 encoded host key
}

struct TunnelInfo {
    var localPort: String
    var remoteServer: String
    var remotePort: String
}

/// Represents the connection lifecycle states
/// Using an enum prevents invalid state combinations (e.g., both connecting AND connected)
enum ConnectionState: Equatable {
    case idle
    case connecting
    case connected
    case disconnecting
    case failed(String)  // Contains error message

    /// Whether the connection is currently active
    var isActive: Bool {
        if case .connected = self { return true }
        return false
    }

    /// Whether a connection attempt is in progress
    var isConnecting: Bool {
        if case .connecting = self { return true }
        return false
    }

    /// Whether disconnection is in progress
    var isDisconnecting: Bool {
        if case .disconnecting = self { return true }
        return false
    }
}

@MainActor
@Observable
class Connection: Identifiable, Equatable, Hashable {
    let id: UUID
    let recordID: CKRecord.ID?
    var connectionInfo: ConnectionInfo
    var tunnelInfo: TunnelInfo

    var bytesSent: Int64 = 0
    var bytesReceived: Int64 = 0
    var state: ConnectionState = .idle

    /// Convenience: whether the connection is active (connected)
    var isActive: Bool { state.isActive }

    /// Convenience: whether a connection attempt is in progress
    var isConnecting: Bool { state.isConnecting }
    
    init(id: UUID = UUID(),
         recordID: CKRecord.ID? = nil,
         connectionInfo: ConnectionInfo,
         tunnelInfo: TunnelInfo) {
        
        self.id = id
        self.recordID = recordID
        self.connectionInfo = connectionInfo
        self.tunnelInfo = tunnelInfo
    }

    func copy() -> Connection {
        let newConnection = Connection(id: self.id, recordID: self.recordID, connectionInfo: self.connectionInfo, tunnelInfo: self.tunnelInfo)
        newConnection.bytesSent = self.bytesSent
        newConnection.bytesReceived = self.bytesReceived
        newConnection.state = self.state
        return newConnection
    }
    
    // Equatable conformity
    nonisolated static func == (lhs: Connection, rhs: Connection) -> Bool {
        return lhs.id == rhs.id
    }

    // Hashable conformity
    nonisolated func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}
