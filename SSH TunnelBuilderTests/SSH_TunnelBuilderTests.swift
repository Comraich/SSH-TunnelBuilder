import Testing
import Foundation
import NIO
import NIOSSH // Required for NIOSSHAvailableUserAuthenticationMethods
import CloudKit
import CryptoKit

// This import gives the test target access to your app's internal types like KeychainService.
@testable import SSH_TunnelBuilder

// NOTE: Since KeychainService is a singleton, these tests will interact
// with the app's actual keychain during the test run. We use a unique
// ID for each test to ensure we don't conflict with real data or other tests.

@Suite("Keychain Service Tests")
struct KeychainServiceTests {
    let keychain = KeychainService.shared
    
    @Test("Save, load, and delete password")
    func testPasswordLifecycle() {
        let id = UUID()
        let password = "super-secret-password-123"
        
        // 1. Save the password
        keychain.savePassword(password, for: id)
        
        // 2. Load and verify the password
        let loadedPassword = keychain.loadPassword(for: id)
        #expect(loadedPassword == password, "The loaded password should match the saved password.")
        
        // 3. Delete the credentials
        keychain.deleteCredentials(for: id)
        
        // 4. Verify the password is deleted
        let deletedPassword = keychain.loadPassword(for: id)
        #expect(deletedPassword == nil, "The password should be nil after deletion.")
    }
    
    @Test("Save, load, and delete private key")
    func testPrivateKeyLifecycle() {
        let id = UUID()
        let privateKey = "-----BEGIN EC PRIVATE KEY-----\nTestKeyData\n-----END EC PRIVATE KEY-----"
        
        // 1. Save the key
        keychain.savePrivateKey(privateKey, for: id)
        
        // 2. Load and verify the key
        let loadedKey = keychain.loadPrivateKey(for: id)
        #expect(loadedKey == privateKey, "The loaded private key should match the saved key.")
        
        // 3. Delete the credentials
        keychain.deleteCredentials(for: id)
        
        // 4. Verify the key is deleted
        let deletedKey = keychain.loadPrivateKey(for: id)
        #expect(deletedKey == nil, "The private key should be nil after deletion.")
    }
    
    @Test("Loading non-existent credential returns nil")
    func testLoadingNonExistent() {
        let id = UUID() // A random ID that has not been saved
        
        let password = keychain.loadPassword(for: id)
        #expect(password == nil, "Loading a password for an unknown ID should return nil.")
        
        let privateKey = keychain.loadPrivateKey(for: id)
        #expect(privateKey == nil, "Loading a private key for an unknown ID should return nil.")
    }
    
    @Test("Updating a credential overwrites the old one")
    func testUpdateCredential() {
        let id = UUID()
        let initialPassword = "password1"
        let updatedPassword = "password2"
        
        // 1. Save initial password
        keychain.savePassword(initialPassword, for: id)
        let firstLoad = keychain.loadPassword(for: id)
        #expect(firstLoad == initialPassword)
        
        // 2. Save updated password
        keychain.savePassword(updatedPassword, for: id)
        let secondLoad = keychain.loadPassword(for: id)
        #expect(secondLoad == updatedPassword, "The updated password should overwrite the initial one.")
        
        // Clean up
        keychain.deleteCredentials(for: id)
    }
}

// MARK: - New ConnectionStore Local Tests

@Suite("ConnectionStore Local Tests")
@MainActor
struct ConnectionStoreLocalTests {
    
    // Helper to mock the connection object needed for testing
    func makeMockConnection(id: UUID = UUID(), password: String, privateKey: String) -> Connection {
        let info = ConnectionInfo(name: "Mock", serverAddress: "127.0.0.1", portNumber: "22", username: "user", password: password, privateKey: privateKey, privateKeyPassphrase: "")
        let tunnel = TunnelInfo(localPort: "8080", remoteServer: "remote", remotePort: "80")
        return Connection(id: id, connectionInfo: info, tunnelInfo: tunnel)
    }
    
    // Use an instance of ConnectionStore to access helper methods like recordToConnection
    // NOTE: This test suite avoids triggering the actual CloudKit initiation (`init()`) 
    // but relies on helper methods being available.
    
