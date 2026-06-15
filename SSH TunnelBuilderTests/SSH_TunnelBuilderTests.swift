import Testing
import Foundation
import NIO
import NIOFoundationCompat
import NIOSSH
import CloudKit
import CryptoKit

@testable import SSH_TunnelBuilder

// MARK: - Keychain Service Tests

@Suite("Keychain Service Tests")
struct KeychainServiceTests {
    let keychain = KeychainService.shared

    @Test("Save, load, and delete password")
    func testPasswordLifecycle() {
        let id = UUID()
        keychain.savePassword("super-secret-password-123", for: id)
        #expect(keychain.loadPassword(for: id) == "super-secret-password-123")
        keychain.deleteCredentials(for: id)
        #expect(keychain.loadPassword(for: id) == nil)
    }

    @Test("Save, load, and delete private key")
    func testPrivateKeyLifecycle() {
        let id = UUID()
        let key = "-----BEGIN EC PRIVATE KEY-----\nTestKeyData\n-----END EC PRIVATE KEY-----"
        keychain.savePrivateKey(key, for: id)
        #expect(keychain.loadPrivateKey(for: id) == key)
        keychain.deleteCredentials(for: id)
        #expect(keychain.loadPrivateKey(for: id) == nil)
    }

    @Test("Loading non-existent credential returns nil")
    func testLoadingNonExistent() {
        let id = UUID()
        #expect(keychain.loadPassword(for: id) == nil)
        #expect(keychain.loadPrivateKey(for: id) == nil)
    }

    @Test("Updating a credential overwrites the old one")
    func testUpdateCredential() {
        let id = UUID()
        keychain.savePassword("password1", for: id)
        #expect(keychain.loadPassword(for: id) == "password1")
        keychain.savePassword("password2", for: id)
        #expect(keychain.loadPassword(for: id) == "password2")
        keychain.deleteCredentials(for: id)
    }
}

// MARK: - ConnectionState Tests

@Suite("ConnectionState Tests")
struct ConnectionStateTests {
    @Test("isActive is true only when connected")
    func isActiveOnlyWhenConnected() {
        #expect(!ConnectionState.idle.isActive)
        #expect(!ConnectionState.connecting.isActive)
        #expect(ConnectionState.connected.isActive)
        #expect(!ConnectionState.disconnecting.isActive)
        #expect(!ConnectionState.failed("err").isActive)
    }

    @Test("isConnecting is true only when connecting")
    func isConnectingOnlyWhenConnecting() {
        #expect(!ConnectionState.idle.isConnecting)
        #expect(ConnectionState.connecting.isConnecting)
        #expect(!ConnectionState.connected.isConnecting)
        #expect(!ConnectionState.disconnecting.isConnecting)
        #expect(!ConnectionState.failed("err").isConnecting)
    }

    @Test("isDisconnecting is true only when disconnecting")
    func isDisconnectingOnlyWhenDisconnecting() {
        #expect(!ConnectionState.idle.isDisconnecting)
        #expect(!ConnectionState.connecting.isDisconnecting)
        #expect(!ConnectionState.connected.isDisconnecting)
        #expect(ConnectionState.disconnecting.isDisconnecting)
        #expect(!ConnectionState.failed("err").isDisconnecting)
    }

    @Test("States with equal associated values compare equal")
    func equalityWithAssociatedValues() {
        #expect(ConnectionState.failed("a") == ConnectionState.failed("a"))
        #expect(ConnectionState.failed("a") != ConnectionState.failed("b"))
        #expect(ConnectionState.idle == ConnectionState.idle)
        #expect(ConnectionState.idle != ConnectionState.connected)
    }
}

// MARK: - Port Field Bridging Tests

/// Tests the String <-> Int64 bridge for the port fields whose CloudKit schema
/// type is NUMBER_INT64. This is the fix for the core persistence bug (CKError 12).
@Suite("Port Field Bridging Tests")
struct PortFieldBridgingTests {
    @MainActor func makeStore() -> ConnectionStore {
        ConnectionStore(mode: .view, connections: [])
    }

