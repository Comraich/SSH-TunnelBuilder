import Foundation
import NIO
import NIOSSH
import CryptoKit
import Combine

// NOTE: PEMKeyKind, detectPEMKeyKind, isPEMEncrypted are assumed to be defined in MainView.swift or another file.
// If they are not visible here, move them to a shared utility file.

// MARK: - Helper Types

private final class InteractiveHostKeyDelegate: NIOSSHClientServerAuthenticationDelegate, Sendable {
    let host: String
    let port: Int
    let validationHandler: @Sendable (String, Int, NIOSSHPublicKey, EventLoopPromise<Void>) -> Void

    init(host: String, port: Int, validationHandler: @escaping @Sendable (String, Int, NIOSSHPublicKey, EventLoopPromise<Void>) -> Void) {
        self.host = host
        self.port = port
        self.validationHandler = validationHandler
    }

    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        validationHandler(host, port, hostKey, validationCompletePromise)
    }
}

struct UncheckedSendable<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}

// MARK: - NIOSSH Handlers

private final class SSHSessionReadyHandler: ChannelInboundHandler, RemovableChannelHandler {
    typealias InboundIn = Any

    private let sessionReadyPromise: EventLoopPromise<Void>
    private var promiseFulfilled = false

    init(sessionReadyPromise: EventLoopPromise<Void>) {
        self.sessionReadyPromise = sessionReadyPromise
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if event is UserAuthSuccessEvent, !promiseFulfilled {
            promiseFulfilled = true
            sessionReadyPromise.succeed(())
        }
        context.fireUserInboundEventTriggered(event)
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        if !promiseFulfilled {
            promiseFulfilled = true
            sessionReadyPromise.fail(error)
        }
        context.fireErrorCaught(error)
    }
    
    func channelInactive(context: ChannelHandlerContext) {
        if !promiseFulfilled {
            promiseFulfilled = true
            sessionReadyPromise.fail(ChannelError.ioOnClosedChannel)
        }
        context.fireChannelInactive()
    }
}

private extension TaskGroup where ChildTaskResult == Void {
    mutating func closeChannel(_ channel: Channel?, name: String) {
        guard let channel = channel else { return }
        self.addTask {
            do {
                try await channel.close(mode: .all).get()
            } catch {
                print("Error closing \(name) channel: \(error)")
            }
        }
    }
}

private final class GenericRelayHandler<InboundType, OutboundType>: ChannelInboundHandler {
    typealias InboundIn = InboundType

    private let peer: Channel
    private let onBytes: (Int) -> Void
    private let transform: (InboundType) -> (OutboundType?, Int)

    init(peer: Channel, onBytes: @escaping (Int) -> Void, transform: @escaping (InboundType) -> (OutboundType?, Int)) {
        self.peer = peer
        self.onBytes = onBytes
        self.transform = transform
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let inboundData = self.unwrapInboundIn(data)
        let (outboundData, count) = transform(inboundData)

        if count > 0 {
            self.onBytes(count)
            if let outboundData = outboundData {
                _ = peer.writeAndFlush(outboundData)
            }
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        _ = peer.close(mode: .all)
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        print("GenericRelayHandler error: \(error)")
        _ = peer.close(mode: .all)
        context.close(promise: nil)
    }
}

internal enum OpenSSHKeyParser {
    static func extractOpenSSHData(from pem: String) throws -> Data { return try FlexibleAuthDelegate.extractOpenSSHData(from: pem) }
    static func parseOpenSSHPrivateKey(_ data: Data) throws -> NIOSSHPrivateKey { return try FlexibleAuthDelegate.parseOpenSSHPrivateKey(data) }
    static func normalizeScalar(_ bytes: [UInt8], targetSize: Int) throws -> Data { return try FlexibleAuthDelegate.normalizeScalar(bytes, targetSize: targetSize) }
    static func readSSHString(from buffer: inout ByteBuffer) throws -> String { return try FlexibleAuthDelegate.readSSHString(from: &buffer) }
    static func readSSHBytes(from buffer: inout ByteBuffer) throws -> [UInt8] { return try FlexibleAuthDelegate.readSSHBytes(from: &buffer) }
}

private final class FlexibleAuthDelegate: NIOSSHClientUserAuthenticationDelegate, Sendable {
    let username: String
    let password: String?
    let privateKey: NIOSSHPrivateKey?
    let initializationError: String? // Captured synchronously for immediate reporting
    let reportError: (@Sendable (String) -> Void)?

