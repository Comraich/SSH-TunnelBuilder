//
//  ConnectionStore.swift
//  SSH TunnelBuilder2
//
//  Created by Simon Bruce-Cassidy on 28/03/2023.
//
import Foundation
import CloudKit

class ConnectionStore: ObservableObject {
    @Published var mode: MainViewMode = .loading
    @Published var connections: [Connection] = []
    private let container = CKContainer.default()
    private let publicDB = CKContainer.default().publicCloudDatabase
    private var customZone: CKRecordZone?
    private let customZoneName = "ConnectionZone"
    
    @Published var connectionName = ""
    @Published var serverAddress = ""
    @Published var portNumber = ""
    @Published var username = ""
    @Published var password = ""
    @Published var privateKey = ""
    @Published var localPort = ""
    @Published var remoteServer = ""
    @Published var remotePort = ""

    init() {
        createCustomZone { result in
            switch result {
            case .success():
                DispatchQueue.main.async {
                }
                print("Created custom zone successfully")
                self.fetchConnections(cursor: nil)
            case .failure(let error):
                print("Failed to create custom zone: \(error.localizedDescription)")
            }
        }
    }

    func createCustomZone(completion: @escaping (Result<Void, Error>) -> Void) {
        let customZone = CKRecordZone(zoneName: customZoneName)
        
        let createZoneOperation = CKModifyRecordZonesOperation(recordZonesToSave: [customZone], recordZoneIDsToDelete: nil)
        createZoneOperation.modifyRecordZonesCompletionBlock = { savedZones, deletedZoneIDs, error in
            if let error = error {
                print("Error creating custom zone: \(error.localizedDescription)")
                print("Detailed error: \(error)")
                completion(.failure(error))
            } else if let savedZone = savedZones?.first {
                self.customZone = savedZone
                completion(.success(()))
            }
        }
        
        container.privateCloudDatabase.add(createZoneOperation)
    }
    
    func fetchConnections(cursor: CKQueryOperation.Cursor? = nil) {
        let query = CKQuery(recordType: "Connection", predicate: NSPredicate(value: true))
        query.sortDescriptors = []
        
        let queryOperation: CKQueryOperation
        
        if let cursor = cursor {
            queryOperation = CKQueryOperation(cursor: cursor)
        } else {
            queryOperation = CKQueryOperation(query: query)
        }
        
        queryOperation.desiredKeys = ["uuid", "name", "serverAddress", "portNumber", "username", "password", "privateKey", "localPort", "remoteServer", "remotePort"]
        
        queryOperation.recordFetchedBlock = { [weak self] record in
            DispatchQueue.main.async {
                if let connection = self?.recordToConnection(record: record) {
                    self?.connections.append(connection)
                }
            }
        }
        
        queryOperation.queryCompletionBlock = { (cursor, error) in
            if let error = error {
                print("Error fetching connections: \(error.localizedDescription)")
            } else if let cursor = cursor {
                print("Fetching more connections")
                self.fetchConnections(cursor: cursor)
            } else {
                print("Fetched connections successfully.")
            }
            
            DispatchQueue.main.async {
                self.mode = self.connections.isEmpty ? .create : .view
            }
        }
        
        // Use the privateCloudDatabase instead of publicDB
        CKContainer.default().privateCloudDatabase.add(queryOperation)
    }

    func createConnection(name: String, serverAddress: String, portNumber: String, username: String, password: String, privateKey: String, localPort: String, remoteServer: String, remotePort: String) {
        let newConnection = Connection(name: name, serverAddress: serverAddress, portNumber: portNumber, username: username, password: password, privateKey: privateKey, localPort: localPort, remoteServer: remoteServer, remotePort: remotePort)
        print("Creating connection: \(newConnection)")
        saveConnection(newConnection)
    }
    
    func saveConnection(_ connection: Connection, recordID: CKRecord.ID? = nil) {
        let record: CKRecord
        
        if let recordID = recordID {
            record = CKRecord(recordType: "Connection", recordID: recordID)
        } else {
            record = CKRecord(recordType: "Connection")
        }

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
        
        CKContainer.default().privateCloudDatabase.save(record) { [weak self] savedRecord, error in
            if let error = error {
                print("Error saving connection: \(error.localizedDescription)")
                return
            }
            
            guard let savedRecord = savedRecord else { return }
            
            DispatchQueue.main.async {
                if let connection = self?.recordToConnection(record: savedRecord) {
                    print("Connection saved: \(connection)")
                    if let recordID = recordID {
                        if let index = self?.connections.firstIndex(where: { $0.recordID?.recordName == recordID.recordName }) {
                            self?.connections[index] = connection
                        }
                    } else {
                        self?.connections.append(connection)
                    }
                }
            }
        }
    }
    
    func deleteConnection(_ connection: Connection) {
        guard let recordID = connection.recordID else { return }
        
        CKContainer.default().privateCloudDatabase.delete(withRecordID: recordID) { [weak self] deletedRecordID, error in
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
        
        if let id = record["uuid"] as? String {
            print("Fetched uuid: \(id)")
        } else {
            print("Missing uuid")
        }

        if let name = record["name"] as? String {
            print("Fetched name: \(name)")
        } else {
            print("Missing name")
        }

        return Connection(id: uuid, recordID: record.recordID, name: name, serverAddress: serverAddress, portNumber: portNumber, username: username, password: password, privateKey: privateKey, localPort: localPort, remoteServer: remoteServer, remotePort: remotePort)
    }
}

