import Foundation
import CloudKit
import Combine

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

@MainActor
class Connection: Identifiable, Equatable, Hashable, ObservableObject {
    let id: UUID
    let recordID: CKRecord.ID?
    @Published var connectionInfo: ConnectionInfo
    @Published var tunnelInfo: TunnelInfo
    
    @Published var bytesSent: Int64 = 0
    @Published var bytesReceived: Int64 = 0
    @Published var isActive: Bool = false
    @Published var isConnecting: Bool = false
    
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
        newConnection.isActive = self.isActive
        newConnection.isConnecting = self.isConnecting
        return newConnection
    }
    
    // Identifiable comfirmity
    nonisolated static func == (lhs: Connection, rhs: Connection) -> Bool {
        return lhs.id == rhs.id
    }
    
    // Hashable conformity
    nonisolated func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}
