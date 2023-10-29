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
}

struct TunnelInfo {
    var localPort: String
    var remoteServer: String
    var remotePort: String
}

class Connection: Identifiable, Equatable, Hashable, ObservableObject {
    let id: UUID
    let recordID: CKRecord.ID?
    @Published var connectionInfo: ConnectionInfo
    @Published var tunnelInfo: TunnelInfo
    
    @Published var bytesSent: Int64 = 0
    @Published var bytesReceived: Int64 = 0
    @Published var isActive: Bool = false
    
    init(id: UUID = UUID(),
         recordID: CKRecord.ID? = nil,
         connectionInfo: ConnectionInfo,
         tunnelInfo: TunnelInfo) {
        
        self.id = id
        self.recordID = recordID
        self.connectionInfo = connectionInfo
        self.tunnelInfo = tunnelInfo
    }

//    init(record: CKRecord) {
//        self.recordID = record.recordID
//        self.id = UUID(uuidString: record.recordID.recordName) ?? UUID()
//        
//        let name = record["name"] as? String ?? ""
//        let serverAddress = record["serverAddress"] as? String ?? ""
//        let portNumber = record["portNumber"] as? String ?? ""
//        let username = record["username"] as? String ?? ""
//        let password = record["password"] as? String ?? ""
//        let privateKey = record["privateKey"] as? String ?? ""
//        self.connectionInfo = ConnectionInfo(name: name, serverAddress: serverAddress, portNumber: portNumber, username: username, password: password, privateKey: privateKey)
//        
//        let localPort = record["localPort"] as? String ?? ""
//        let remoteServer = record["remoteServer"] as? String ?? ""
//        let remotePort = record["remotePort"] as? String ?? ""
//        self.tunnelInfo = TunnelInfo(localPort: localPort, remoteServer: remoteServer, remotePort: remotePort)
//    }
    
    // Identifiable comfirmity
    static func == (lhs: Connection, rhs: Connection) -> Bool {
        return lhs.id == rhs.id
    }
    
    // Hashable conformity
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}