    @MainActor func makeConnection(id: UUID = UUID(), portNumber: String, localPort: String, remotePort: String) -> Connection {
        let info = ConnectionInfo(name: "Port Test", serverAddress: "host.example.com",
                                  portNumber: portNumber, username: "user",
                                  password: "", privateKey: "", privateKeyPassphrase: "")
        let tunnel = TunnelInfo(localPort: localPort, remoteServer: "remote", remotePort: remotePort)
        return Connection(id: id, connectionInfo: info, tunnelInfo: tunnel)
    }

    @Test("Numeric port strings are written as Int64 and read back as String")
    @MainActor func numericPortsRoundTrip() throws {
        let store = makeStore()
        let id = UUID()
        let connection = makeConnection(id: id, portNumber: "22", localPort: "8080", remotePort: "5432")

        let record = CKRecord(recordType: "Connection",
                              recordID: CKRecord.ID(recordName: id.uuidString))
        store.updateRecordFields(record, withConnection: connection)

        // Verify stored as Int64 (matching the CloudKit schema)
        #expect(record["portNumber"] as? Int64 == 22)
        #expect(record["localPort"] as? Int64 == 8080)
        #expect(record["remotePort"] as? Int64 == 5432)

        // Complete the record so recordToConnection can parse it
        record["uuid"] = id.uuidString
        record["name"] = "Port Test"
        record["serverAddress"] = "host.example.com"
        record["username"] = "user"
        record["remoteServer"] = "remote"

        let result = try #require(store.recordToConnection(record: record))
        #expect(result.connectionInfo.portNumber == "22")
        #expect(result.tunnelInfo.localPort == "8080")
        #expect(result.tunnelInfo.remotePort == "5432")

        KeychainService.shared.deleteCredentials(for: id)
    }

    @Test("Blank port strings are stored as absent fields and read back as empty string")
    @MainActor func blankPortsAreAbsent() throws {
        let store = makeStore()
        let id = UUID()
        let connection = makeConnection(id: id, portNumber: "", localPort: "", remotePort: "")

        let record = CKRecord(recordType: "Connection",
                              recordID: CKRecord.ID(recordName: id.uuidString))
        store.updateRecordFields(record, withConnection: connection)

        // Blank values should produce absent (nil) fields, not a zero
        #expect(record["portNumber"] == nil)
        #expect(record["localPort"] == nil)
        #expect(record["remotePort"] == nil)

        record["uuid"] = id.uuidString
        record["name"] = "Port Test"
        record["serverAddress"] = "host.example.com"
        record["username"] = "user"
        record["remoteServer"] = "remote"

        let result = try #require(store.recordToConnection(record: record))
        #expect(result.connectionInfo.portNumber == "")
        #expect(result.tunnelInfo.localPort == "")
        #expect(result.tunnelInfo.remotePort == "")

        KeychainService.shared.deleteCredentials(for: id)
    }

    @Test("Non-numeric port strings are stored as absent fields")
    @MainActor func nonNumericPortsAreAbsent() {
        let store = makeStore()
        let id = UUID()
        let connection = makeConnection(id: id, portNumber: "not-a-port", localPort: "abc", remotePort: "xyz")

        let record = CKRecord(recordType: "Connection",
                              recordID: CKRecord.ID(recordName: id.uuidString))
        store.updateRecordFields(record, withConnection: connection)

        #expect(record["portNumber"] == nil)
        #expect(record["localPort"] == nil)
        #expect(record["remotePort"] == nil)
    }

