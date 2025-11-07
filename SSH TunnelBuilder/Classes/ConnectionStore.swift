import Foundation
import CloudKit

class ConnectionStore: ObservableObject {
    @Published var mode: MainViewMode = .loading
    @Published var connections: [Connection] = []
    @Published var tempConnection: Connection?
    @Published var connectionName = ""
    @Published var serverAddress = ""
    @Published var portNumber = ""
    @Published var username = ""
    @Published var password = ""
    @Published var privateKey = ""
    @Published var localPort = ""
    @Published var remoteServer = ""
    @Published var remotePort = ""
    @Published var migrationNotice: String? = nil

    private var managers: [UUID: SSHManager] = [:]
    
    private let container = CKContainer.default()
    private let database = CKContainer.default().privateCloudDatabase
    private var customZone: CKRecordZone?
    private let customZoneName = "ConnectionZone"
    
    private let migrationNotifiedKey = "MigratedCredentialsNotified"

    private func hasShownMigrationNotice(for uuid: UUID) -> Bool {
        let defaults = UserDefaults.standard
        let notified = defaults.array(forKey: migrationNotifiedKey) as? [String] ?? []
        return notified.contains(uuid.uuidString)
    }

    private func markMigrationNoticeShown(for uuid: UUID) {
        let defaults = UserDefaults.standard
        var notified = defaults.array(forKey: migrationNotifiedKey) as? [String] ?? []
        if !notified.contains(uuid.uuidString) {
            notified.append(uuid.uuidString)
            defaults.set(notified, forKey: migrationNotifiedKey)
        }
    }
    
    init() {
        createCustomZone { result in
            switch result {
            case .success():
                self.fetchConnections(cursor: nil)
            case .failure(let error):
                print("Failed to create custom zone: \(error.localizedDescription)")
            }
        }
    }

    private func manager(for connection: Connection) -> SSHManager {
        if let existing = managers[connection.id] { return existing }
        let new = SSHManager(connection: connection)
        managers[connection.id] = new
        return new
    }

    func connect(_ connection: Connection) {
        let mgr = manager(for: connection)
        mgr.connect()
    }

    func disconnect(_ connection: Connection) {
        if let mgr = managers[connection.id] {
            mgr.disconnect()
        }
    }
    
    func createCustomZone(completion: @escaping (Result<Void, Error>) -> Void) {
        let newZone = CKRecordZone(zoneName: customZoneName)

        let createZoneOperation = CKModifyRecordZonesOperation(recordZonesToSave: [newZone], recordZoneIDsToDelete: nil)

        // Capture the saved zone if CloudKit provides it
        createZoneOperation.perRecordZoneSaveBlock = { _, result in
            switch result {
            case .success(let savedZone):
                self.customZone = savedZone
            case .failure(let error):
                // We'll surface the error in the overall result block
                print("Error saving zone (perRecordZoneSaveBlock): \(error.localizedDescription)")
            }
        }

        // Final result of the operation (success/failure)
        createZoneOperation.modifyRecordZonesResultBlock = { result in
            switch result {
            case .failure(let error):
                print("Error creating custom zone: \(error.localizedDescription)")
                print("Detailed error: \(error)")
                completion(.failure(error))
            case .success:
                // If perRecordZoneSaveBlock didn't run or didn't set, fall back to local zone
                if self.customZone == nil {
                    self.customZone = newZone
                }
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

        queryOperation.desiredKeys = [
            "uuid", "name", "serverAddress", "portNumber", "username",
            "password", "privateKey", "localPort", "remoteServer", "remotePort"
        ]
        queryOperation.zoneID = customZoneID

        queryOperation.recordMatchedBlock = { [weak self] recordID, result in
            switch result {
            case .success(let record):
                DispatchQueue.main.async {
                    self?.migrateSecretsIfNeeded(from: record)
                    if let connection = self?.recordToConnection(record: record) {
                        print("Fetched connection: \(connection)")
                        self?.connections.append(connection)
                    } else {
                        print("Failed to convert record to connection: \(record)")
                    }
                }
            case .failure(let error):
                print("Failed to fetch record \(recordID): \(error.localizedDescription)")
            }
        }

        queryOperation.queryResultBlock = { [weak self] result in
            switch result {
            case .failure(let error):
                print("Error fetching connections: \(error.localizedDescription)")
            case .success(let cursor):
                if let cursor = cursor {
                    print("Fetching more connections")
                    self?.fetchConnections(cursor: cursor)
                } else {
                    print("Finished fetching connections")
                }
            }

            DispatchQueue.main.async {
                guard let self = self else { return }
                self.mode = self.connections.isEmpty ? .create : .view
            }
        }

        // Use the configured database instance
        database.add(queryOperation)
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
                self.updateRecordFields(fetchedRecord, withConnection: connection)
                
                self.database.save(fetchedRecord) { _, error in
                    if let error = error {
                        print("Error updating connection: \(error)")
                        return
                    }
                    
                     DispatchQueue.main.async {
                        if let index = self.connections.firstIndex(where: { $0.id == connection.id }) {
                            
                            if let newConnect = self.recordToConnection(record: fetchedRecord)
                            {
                                self.connections[index] = newConnect
                            }
                        }
                    }
                }
            }
        }
    }