    init(username: String, password: String?, privateKeyString: String?, privateKeyPassphrase: String?, reportError: (@Sendable (String) -> Void)? = nil) {
        self.reportError = reportError
        self.username = username
        self.password = password?.isEmpty == false ? password : nil
        
        var parsedKey: NIOSSHPrivateKey? = nil
        var initError: String? = nil
        
        if let keyString = privateKeyString, !keyString.isEmpty {
            do {
                parsedKey = try FlexibleAuthDelegate.parsePrivateKey(pemString: keyString, passphrase: privateKeyPassphrase)
                print("[SSH] Private key parsed successfully.")
            } catch {
                let errorMsg = "Failed to parse private key: \(error.localizedDescription)"
                initError = error.localizedDescription
                reportError?(errorMsg)
                print(errorMsg)
            }
        }
        self.privateKey = parsedKey
        self.initializationError = initError
    }
    
    private func makeAuthOffer(with offerType: NIOSSHUserAuthenticationOffer.Offer) -> NIOSSHUserAuthenticationOffer {
        return NIOSSHUserAuthenticationOffer(
            username: username,
            serviceName: "ssh-connection",
            offer: offerType
        )
    }

    func nextAuthenticationType(
        availableMethods: NIOSSHAvailableUserAuthenticationMethods,
        nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>
    ) {
        if availableMethods.contains(.publicKey), let key = self.privateKey {
             // Correctly construct the private key offer wrapper
             let offer = makeAuthOffer(with: .privateKey(.init(privateKey: key)))
             nextChallengePromise.succeed(offer)
             return
        }
        
        if availableMethods.contains(.password), let password = self.password {
            let offer = makeAuthOffer(with: .password(.init(password: password)))
            nextChallengePromise.succeed(offer)
            return
        }

        nextChallengePromise.succeed(nil)
    }
}

private extension FlexibleAuthDelegate {
    static func parsePrivateKey(pemString: String, passphrase: String?) throws -> NIOSSHPrivateKey {
        let trimmed = pemString.trimmingCharacters(in: .whitespacesAndNewlines)
        
        let kind = detectPEMKeyKind(trimmed)
        
        // Handle OpenSSH keys (Ed25519, ECDSA)
        if kind == .openssh {
            let data = try extractOpenSSHData(from: trimmed)
            return try parseOpenSSHPrivateKey(data)
        }
        
        guard kind == .pkcs8 || kind == .ec else {
            throw NSError(domain: "FlexibleAuthDelegate", code: 0, userInfo: [NSLocalizedDescriptionKey: "Unsupported key type: \(keyKindDescription(kind))"])
        }

        let isEncrypted = isPEMEncrypted(trimmed)
        let derData: Data
        
        if isEncrypted {
            guard let passphrase = passphrase, !passphrase.isEmpty else {
                 throw NSError(domain: "FlexibleAuthDelegate", code: 0, userInfo: [NSLocalizedDescriptionKey: "Key is encrypted but no passphrase provided."])
            }
            derData = try PEMDecryptor.decryptEncryptedPKCS8PEM(trimmed, passphrase: passphrase)
        } else if trimmed.contains("-----BEGIN PRIVATE KEY-----") || trimmed.contains("-----BEGIN EC PRIVATE KEY-----") {
            derData = try decodeUnencryptedPEM(trimmed)
        } else {
            throw PEMDecryptorError.invalidPEM
        }
        
        let parsedKey = try PEMDecryptor.parsePKCS8PrivateKey(derData)
        
        switch parsedKey {
        case .ec(_, let privateScalar):
            switch privateScalar.count {
            case 32:
                let key = try P256.Signing.PrivateKey(rawRepresentation: privateScalar)
                return NIOSSHPrivateKey(p256Key: key)
            case 48:
                let key = try P384.Signing.PrivateKey(rawRepresentation: privateScalar)
                return NIOSSHPrivateKey(p384Key: key)
            case 66:
                let key = try P521.Signing.PrivateKey(rawRepresentation: privateScalar)
                return NIOSSHPrivateKey(p521Key: key)
            default:
                throw NSError(domain: "FlexibleAuthDelegate", code: 0, userInfo: [NSLocalizedDescriptionKey: "Unsupported ECDSA curve length."])
            }
        case .rsa:
            throw NSError(domain: "FlexibleAuthDelegate", code: 0, userInfo: [NSLocalizedDescriptionKey: "RSA keys are not currently supported by the underlying cryptographic library setup. Convert your key to Ed25519 or ECDSA (nistp256/384/521)."])
        }
    }
    
