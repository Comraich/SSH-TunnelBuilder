import Foundation
import CloudKit
import Observation

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
struct ErrorAlert: Identifiable, Equatable {
    let id = UUID()
    let message: String

    static func == (lhs: ErrorAlert, rhs: ErrorAlert) -> Bool {
        lhs.message == rhs.message
    }
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
@Observable
class ConnectionStore {
    
    // MARK: - Nested Types
    
    enum Mode: CaseIterable, Codable {
        case create
        case edit
        case view
        case loading
    }
    
    var mode: Mode = .loading
    private(set) var connections: [Connection] = []
    private(set) var tempConnection: Connection?

    // Properties for the "Create" form
    var connectionName = ""
    var serverAddress = ""
    var portNumber = ""
    var username = ""
    var password = ""
    var privateKey = ""
    var localPort = ""
    var remoteServer = ""
    var remotePort = ""

    var migrationNotice: String? = nil
    var cloudNotice: String? = nil
    var errorAlert: ErrorAlert? = nil
    var hostKeyRequest: HostKeyRequest? = nil

    /// The resume handler for an in-flight host-key prompt, if any. Tracked so a
    /// superseding prompt can deny the previous one instead of leaking its
    /// awaiting Task.
    @ObservationIgnored private var pendingHostKeyDecision: ((Bool) -> Void)?

    @ObservationIgnored private var managers: [UUID: SSHManager] = [:]

    /// Credentials storage (Keychain in production, mock for tests)
    private let credentialsStore: CredentialsStore

    /// Explicit CloudKit container identifier. Must match the value in
    /// SSH_TunnelBuilder.entitlements. We reference the container explicitly
    /// rather than via `CKContainer.default()` because `default()` resolves to
    /// `iCloud.<bundleID>` (the legacy container) regardless of the entitlements
    /// list, which would silently keep using the old container.
    static let containerIdentifier = "iCloud.no.comraich.sshTunnelBuilder"

    private let container = CKContainer(identifier: ConnectionStore.containerIdentifier)
    private var database: CKDatabase { container.privateCloudDatabase }
    @ObservationIgnored private var customZone: CKRecordZone?
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
    
    /// Produces a detailed, log-friendly description of a CloudKit error.
    /// Crucially this surfaces the underlying `CKError.Code` and any
    /// per-item partial errors, which `localizedDescription` alone hides.
    /// (e.g. the "Field 'recordName' is not marked queryable" condition.)
    private func cloudKitErrorDescription(_ error: Error) -> String {
        let ns = error as NSError
        var parts: [String] = ["domain=\(ns.domain) code=\(ns.code) desc=\(ns.localizedDescription)"]
        if let ckError = error as? CKError {
            parts.append("ckCode=\(ckError.code.rawValue) (\(String(describing: ckError.code)))")
            if let retry = ckError.retryAfterSeconds {
                parts.append("retryAfter=\(retry)s")
            }
            if let partial = ckError.partialErrorsByItemID, !partial.isEmpty {
                for (item, itemError) in partial {
                    let itemNS = itemError as NSError
                    parts.append("partial[\(item)]=code:\(itemNS.code) \(itemNS.localizedDescription)")
                }
            }
        }
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError {
            parts.append("underlying=domain:\(underlying.domain) code:\(underlying.code) \(underlying.localizedDescription)")
        }
        return parts.joined(separator: " | ")
    }
    
    /// If CloudKit setup hasn't resolved within this window, fall back to local
    /// create mode so the UI never gets stuck on the loading screen.
    private static let loadingFallbackSeconds = 8

