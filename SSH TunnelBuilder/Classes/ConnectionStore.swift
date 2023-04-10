import Foundation
import CloudKit

class ConnectionStore: ObservableObject {
    @Published var mode: MainViewMode = .loading
    @Published var connections: [Connection] = []
    @Published var tempConnection: Connection?
    private let container = CKContainer.default()
    // private let publicDB = CKContainer.default().publicCloudDatabase
    private let database = CKContainer.default().privateCloudDatabase
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
        saveConnection(newConnection)
    }
    
    func updateTempConnection(with connection: Connection) {
        tempConnection = Connection(id: connection.id, name: connection.name, serverAddress: connection.serverAddress, portNumber: connection.portNumber, username: connection.username, password: connection.password, privateKey: connection.privateKey, localPort: connection.localPort, remoteServer: connection.remoteServer, remotePort: connection.remotePort)
    }

    func saveConnection(_ connection: Connection, connectionToUpdate: Connection? = nil) {
        let record: CKRecord
        
        if let connectionToUpdate = connectionToUpdate, let recordID = connectionToUpdate.recordID {
            // Update existing connection
            database.fetch(withRecordID: recordID) { fetchedRecord, error in
                if let error = error {
                    print("Error fetching record for update: \(error)")
                    return
                }
                
                if let fetchedRecord = fetchedRecord {
                    fetchedRecord["name"] = connection.name
                    fetchedRecord["serverAddress"] = connection.serverAddress
                    fetchedRecord["portNumber"] = connection.portNumber
                    fetchedRecord["username"] = connection.username
                    fetchedRecord["password"] = connection.password
                    fetchedRecord["privateKey"] = connection.privateKey
                    fetchedRecord["localPort"] = connection.localPort
                    fetchedRecord["remoteServer"] = connection.remoteServer
                    fetchedRecord["remotePort"] = connection.remotePort
                    
                    self.database.save(fetchedRecord) { savedRecord, error in
                        if let error = error {
                            print("Error updating connection: \(error)")
                            return
                        }
                        
                        DispatchQueue.main.async {
                            if let index = self.connections.firstIndex(where: { $0.id == connection.id }) {
                                self.connections[index] = Connection(record: fetchedRecord)
                            }
                        }
                    }
                }
            }
        } else {
            // Create new connection
            record = CKRecord(recordType: "Connection")
            record["name"] = connection.name
            record["serverAddress"] = connection.serverAddress
            record["portNumber"] = connection.portNumber
            record["username"] = connection.username
            record["password"] = connection.password
            record["privateKey"] = connection.privateKey
            record["localPort"] = connection.localPort
            record["remoteServer"] = connection.remoteServer
            record["remotePort"] = connection.remotePort
            
            database.save(record) { savedRecord, error in
                if let error = error {
                    print("Error saving connection: \(error)")
                    return
                }
                
                DispatchQueue.main.async {
                    self.connections.append(Connection(record: savedRecord!))
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

        return Connection(id: uuid, recordID: record.recordID, name: name, serverAddress: serverAddress, portNumber: portNumber, username: username, password: password, privateKey: privateKey, localPort: localPort, remoteServer: remoteServer, remotePort: remotePort)
    }
}