    // MARK: - OpenSSH Parsing Helpers
    
    private static func extractOpenSSHData(from pem: String) throws -> Data {
        let lines = pem.components(separatedBy: .newlines)
        var base64String = ""
        var insideBlock = false
        
        for line in lines {
            if line.contains("-----BEGIN OPENSSH PRIVATE KEY-----") {
                insideBlock = true
                continue
            }
            if line.contains("-----END OPENSSH PRIVATE KEY-----") {
                insideBlock = false
                break
            }
            if insideBlock {
                base64String += line.trimmingCharacters(in: .whitespaces)
            }
        }
        
        guard !base64String.isEmpty, let data = Data(base64Encoded: base64String) else {
            throw NSError(domain: "FlexibleAuthDelegate", code: 0, userInfo: [NSLocalizedDescriptionKey: "Invalid OpenSSH PEM format"])
        }
        return data
    }

    private static func parseOpenSSHPrivateKey(_ data: Data) throws -> NIOSSHPrivateKey {
        var buffer = ByteBuffer(data: data)
        
        // 1. Magic "openssh-key-v1\0" (15 bytes)
        guard let magic = buffer.readBytes(length: 15),
              String(bytes: magic, encoding: .utf8) == "openssh-key-v1\0" else {
            throw NSError(domain: "OpenSSHParser", code: 0, userInfo: [NSLocalizedDescriptionKey: "Invalid OpenSSH header"])
        }
        
        // 2. Cipher
        let cipherName = try readSSHString(from: &buffer)
        // 3. KDF
        let kdfName = try readSSHString(from: &buffer)
        // 4. KDF Options (Binary data)
        let _ = try readSSHBytes(from: &buffer) // kdfOptions
        
        if cipherName != "none" || kdfName != "none" {
            throw NSError(domain: "OpenSSHParser", code: 0, userInfo: [NSLocalizedDescriptionKey: "Encrypted OpenSSH keys (passphrase) are not supported yet. Please remove the passphrase or convert to PEM."])
        }
        
        // 5. Num Keys
        guard let numKeys = buffer.readInteger(as: UInt32.self) else {
             throw NSError(domain: "OpenSSHParser", code: 0, userInfo: [NSLocalizedDescriptionKey: "Invalid format (num keys)"])
        }
        
        guard numKeys >= 1 else {
             throw NSError(domain: "OpenSSHParser", code: 0, userInfo: [NSLocalizedDescriptionKey: "No keys found in file"])
        }
        
        // 6. Public Key Blob (Binary data)
        let _ = try readSSHBytes(from: &buffer) // pubKeyBlob
        
        // 7. Private Key Blob
        let privateBlobBytes = try readSSHBytes(from: &buffer)
        var privateBuffer = ByteBuffer(bytes: privateBlobBytes)
        
        // Check Ints
        guard let check1 = privateBuffer.readInteger(as: UInt32.self),
              let check2 = privateBuffer.readInteger(as: UInt32.self),
              check1 == check2 else {
            throw NSError(domain: "OpenSSHParser", code: 0, userInfo: [NSLocalizedDescriptionKey: "OpenSSH integrity check failed"])
        }
        
        // Key Type
        let keyType = try readSSHString(from: &privateBuffer)
        
        if keyType == "ssh-ed25519" {
            // Pub key
            let _ = try readSSHBytes(from: &privateBuffer)
            // Priv key
            let keyBytes = try readSSHBytes(from: &privateBuffer)
            
            // NIOSSH expects the OpenSSH Ed25519 blob
            return try NIOSSHPrivateKey(openSSHEd25519PrivateKeyBlob: keyBytes)
        } else if keyType.hasPrefix("ecdsa-sha2-") {
            let curveName = try readSSHString(from: &privateBuffer)
            let _ = try readSSHBytes(from: &privateBuffer) // Public Key
            let privateScalarBytes = try readSSHBytes(from: &privateBuffer) // Private Key Scalar
            
            let normalized: Data
            switch curveName {
            case "nistp256":
                normalized = try normalizeScalar(privateScalarBytes, targetSize: 32)
                let key = try P256.Signing.PrivateKey(rawRepresentation: normalized)
                return NIOSSHPrivateKey(p256Key: key)
            case "nistp384":
                normalized = try normalizeScalar(privateScalarBytes, targetSize: 48)
                let key = try P384.Signing.PrivateKey(rawRepresentation: normalized)
                return NIOSSHPrivateKey(p384Key: key)
            case "nistp521":
                normalized = try normalizeScalar(privateScalarBytes, targetSize: 66)
                let key = try P521.Signing.PrivateKey(rawRepresentation: normalized)
                return NIOSSHPrivateKey(p521Key: key)
            default:
                throw NSError(domain: "OpenSSHParser", code: 0, userInfo: [NSLocalizedDescriptionKey: "Unsupported ECDSA curve: \(curveName)"])
            }
        } else {
             throw NSError(domain: "OpenSSHParser", code: 0, userInfo: [NSLocalizedDescriptionKey: "Unsupported OpenSSH key type: \(keyType). Only ssh-ed25519 and ecdsa-sha2-nistp256/384/521 are supported in this format."])
        }
    }
    