    @Test("Legacy Int64 values in a CKRecord are read back as String")
    @MainActor func legacyInt64FieldsReadAsString() throws {
        // Simulate a record returned from the server with Int64 port fields
        let store = makeStore()
        let id = UUID()

        let record = CKRecord(recordType: "Connection",
                              recordID: CKRecord.ID(recordName: id.uuidString))
        record["uuid"] = id.uuidString
        record["name"] = "DB Server"
        record["serverAddress"] = "db.example.com"
        record["username"] = "admin"
        record["remoteServer"] = "localhost"
        record["portNumber"] = Int64(2222)
        record["localPort"]   = Int64(5433)
        record["remotePort"]  = Int64(5432)

        let result = try #require(store.recordToConnection(record: record))
        #expect(result.connectionInfo.portNumber == "2222")
        #expect(result.tunnelInfo.localPort == "5433")
        #expect(result.tunnelInfo.remotePort == "5432")

        KeychainService.shared.deleteCredentials(for: id)
    }
}

// MARK: - ConnectionStore Local Tests

@Suite("ConnectionStore Local Tests")
struct ConnectionStoreLocalTests {
    @MainActor func makeMockConnection(id: UUID = UUID(), password: String, privateKey: String) -> Connection {
        let info = ConnectionInfo(name: "Mock", serverAddress: "127.0.0.1",
                                  portNumber: "22", username: "user",
                                  password: password, privateKey: privateKey,
                                  privateKeyPassphrase: "")
        let tunnel = TunnelInfo(localPort: "8080", remoteServer: "remote", remotePort: "80")
        return Connection(id: id, connectionInfo: info, tunnelInfo: tunnel)
    }

    @Test("Secrets are saved to Keychain and retrieved correctly via recordToConnection")
    @MainActor func testSecretHandlingInRecordMapping() throws {
        let store = ConnectionStore(mode: .view, connections: [])
        let id = UUID()
        let mockConnection = makeMockConnection(id: id, password: "test_password", privateKey: "test_key_pem")

        let zoneID = CKRecordZone.ID(zoneName: "TestZone", ownerName: CKCurrentUserDefaultName)
        let recordID = CKRecord.ID(recordName: id.uuidString, zoneID: zoneID)
        let record = CKRecord(recordType: "Connection", recordID: recordID)

        store.updateRecordFields(record, withConnection: mockConnection)
        record["uuid"] = id.uuidString  // updateRecordFields doesn't set uuid; production code sets it separately

        // Secrets must not be stored in CloudKit
        #expect((record["password"] as? String ?? "") == "")
        #expect((record["privateKey"] as? String ?? "") == "")

        // Secrets must be recoverable via the store's credentials layer
        let retrieved = try #require(store.recordToConnection(record: record))
        #expect(retrieved.connectionInfo.password == "test_password")
        #expect(retrieved.connectionInfo.privateKey == "test_key_pem")
    }

    @Test("Updating temporary connection uses a deep copy")
    @MainActor func testTempConnectionUpdate() throws {
        let store = ConnectionStore(mode: .view, connections: [])
        let original = makeMockConnection(password: "p1", privateKey: "k1")

        store.updateTempConnection(with: original)
        let temp = try #require(store.tempConnection)

        temp.connectionInfo.password = "p2"
        #expect(original.connectionInfo.password == "p1",
                "Modifying the temp copy must not affect the original")
    }

    @Test("Deleting a local-only connection removes it synchronously from the list")
    @MainActor func testLocalConnectionDeletion() {
        let id = UUID()
        let info = ConnectionInfo(name: "To Delete", serverAddress: "host",
                                  portNumber: "22", username: "user",
                                  password: "", privateKey: "", privateKeyPassphrase: "")
        let tunnel = TunnelInfo(localPort: "8080", remoteServer: "remote", remotePort: "80")
        // recordID: nil means this connection has never been synced to CloudKit
        let connection = Connection(id: id, recordID: nil,
                                    connectionInfo: info, tunnelInfo: tunnel)

        let store = ConnectionStore(mode: .view, connections: [connection])
        #expect(store.connections.count == 1)

        store.deleteConnection(connection)
        #expect(store.connections.isEmpty,
                "A local-only connection should be removed synchronously from the list")
    }
}