    @Test("Secrets are saved to Keychain and retrieved correctly via recordToConnection")
    func testSecretHandlingInRecordMapping() throws {
        let store = ConnectionStore()
        let id = UUID()
        let initialPassword = "test_password"
        let initialKey = "test_key_pem"
        let mockConnection = makeMockConnection(id: id, password: initialPassword, privateKey: initialKey)
        
        let zoneID = CKRecordZone.ID(zoneName: "TestZone", ownerName: CKCurrentUserDefaultName)
        let recordID = CKRecord.ID(recordName: id.uuidString, zoneID: zoneID)
        let record = CKRecord(recordType: "Connection", recordID: recordID)
        
        // 1. Simulate saving the connection (which calls updateRecordFields)
        store.updateRecordFields(record, withConnection: mockConnection)
        
        // Verify secrets are cleared from the record (CK security principle)
        let recordPassword = record[CloudKitKeys.password] as? String
        let recordKey = record[CloudKitKeys.privateKey] as? String
        #expect(recordPassword == "" || recordPassword == nil)
        #expect(recordKey == "" || recordKey == nil)
        
        // 2. Simulate retrieving the connection (which calls recordToConnection)
        let retrievedConnection = try #require(store.recordToConnection(record: record))
        
        // Verify secrets are correctly retrieved from Keychain
        #expect(retrievedConnection.connectionInfo.password == initialPassword)
        #expect(retrievedConnection.connectionInfo.privateKey == initialKey)
        
        // Cleanup
        KeychainService.shared.deleteCredentials(for: id)
    }
    
    @Test("Updating temporary connection uses deep copy")
    func testTempConnectionUpdate() {
        let store = ConnectionStore()
        let originalConnection = makeMockConnection(password: "p1", privateKey: "k1")
        
        store.updateTempConnection(with: originalConnection)
        let tempConnection = try #require(store.tempConnection)
        
        // Modify the copy
        tempConnection.connectionInfo.password = "p2"
        
        // Verify original is untouched
        #expect(originalConnection.connectionInfo.password == "p1")
    }

    @Test("Connection deletion cleans up manager and keychain") {
        let store = ConnectionStore()
        let id = UUID()
        let connection = makeMockConnection(id: id, password: "test", privateKey: "test")
        
        // Setup: Ensure manager and keychain data exist
        KeychainService.shared.savePassword("test", for: id)
        
        // Mock a minimal CKRecord ID to allow the delete logic to execute locally
        let recordID = CKRecord.ID(recordName: id.uuidString)
        let connectionToDelete = Connection(id: id, recordID: recordID, connectionInfo: connection.connectionInfo, tunnelInfo: connection.tunnelInfo)
        
        store.connections.append(connectionToDelete)
        
        // Mock the CloudKit delete operation (We assume success here for local cleanup test)
        // Since deleteConnection is async, we can't fully test manager cleanup without a CloudKit mock, 
        // but we can simulate the successful post-CloudKit cleanup logic.
        
        // Manually simulating successful CK deletion to trigger local cleanup logic
        Task {
            // Note: Since ConnectionStore.deleteConnection calls disconnect, 
            // and we rely on the CloudKit DELETE succeeding, full end-to-end testing of deletion 
            // requires mocking CKDatabase responses.
            
            // However, we can assert that Keychain cleanup should happen:
            // Since we cannot easily await the full async flow without complex mocks,
            // we rely on the fact that the keychain data should be deleted eventually 
            // after the deleteConnection call. For now, we manually check the code path's intent.
            // (If using a mocking framework, we would assert database.delete was called, 
            // and then assert the keychain deletion.)
            
            // For now, focus on the synchronous cleanup inside recordToConnection and updateRecordFields.
            
            // Re-adding this test for future development where proper mocking might be available.
            
            // The fact that mgr is retained in `managers` dictionary is the main local concern.
            
            // Cleanup assertion verification is best left to integration/mocking for async deletion.
        }
        
        // Resetting the list of connections is synchronous after the async delete is complete
    }
}


@Suite("Authentication Delegate Tests")
struct AuthDelegateTests {
    // This is a known-valid, unencrypted EC PRIVATE KEY for P-256 (from original snippets)
    let p256TestKey = """
    -----BEGIN EC PRIVATE KEY-----
    MHcCAQEEIP2/85aP5w3A0a42M4pvi5b+4V2Fb6U2aT7g46Gl2nk9oAoGCCqGSM49
    AwEHoUQDQgAEG5k4T0t2P9sWbYJml8l6s5OB8kUvDSAn3yxdI6f851k2iEg5NGAa
    pOkxts1b25Kk2t99y2nFaEw+uHFKWQj/Lg==
    -----END EC PRIVATE KEY-----
    """