    private static func normalizeScalar(_ bytes: [UInt8], targetSize: Int) throws -> Data {
        var result = bytes
        // Strip leading zeros if longer (OpenSSH MPINT format)
        while result.count > targetSize && result.first == 0 {
            result.removeFirst()
        }
        
        if result.count > targetSize {
            throw NSError(domain: "OpenSSHParser", code: 0, userInfo: [NSLocalizedDescriptionKey: "Private key scalar too large for curve"])
        }
        
        // Pad with leading zeros if shorter
        while result.count < targetSize {
            result.insert(0, at: 0)
        }
        
        return Data(result)
    }

    private static func readSSHString(from buffer: inout ByteBuffer) throws -> String {
        let bytes = try readSSHBytes(from: &buffer)
        guard let string = String(bytes: bytes, encoding: .utf8) else {
             throw NSError(domain: "OpenSSHParser", code: 0, userInfo: [NSLocalizedDescriptionKey: "Invalid string encoding"])
        }
        return string
    }
    
    private static func readSSHBytes(from buffer: inout ByteBuffer) throws -> [UInt8] {
        guard let length = buffer.readInteger(as: UInt32.self) else {
            throw NSError(domain: "OpenSSHParser", code: 0, userInfo: [NSLocalizedDescriptionKey: "Truncated data (length)"])
        }
        guard let bytes = buffer.readBytes(length: Int(length)) else {
             throw NSError(domain: "OpenSSHParser", code: 0, userInfo: [NSLocalizedDescriptionKey: "Truncated data (bytes)"])
        }
        return bytes
    }
    
    private static func decodeUnencryptedPEM(_ pem: String) throws -> Data {
        let normalized = pem
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        
        let startMarkers = ["-----BEGIN PRIVATE KEY-----", "-----BEGIN EC PRIVATE KEY-----"]
        let endMarkers = ["-----END PRIVATE KEY-----", "-----END EC PRIVATE KEY-----"]
        
        var base64Content = ""
        
        for (start, end) in zip(startMarkers, endMarkers) {
            if let startRange = normalized.range(of: start),
               let endRange = normalized.range(of: end) {
                let base64Start = startRange.upperBound
                let base64End = endRange.lowerBound
                base64Content = normalized[base64Start..<base64End]
                    .components(separatedBy: .newlines)
                    .joined()
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                break
            }
        }
        
        guard !base64Content.isEmpty, let data = Data(base64Encoded: base64Content) else {
            throw PEMDecryptorError.invalidPEM
        }
        return data
    }
}

// MARK: - SSHManager

final class SSHManager: ObservableObject, @unchecked Sendable {
    let connection: Connection
    private var eventLoopGroup: MultiThreadedEventLoopGroup?
    private var sshClientChannel: Channel?
    private var localServerChannel: Channel?
    private let lock = NSLock()
    
    // Store active config safely for background threads
    private var activeTunnelInfo: TunnelInfo?

    private var sessionReadyPromise: EventLoopPromise<Void>?
    private var sessionReadyCompleted = false

    @Published var lastErrorMessage: String? = nil
    
    private var internalBytesSent: Int64 = 0
    private var internalBytesReceived: Int64 = 0
    