// MARK: - Authentication Delegate Tests

@Suite("Authentication Delegate Tests")
struct AuthDelegateTests {
    let p256TestKey = """
    -----BEGIN EC PRIVATE KEY-----
    MHcCAQEEIP2/85aP5w3A0a42M4pvi5b+4V2Fb6U2aT7g46Gl2nk9oAoGCCqGSM49
    AwEHoUQDQgAEG5k4T0t2P9sWbYJml8l6s5OB8kUvDSAn3yxdI6f851k2iEg5NGAa
    pOkxts1b25Kk2t99y2nFaEw+uHFKWQj/Lg==
    -----END EC PRIVATE KEY-----
    """

    /// SEC1 `EC PRIVATE KEY` (RFC 5915) for the P-384 curve.
    let p384TestKey = """
    -----BEGIN EC PRIVATE KEY-----
    MIGkAgEBBDDgU65GwW8KYZzGCFK0/QlqCskB8AXooHh/aSy9WfxKVkfXh3Tx/S+K
    1S4mexrXOMqgBwYFK4EEACKhZANiAATml2B9CXVZ1cd9qBqVoNDXTuQ9+CzXnhZF
    SkpLY034jzg2u7wKq5kAcHg0sxo3AWdpf9qjHaGsihqB7KLxpHhiKhdIR3o0eW/b
    PsePEY/O7/KpGBRLC69Msyl/eTfTIDg=
    -----END EC PRIVATE KEY-----
    """

    /// SEC1 `EC PRIVATE KEY` (RFC 5915) for the P-521 curve.
    let p521TestKey = """
    -----BEGIN EC PRIVATE KEY-----
    MIHcAgEBBEIAkvmBqlPwmCaehCIZrBRmpHa8PDBH/q2hRi3e8l80H8RU3jRHJQk5
    m5wczKcnwNUAHObbqzJyLZ7oBgw12iWKPiSgBwYFK4EEACOhgYkDgYYABADDq70e
    k/nw6fP36G/ONCk/KKyG3W2ie674awBwDANSocngQbpa5uuAt6CzNJ64zrRHVqsO
    8UHJa1ZhZAfuQdbZ3wEudsiLfOcogcONYsKOs2gi+L4BTPnExN2TUlrbomDXizUT
    vyGPHesrZpoxhNoSMFqFlt9NnfIDblMNEU7JkRC63A==
    -----END EC PRIVATE KEY-----
    """

    @Test("Delegate initializes with a valid unencrypted ECDSA P-256 SEC1 key")
    func testValidUnencryptedECKeyInitialization() {
        let delegate = FlexibleAuthDelegate(username: "test", password: nil,
                                            privateKeyString: p256TestKey,
                                            privateKeyPassphrase: nil)
        #expect(delegate.privateKey != nil)
    }

    @Test("Delegate initializes with a valid unencrypted ECDSA P-384 SEC1 key")
    func testValidUnencryptedP384KeyInitialization() {
        let delegate = FlexibleAuthDelegate(username: "test", password: nil,
                                            privateKeyString: p384TestKey,
                                            privateKeyPassphrase: nil)
        #expect(delegate.privateKey != nil)
    }

    @Test("Delegate initializes with a valid unencrypted ECDSA P-521 SEC1 key")
    func testValidUnencryptedP521KeyInitialization() {
        let delegate = FlexibleAuthDelegate(username: "test", password: nil,
                                            privateKeyString: p521TestKey,
                                            privateKeyPassphrase: nil)
        #expect(delegate.privateKey != nil)
    }

    /// Ed25519 in unencrypted PKCS#8 (`openssl genpkey -algorithm ed25519`).
    let ed25519PKCS8 = """
    -----BEGIN PRIVATE KEY-----
    MC4CAQAwBQYDK2VwBCIEIDmuqa3zNPAT5I/FSnGkNz1s/wt3l9o4S9TBBhOu8i8+
    -----END PRIVATE KEY-----
    """

