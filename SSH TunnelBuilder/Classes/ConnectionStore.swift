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
    static let knownHostKey = "knownHostKey"
}

// A wrapper to make error strings identifiable for SwiftUI Alerts
struct ErrorAlert: Identifiable {
    let id = UUID()
    let message: String
}

// MARK: - Structure to hold host key verification details for UI

/// Represents a host key validation request that requires user confirmation
struct HostKeyRequest: Identifiable {
    let id = UUID()
    let hostname: String
    let fingerprint: String
    let keyData: Data
    let completion: (Bool) -> Void
}

/// Main data store for SSH connections, managing CloudKit sync and local state
@MainActor // Mark the store to run updates on the MainActor
class ConnectionStore: ObservableObject {
    
    // MARK: - Nested Types
    
    enum Mode: CaseIterable, Codable {
        case create
        case edit
        case view
        case loading
    }
    
    @Published var mode: Mode = .loading
    @Published private(set) var connections: [Connection] = []
    @Published private(set) var tempConnection: Connection?
    
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
    @Published private(set) var errorAlert: ErrorAlert? = nil
    @Published var hostKeyRequest: HostKeyRequest? = nil

    private var managers: [UUID: SSHManager] = [:]

    /// Credentials storage (Keychain in production, mock for tests)
    private let credentialsStore: CredentialsStore

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
    
    init(credentialsStore: CredentialsStore = KeychainService.shared) {
        self.credentialsStore = credentialsStore
        // Since init is run on the Main Actor, we can use Task {} here.
        Task {
            await self.createCustomZoneAsync()
            if self.customZone != nil {
                await self.fetchConnectionsAsync(cursor: nil)
            } else {
                 self.mode = .create
                // Show a notice explaining the fallback
                self.cloudNotice = "CloudKit unavailable. You can create connections locally; credentials will be stored in Keychain."
            }
            
            // Fallback: if we're still loading after a short delay, allow creating locally
            do {
                try await Task.sleep(nanoseconds: 3_000_000_000) // 3 seconds
            } catch {
                // Sleep was cancelled; proceed without delay.
                Logger.debug("Task.sleep cancelled: \(error.localizedDescription)", log: Logger.cloudKit)
            }
            
            if self.mode == .loading {
                self.mode = .create
            }
        }
    }
    
    /// Internal initializer for testing and previews
    /// - Parameters:
    ///   - mode: Initial mode
    ///   - connections: Pre-populated connections
    ///   - credentialsStore: Credential storage (defaults to mock for tests)
    internal init(mode: Mode, connections: [Connection], credentialsStore: CredentialsStore = MockCredentialsStore()) {
        self.mode = mode
        self.connections = connections
        self.credentialsStore = credentialsStore
        // Don't start CloudKit tasks for test/preview instances
    }
    
    /// Clears all fields in the create connection form
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
    
    /// Displays an error alert to the user
    /// - Parameter message: The error message to display
    func showError(_ message: String) {
        errorAlert = ErrorAlert(message: message)
    }

    private func manager(for connection: Connection) -> SSHManager {
        if let existing = managers[connection.id] { return existing }
        // Ensure SSHManager initialization uses the correct, restored name
        let new = SSHManager(connection: connection) 
        managers[connection.id] = new
        return new
    }

    /// Initiates an SSH connection for the given connection object
    /// - Parameter connection: The connection to establish
    func connect(_ connection: Connection) {
        let mgr = manager(for: connection)
        
        // Configure the host key validation callback
        mgr.hostKeyValidationCallback = { [weak self] host, fingerprint, _, keyData, completion in
            Task { @MainActor in
                // We wrap the original completion to handle saving the key if trusted
                self?.hostKeyRequest = HostKeyRequest(hostname: host, fingerprint: fingerprint, keyData: keyData) { trusted in
                    if trusted {
                        // Update the connection object with the new trusted key
                        connection.connectionInfo.knownHostKey = keyData.base64EncodedString()
                        // Persist this change to CloudKit immediately
                        self?.saveConnection(connection, connectionToUpdate: connection)
                    }
                    completion(trusted)
                }
            }
        }
        
        Task {
            do {
                try await mgr.connect()
            } catch {
                self.errorAlert = ErrorAlert(message: "Connection failed: \(error.localizedDescription)")
            }
        }
    }