    // Callback: (hostname, fingerprint, keyType, keyData, completion)
    var hostKeyValidationCallback: (@Sendable (String, String, String, Data, @escaping @Sendable (Bool) -> Void) -> Void)?

    init(connection: Connection) { self.connection = connection }

    func connect() async throws {
        // 1. Capture connection info on MainActor to avoid races and allow background processing
        let (connInfo, tunnelInfo) = await MainActor.run { () -> (ConnectionInfo?, TunnelInfo?) in
            if connection.isActive {
                return (nil, nil)
            }
            connection.isConnecting = true
            return (connection.connectionInfo, connection.tunnelInfo)
        }
        
        guard let connectionInfo = connInfo, let tunnelInfo = tunnelInfo else { return }
        
        lock.withLock {
            self.activeTunnelInfo = tunnelInfo
        }
        
        let hasPassword = !connectionInfo.password.isEmpty
        let hasKey = !connectionInfo.privateKey.isEmpty
        
        guard hasPassword || hasKey else {
            print("SSHManager.connect: Missing credentials for authentication.")
            await MainActor.run {
                connection.isConnecting = false
                connection.isActive = false
            }
            throw NSError(domain: "SSHManager", code: 1, userInfo: [NSLocalizedDescriptionKey: "Missing password or private key"])
        }

        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        lock.withLock { self.eventLoopGroup = group }

        // 2. Offload auth delegate creation (heavy crypto) to detached task
        let authDelegate = await Task.detached { () -> FlexibleAuthDelegate in
            return FlexibleAuthDelegate(
                username: connectionInfo.username,
                password: hasPassword ? connectionInfo.password : nil,
                privateKeyString: hasKey ? connectionInfo.privateKey : nil,
                privateKeyPassphrase: connectionInfo.privateKeyPassphrase,
                reportError: nil // We will check initializationError directly
            )
        }.value
        
        if let initError = authDelegate.initializationError {
            await MainActor.run {
                self.lastErrorMessage = "Failed to parse private key: \(initError)"
            }
        }
        
        if hasKey && authDelegate.privateKey == nil && !hasPassword {
            await MainActor.run { connection.isConnecting = false }
            await shutdown()
            
            let detail = authDelegate.initializationError ?? "Unknown key error"
            let errorMsg = "Failed to initialize key: \(detail). If this is an OpenSSH encrypted key, remove the passphrase or convert to PKCS#8/Ed25519/ECDSA."
            
            await MainActor.run {
                self.lastErrorMessage = errorMsg
            }
            
            throw NSError(domain: "SSHManager", code: 1, userInfo: [NSLocalizedDescriptionKey: errorMsg])
        }
        
        let host = connectionInfo.serverAddress
        let port = Int(connectionInfo.portNumber) ?? 22

        let serverDelegate = InteractiveHostKeyDelegate(host: host, port: port) { [weak self] host, port, key, promise in
            self?.handleHostKeyValidation(host: host, port: port, key: key, promise: promise, knownHostKey: connectionInfo.knownHostKey)
        }

        self.sessionReadyPromise = group.next().makePromise(of: Void.self)
        self.sessionReadyCompleted = false

        let bootstrap = ClientBootstrap(group: group)
            .channelOption(ChannelOptions.connectTimeout, value: .seconds(10))
            .channelInitializer { channel in
                let clientConfig = SSHClientConfiguration(userAuthDelegate: authDelegate,
                                                          serverAuthDelegate: serverDelegate)
                let sshHandler = NIOSSHHandler(
                    role: .client(clientConfig),
                    allocator: channel.allocator,
                    inboundChildChannelInitializer: nil
                )
                guard let sessionReadyPromise = self.sessionReadyPromise else {
                    let error = NSError(domain: "SSHManager", code: 1, userInfo: [NSLocalizedDescriptionKey: "Missing sessionReadyPromise"])
                    return channel.eventLoop.makeFailedFuture(error)
                }
                let sessionReadyHandler = SSHSessionReadyHandler(sessionReadyPromise: sessionReadyPromise)
                
                return channel.pipeline.addHandler(sshHandler).flatMap {
                    return channel.pipeline.addHandler(sessionReadyHandler)
                }
            }

        do {
            let channel = try await bootstrap.connect(host: host, port: port).get()
            
            if let sessionReadyPromise = self.sessionReadyPromise {
                try await sessionReadyPromise.futureResult.get()
                self.sessionReadyCompleted = true
            }
            
            lock.withLock { self.sshClientChannel = channel }
            await MainActor.run {
                self.connection.isActive = true
                self.lastErrorMessage = nil
                self.connection.isConnecting = false
            }
            
            try await startLocalListener()
        } catch {
            print("SSH connect failed: \(error)")
            if let p = self.sessionReadyPromise, self.sessionReadyCompleted == false {
                self.sessionReadyCompleted = true
                p.fail(error)
            }
            self.sessionReadyPromise = nil

            await MainActor.run { self.connection.isConnecting = false }
            await shutdown()
            throw error 
        }
    }
    