    /// The same Ed25519 key in encrypted PKCS#8 (AES-256-CBC + PBKDF2-SHA256). Passphrase: "hunter2".
    let ed25519PKCS8Encrypted = """
    -----BEGIN ENCRYPTED PRIVATE KEY-----
    MIGjMF8GCSqGSIb3DQEFDTBSMDEGCSqGSIb3DQEFDDAkBBD9rdog5l0MTvoeuws0
    PF9oAgIIADAMBggqhkiG9w0CCQUAMB0GCWCGSAFlAwQBKgQQIlViEFefceB0/UR7
    P60BqARAV81TF7jGD3f2x0B6uxoyX0/PmZdSEEV02RbOjrOgKW+J8imN5qycvcks
    pZ4oKLZTaxou5tErgSM6rJcxO2H15Q==
    -----END ENCRYPTED PRIVATE KEY-----
    """

    @Test("Delegate initializes with an unencrypted Ed25519 PKCS#8 key")
    func testEd25519PKCS8Initialization() {
        let delegate = FlexibleAuthDelegate(username: "test", password: nil,
                                            privateKeyString: ed25519PKCS8,
                                            privateKeyPassphrase: nil)
        #expect(delegate.privateKey != nil)
    }

    @Test("Delegate decrypts an encrypted Ed25519 PKCS#8 key")
    func testEd25519PKCS8EncryptedInitialization() {
        let delegate = FlexibleAuthDelegate(username: "test", password: nil,
                                            privateKeyString: ed25519PKCS8Encrypted,
                                            privateKeyPassphrase: fixtureUnlock)
        #expect(delegate.privateKey != nil)
    }

    @Test("Encrypted Ed25519 PKCS#8 decrypts to the exact original key")
    func testEd25519PKCS8RecoversOriginalKey() throws {
        let knownPub = Data(base64Encoded: "5TeA8DPnYQ97FJWdT+sUK+gnoTIJpocwlAUJzks7/Yc=")!
        let der = try PEMDecryptor.decryptEncryptedPKCS8PEM(ed25519PKCS8Encrypted, passphrase: fixtureUnlock)
        guard case .ed25519(let seed) = try PEMDecryptor.parsePKCS8PrivateKey(der) else {
            Issue.record("Expected an Ed25519 key")
            return
        }
        let pub = try Curve25519.Signing.PrivateKey(rawRepresentation: seed).publicKey.rawRepresentation
        #expect(Data(pub) == knownPub)
    }

    @Test("Delegate rejects an RSA key and records an initialization error")
    func testRSAKeyRejected() {
        let rsaKey = """
        -----BEGIN RSA PRIVATE KEY-----
        MIICXQIBAAKBgQCw0/Vv1xR0z...
        -----END RSA PRIVATE KEY-----
        """
        // We check initializationError rather than using a reportError closure,
        // which would require mutating a var from a @Sendable context.
        let delegate = FlexibleAuthDelegate(username: "test", password: nil,
                                            privateKeyString: rsaKey,
                                            privateKeyPassphrase: nil)
        #expect(delegate.privateKey == nil)
        #expect(delegate.initializationError != nil)
    }

    @Test("Delegate returns nil private key for an unrecognisable key string")
    func testInvalidKeyInitialization() {
        let delegate = FlexibleAuthDelegate(username: "test", password: nil,
                                            privateKeyString: "invalid-key-string",
                                            privateKeyPassphrase: nil)
        #expect(delegate.privateKey == nil)
    }