    /// Disconnects an active SSH connection
    /// - Parameter connection: The connection to disconnect
    func disconnect(_ connection: Connection) {
        if let mgr = managers[connection.id] {
            Task {
                await mgr.disconnect()
            }
        }
    }
    
    // MARK: - CloudKit Helpers (Synchronized via Task/Async/Await)

    private func createCustomZoneAsync() async {
        let newZone = CKRecordZone(zoneName: customZoneName)
        
        do {
            let savedZone = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<CKRecordZone, Error>) in
                let createZoneOperation = CKModifyRecordZonesOperation(recordZonesToSave: [newZone], recordZoneIDsToDelete: nil)
                
                var finalSavedZone: CKRecordZone?
                
                createZoneOperation.perRecordZoneSaveBlock = { (_, result) in
                    if case .success(let zone) = result {
                        finalSavedZone = zone
                    }
                }

                createZoneOperation.modifyRecordZonesResultBlock = { result in
                    switch result {
                    case .success:
                        if let zone = finalSavedZone {
                            continuation.resume(returning: zone)
                        } else {
                            // This might happen if the operation succeeds but perRecordZoneSaveBlock wasn't hit, 
                            // though unlikely for creation. Assume success based on operation result.
                            continuation.resume(returning: newZone) 
                        }
                    case .failure(let error):
                        continuation.resume(throwing: error)
                    }
                }
                self.database.add(createZoneOperation)
            }
            self.customZone = savedZone
        } catch {
            Logger.error("Failed to create custom zone: \(error.localizedDescription)", log: Logger.cloudKit)
            self.errorAlert = ErrorAlert(message: "Failed to create iCloud zone: \(error.localizedDescription)")
        }
    }
    
    private func fetchConnectionsAsync(cursor: CKQueryOperation.Cursor? = nil) async {
        guard let customZoneID = customZone?.zoneID else {
            self.mode = .create
            self.cloudNotice = "CloudKit not configured. Working locally with Keychain for credentials."
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
            CloudKitKeys.password, CloudKitKeys.privateKey, CloudKitKeys.localPort, CloudKitKeys.remoteServer, CloudKitKeys.remotePort,
            CloudKitKeys.knownHostKey
        ]
        queryOperation.zoneID = customZoneID
        queryOperation.queuePriority = .veryHigh
        
        var fetchedConnections: [Connection] = []

        queryOperation.recordMatchedBlock = { [weak self] recordID, result in
            guard let self = self else { return }
            switch result {
            case .success(let record):
                // Ensure migration/parsing runs on the main actor if it affects @Published state, 
                // but the code within migrateSecretsIfNeeded handles synchronization internally.
                self.migrateSecretsIfNeeded(from: record)
                if let connection = self.recordToConnection(record: record) {
                    fetchedConnections.append(connection)
                } else {
                    Logger.error("Failed to convert record to connection: \(record)", log: Logger.cloudKit)
                }
            case .failure(let error):
                Logger.error("Failed to fetch record \(recordID): \(error.localizedDescription)", log: Logger.cloudKit)
            }
        }

        // Bridge CKOperation to async/await using CheckedContinuation
        let (result, cursor) = await withCheckedContinuation { continuation in
            queryOperation.queryResultBlock = { result in
                switch result {
                case .success(let cursor):
                    continuation.resume(returning: (Result<Void, Error>.success(()), cursor))
                case .failure(let error):
                    continuation.resume(returning: (Result<Void, Error>.failure(error), nil))
                }
            }
            database.add(queryOperation)
        }

        // Update @Published properties only on completion of the operation
        self.connections.append(contentsOf: fetchedConnections)

        switch result {
        case .failure(let error):
            Logger.error("Error fetching connections: \(error.localizedDescription)", log: Logger.cloudKit)
            self.errorAlert = ErrorAlert(message: "Failed to fetch connections: \(error.localizedDescription)")

        case .success:
            if let nextCursor = cursor {
                Logger.debug("Fetching more connections", log: Logger.cloudKit)
                await self.fetchConnectionsAsync(cursor: nextCursor)
            } else {
                Logger.info("Finished fetching connections", log: Logger.cloudKit)
            }
        }

        self.mode = self.connections.isEmpty ? .create : .view
        self.cloudNotice = nil
    }

    func newConnection(connectionInfo: ConnectionInfo, tunnelInfo: TunnelInfo){
        let newConnection = Connection(connectionInfo: connectionInfo, tunnelInfo: tunnelInfo)
        Task { await saveConnectionAsync(newConnection) }
    }
    
    func updateTempConnection(with connection: Connection) {
        self.tempConnection = connection.copy() // Use a copy for editing
    }
    
    func clearTempConnection() {
        self.tempConnection = nil
    }

    func saveConnection(_ connection: Connection, connectionToUpdate: Connection? = nil) {
        Task { await saveConnectionAsync(connection, connectionToUpdate: connectionToUpdate) }
    }
    
    private func saveConnectionAsync(_ connection: Connection, connectionToUpdate: Connection? = nil) async {
        if let connectionToUpdate = connectionToUpdate {
            await updateConnectionAsync(connection, connectionToUpdate: connectionToUpdate)
        } else {
            await createConnectionAsync(connection)
        }
    }
    
    // Helper to wrap CKDatabase.fetch(withRecordID:completionHandler:)
    private func fetchRecord(with recordID: CKRecord.ID) async throws -> CKRecord {
        return try await withCheckedThrowingContinuation { continuation in
            database.fetch(withRecordID: recordID) { record, error in
                if let record = record {
                    continuation.resume(returning: record)
                } else if let error = error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(throwing: SSHTunnelError.cloudKitFetchFailed("Unknown error"))
                }
            }
        }
    }

    // Helper to wrap CKDatabase.save(_:completionHandler:)
    private func saveRecord(_ record: CKRecord) async throws -> CKRecord {
        return try await withCheckedThrowingContinuation { continuation in
            database.save(record) { savedRecord, error in
                if let savedRecord = savedRecord {
                    continuation.resume(returning: savedRecord)
                } else if let error = error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(throwing: SSHTunnelError.cloudKitSaveFailed("Unknown error"))
                }
            }
        }
    }

    // Helper to wrap CKDatabase.delete(withRecordID:completionHandler:)
    private func deleteRecord(with recordID: CKRecord.ID) async throws -> CKRecord.ID {
        return try await withCheckedThrowingContinuation { continuation in
            database.delete(withRecordID: recordID) { deletedRecordID, error in
                if let deletedRecordID = deletedRecordID {
                    continuation.resume(returning: deletedRecordID)
                } else if let error = error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(throwing: SSHTunnelError.cloudKitDeleteFailed("Unknown error"))
                }
            }
        }
    }

    private func updateConnectionAsync(_ connection: Connection, connectionToUpdate: Connection) async {
        guard let recordID = connectionToUpdate.recordID else { return }
        
        do {
            // FIX: Use async wrappers
            let fetchedRecord = try await fetchRecord(with: recordID)
            self.updateRecordFields(fetchedRecord, withConnection: connection)
            let savedRecord = try await saveRecord(fetchedRecord)
            
            if let index = self.connections.firstIndex(where: { $0.id == connection.id }) {
                if let newConnect = self.recordToConnection(record: savedRecord) {
                    self.connections[index] = newConnect
                }
            }
        } catch {
            self.errorAlert = ErrorAlert(message: "Failed to save changes: \(error.localizedDescription)")
        }
    }

    private func createConnectionAsync(_ connection: Connection) async {
        guard let zoneID = customZone?.zoneID else {
            self.errorAlert = ErrorAlert(message: "Cannot save connection: CloudKit zone not available.")
            return
        }
        
        let recordID = CKRecord.ID(recordName: connection.id.uuidString, zoneID: zoneID)
        let record = CKRecord(recordType: CloudKitKeys.recordType, recordID: recordID)
        updateRecordFields(record, withConnection: connection)
        
        record[CloudKitKeys.uuid] = connection.id.uuidString
        
        do {
            let savedRecord = try await saveRecord(record)
            await self.fetchConnectionAsync(withId: savedRecord.recordID)
        } catch {
            self.errorAlert = ErrorAlert(message: "Failed to save connection: \(error.localizedDescription)")
        }
    }

    private func fetchConnectionAsync(withId recordID: CKRecord.ID) async {
        do {
            let fetchedRecord = try await fetchRecord(with: recordID)
            self.migrateSecretsIfNeeded(from: fetchedRecord)
            if let connection = self.recordToConnection(record: fetchedRecord) {
                self.connections.append(connection)
            }
        } catch {
            self.errorAlert = ErrorAlert(message: "Failed to fetch connection: \(error.localizedDescription)")
        }
    }

    func updateRecordFields(_ record: CKRecord, withConnection connection: Connection) {
        record[CloudKitKeys.name] = connection.connectionInfo.name
        record[CloudKitKeys.serverAddress] = connection.connectionInfo.serverAddress
        record[CloudKitKeys.portNumber] = connection.connectionInfo.portNumber
        record[CloudKitKeys.username] = connection.connectionInfo.username
        record[CloudKitKeys.password] = "" // placeholder
        record[CloudKitKeys.privateKey] = "" // placeholder
        record[CloudKitKeys.knownHostKey] = connection.connectionInfo.knownHostKey
        
        // Keychain operations remain synchronous but are protected by @MainActor scope
        credentialsStore.savePassword(connection.connectionInfo.password, for: connection.id)
        credentialsStore.savePrivateKey(connection.connectionInfo.privateKey, for: connection.id)
        
        record[CloudKitKeys.localPort] = connection.tunnelInfo.localPort
        record[CloudKitKeys.remoteServer] = connection.tunnelInfo.remoteServer
        record[CloudKitKeys.remotePort] = connection.tunnelInfo.remotePort
    }

    func deleteConnection(_ connection: Connection) {
        // Always clean up keychain regardless of CloudKit state
        self.disconnect(connection)
        self.managers[connection.id] = nil
        credentialsStore.deleteCredentials(for: connection.id)
        
        guard let recordID = connection.recordID else {
            // Connection exists only locally (no CloudKit record yet)
            self.connections.removeAll { $0.id == connection.id }
            return
        }
        
        Task {
            do {
                let deletedRecordID = try await deleteRecord(with: recordID)
                self.connections.removeAll { $0.recordID == deletedRecordID }
            } catch {
                self.errorAlert = ErrorAlert(message: "Failed to delete connection from iCloud: \(error.localizedDescription)")
                // Note: Local state and keychain were already cleaned up above
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
        
        let passwordMigrated = migrateSecret(from: record, field: CloudKitKeys.password, for: uuid, saveAction: credentialsStore.savePassword)
        let keyMigrated = migrateSecret(from: record, field: CloudKitKeys.privateKey, for: uuid, saveAction: credentialsStore.savePrivateKey)

        if passwordMigrated || keyMigrated {
            Task {
                do {
                    _ = try await saveRecord(record)
                    if !self.hasShownMigrationNotice(for: uuid) {
                        self.migrationNotice = "Credentials for '\(friendlyName)' were moved to Keychain and removed from iCloud."
                        self.markMigrationNoticeShown(for: uuid)
                    }
                    Logger.info("Migrated secrets to Keychain and cleared CloudKit for record: \(record.recordID.recordName)", log: Logger.cloudKit)
                } catch {
                    Logger.error("Migration save error: \(error)", log: Logger.cloudKit)
                }
            }
        }
    }

    func recordToConnection(record: CKRecord) -> Connection? {
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
        
        let knownHostKey = (record[CloudKitKeys.knownHostKey] as? String) ?? ""
        
        // Keychain operations are synchronous
        let password = credentialsStore.loadPassword(for: uuid) ?? ""
        let privateKey = credentialsStore.loadPrivateKey(for: uuid) ?? ""
        // Note: privateKeyPassphrase is not persisted long-term

        let connectionInfo = ConnectionInfo(name: name, serverAddress: serverAddress, portNumber: portNumber, username: username, password: password, privateKey: privateKey, privateKeyPassphrase: "", knownHostKey: knownHostKey)
        let tunnelInfo = TunnelInfo(localPort: localPort, remoteServer: remoteServer, remotePort: remotePort)

        return Connection(id: uuid, recordID: record.recordID, connectionInfo: connectionInfo, tunnelInfo: tunnelInfo)
    }
}