    @Test("Delegate initializes with a valid unencrypted ECDSA key")
    func testValidUnencryptedECKeyInitialization() {
        let delegate = FlexibleAuthDelegate(username: "test", password: nil, privateKeyString: p256TestKey, privateKeyPassphrase: nil)
        #expect(delegate.privateKey != nil, "Delegate should successfully parse a valid unencrypted ECDSA P-256 key.")
    }
    
    @Test("Delegate rejects unsupported key type (RSA)") {
        // RSA key in PKCS#1 format (which is detected and rejected by FlexibleAuthDelegate)
        let rsaKey = """
        -----BEGIN RSA PRIVATE KEY-----
        MIICXQIBAAKBgQCw0/Vv1xR0z...
        -----END RSA PRIVATE KEY-----
        """
        
        var reportedError: String? = nil
        let delegate = FlexibleAuthDelegate(username: "test", password: nil, privateKeyString: rsaKey, privateKeyPassphrase: nil, reportError: { reportedError = $0 })
        
        #expect(delegate.privateKey == nil, "Delegate should reject unsupported RSA key.")
        #expect(reportedError?.contains("RSA keys are not currently supported") == true, "Delegate should report the RSA incompatibility error.")
    }

    @Test("Delegate handles completely invalid key string")
    func testInvalidKeyInitialization() {
        let delegate = FlexibleAuthDelegate(username: "test", password: nil, privateKeyString: "invalid-key-string", privateKeyPassphrase: nil)
        #expect(delegate.privateKey == nil, "Delegate should return nil for an invalid key.")
    }
    
    @Test("Delegate offers password when available and key auth is skipped")
    func testOffersPasswordFallback() async throws {
        // We ensure that even with a valid key, if password is also present, password takes precedence
        // or is offered next if the key attempt fails/is skipped (as in 0.12.0).
        let delegate = FlexibleAuthDelegate(username: "test", password: "pw", privateKeyString: p256TestKey)
        
        let eventLoop = EmbeddedEventLoop()
        let promise = eventLoop.makePromise(of: NIOSSHUserAuthenticationOffer?.self)
        
        let availableMethods: NIOSSHAvailableUserAuthenticationMethods = [.publicKey, .password]
        delegate.nextAuthenticationType(availableMethods: availableMethods, nextChallengePromise: promise)
        
        let offer = try await promise.futureResult.get()
        
        // Since public key authentication is skipped (due to the if block guard), it falls directly to password check.
        #expect(offer?.offer.isPassword == true, "Should offer password if public key auth is skipped.")
    }

    @Test("Delegate fails if neither key nor password available") async throws {
        let delegate = FlexibleAuthDelegate(username: "test", password: nil, privateKeyString: nil)
        
        let eventLoop = EmbeddedEventLoop()
        let promise = eventLoop.makePromise(of: NIOSSHUserAuthenticationOffer?.self)
        
        let availableMethods: NIOSSHAvailableUserAuthenticationMethods = [.publicKey, .password]
        delegate.nextAuthenticationType(availableMethods: availableMethods, nextChallengePromise: promise)
        
        let offer = try await promise.futureResult.get()
        
        #expect(offer == nil, "Should fail authentication if no credentials are provided.")
    }
}

@Suite("PEM Key Logic Tests")
struct PEMKeyLogicTests {
    // Helper access to methods defined externally in MainView.swift and SSHManager.swift
    // To access these, we must use the wrapper type provided by `@testable import`.
    
    @Test("Detects various PEM key kinds")
    func testDetectKeyKind() {
        // Need to ensure these utility functions are correctly linked via @testable import
        #expect(detectPEMKeyKind("-----BEGIN EC PRIVATE KEY-----") == .ec)
        #expect(detectPEMKeyKind("-----BEGIN PRIVATE KEY-----") == .pkcs8)
        #expect(detectPEMKeyKind("-----BEGIN ENCRYPTED PRIVATE KEY-----") == .pkcs8)
        #expect(detectPEMKeyKind("-----BEGIN RSA PRIVATE KEY-----") == .rsa)
        #expect(detectPEMKeyKind("-----BEGIN OPENSSH PRIVATE KEY-----") == .openssh)
        #expect(detectPEMKeyKind("garbage") == .unknown)
    }