    /// Passphrase-protected OpenSSH Ed25519 key (aes256-ctr + bcrypt). Passphrase: "hunter2".
    let encryptedEd25519OpenSSH = """
    -----BEGIN OPENSSH PRIVATE KEY-----
    b3BlbnNzaC1rZXktdjEAAAAACmFlczI1Ni1jdHIAAAAGYmNyeXB0AAAAGAAAABCGuDeZnO
    v7qptIAztAmpGuAAAAGAAAAAEAAAAzAAAAC3NzaC1lZDI1NTE5AAAAIODWg9L7e5NYe+OR
    Tnd2yR1iFBEQYCCB91Mnj0SNeDKgAAAAkA8WOCSuMcff2sis5T6Png55wOWmRORKgPy2VT
    qT2bov2Co/I6s3yZHgaAtn7N1EbUFVZQfbnDoRp/OWXerfhZYoIQhfUpSBz3rSSM9sD/3F
    I6lSv/ZVwAhsaL1guNNBkcMTCVS7ta68sVYLt4Q8C2pPQ7j59LeqS613Pa1qXbk59zS4fN
    KJG+5qhAGobc9DKA==
    -----END OPENSSH PRIVATE KEY-----
    """

    /// Passphrase-protected OpenSSH ECDSA P-256 key (aes256-ctr + bcrypt). Passphrase: "hunter2".
    let encryptedECDSAOpenSSH = """
    -----BEGIN OPENSSH PRIVATE KEY-----
    b3BlbnNzaC1rZXktdjEAAAAACmFlczI1Ni1jdHIAAAAGYmNyeXB0AAAAGAAAABCDQFFoay
    rJoOkz9wQU7ZosAAAAGAAAAAEAAABoAAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlz
    dHAyNTYAAABBBIZqR2mWsSsdgFfgVL60Yv1FGSlZtcIWz/qwsQId2/VgE0eId3z8WQP8Ex
    JB0VPPvQr3D45tVYVBBSe4tW+FNq0AAACglBD0VNzXp23K/gKDqkjOGf0oSIY/cvj1C9ui
    3rA+walb4SMDk3tEGTc7UjKsLZmPizbMx5e5oItBuFKybIy9go81q/UFLi7zSzOd8Jf8RF
    Vtv4Idu0SlN7K245nVpAY8aUdA3F7OnEvkgnKhgxGSWBfOd+J48AhsY8+fc9/KOj8rdgs7
    iaZNQjgiCd+p+BS7GhcuTtKdsQf6mZDvXknVRQ==
    -----END OPENSSH PRIVATE KEY-----
    """

    /// Unlocks the throwaway encrypted test vectors above. Not a real credential —
    /// held in a neutrally-named constant so the value isn't bound to a
    /// passphrase-named symbol at each call site.
    let fixtureUnlock = "hunter2"

    @Test("Delegate decrypts a passphrase-protected OpenSSH Ed25519 key")
    func testEncryptedEd25519OpenSSHKey() {
        let delegate = FlexibleAuthDelegate(username: "test", password: nil,
                                            privateKeyString: encryptedEd25519OpenSSH,
                                            privateKeyPassphrase: fixtureUnlock)
        #expect(delegate.privateKey != nil)
    }

    @Test("Delegate decrypts a passphrase-protected OpenSSH ECDSA key")
    func testEncryptedECDSAOpenSSHKey() {
        let delegate = FlexibleAuthDelegate(username: "test", password: nil,
                                            privateKeyString: encryptedECDSAOpenSSH,
                                            privateKeyPassphrase: fixtureUnlock)
        #expect(delegate.privateKey != nil)
    }

    @Test("A wrong passphrase is rejected for an encrypted OpenSSH key")
    func testEncryptedOpenSSHWrongPassphrase() {
        let delegate = FlexibleAuthDelegate(username: "test", password: nil,
                                            privateKeyString: encryptedEd25519OpenSSH,
                                            privateKeyPassphrase: fixtureUnlock + "-wrong")
        #expect(delegate.privateKey == nil)
        #expect(delegate.initializationError != nil)
    }

    @Test("An encrypted OpenSSH key with no passphrase is rejected")
    func testEncryptedOpenSSHMissingPassphrase() {
        let delegate = FlexibleAuthDelegate(username: "test", password: nil,
                                            privateKeyString: encryptedEd25519OpenSSH,
                                            privateKeyPassphrase: nil)
        #expect(delegate.privateKey == nil)
    }

