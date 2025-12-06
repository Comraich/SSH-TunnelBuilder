import Foundation
import CloudKit

private enum CloudKitKeys {
    static let recordType = "Connection"
    static let uuid = "uuid"
    static let name = "name"
    static let serverAddress = "serverAddress"
    static let portNumber = "portNumber"
    static let username = "username"
    static let password = "password"
    static let privateKey = "privateKey"
    static let localPort = "localPort"
    static let remoteServer = "remoteServer"
    static let remotePort = "remotePort"
}

// A wrapper to make error strings identifiable for SwiftUI Alerts
struct ErrorAlert: Identifiable {
    let id = UUID()
    let message: String
}

class ConnectionStore: ObservableObject {
    @Published var mode: MainViewMode = .loading
    @Published var connections: [Connection] = []
    @Published var tempConnection: Connection?
    
    // Properties for the "Create" form
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
    @Published var cloudNotice: String? = nil
    @Published var errorAlert: ErrorAlert? = nil

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
                DispatchQueue.main.async {
                    self.errorAlert = ErrorAlert(message: "Failed to create iCloud zone: \(error.localizedDescription)")
                    // Fall back to create mode so the UI doesn't stick on Loading
                    self.mode = .create
                    // Show a notice explaining the fallback
                    self.cloudNotice = "CloudKit unavailable. You can create connections locally; credentials will be stored in Keychain."
                }
            }
        }
        // Fallback: if we're still loading after a short delay, allow creating locally
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
            guard let self = self else { return }
            if self.mode == .loading {
                // Switch to create mode without showing a CloudKit warning: this case may simply be an empty database on first run.
                self.mode = .create
            }
        }
    }
    
    func clearCreateForm() {
        connectionName = ""
        serverAddress = ""
        portNumber = ""
        username = ""
        password = ""
        privateKey = ""
        localPort = ""
        remoteServer = ""
        remotePort = ""
    }

    private func manager(for connection: Connection) -> SSHManager {
        if let existing = managers[connection.id] { return existing }
        let new = SSHManager(connection: connection)
        managers[connection.id] = new
        return new
    }

    func connect(_ connection: Connection) {
        let mgr = manager(for: connection)
        Task {
            do {
                try await mgr.connect()
            } catch {
                await MainActor.run {
                    self.errorAlert = ErrorAlert(message: "Connection failed: \(error.localizedDescription)")
                }
            }
        }
    }

    func disconnect(_ connection: Connection) {
        if let mgr = managers[connection.id] {
            Task {
                await mgr.disconnect()
            }
        }
    }
    
    func createCustomZone(completion: @escaping (Result<Void, Error>) -> Void) {
        let newZone = CKRecordZone(zoneName: customZoneName)

        let createZoneOperation = CKModifyRecordZonesOperation(recordZonesToSave: [newZone], recordZoneIDsToDelete: nil)

        createZoneOperation.perRecordZoneSaveBlock = { _, result in
            switch result {
            case .success(let savedZone):
                self.customZone = savedZone
            case .failure(let error):
                print("Error saving zone (perRecordZoneSaveBlock): \(error.localizedDescription)")
            }
        }

        createZoneOperation.modifyRecordZonesResultBlock = { result in
            switch result {
            case .failure(let error):
                print("Error creating custom zone: \(error.localizedDescription)")
                completion(.failure(error))
            case .success:
                if self.customZone == nil {
                    self.customZone = newZone
                }
                completion(.success(()))
            }
        }

        container.privateCloudDatabase.add(createZoneOperation)
    }
    
    func fetchConnections(cursor: CKQueryOperation.Cursor? = nil) {
        guard let customZoneID = customZone?.zoneID else {
            DispatchQueue.main.async { [weak self] in
                self?.mode = .create
                if self?.cloudNotice == nil {
                    self?.cloudNotice = "CloudKit not configured. Working locally with Keychain for credentials."
                }
            }
            return
        }

        let query = CKQuery(recordType: CloudKitKeys.recordType, predicate: NSPredicate(value: true))
        query.sortDescriptors = []

        let queryOperation: CKQueryOperation
        if let cursor = cursor {
            queryOperation = CKQueryOperation(cursor: cursor)
        } else {
            queryOperation = CKQueryOperation(query: query)
        }

        queryOperation.desiredKeys = [
            CloudKitKeys.uuid, CloudKitKeys.name, CloudKitKeys.serverAddress, CloudKitKeys.portNumber, CloudKitKeys.username,
            CloudKitKeys.password, CloudKitKeys.privateKey, CloudKitKeys.localPort, CloudKitKeys.remoteServer, CloudKitKeys.remotePort
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
                DispatchQueue.main.async {
                    self?.errorAlert = ErrorAlert(message: "Failed to fetch connections: \(error.localizedDescription)")
                }
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
                self.cloudNotice = nil
            }
        }

        database.add(queryOperation)
    }

    func newConnection(connectionInfo: ConnectionInfo, tunnelInfo: TunnelInfo){
        let newConnection = Connection(connectionInfo: connectionInfo, tunnelInfo: tunnelInfo)
        saveConnection(newConnection)
    }
    
    func updateTempConnection(with connection: Connection) {
        self.tempConnection = connection.copy() // Use a copy for editing
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
        
        database.fetch(withRecordID: recordID) { [weak self] fetchedRecord, error in
            guard let self = self else { return }
            if let error = error {
                print("Error fetching record for update: \(error)")
                DispatchQueue.main.async {
                    self.errorAlert = ErrorAlert(message: "Failed to save changes: \(error.localizedDescription)")
                }
                return
            }
            
            if let fetchedRecord = fetchedRecord {
                self.updateRecordFields(fetchedRecord, withConnection: connection)
                
                self.database.save(fetchedRecord) { _, error in
                    if let error = error {
                        print("Error updating connection: \(error)")
                         DispatchQueue.main.async {
                            self.errorAlert = ErrorAlert(message: "Failed to update connection: \(error.localizedDescription)")
                        }
                        return
                    }
                    
                     DispatchQueue.main.async {
                        if let index = self.connections.firstIndex(where: { $0.id == connection.id }) {
                            if let newConnect = self.recordToConnection(record: fetchedRecord) {
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
        let record = CKRecord(recordType: CloudKitKeys.recordType, recordID: recordID)
        updateRecordFields(record, withConnection: connection)
        
        record[CloudKitKeys.uuid] = connection.id.uuidString
        
        database.save(record) { [weak self] _, error in
            guard let self = self else { return }
            if let error = error {
                print("Error saving connection: \(error)")
                DispatchQueue.main.async {
                    self.errorAlert = ErrorAlert(message: "Failed to save connection: \(error.localizedDescription)")
                }
                return
            }
            
            self.fetchConnection(withId: recordID)
        }
    }

    func fetchConnection(withId recordID: CKRecord.ID) {
        database.fetch(withRecordID: recordID) { [weak self] fetchedRecord, error in
            guard let self = self else { return }
            if let error = error {
                print("Error fetching connection: \(error.localizedDescription)")
                DispatchQueue.main.async {
                    self.errorAlert = ErrorAlert(message: "Failed to fetch connection: \(error.localizedDescription)")
                }
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
        record[CloudKitKeys.name] = connection.connectionInfo.name
        record[CloudKitKeys.serverAddress] = connection.connectionInfo.serverAddress
        record[CloudKitKeys.portNumber] = connection.connectionInfo.portNumber
        record[CloudKitKeys.username] = connection.connectionInfo.username
        record[CloudKitKeys.password] = "" // placeholder
        record[CloudKitKeys.privateKey] = "" // placeholder
        KeychainService.shared.savePassword(connection.connectionInfo.password, for: connection.id)
        KeychainService.shared.savePrivateKey(connection.connectionInfo.privateKey, for: connection.id)
        record[CloudKitKeys.localPort] = connection.tunnelInfo.localPort
        record[CloudKitKeys.remoteServer] = connection.tunnelInfo.remoteServer
        record[CloudKitKeys.remotePort] = connection.tunnelInfo.remotePort
    }

    func deleteConnection(_ connection: Connection) {
        guard let recordID = connection.recordID else { return }
        
        CKContainer.default().privateCloudDatabase.delete(withRecordID: recordID) { [weak self] deletedRecordID, error in
            if let error = error {
                print("Error deleting connection: \(error.localizedDescription)")
                DispatchQueue.main.async {
                    self?.errorAlert = ErrorAlert(message: "Failed to delete connection: \(error.localizedDescription)")
                }
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
    
    private func migrateSecret(from record: CKRecord, field: String, for uuid: UUID, saveAction: (String, UUID) -> Void) -> Bool {
        if let encodedValue = record[field] as? String, !encodedValue.isEmpty {
            saveAction(encodedValue, uuid)
            record[field] = ""
            return true
        }
        return false
    }
    
    private func migrateSecretsIfNeeded(from record: CKRecord) {
        guard let id = record[CloudKitKeys.uuid] as? String, let uuid = UUID(uuidString: id) else { return }
        
        let friendlyName: String = (record[CloudKitKeys.name] as? String) ?? "connection"
        
        let passwordMigrated = migrateSecret(from: record, field: CloudKitKeys.password, for: uuid, saveAction: KeychainService.shared.savePassword)
        let keyMigrated = migrateSecret(from: record, field: CloudKitKeys.privateKey, for: uuid, saveAction: KeychainService.shared.savePrivateKey)

        if passwordMigrated || keyMigrated {
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
        guard let id = record[CloudKitKeys.uuid] as? String,
              let uuid = UUID(uuidString: id),
              let name = record[CloudKitKeys.name] as? String,
              let serverAddress = record[CloudKitKeys.serverAddress] as? String,
              let portNumber = record[CloudKitKeys.portNumber] as? String,
              let username = record[CloudKitKeys.username] as? String,
              let localPort = record[CloudKitKeys.localPort] as? String,
              let remoteServer = record[CloudKitKeys.remoteServer] as? String,
              let remotePort = record[CloudKitKeys.remotePort] as? String else {
            return nil
        }
        
        let password = KeychainService.shared.loadPassword(for: uuid) ?? ""
        let privateKey = KeychainService.shared.loadPrivateKey(for: uuid) ?? ""

        let connectionInfo = ConnectionInfo(name: name, serverAddress: serverAddress, portNumber: portNumber, username: username, password: password, privateKey: privateKey)
        let tunnelInfo = TunnelInfo(localPort: localPort, remoteServer: remoteServer, remotePort: remotePort)

        return Connection(id: uuid, recordID: record.recordID, connectionInfo: connectionInfo, tunnelInfo: tunnelInfo)
    }
}