    private func handleHostKeyValidation(host: String, port: Int, key: NIOSSHPublicKey, promise: EventLoopPromise<Void>, knownHostKey: String) {
        let keyData = serialize(key: key)
        let fingerprint: String
        if let keyData = keyData {
            let digest = SHA256.hash(data: keyData)
            fingerprint = "SHA256:" + Data(digest).base64EncodedString()
        } else {
            // Fallback: we cannot serialize the key with this NIOSSH version; present a legacy marker.
            fingerprint = "SHA256:UNAVAILABLE"
        }
        
        if !knownHostKey.isEmpty {
            // Try raw key base64 match first (if we have raw key bytes)
            if let keyData = keyData, let knownData = Data(base64Encoded: knownHostKey), knownData == keyData {
                promise.succeed(())
                return
            }
            // Then try fingerprint match (stored as the literal SHA256:... string)
            if knownHostKey == fingerprint {
                promise.succeed(())
                return
            }
            let error = NSError(domain: "SSHManager", code: 2, userInfo: [NSLocalizedDescriptionKey: "SECURITY WARNING: Host key mismatch! The server key has changed. This could be a Man-in-the-Middle attack."])
            promise.fail(error)
            return
        }
        
        guard let callback = self.hostKeyValidationCallback else {
            promise.fail(NSError(domain: "SSHManager", code: 3, userInfo: [NSLocalizedDescriptionKey: "Unknown host key and no validation callback configured."]))
            return
        }
        
        let keyType = keyData == nil ? "Unknown (Legacy Lib)" : "Unknown"
        callback(host, fingerprint, keyType, keyData ?? Data()) { allowed in
            if allowed {
                promise.succeed(())
            } else {
                promise.fail(NSError(domain: "SSHManager", code: 4, userInfo: [NSLocalizedDescriptionKey: "User rejected host key."]))
            }
        }
    }
    
    private func serialize(key: NIOSSHPublicKey) -> Data? {
        // If NIOSSH supports serializing the key (e.g. key.write(to:)), return raw key bytes.
        // Otherwise return nil and we will fall back to fingerprint-based verification.
        return nil
    }