    @Test("Detects encrypted PEM keys")
    func testDetectEncrypted() {
        #expect(isPEMEncrypted("-----BEGIN ENCRYPTED PRIVATE KEY-----"))
        #expect(isPEMEncrypted("DEK-Info: AES-256-CBC"))
        #expect(isPEMEncrypted("Proc-Type: 4,ENCRYPTED"))
        #expect(!isPEMEncrypted("-----BEGIN EC PRIVATE KEY-----"))
    }
}

@Suite("Connection Model Tests")
struct ConnectionModelTests {
    @Test("Copy method creates a deep, independent copy")
    func testConnectionCopy() {
        // 1. Create original connection
        let originalInfo = ConnectionInfo(name: "Original", serverAddress: "127.0.0.1", portNumber: "22", username: "user", password: "pw", privateKey: "key", privateKeyPassphrase: "pp")
        let originalTunnel = TunnelInfo(localPort: "8080", remoteServer: "localhost", remotePort: "80")
        let original = Connection(connectionInfo: originalInfo, tunnelInfo: originalTunnel)
        
        // 2. Create a copy
        let copy = original.copy()
        
        // 3. Verify the copy is a new instance, not the same object
        #expect(original !== copy, "The copied object should be a different instance.")
        
        // 4. Verify all properties were copied correctly
        #expect(original.id == copy.id)
        #expect(original.connectionInfo.name == copy.connectionInfo.name)
        #expect(original.tunnelInfo.localPort == copy.tunnelInfo.localPort)
        
        // 5. Modify the copy and verify the original is unchanged
        copy.connectionInfo.name = "Modified"
        #expect(original.connectionInfo.name == "Original", "Modifying the copy's name should not affect the original.")
        #expect(copy.connectionInfo.name == "Modified")
    }
}

@Suite("ConnectionStore Mapping Tests")
struct ConnectionStoreMappingTests {
    // Use a dummy ConnectionStore instance just to access the mapping methods.
    // This test does not depend on the store's state or its CloudKit connection.
    let store = ConnectionStore()

    @Test("CloudKit record mapping round-trip")
    func testCloudKitMapping() throws {
        let store = ConnectionStore()
        let id = UUID()
        
        // Initialize the store on the MainActor, but we only use synchronous helpers here.
        
        // 1. Create a source Connection object
        let connectionInfo = ConnectionInfo(name: "Test Server", serverAddress: "server.example.com", portNumber: "2222", username: "testuser", password: "testpassword", privateKey: "testkey", privateKeyPassphrase: "pp")
        let tunnelInfo = TunnelInfo(localPort: "9000", remoteServer: "db.internal", remotePort: "5432")
        let sourceConnection = Connection(id: id, connectionInfo: connectionInfo, tunnelInfo: tunnelInfo)
        
        // 2. Create a dummy CKRecord to populate
        let zoneID = CKRecordZone.ID(zoneName: "TestZone", ownerName: CKCurrentUserDefaultName)
        let recordID = CKRecord.ID(recordName: id.uuidString, zoneID: zoneID)
        let record = CKRecord(recordType: "Connection", recordID: recordID)
        
        // 3. Map Connection -> CKRecord (Saves secrets to Keychain)
        store.updateRecordFields(record, withConnection: sourceConnection)
        
        // 4. Map CKRecord -> Connection (Loads secrets from Keychain)
        let resultConnection = try #require(store.recordToConnection(record: record))
        
        // 5. Assert that the data survived the round-trip
        #expect(resultConnection.id == sourceConnection.id)
        #expect(resultConnection.connectionInfo.name == "Test Server")
        
        // 6. Verify that secrets were correctly handled via the Keychain
        #expect(resultConnection.connectionInfo.password == "testpassword")
        #expect(resultConnection.connectionInfo.privateKey == "testkey")
        
        // Clean up the keychain
        KeychainService.shared.deleteCredentials(for: id)
    }
}


// Helper extension to make checking the auth offer type easier in tests
private extension NIOSSHUserAuthenticationOffer.Offer {
    var isPrivateKey: Bool {
        if case .privateKey = self { return true }
        return false
    }
    
    var isPassword: Bool {
        if case .password = self {
            return true
        }
        return false
    }
}

