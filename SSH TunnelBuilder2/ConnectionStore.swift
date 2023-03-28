//
//  ConnectionStore.swift
//  SSH TunnelBuilder2
//
//  Created by Simon Bruce-Cassidy on 28/03/2023.
//
import Foundation
import CloudKit

class ConnectionStore: ObservableObject {
    @Published var connections: [Connection] = []
    
    private let container: CKContainer
    private let publicDB: CKDatabase
    
    init() {
        container = CKContainer.default()
        publicDB = container.publicCloudDatabase
        fetchConnections()
    }
    
    func fetchConnections() {
        let predicate = NSPredicate(value: true)
        let query = CKQuery(recordType: "Connection", predicate: predicate)
        
        publicDB.perform(query, inZoneWith: nil) { [weak self] records, error in
            if let error = error {
                print("Error fetching connections: \(error.localizedDescription)")
                return
            }
            
            guard let records = records else { return }
            
            DispatchQueue.main.async {
                self?.connections = records.compactMap { self?.recordToConnection(record: $0) }
            }
        }
    }
    
    func saveConnection(_ connection: Connection) {
        let record = CKRecord(recordType: "Connection")
        record["uuid"] = connection.id.uuidString as CKRecordValue
        record["name"] = connection.name as CKRecordValue
        record["serverAddress"] = connection.serverAddress as CKRecordValue
        record["portNumber"] = connection.portNumber as CKRecordValue
        record["username"] = connection.username as CKRecordValue
        record["password"] = connection.password as CKRecordValue
        record["privateKey"] = connection.privateKey as CKRecordValue
        record["localPort"] = connection.localPort as CKRecordValue
        record["remoteServer"] = connection.remoteServer as CKRecordValue
        record["remotePort"] = connection.remotePort as CKRecordValue
        
        publicDB.save(record) { [weak self] savedRecord, error in
            if let error = error {
                print("Error saving connection: \(error.localizedDescription)")
                return
            }
            
            guard let savedRecord = savedRecord else { return }
            
            DispatchQueue.main.async {
                self?.connections.append((self?.recordToConnection(record: savedRecord)!)!)
            }
        }
    }
    
    func deleteConnection(_ connection: Connection) {
        guard let recordID = connection.recordID else { return }
        
        publicDB.delete(withRecordID: recordID) { [weak self] deletedRecordID, error in
            if let error = error {
                print("Error deleting connection: \(error.localizedDescription)")
                return
            }
            
            DispatchQueue.main.async {
                self?.connections.removeAll { $0.recordID == deletedRecordID }
            }
        }
    }

    private func recordToConnection(record: CKRecord) -> Connection? {
        guard let id = record["uuid"] as? String,
              let uuid = UUID(uuidString: id),
              let name = record["name"] as? String,
              let serverAddress = record["serverAddress"] as? String,
              let portNumber = record["portNumber"] as? String,
              let username = record["username"] as? String,
              let password = record["password"] as? String,
              let privateKey = record["privateKey"] as? String,
              let localPort = record["localPort"] as? String,
              let remoteServer = record["remoteServer"] as? String,
              let remotePort = record["remotePort"] as? String else {
            return nil
        }

        return Connection(id: uuid, recordID: record.recordID, name: name, serverAddress: serverAddress, portNumber: portNumber, username: username, password: password, privateKey: privateKey, localPort: localPort, remoteServer: remoteServer, remotePort: remotePort)
    }
}