    init(credentialsStore: CredentialsStore = KeychainService.shared) {
        self.credentialsStore = credentialsStore
        // init runs on the Main Actor, so these Tasks inherit @MainActor isolation.
        Task {
            // Watchdog runs concurrently with the CloudKit setup below. Because the
            // store is @MainActor, it gets to run during any `await` suspension in
            // the setup, so it genuinely times out a slow/hung fetch — unlike a
            // sequential sleep, which only runs *after* the fetch has returned.
            // Captures self strongly to match the enclosing Task; the `defer`
            // below cancels this watchdog as soon as setup finishes, so it never
            // outlives the work it is guarding.
            let watchdog = Task {
                try? await Task.sleep(for: .seconds(ConnectionStore.loadingFallbackSeconds))
                guard !Task.isCancelled else { return }
                if self.mode == .loading {
                    self.mode = .create
                    self.cloudNotice = "CloudKit is taking a while or is unavailable. You can create connections locally; credentials are stored in Keychain."
                }
            }
            defer { watchdog.cancel() }

            await self.createCustomZoneAsync()
            if self.customZone != nil {
                await self.fetchConnectionsAsync()
            } else {
                 Logger.error("Custom zone unavailable after createCustomZoneAsync; falling back to local create mode", log: Logger.cloudKit)
                 self.mode = .create
                // Show a notice explaining the fallback
                self.cloudNotice = "CloudKit unavailable. You can create connections locally; credentials will be stored in Keychain."
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

    /// Presents the unknown-host prompt and suspends until the user answers.
    /// On trust, records the key on the connection and persists it.
    /// - Returns: `true` if the user trusts the host, `false` otherwise.
    private func confirmHostKeyTrust(host: String, fingerprint: String,
                                     keyData: Data, connection: Connection) async -> Bool {
        // If a prior prompt is still awaiting an answer, deny it before replacing
        // it so its awaiting Task can't leak.
        pendingHostKeyDecision?(false)

        let trusted = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            // Resume at most once, whether the answer arrives from the UI or from
            // a superseding prompt clearing this one.
            var hasResumed = false
            let decide: (Bool) -> Void = { [weak self] decision in
                guard !hasResumed else { return }
                hasResumed = true
                self?.pendingHostKeyDecision = nil
                continuation.resume(returning: decision)
            }
            pendingHostKeyDecision = decide
            hostKeyRequest = HostKeyRequest(hostname: host, fingerprint: fingerprint,
                                            keyData: keyData, completion: decide)
        }

        if trusted {
            // Record the now-trusted key on the connection and persist to CloudKit.
            connection.connectionInfo.knownHostKey = keyData.base64EncodedString()
            saveConnection(connection, connectionToUpdate: connection)
        }
        return trusted
    }

    /// Populates `connection`'s secrets from the Keychain if they aren't already
    /// set in memory. A no-op for fields that already carry a value (e.g. typed
    /// into the credentials sheet for this session).
    private func hydrateCredentials(for connection: Connection) {
        if connection.connectionInfo.password.isEmpty {
            connection.connectionInfo.password = credentialsStore.loadPassword(for: connection.id) ?? ""
        }
        if connection.connectionInfo.privateKey.isEmpty {
            connection.connectionInfo.privateKey = credentialsStore.loadPrivateKey(for: connection.id) ?? ""
        }
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
        // Load stored secrets just before connecting. They're not kept in the
        // in-memory model at rest, so this is the point where they're read back —
        // and, when "require authentication" is on, where the OS prompts for
        // Touch ID / password. Values already present (e.g. just entered in the
        // credentials sheet) are left untouched.
        hydrateCredentials(for: connection)

        let mgr = manager(for: connection)

        // Configure the host key validation handler. It suspends until the user
        // answers the prompt, then returns their trust decision.
        mgr.hostKeyValidationHandler = { [weak self] host, fingerprint, _, keyData in
            guard let self else { return false }
            return await self.confirmHostKeyTrust(host: host, fingerprint: fingerprint,
                                                  keyData: keyData, connection: connection)
        }

        // Configure the error callback to show alerts
        mgr.errorCallback = { [weak self] errorMsg in
            Task { @MainActor in
                self?.showError(errorMsg)
            }
        }

        Task {
            do {
                Logger.info("Starting SSH connection for \(connection.connectionInfo.name)", log: Logger.ssh)
                try await mgr.connect()
                Logger.info("SSH connection successful for \(connection.connectionInfo.name)", log: Logger.ssh)
            } catch {
                // Show the error - SSHTunnelError provides good localized descriptions
                let errorMsg = error.localizedDescription
                Logger.error("SSH connection failed for \(connection.connectionInfo.name): \(errorMsg)", log: Logger.ssh)
                await MainActor.run {
                    self.errorAlert = ErrorAlert(message: errorMsg)
                }
            }
        }
    }

    /// Disconnects an active SSH connection
    /// - Parameter connection: The connection to disconnect
    func disconnect(_ connection: Connection) {
        if let mgr = managers[connection.id] {
            Task {
                await mgr.disconnect()
                // When credentials are protected, drop the hydrated secrets from
                // memory after use so the next connect re-authenticates. (When
                // protection is off we leave them, preserving the prior behaviour
                // where session-entered credentials survive a reconnect.)
                if self.isCredentialProtectionEnabled {
                    connection.connectionInfo.password = ""
                    connection.connectionInfo.privateKey = ""
                }
            }
        }
    }

    /// Whether the user has opted in to requiring authentication to use saved
    /// credentials. Mirrors the Settings toggle.
    var isCredentialProtectionEnabled: Bool {
        UserDefaults.standard.bool(forKey: KeychainService.protectionEnabledKey)
    }

    /// Re-keys all stored credentials to match the new protection preference.
    /// The preference itself is written by the Settings toggle (`@AppStorage`)
    /// before this runs; here we just bring existing Keychain items in line.
    func reprotectStoredCredentials(enabled: Bool) {
        credentialsStore.setCredentialProtection(enabled: enabled, for: connections.map(\.id))
    }
    
    // MARK: - CloudKit Helpers (Synchronized via Task/Async/Await)

    private func createCustomZoneAsync() async {
        let newZone = CKRecordZone(zoneName: customZoneName)
        
        do {
            let result = try await database.modifyRecordZones(saving: [newZone], deleting: [])
            // If the server didn't report a per-zone result (unlikely for a
            // successful save), fall back to the zone we asked it to create.
            let savedZone = try result.saveResults[newZone.zoneID]?.get() ?? newZone
            self.customZone = savedZone
            Logger.info("Custom zone ready: \(savedZone.zoneID.zoneName) owner=\(savedZone.zoneID.ownerName)", log: Logger.cloudKit)
        } catch {
            Logger.error("Failed to create custom zone: \(self.cloudKitErrorDescription(error))", log: Logger.cloudKit)
            self.errorAlert = ErrorAlert(message: "Failed to create iCloud zone: \(error.localizedDescription)")
        }
    }
    
    private func fetchConnectionsAsync() async {
        guard let customZoneID = customZone?.zoneID else {
            self.mode = .create
            self.cloudNotice = "CloudKit not configured. Working locally with Keychain for credentials."
            return
        }

        // Fetch via recordZoneChanges(inZoneWith:since:) rather than a CKQuery:
        // listing a custom zone this way needs NO queryable indexes (CKQuery
        // requires a Queryable index on `recordName`, which is easy to forget when
        // deploying to Production). We start from a nil change token to fetch every
        // record and intentionally do NOT persist the token across launches — the
        // app keeps no local record cache, so a persisted token would return only
        // deltas and the list would appear empty on relaunch. (Persisting the
        // token + caching records for incremental/offline sync is a future step.)
        // The token is still used within this call to page through `moreComing`.
        var fetchedRecords: [CKRecord] = []
        var recordErrors: [(name: String, error: Error)] = []
        var deletedRecordNames: [String] = []
        var fetchError: Error?
        var token: CKServerChangeToken?

        pageLoop: while true {
            do {
                let changes = try await database.recordZoneChanges(inZoneWith: customZoneID, since: token)
                for (recordID, modificationResult) in changes.modificationResultsByID {
                    switch modificationResult {
                    case .success(let modification):
                        fetchedRecords.append(modification.record)
                    case .failure(let error):
                        recordErrors.append((recordID.recordName, error))
                    }
                }
                for deletion in changes.deletions {
                    deletedRecordNames.append(deletion.recordID.recordName)
                }
                token = changes.changeToken
                if !changes.moreComing { break pageLoop }
            } catch {
                fetchError = error
                break pageLoop
            }
        }

        Logger.info("Fetch done: records=\(fetchedRecords.count) recordErrors=\(recordErrors.count) deleted=\(deletedRecordNames.count) fetchError=\(fetchError.map { self.cloudKitErrorDescription($0) } ?? "none")", log: Logger.cloudKit)

        // Back on the MainActor: report per-record failures, then map the records.
        for failure in recordErrors {
            Logger.error("Failed to fetch record \(failure.name): \(self.cloudKitErrorDescription(failure.error))", log: Logger.cloudKit)
        }

        if let fetchError {
            Logger.error("Error fetching connections: \(self.cloudKitErrorDescription(fetchError))", log: Logger.cloudKit)
            self.errorAlert = ErrorAlert(message: "Failed to fetch connections: \(fetchError.localizedDescription)")
        }

        var fetchedConnections: [Connection] = []
        for record in fetchedRecords {
            self.migrateSecretsIfNeeded(from: record)
            if let connection = self.recordToConnection(record: record) {
                fetchedConnections.append(connection)
            }
            // recordToConnection logs its own detail when it drops a record.
        }

        // Apply results: drop any reported deletions, then upsert fetched records.
        if !deletedRecordNames.isEmpty {
            let deleted = Set(deletedRecordNames)
            self.connections.removeAll { deleted.contains($0.id.uuidString) }
        }
        for connection in fetchedConnections {
            self.upsertConnection(connection)
        }

        // Sort connections by name in memory (CloudKit sorting requires indexes).
        self.connections.sort { $0.connectionInfo.name.localizedCaseInsensitiveCompare($1.connectionInfo.name) == .orderedAscending }

        Logger.info("Finished fetching connections (total: \(self.connections.count))", log: Logger.cloudKit)

        self.mode = self.connections.isEmpty ? .create : .view
        self.cloudNotice = nil
    }

    func newConnection(connectionInfo: ConnectionInfo, tunnelInfo: TunnelInfo){
        let newConnection = Connection(connectionInfo: connectionInfo, tunnelInfo: tunnelInfo)
        Task { await saveConnectionAsync(newConnection) }
    }
    
    func updateTempConnection(with connection: Connection) {
        let copy = connection.copy() // Use a copy for editing
        // Secrets aren't held in the in-memory model at rest (lazy loading), so
        // pull them into the editable copy now. Otherwise saving an edit (even
        // an unrelated change like the name) would persist empty secrets over
        // the stored ones. This is also where a future auth prompt for editing
        // would surface.
        if copy.connectionInfo.password.isEmpty {
            copy.connectionInfo.password = credentialsStore.loadPassword(for: connection.id) ?? ""
        }
        if copy.connectionInfo.privateKey.isEmpty {
            copy.connectionInfo.privateKey = credentialsStore.loadPrivateKey(for: connection.id) ?? ""
        }
        self.tempConnection = copy
    }

    /// Whether a password is stored for this connection, without reading it.
    func hasStoredPassword(_ connection: Connection) -> Bool {
        credentialsStore.hasPassword(for: connection.id)
    }

    /// Whether a private key is stored for this connection, without reading it.
    func hasStoredPrivateKey(_ connection: Connection) -> Bool {
        credentialsStore.hasPrivateKey(for: connection.id)
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
    
    /// Inserts the connection, or replaces the existing entry with the same id.
    /// Keeps the in-memory list free of duplicates when re-fetching after a save.
    private func upsertConnection(_ connection: Connection) {
        if let index = self.connections.firstIndex(where: { $0.id == connection.id }) {
            self.connections[index] = connection
        } else {
            self.connections.append(connection)
        }
        // Keep Spotlight in sync (no-op unless the user has opted in). This is the
        // single choke point for additions/updates, so it covers create, edit,
        // and each record restored during a fetch.
        SpotlightIndexer.index(connection)
    }

    private func updateConnectionAsync(_ connection: Connection, connectionToUpdate: Connection) async {
        guard let recordID = connectionToUpdate.recordID else {
            // No server record exists yet (never synced) — create one instead of
            // silently dropping the edit.
            Logger.info("updateConnectionAsync: no existing recordID; creating a new record instead (id=\(connection.id))", log: Logger.cloudKit)
            await createConnectionAsync(connection)
            return
        }

        do {
            let fetchedRecord = try await database.record(for: recordID)
            self.updateRecordFields(fetchedRecord, withConnection: connection)
            let savedRecord = try await database.save(fetchedRecord)

            if let newConnect = self.recordToConnection(record: savedRecord) {
                self.upsertConnection(newConnect)
            }
        } catch {
            Logger.error("Failed to update connection: \(self.cloudKitErrorDescription(error))", log: Logger.cloudKit)
            self.errorAlert = ErrorAlert(message: "Failed to save changes: \(error.localizedDescription)")
        }
    }

    private func createConnectionAsync(_ connection: Connection) async {
        guard let zoneID = customZone?.zoneID else {
            Logger.error("createConnectionAsync: customZone is nil; connection not persisted (id=\(connection.id))", log: Logger.cloudKit)
            self.errorAlert = ErrorAlert(message: "Cannot save connection: CloudKit zone not available.")
            return
        }

        let recordID = CKRecord.ID(recordName: connection.id.uuidString, zoneID: zoneID)
        let record = CKRecord(recordType: CloudKitKeys.recordType, recordID: recordID)
        updateRecordFields(record, withConnection: connection)

        record[CloudKitKeys.uuid] = connection.id.uuidString

        do {
            let savedRecord = try await database.save(record)
            await self.fetchConnectionAsync(withId: savedRecord.recordID)
        } catch {
            Logger.error("Failed to save connection: \(self.cloudKitErrorDescription(error))", log: Logger.cloudKit)
            self.errorAlert = ErrorAlert(message: "Failed to save connection: \(error.localizedDescription)")
        }
    }

    private func fetchConnectionAsync(withId recordID: CKRecord.ID) async {
        do {
            let fetchedRecord = try await database.record(for: recordID)
            self.migrateSecretsIfNeeded(from: fetchedRecord)
            if let connection = self.recordToConnection(record: fetchedRecord) {
                self.upsertConnection(connection)
            }
        } catch {
            Logger.error("Failed to fetch connection: \(self.cloudKitErrorDescription(error))", log: Logger.cloudKit)
            self.errorAlert = ErrorAlert(message: "Failed to fetch connection: \(error.localizedDescription)")
        }
    }

    // MARK: - Port field bridging (CloudKit schema stores ports as NUMBER_INT64)

    /// Writes a port-like value into a field that the CloudKit schema defines as
    /// `NUMBER_INT64`. The app models ports as `String`, so we parse to `Int64`.
    /// Blank or non-numeric values are stored as an absent field (read back as "").
    private func setPortField(_ record: CKRecord, _ key: String, _ stringValue: String) {
        let trimmed = stringValue.trimmingCharacters(in: .whitespaces)
        if let intValue = Int64(trimmed) {
            record[key] = intValue
        } else {
            record[key] = nil
        }
    }

    /// Reads a port-like field back into the app's `String` model. Accepts the
    /// current `Int64` schema as well as legacy `Int`/`String` representations,
    /// so mapping is robust across environments. Returns "" when absent.
    private func portString(_ record: CKRecord, _ key: String) -> String {
        if let intValue = record[key] as? Int64 { return String(intValue) }
        if let intValue = record[key] as? Int { return String(intValue) }
        if let stringValue = record[key] as? String { return stringValue }
        return ""
    }

    func updateRecordFields(_ record: CKRecord, withConnection connection: Connection) {
        record[CloudKitKeys.name] = connection.connectionInfo.name
        record[CloudKitKeys.serverAddress] = connection.connectionInfo.serverAddress
        setPortField(record, CloudKitKeys.portNumber, connection.connectionInfo.portNumber)
        record[CloudKitKeys.username] = connection.connectionInfo.username
        record[CloudKitKeys.password] = "" // placeholder
        record[CloudKitKeys.privateKey] = "" // placeholder
        record[CloudKitKeys.knownHostKey] = connection.connectionInfo.knownHostKey

        // Keychain operations remain synchronous but are protected by @MainActor scope
        credentialsStore.savePassword(connection.connectionInfo.password, for: connection.id)
        credentialsStore.savePrivateKey(connection.connectionInfo.privateKey, for: connection.id)

        setPortField(record, CloudKitKeys.localPort, connection.tunnelInfo.localPort)
        record[CloudKitKeys.remoteServer] = connection.tunnelInfo.remoteServer
        setPortField(record, CloudKitKeys.remotePort, connection.tunnelInfo.remotePort)
    }

    func deleteConnection(_ connection: Connection) {
        // Always clean up keychain regardless of CloudKit state
        self.disconnect(connection)
        self.managers[connection.id] = nil
        credentialsStore.deleteCredentials(for: connection.id)
        // Remove from Spotlight regardless of opt-in state, so a deleted
        // connection never lingers in the system index.
        SpotlightIndexer.deindex(id: connection.id)
        
        guard let recordID = connection.recordID else {
            // Connection exists only locally (no CloudKit record yet)
            self.connections.removeAll { $0.id == connection.id }
            return
        }
        
        Task {
            do {
                let deletedRecordID = try await database.deleteRecord(withID: recordID)
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
                    _ = try await database.save(record)
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
        // Per-field extraction so we can log exactly which field is missing
        // when a record is silently dropped from the list.
        func requireString(_ key: String) -> String? {
            if let value = record[key] as? String { return value }
            Logger.error("recordToConnection: record \(record.recordID.recordName) missing required field '\(key)'", log: Logger.cloudKit)
            return nil
        }

        guard let id = requireString(CloudKitKeys.uuid),
              let uuid = UUID(uuidString: id),
              let name = requireString(CloudKitKeys.name),
              let serverAddress = requireString(CloudKitKeys.serverAddress),
              let username = requireString(CloudKitKeys.username),
              let remoteServer = requireString(CloudKitKeys.remoteServer) else {
            return nil
        }

        // Port fields are stored as NUMBER_INT64 in the CloudKit schema; read
        // them leniently and convert back to the app's String model.
        let portNumber = portString(record, CloudKitKeys.portNumber)
        let localPort = portString(record, CloudKitKeys.localPort)
        let remotePort = portString(record, CloudKitKeys.remotePort)

        let knownHostKey = (record[CloudKitKeys.knownHostKey] as? String) ?? ""

        // Secrets are NOT loaded into the in-memory model here. They're read
        // lazily from the Keychain at the moment they're needed — at connect
        // time (`hydrateCredentials`) and when editing (`updateTempConnection`).
        // This keeps the whole connection list from pulling every secret on
        // launch, and is the single choke point a future "require auth to use
        // credentials" prompt can hook into. Existence (for display and the
        // connect gate) is checked via `hasStoredPassword`/`hasStoredPrivateKey`
        // without reading the secret value.
        // Note: privateKeyPassphrase is not persisted long-term.
        let connectionInfo = ConnectionInfo(name: name, serverAddress: serverAddress, portNumber: portNumber, username: username, password: "", privateKey: "", privateKeyPassphrase: "", knownHostKey: knownHostKey)
        let tunnelInfo = TunnelInfo(localPort: localPort, remoteServer: remoteServer, remotePort: remotePort)

        return Connection(id: uuid, recordID: record.recordID, connectionInfo: connectionInfo, tunnelInfo: tunnelInfo)
    }
}