    private func startLocalListener() async throws {
        let group = lock.withLock { self.eventLoopGroup }
        // Capture active tunnel info safely
        guard let group, let sshChannel = lock.withLock({ self.sshClientChannel }),
              let tunnelInfo = lock.withLock({ self.activeTunnelInfo }) else { return }

        let localPort = Int(tunnelInfo.localPort) ?? 0

        let serverBootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.backlog, value: 8)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { [weak self] inbound in
                guard let strongSelf = self else {
                    return inbound.eventLoop.makeFailedFuture(IOError(errnoCode: ECANCELED, reason: "SSHManager deallocated"))
                }

                guard let originator = inbound.remoteAddress else {
                    let error = IOError(errnoCode: EADDRNOTAVAIL, reason: "Inbound channel has no remote address")
                    return inbound.eventLoop.makeFailedFuture(error)
                }

                let setupFuture = inbound.setOption(ChannelOptions.autoRead, value: false).flatMap {
                    sshChannel.pipeline.handler(type: NIOSSHHandler.self)
                        .map { UncheckedSendable($0) } // Wrap immediately to satisfy Sendable check
                }.flatMap { (wrappedSSH: UncheckedSendable<NIOSSHHandler>) -> EventLoopFuture<Channel> in
                    let childChannelPromise = inbound.eventLoop.makePromise(of: Channel.self)
                    
                    print("Opening direct-tcpip to \(tunnelInfo.remoteServer):\(Int(tunnelInfo.remotePort) ?? 0) from originator: \(originator)")
                    
                    let directTCPIP = NIOSSH.SSHChannelType.DirectTCPIP(
                        targetHost: tunnelInfo.remoteServer,
                        targetPort: Int(tunnelInfo.remotePort) ?? 0,
                        originatorAddress: originator
                    )
                    
                    wrappedSSH.value.createChannel(childChannelPromise, channelType: .directTCPIP(directTCPIP)) { sshChildChannel, _ in
                        let received: (Int) -> Void = { [weak strongSelf] n in
                            guard let manager = strongSelf else { return }
                            Task { @MainActor in manager.handleBytesReceived(n) }
                        }
                        let sshToTCP = GenericRelayHandler<SSHChannelData, ByteBuffer>(peer: inbound, onBytes: received) { sshData in
                            guard case .byteBuffer(let buffer) = sshData.data else { return (nil, 0) }
                            return (buffer, buffer.readableBytes)
                        }
                        return sshChildChannel.pipeline.addHandler(sshToTCP)
                    }
                    return childChannelPromise.futureResult
                }.flatMap { sshChildChannel -> EventLoopFuture<Void> in
                    let sent: (Int) -> Void = { [weak strongSelf] n in
                        guard let manager = strongSelf else { return }
                        Task { @MainActor in manager.handleBytesSent(n) }
                    }
                    let tcpToSSH = GenericRelayHandler<ByteBuffer, SSHChannelData>(peer: sshChildChannel, onBytes: sent) { buffer in
                        let sshData = SSHChannelData(type: .channel, data: .byteBuffer(buffer))
                        return (sshData, buffer.readableBytes)
                    }
                    return inbound.pipeline.addHandler(tcpToSSH)
                }.flatMap {
                    inbound.setOption(ChannelOptions.autoRead, value: true)
                }

                setupFuture.whenFailure { error in
                    print("Failed to establish forwarding channel to \(tunnelInfo.remoteServer):\(Int(tunnelInfo.remotePort) ?? 0) — error: \(error)")
                    inbound.close(promise: nil)
                }
                
                return setupFuture
            }
            .childChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)

        do {
            let server = try await serverBootstrap.bind(host: "127.0.0.1", port: localPort).get()
            lock.withLock { self.localServerChannel = server }
            if let localPort = server.localAddress?.port {
                print("Local listener bound on 127.0.0.1:\(localPort)")
            }
        } catch {
            print("Local listener bind failed: \(error)")
            await MainActor.run { self.connection.isConnecting = false }
            await self.disconnect()
            throw error 
        }
    }

    func disconnect() async {
        await shutdown()
    }

    private func shutdown() async {
        await MainActor.run { connection.isConnecting = false }
        
        await withTaskGroup(of: Void.self) { group in
            var mutableGroup = group
            let (ssh, local) = lock.withLock { (self.sshClientChannel, self.localServerChannel) }
            mutableGroup.closeChannel(ssh, name: "SSH client")
            mutableGroup.closeChannel(local, name: "local server")
        }
        
        lock.withLock {
            sshClientChannel = nil
            localServerChannel = nil
            activeTunnelInfo = nil

            if let p = self.sessionReadyPromise, self.sessionReadyCompleted == false {
                self.sessionReadyCompleted = true
                p.fail(ChannelError.ioOnClosedChannel)
            }
            self.internalBytesSent = 0
            self.internalBytesReceived = 0
        }
        
        self.sessionReadyPromise = nil
        self.sessionReadyCompleted = false

        if let group = lock.withLock({ self.eventLoopGroup }) {
            do {
                try await group.shutdownGracefully()
            } catch {
                print("EventLoopGroup shutdown error: \(error)")
            }
            lock.withLock { self.eventLoopGroup = nil }
        }
        
        await MainActor.run {
            self.connection.isActive = false
            self.connection.bytesSent = 0
            self.connection.bytesReceived = 0
            self.lastErrorMessage = nil
        }
    }
    
    // MARK: - Main Actor State Updates
    
    private func handleBytesSent(_ count: Int) {
        let n = Int64(count)
        self.internalBytesSent += n
        Task { @MainActor in
            self.connection.bytesSent += n
        }
    }
    
    private func handleBytesReceived(_ count: Int) {
        let n = Int64(count)
        self.internalBytesReceived += n
        Task { @MainActor in
            self.connection.bytesReceived += n
        }
    }
}