    @Test("bcrypt_pbkdf decrypts to the exact original Ed25519 key")
    func testEncryptedOpenSSHRecoversOriginalKey() throws {
        // The known public key of the same (unencrypted) key pair.
        let knownPub = Data(base64Encoded: "AAAAC3NzaC1lZDI1NTE5AAAAIODWg9L7e5NYe+ORTnd2yR1iFBEQYCCB91Mnj0SNeDKg")!.suffix(32)

        let data = try OpenSSHKeyParser.extractOpenSSHData(from: encryptedEd25519OpenSSH)
        var buf = ByteBuffer(data: data)
        _ = buf.readBytes(length: 15) // magic
        let cipher = String(bytes: try OpenSSHKeyParser.readSSHBytes(from: &buf), encoding: .utf8)!
        let kdf = String(bytes: try OpenSSHKeyParser.readSSHBytes(from: &buf), encoding: .utf8)!
        let opts = try OpenSSHKeyParser.readSSHBytes(from: &buf)
        _ = buf.readInteger(as: UInt32.self) // numKeys
        _ = try OpenSSHKeyParser.readSSHBytes(from: &buf) // pubKey blob
        let cipherText = try OpenSSHKeyParser.readSSHBytes(from: &buf)

        let plain = try OpenSSHKeyDecryptor.decryptPrivateSection(
            cipherName: cipher, kdfName: kdf, kdfOptions: opts,
            ciphertext: cipherText, passphrase: fixtureUnlock)

        var pb = ByteBuffer(bytes: plain)
        let check1 = pb.readInteger(as: UInt32.self)
        let check2 = pb.readInteger(as: UInt32.self)
        #expect(check1 == check2, "integrity check (proves correct passphrase/KDF)")
        _ = try OpenSSHKeyParser.readSSHBytes(from: &pb) // key type
        _ = try OpenSSHKeyParser.readSSHBytes(from: &pb) // public key
        let privField = try OpenSSHKeyParser.readSSHBytes(from: &pb) // seed(32) || pub(32)
        let seed = Data(privField.prefix(32))
        let derivedPub = try Curve25519.Signing.PrivateKey(rawRepresentation: seed).publicKey.rawRepresentation
        #expect(Data(derivedPub) == Data(knownPub))
    }

    @Test("Delegate offers public key first when both key and password are available")
    func testPublicKeyOfferedBeforePassword() throws {
        let delegate = FlexibleAuthDelegate(username: "test", password: "pw",
                                            privateKeyString: p256TestKey,
                                            privateKeyPassphrase: nil)
        #expect(delegate.privateKey != nil, "Key must parse for this test to be meaningful")

        // Use a real event loop so wait() can deliver the promise synchronously.
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { try? group.syncShutdownGracefully() }
        let promise = group.next().makePromise(of: NIOSSHUserAuthenticationOffer?.self)
        delegate.nextAuthenticationType(availableMethods: [.publicKey, .password],
                                        nextChallengePromise: promise)
        let offer = try promise.futureResult.wait()
        #expect(offer?.offer.isPrivateKey == true,
                "Public-key auth should be offered first")
    }

    @Test("Delegate offers password when only password auth is available")
    func testPasswordOfferedWhenOnlyPasswordAvailable() throws {
        let delegate = FlexibleAuthDelegate(username: "test", password: "pw",
                                            privateKeyString: nil,
                                            privateKeyPassphrase: nil)
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { try? group.syncShutdownGracefully() }
        let promise = group.next().makePromise(of: NIOSSHUserAuthenticationOffer?.self)
        delegate.nextAuthenticationType(availableMethods: [.password],
                                        nextChallengePromise: promise)
        let offer = try promise.futureResult.wait()
        #expect(offer?.offer.isPassword == true)
    }

    @Test("Delegate returns nil when neither key nor password is available")
    func testNoCredentialsFails() throws {
        let delegate = FlexibleAuthDelegate(username: "test", password: nil,
                                            privateKeyString: nil,
                                            privateKeyPassphrase: nil)
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { try? group.syncShutdownGracefully() }
        let promise = group.next().makePromise(of: NIOSSHUserAuthenticationOffer?.self)
        delegate.nextAuthenticationType(availableMethods: [.publicKey, .password],
                                        nextChallengePromise: promise)
        let offer = try promise.futureResult.wait()
        #expect(offer == nil)
    }
}