    func createConnection(_ connection: Connection) {
        let recordID = CKRecord.ID(recordName: connection.id.uuidString, zoneID: customZone!.zoneID)
        let record = CKRecord(recordType: "Connection", recordID: recordID)
        updateRecordFields(record, withConnection: connection)
        
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
                self.migrateSecretsIfNeeded(from: fetchedRecord)
                DispatchQueue.main.async {
                    self.connections.append(connection)
                }
            }
        }
    }

    func updateRecordFields(_ record: CKRecord, withConnection connection: Connection) {
        record["name"] = connection.connectionInfo.name.toBase64()
        record["serverAddress"] = connection.connectionInfo.serverAddress.toBase64()
        record["portNumber"] = connection.connectionInfo.portNumber.toBase64()
        record["username"] = connection.connectionInfo.username.toBase64()
        // Do not store secrets in CloudKit; use Keychain instead
        record["password"] = "" // placeholder
        record["privateKey"] = "" // placeholder
        KeychainService.shared.savePassword(connection.connectionInfo.password, for: connection.id)
        KeychainService.shared.savePrivateKey(connection.connectionInfo.privateKey, for: connection.id)
        record["localPort"] = connection.tunnelInfo.localPort.toBase64()
        record["remoteServer"] = connection.tunnelInfo.remoteServer.toBase64()
        record["remotePort"] = connection.tunnelInfo.remotePort.toBase64()
    }

    func deleteConnection(_ connection: Connection) {
        guard let recordID = connection.recordID else { return }
        
        CKContainer.default().privateCloudDatabase.delete(withRecordID: recordID) { [weak self] deletedRecordID, error in
            if let error = error {
                print("Error deleting connection: \(error.localizedDescription)")
                return
            }
            
            DispatchQueue.main.async {
                if let toDelete = self?.connections.first(where: { $0.recordID == deletedRecordID }) {
                    self?.disconnect(toDelete)
                    self?.managers[toDelete.id] = nil
                    KeychainService.shared.deleteCredentials(for: toDelete.id)
                }
                self?.connections.removeAll { $0.recordID == deletedRecordID }
            }
        }
    }
    
    private func migrateSecretsIfNeeded(from record: CKRecord) {
        // Ensure we have a UUID to key the Keychain entries
        guard let id = record["uuid"] as? String, let uuid = UUID(uuidString: id) else { return }
        
        let friendlyName: String = (record["name"] as? String)?.fromBase64() ?? "connection"

        var didMigrate = false

        if let encodedPassword = record["password"] as? String, !encodedPassword.isEmpty,
           let decodedPassword = encodedPassword.fromBase64() {
            KeychainService.shared.savePassword(decodedPassword, for: uuid)
            record["password"] = ""
            didMigrate = true
        }

        if let encodedKey = record["privateKey"] as? String, !encodedKey.isEmpty,
           let decodedKey = encodedKey.fromBase64() {
            KeychainService.shared.savePrivateKey(decodedKey, for: uuid)
            record["privateKey"] = ""
            didMigrate = true
        }

        if didMigrate {
            database.save(record) { _, error in
                if let error = error {
                    print("Migration save error: \(error)")
                } else {
                    if !self.hasShownMigrationNotice(for: uuid) {
                        DispatchQueue.main.async {
                            self.migrationNotice = "Credentials for '\(friendlyName)' were moved to Keychain and removed from iCloud."
                            self.markMigrationNoticeShown(for: uuid)
                        }
                    }
                    print("Migrated secrets to Keychain and cleared CloudKit for record: \(record.recordID.recordName)")
                }
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
              let localPort = (record["localPort"] as? String)?.fromBase64(),
              let remoteServer = (record["remoteServer"] as? String)?.fromBase64(),
              let remotePort = (record["remotePort"] as? String)?.fromBase64() else {
            return nil
        }
        
        let password = KeychainService.shared.loadPassword(for: uuid) ?? ""
        let privateKey = KeychainService.shared.loadPrivateKey(for: uuid) ?? ""

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
