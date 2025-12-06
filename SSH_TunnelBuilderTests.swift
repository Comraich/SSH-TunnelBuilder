import Testing
import Foundation
import NIO
import NIOSSH // Required for NIOSSHAvailableUserAuthenticationMethods
import CloudKit

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


@Suite("Data Formatting Tests")
struct DataFormattingTests {

    @Test("Verify byte count formatting")
    func testByteCountFormatting() {
        let formatter = ByteCountFormatter()
        // Ensure we use the same style as the app's UI
        formatter.countStyle = .file 
        
        #expect(formatter.string(fromByteCount: 0) == "Zero bytes")
        #expect(formatter.string(fromByteCount: 500) == "500 bytes")
        #expect(formatter.string(fromByteCount: 999) == "999 bytes")
        #expect(formatter.string(fromByteCount: 1_000) == "1 KB")
        #expect(formatter.string(fromByteCount: 150_000) == "150 KB")
        #expect(formatter.string(fromByteCount: 2_500_000) == "2.5 MB")
    }
}

@Suite("Authentication Delegate Tests")
struct AuthDelegateTests {
    // This is a valid P-256 key generated for testing purposes.
    let p256TestKey = """
    -----BEGIN EC PRIVATE KEY-----
    MHcCAQEEIP2/85aP5w3A0a42M4pvi5b+4V2Fb6U2aT7g46Gl2nk9oAoGCCqGSM49
    AwEHoUQDQgAEG5k4T0t2P9sWbYJml8l6s5OB8kUvDSAn3yxdI6f851k2iEg5NGAa
    pOkxts1b25Kk2t99y2nFaEw+uHFKWQj/Lg==
    -----END EC PRIVATE KEY-----
    """

    @Test("Delegate initializes with a valid private key")
    func testValidKeyInitialization() {
        let delegate = FlexibleAuthDelegate(username: "test", password: nil, privateKeyString: p256TestKey)
        #expect(delegate.privateKey != nil, "Delegate should successfully parse a valid P-256 key.")
    }

    @Test("Delegate handles an invalid private key")
    func testInvalidKeyInitialization() {
        let delegate = FlexibleAuthDelegate(username: "test", password: nil, privateKeyString: "invalid-key-string")
        #expect(delegate.privateKey == nil, "Delegate should return nil for an invalid key.")
    }
    
    @Test("Delegate offers public key when available")
    func testOffersPublicKeyFirst() async throws {
        let delegate = FlexibleAuthDelegate(username: "test", password: "pw", privateKeyString: p256TestKey)
        
        let eventLoop = EmbeddedEventLoop()
        let promise = eventLoop.makePromise(of: NIOSSHUserAuthenticationOffer?.self)
        
        let availableMethods: NIOSSHAvailableUserAuthenticationMethods = [.publicKey, .password]
        delegate.nextAuthenticationType(availableMethods: availableMethods, nextChallengePromise: promise)
        
        let offer = try await promise.futureResult.get()
        
        #expect(offer?.offer.isPrivateKey == true, "Should offer public key first.")
    }
    
    @Test("Delegate falls back to password")
    func testFallsBackToPassword() async throws {
        let delegate = FlexibleAuthDelegate(username: "test", password: "pw", privateKeyString: p256TestKey)
        
        let eventLoop = EmbeddedEventLoop()
        let promise = eventLoop.makePromise(of: NIOSSHUserAuthenticationOffer?.self)
        
        // Server only allows password auth
        let availableMethods: NIOSSHAvailableUserAuthenticationMethods = [.password]
        delegate.nextAuthenticationType(availableMethods: availableMethods, nextChallengePromise: promise)
        
        let offer = try await promise.futureResult.get()
        
        #expect(offer?.offer.isPassword == true, "Should fall back to password if public key is not available.")
    }
}

@Suite("PEM Key Logic Tests")
struct PEMKeyLogicTests {
    @Test("Detects various PEM key kinds")
    func testDetectKeyKind() {
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
        let originalInfo = ConnectionInfo(name: "Original", serverAddress: "127.0.0.1", portNumber: "22", username: "user", password: "pw", privateKey: "key")
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
        // 1. Create a source Connection object
        let id = UUID()
        let connectionInfo = ConnectionInfo(name: "Test Server", serverAddress: "server.example.com", portNumber: "2222", username: "testuser", password: "testpassword", privateKey: "testkey")
        let tunnelInfo = TunnelInfo(localPort: "9000", remoteServer: "db.internal", remotePort: "5432")
        let sourceConnection = Connection(id: id, connectionInfo: connectionInfo, tunnelInfo: tunnelInfo)
        
        // 2. Create a dummy CKRecord to populate
        let zoneID = CKRecordZone.ID(zoneName: "TestZone", ownerName: CKCurrentUserDefaultName)
        let recordID = CKRecord.ID(recordName: id.uuidString, zoneID: zoneID)
        let record = CKRecord(recordType: "Connection", recordID: recordID)
        
        // 3. Map Connection -> CKRecord
        store.updateRecordFields(record, withConnection: sourceConnection)
        
        // 4. Map CKRecord -> Connection
        let resultConnection = try #require(store.recordToConnection(record: record))
        
        // 5. Assert that the data survived the round-trip
        #expect(resultConnection.id == sourceConnection.id)
        #expect(resultConnection.connectionInfo.name == "Test Server")
        #expect(resultConnection.connectionInfo.username == "testuser")
        #expect(resultConnection.tunnelInfo.remotePort == "5432")
        
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
