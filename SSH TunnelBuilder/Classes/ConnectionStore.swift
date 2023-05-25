import Foundation
import CloudKit

class ConnectionStore: ObservableObject {
    @Published var mode: MainViewMode = .loading
    @Published var connections: [Connection] = []
    @Published var tempConnection: Connection?
    private let container = CKContainer.default()
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
                    // Nothing to dispatch
                }
                self.fetchConnections(cursor: nil)
            case .failure(let error):
                print("Failed to create custom zone: \(error.localizedDescription)")
            }
        }
    }

    func createCustomZone(completion: @escaping (Result<Void, Error>) -> Void) {
        let newZone = CKRecordZone(zoneName: customZoneName)
        
        let createZoneOperation = CKModifyRecordZonesOperation(recordZonesToSave: [newZone], recordZoneIDsToDelete: nil)
        createZoneOperation.modifyRecordZonesCompletionBlock = { savedZones, _, error in
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
        guard let customZoneID = customZone?.zoneID else { return }
        let query = CKQuery(recordType: "Connection", predicate: NSPredicate(value: true))
        query.sortDescriptors = []

        let queryOperation: CKQueryOperation

        if let cursor = cursor {
            queryOperation = CKQueryOperation(cursor: cursor)
        } else {
            queryOperation = CKQueryOperation(query: query)
        }

        queryOperation.desiredKeys = ["uuid", "name", "serverAddress", "portNumber", "username", "password", "privateKey", "localPort", "remoteServer", "remotePort"]
        queryOperation.zoneID = customZoneID

        queryOperation.recordFetchedBlock = { [weak self] record in
            DispatchQueue.main.async {
                if let connection = self?.recordToConnection(record: record) {
                    print("Fetched connection: \(connection)") // Add this line
                    self?.connections.append(connection)
                } else {
                    print("Failed to convert record to connection: \(record)") // Add this line
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
                print("Finished fetching connections") // Add this line
            }

            DispatchQueue.main.async {
                self.mode = self.connections.isEmpty ? .create : .view
            }
        }

        CKContainer.default().privateCloudDatabase.add(queryOperation)
    }

    func newConnection(connectionInfo: ConnectionInfo, tunnelInfo: TunnelInfo){
        let newConnection = Connection(connectionInfo: connectionInfo, tunnelInfo: tunnelInfo)
        saveConnection(newConnection)
    }
    
    func updateTempConnection(with connection: Connection) {
        self.tempConnection = connection
    }

    func saveConnection(_ connection: Connection, connectionToUpdate: Connection? = nil) {
        if let connectionToUpdate = connectionToUpdate {
            updateConnection(connection, connectionToUpdate: connectionToUpdate)
        } else {
            createConnection(connection)
        }
    }

    func updateConnection(_ connection: Connection, connectionToUpdate: Connection) {
        guard let recordID = connectionToUpdate.recordID else { return }
        
        database.fetch(withRecordID: recordID) { fetchedRecord, error in
            if let error = error {
                print("Error fetching record for update: \(error)")
                return
            }
            
            if let fetchedRecord = fetchedRecord {
                self.updateRecordFields(fetchedRecord, withConnection: connection, encodeData: true)
                
                self.database.save(fetchedRecord) { _, error in
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
    }

    func createConnection(_ connection: Connection) {
        let recordID = CKRecord.ID(recordName: connection.id.uuidString, zoneID: customZone!.zoneID)
        let record = CKRecord(recordType: "Connection", recordID: recordID)
        updateRecordFields(record, withConnection: connection, encodeData: true)
        
        record["uuid"] = connection.id.uuidString
        
        database.save(record) { _, error in
            if let error = error {
                print("Error saving connection: \(error)")
                return
            }
            
            self.fetchConnection(withId: recordID)
        }
    }

    func fetchConnection(withId recordID: CKRecord.ID) {
        database.fetch(withRecordID: recordID) { fetchedRecord, error in
            if let error = error {
                print("Error fetching connection: \(error.localizedDescription)")
                return
            }
            
            if let fetchedRecord = fetchedRecord, let connection = self.recordToConnection(record: fetchedRecord) {
                DispatchQueue.main.async {
                    self.connections.append(connection)
                }
            }
        }
    }

    func updateRecordFields(_ record: CKRecord, withConnection connection: Connection, encodeData: Bool) {
        record["name"] = connection.connectionInfo.name.data(using: .utf8)
        record["serverAddress"] = connection.connectionInfo.serverAddress.data(using: .utf8)
        record["portNumber"] = connection.connectionInfo.portNumber
        record["username"] = connection.connectionInfo.username.data(using: .utf8)
        record["password"] = connection.connectionInfo.password.data(using: .utf8)
        record["privateKey"] = connection.connectionInfo.privateKey.data(using: .utf8)
        record["localPort"] = String(connection.tunnelInfo.localPort)
        record["remoteServer"] = connection.tunnelInfo.remoteServer.data(using: .utf8)
        record["remotePort"] = String(connection.tunnelInfo.remotePort)
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
              let name = (record["name"] as? String)?.fromBase64(),
              let serverAddress = (record["serverAddress"] as? String)?.fromBase64(),
              let portNumber = (record["portNumber"] as? String)?.fromBase64(),
              let username = (record["username"] as? String)?.fromBase64(),
              let password = (record["password"] as? String)?.fromBase64(),
              let privateKey = (record["privateKey"] as? String)?.fromBase64(),
              let localPort = (record["localPort"] as? String)?.fromBase64(),
              let remoteServer = (record["remoteServer"] as? String)?.fromBase64(),
              let remotePort = (record["remotePort"] as? String)?.fromBase64() else {
            return nil
        }

        let connectionInfo = ConnectionInfo(name: name, serverAddress: serverAddress, portNumber: portNumber, username: username, password: password, privateKey: privateKey)
        let tunnelInfo = TunnelInfo(localPort: localPort, remoteServer: remoteServer, remotePort: remotePort)

        return Connection(id: uuid, recordID: record.recordID, connectionInfo: connectionInfo, tunnelInfo: tunnelInfo)
    }
}

extension String {
    func toBase64() -> String {
        return Data(self.utf8).base64EncodedString()
    }

    func fromBase64() -> String? {
        guard let data = Data(base64Encoded: self) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
