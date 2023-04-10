import Foundation
import CloudKit
import Combine

class Connection: Identifiable, Equatable, Hashable, ObservableObject {
    let id: UUID
    let recordID: CKRecord.ID?
    @Published var name: String
    @Published var serverAddress: String
    @Published var portNumber: String
    @Published var username: String
    @Published var password: String
    @Published var privateKey: String
    @Published var localPort: String
    @Published var remoteServer: String
    @Published var remotePort: String
    
    @Published var bytesSent: Int64 = 0
    @Published var bytesReceived: Int64 = 0
    @Published var isActive: Bool = false
    
    init(id: UUID = UUID(),
         recordID: CKRecord.ID? = nil,
         name: String,
         serverAddress: String,
         portNumber: String,
         username: String,
         password: String,
         privateKey: String,
         localPort: String,
         remoteServer: String,
         remotePort: String) {
        
        self.id = id
        self.recordID = recordID
        self.name = name
        self.serverAddress = serverAddress
        self.portNumber = portNumber
        self.username = username
        self.password = password
        self.privateKey = privateKey
        self.localPort = localPort
        self.remoteServer = remoteServer
        self.remotePort = remotePort
    }
    
    init(record: CKRecord) {
        self.recordID = record.recordID
        self.id = UUID(uuidString: record.recordID.recordName) ?? UUID()
        self.name = record["name"] as? String ?? ""
        self.serverAddress = record["serverAddress"] as? String ?? ""
        self.portNumber = record["portNumber"] as? String ?? ""
        self.username = record["username"] as? String ?? ""
        self.password = record["password"] as? String ?? ""
        self.privateKey = record["privateKey"] as? String ?? ""
        self.localPort = record["localPort"] as? String ?? ""
        self.remoteServer = record["remoteServer"] as? String ?? ""
        self.remotePort = record["remotePort"] as? String ?? ""
    }
    
    // Identifiable comfirmity
    static func == (lhs: Connection, rhs: Connection) -> Bool {
        return lhs.id == rhs.id
    }
    
    // Hashable conformity
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}