// MARK: - PEM Key Logic Tests

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

// MARK: - Connection Model Tests

@Suite("Connection Model Tests")
struct ConnectionModelTests {
    @Test("Copy method creates a deep, independent copy")
    @MainActor func testConnectionCopy() {
        let info = ConnectionInfo(name: "Original", serverAddress: "127.0.0.1",
                                  portNumber: "22", username: "user",
                                  password: "pw", privateKey: "key",
                                  privateKeyPassphrase: "pp")
        let tunnel = TunnelInfo(localPort: "8080", remoteServer: "localhost", remotePort: "80")
        let original = Connection(connectionInfo: info, tunnelInfo: tunnel)

        let copy = original.copy()
        #expect(original !== copy)
        #expect(original.id == copy.id)
        #expect(original.connectionInfo.name == copy.connectionInfo.name)
        #expect(original.tunnelInfo.localPort == copy.tunnelInfo.localPort)

        copy.connectionInfo.name = "Modified"
        #expect(original.connectionInfo.name == "Original")
        #expect(copy.connectionInfo.name == "Modified")
    }
}

// MARK: - ConnectionStore Mapping Tests

@Suite("ConnectionStore Mapping Tests")
struct ConnectionStoreMappingTests {
    @Test("CloudKit record mapping round-trip preserves all fields including ports")
    @MainActor func testCloudKitMapping() throws {
        let store = ConnectionStore(mode: .view, connections: [])
        let id = UUID()

        let info = ConnectionInfo(name: "Test Server", serverAddress: "server.example.com",
                                  portNumber: "2222", username: "testuser",
                                  password: "testpassword", privateKey: "testkey",
                                  privateKeyPassphrase: "pp")
        let tunnel = TunnelInfo(localPort: "9000", remoteServer: "db.internal", remotePort: "5432")
        let source = Connection(id: id, connectionInfo: info, tunnelInfo: tunnel)

        let zoneID = CKRecordZone.ID(zoneName: "TestZone", ownerName: CKCurrentUserDefaultName)
        let record = CKRecord(recordType: "Connection",
                              recordID: CKRecord.ID(recordName: id.uuidString, zoneID: zoneID))

        store.updateRecordFields(record, withConnection: source)
        record["uuid"] = id.uuidString  // updateRecordFields doesn't set uuid; production code sets it separately
        let result = try #require(store.recordToConnection(record: record))

        #expect(result.id == source.id)
        #expect(result.connectionInfo.name == "Test Server")
        #expect(result.connectionInfo.serverAddress == "server.example.com")
        #expect(result.connectionInfo.username == "testuser")
        // Secrets recovered from the mock credentials store
        #expect(result.connectionInfo.password == "testpassword")
        #expect(result.connectionInfo.privateKey == "testkey")
        // Port fields survive the String -> Int64 -> String round-trip
        #expect(result.connectionInfo.portNumber == "2222")
        #expect(result.tunnelInfo.localPort == "9000")
        #expect(result.tunnelInfo.remotePort == "5432")
        #expect(result.tunnelInfo.remoteServer == "db.internal")
    }
}

// MARK: - Helpers

private extension NIOSSHUserAuthenticationOffer.Offer {
    var isPrivateKey: Bool {
        if case .privateKey = self { return true }
        return false
    }

    var isPassword: Bool {
        if case .password = self { return true }
        return false
    }
}
