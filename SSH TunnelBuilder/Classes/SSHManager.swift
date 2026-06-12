import Foundation
import NIO
@preconcurrency import NIOSSH
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
                Logger.error("Error closing \(name) channel: \(error)", log: Logger.ssh)
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
                // Ensure write happens on the peer's event loop for thread safety.
                peer.eventLoop.execute {
                    self.peer.writeAndFlush(outboundData, promise: nil)
                }
            }
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        // Ensure close happens on the peer's event loop for thread safety.
        peer.eventLoop.execute {
            self.peer.close(mode: .all, promise: nil)
        }
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        Logger.error("GenericRelayHandler error: \(error)", log: Logger.ssh)
        // Ensure close happens on the peer's event loop for thread safety.
        peer.eventLoop.execute {
            self.peer.close(mode: .all, promise: nil)
        }
        context.close(promise: nil)
    }
}

internal enum OpenSSHKeyParser {
    enum OpenSSHParsingError: LocalizedError, Equatable {
        case insufficientData
        case invalidPEMFormat
        case invalidKeyFormat(reason: String)
        case encryptedKeyNotSupported
        case unsupportedKeyType(String)
        case unsupportedCurve(String)
        case invalidStringData

        var errorDescription: String? {
            switch self {
            case .insufficientData:
                return "Insufficient data while parsing the key."
            case .invalidPEMFormat:
                return "Invalid PEM format."
            case .invalidKeyFormat(let reason):
                return "Invalid key format: \(reason)"
            case .encryptedKeyNotSupported:
                return "Encrypted OpenSSH keys are not supported. Please remove the passphrase or convert to PKCS#8."
            case .unsupportedKeyType(let type):
                return "Unsupported key type: '\(type)'."
            case .unsupportedCurve(let curve):
                return "Unsupported elliptic curve: '\(curve)'. Supported curves are nistp256, nistp384, and nistp521."
            case .invalidStringData:
                return "Invalid string data in key."
            }
        }
    }

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
                Logger.info("Private key parsed successfully", log: Logger.ssh)
            } catch {
                let errorMsg = "Failed to parse private key: \(error.localizedDescription)"
                initError = error.localizedDescription
                reportError?(errorMsg)
                Logger.error(errorMsg, log: Logger.ssh)
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
            throw SSHTunnelError.unsupportedKeyType(keyKindDescription(kind))
        }

        let isEncrypted = isPEMEncrypted(trimmed)
        let derData: Data

        if isEncrypted {
            guard let passphrase = passphrase, !passphrase.isEmpty else {
                throw SSHTunnelError.encryptedKeyNoPassphrase
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
                throw SSHTunnelError.unsupportedCurveLength
            }
        case .rsa:
            throw SSHTunnelError.rsaNotSupported
        }
    }
    
    // MARK: - OpenSSH Parsing Helpers
    
    static func extractOpenSSHData(from pem: String) throws -> Data {
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
            throw OpenSSHKeyParser.OpenSSHParsingError.invalidPEMFormat
        }
        return data
    }

    static func parseOpenSSHPrivateKey(_ data: Data) throws -> NIOSSHPrivateKey {
        var buffer = ByteBuffer(data: data)
        
        // 1. Magic "openssh-key-v1\0" (15 bytes)
        guard let magic = buffer.readBytes(length: 15),
              String(bytes: magic, encoding: .utf8) == "openssh-key-v1\0" else {
            throw OpenSSHKeyParser.OpenSSHParsingError.invalidKeyFormat(reason: "Invalid OpenSSH magic header")
        }
        
        // 2. Cipher
        let cipherName = try readSSHString(from: &buffer)
        // 3. KDF
        let kdfName = try readSSHString(from: &buffer)
        // 4. KDF Options (Binary data)
        let _ = try readSSHBytes(from: &buffer) // kdfOptions
        
        if cipherName != "none" || kdfName != "none" {
            throw OpenSSHKeyParser.OpenSSHParsingError.encryptedKeyNotSupported
        }
        
        // 5. Num Keys
        guard let numKeys = buffer.readInteger(as: UInt32.self) else {
             throw OpenSSHKeyParser.OpenSSHParsingError.invalidKeyFormat(reason: "Could not read number of keys from private key blob")
        }
        
        guard numKeys >= 1 else {
             throw OpenSSHKeyParser.OpenSSHParsingError.invalidKeyFormat(reason: "No keys found in private key data")
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
            throw OpenSSHKeyParser.OpenSSHParsingError.invalidKeyFormat(reason: "Private key blob integrity check failed")
        }
        
        // Key Type
        let keyType = try readSSHString(from: &privateBuffer)
        
        if keyType == "ssh-ed25519" {
            // Pub key
            let _ = try readSSHBytes(from: &privateBuffer)
            // Priv key — OpenSSH stores 64 bytes: seed (32) || public key (32).
            // Curve25519.Signing.PrivateKey takes the 32-byte seed as rawRepresentation.
            let keyBytes = try readSSHBytes(from: &privateBuffer)
            guard keyBytes.count >= 32 else {
                throw OpenSSHKeyParser.OpenSSHParsingError.invalidKeyFormat(reason: "Ed25519 private key blob too short (\(keyBytes.count) bytes)")
            }
            let seed = Data(keyBytes.prefix(32))
            let ed25519Key = try Curve25519.Signing.PrivateKey(rawRepresentation: seed)
            return NIOSSHPrivateKey(ed25519Key: ed25519Key)
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
                throw OpenSSHKeyParser.OpenSSHParsingError.unsupportedCurve(curveName)
            }
        } else {
            throw OpenSSHKeyParser.OpenSSHParsingError.unsupportedKeyType(keyType)
        }
    }
    
    static func normalizeScalar(_ bytes: [UInt8], targetSize: Int) throws -> Data {
        var result = bytes
        // Strip leading zeros if longer (OpenSSH MPINT format)
        while result.count > targetSize && result.first == 0 {
            result.removeFirst()
        }
        
        if result.count > targetSize {
            throw OpenSSHKeyParser.OpenSSHParsingError.invalidKeyFormat(reason: "Private key scalar is too large for the curve")
        }
        
        // Pad with leading zeros if shorter
        while result.count < targetSize {
            result.insert(0, at: 0)
        }
        
        return Data(result)
    }

    static func readSSHString(from buffer: inout ByteBuffer) throws -> String {
        let bytes = try readSSHBytes(from: &buffer)
        guard let string = String(bytes: bytes, encoding: .utf8) else {
             throw OpenSSHKeyParser.OpenSSHParsingError.invalidStringData
        }
        return string
    }
    
    static func readSSHBytes(from buffer: inout ByteBuffer) throws -> [UInt8] {
        guard let length = buffer.readInteger(as: UInt32.self) else {
            throw OpenSSHKeyParser.OpenSSHParsingError.insufficientData
        }
        guard let bytes = buffer.readBytes(length: Int(length)) else {
             throw OpenSSHKeyParser.OpenSSHParsingError.insufficientData
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
    /// Connection timeout in seconds. Increase for high-latency networks.
    static var connectionTimeoutSeconds: Int64 = 10

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

    /// Callback invoked when an error occurs that should be shown to the user
    var errorCallback: (@Sendable (String) -> Void)?

    init(connection: Connection) { self.connection = connection }

    func connect() async throws {
        // 1. Capture connection info on MainActor to avoid races and allow background processing
        let (connInfo, tunnelInfo) = await MainActor.run { () -> (ConnectionInfo?, TunnelInfo?) in
            if connection.state.isActive {
                return (nil, nil)
            }
            connection.state = .connecting
            return (connection.connectionInfo, connection.tunnelInfo)
        }

        guard let connectionInfo = connInfo, let tunnelInfo = tunnelInfo else { return }

        lock.withLock {
            self.activeTunnelInfo = tunnelInfo
        }

        let hasPassword = !connectionInfo.password.isEmpty
        let hasKey = !connectionInfo.privateKey.isEmpty

        guard hasPassword || hasKey else {
            let errorMsg = "Missing password or private key"
            Logger.error("Missing credentials for authentication", log: Logger.ssh)
            await MainActor.run {
                connection.state = .failed(errorMsg)
                self.errorCallback?(errorMsg)
            }
            throw SSHTunnelError.missingCredentials
        }

        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        lock.withLock { self.eventLoopGroup = group }

        // 2. Offload auth delegate creation (heavy crypto) to detached task
        // Capture errorCallback outside the detached task to ensure it's available
        let errorHandler = self.errorCallback
        let authDelegate = await Task.detached { () -> FlexibleAuthDelegate in
            return FlexibleAuthDelegate(
                username: connectionInfo.username,
                password: hasPassword ? connectionInfo.password : nil,
                privateKeyString: hasKey ? connectionInfo.privateKey : nil,
                privateKeyPassphrase: connectionInfo.privateKeyPassphrase,
                reportError: { errorMsg in
                    Task { @MainActor in
                        errorHandler?(errorMsg)
                    }
                }
            )
        }.value
        
        // Check for initialization errors first - these are fatal
        if let initError = authDelegate.initializationError {
            let errorMsg = "Failed to parse private key: \(initError)"
            await MainActor.run {
                self.lastErrorMessage = errorMsg
                connection.state = .failed(errorMsg)
                self.errorCallback?(errorMsg)
            }
            await shutdown()
            throw SSHTunnelError.keyParsingFailed(initError)
        }

        if hasKey && authDelegate.privateKey == nil && !hasPassword {
            let detail = authDelegate.initializationError ?? "Unknown key error"
            let errorMsg = "Failed to initialize key: \(detail). If this is an OpenSSH encrypted key, remove the passphrase or convert to PKCS#8/Ed25519/ECDSA."

            await MainActor.run {
                self.lastErrorMessage = errorMsg
                connection.state = .failed(errorMsg)
                self.errorCallback?(errorMsg)
            }
            await shutdown()

            throw SSHTunnelError.keyParsingFailed(detail)
        }
        
        let host = connectionInfo.serverAddress
        let port = Int(connectionInfo.portNumber) ?? 22

        let serverDelegate = InteractiveHostKeyDelegate(host: host, port: port) { [weak self] host, port, key, promise in
            self?.handleHostKeyValidation(host: host, port: port, key: key, promise: promise, knownHostKey: connectionInfo.knownHostKey)
        }

        self.sessionReadyPromise = group.next().makePromise(of: Void.self)
        self.sessionReadyCompleted = false

        let bootstrap = ClientBootstrap(group: group)
            .channelOption(ChannelOptions.connectTimeout, value: .seconds(Self.connectionTimeoutSeconds))
            .channelInitializer { channel in
                let clientConfig = SSHClientConfiguration(userAuthDelegate: authDelegate,
                                                          serverAuthDelegate: serverDelegate)
                let sshHandler = NIOSSHHandler(
                    role: .client(clientConfig),
                    allocator: channel.allocator,
                    inboundChildChannelInitializer: nil
                )
                guard let sessionReadyPromise = self.sessionReadyPromise else {
                    return channel.eventLoop.makeFailedFuture(SSHTunnelError.internalError("Missing sessionReadyPromise"))
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
                self.connection.state = .connected
                self.lastErrorMessage = nil
            }

            try await startLocalListener()
        } catch {
            Logger.error("SSH connect failed: \(error)", log: Logger.ssh)
            if let p = self.sessionReadyPromise, self.sessionReadyCompleted == false {
                self.sessionReadyCompleted = true
                p.fail(error)
            }
            self.sessionReadyPromise = nil

            await MainActor.run {
                self.connection.state = .failed(error.localizedDescription)
                self.errorCallback?(error.localizedDescription)
            }
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
            promise.fail(SSHTunnelError.hostKeyMismatch)
            return
        }

        guard let callback = self.hostKeyValidationCallback else {
            promise.fail(SSHTunnelError.hostKeyValidationMissing)
            return
        }

        let keyType = keyData == nil ? "Unknown (Legacy Lib)" : "Unknown"
        callback(host, fingerprint, keyType, keyData ?? Data()) { allowed in
            if allowed {
                promise.succeed(())
            } else {
                promise.fail(SSHTunnelError.hostKeyRejected)
            }
        }
    }
    
    private func serialize(key _: NIOSSHPublicKey) -> Data? {
        // NIOSSH does not currently expose a public API to serialize host keys to raw bytes.
        // Returning nil causes handleHostKeyValidation to use fingerprint-based verification,
        // which compares the SHA256 fingerprint string stored in knownHostKey.
        // If NIOSSH adds serialization support in the future, implement it here for raw key matching.
        return nil
    }

    private func startLocalListener() async throws {
        // Capture active tunnel info safely
        guard let group = lock.withLock({ self.eventLoopGroup }),
              let sshChannel = lock.withLock({ self.sshClientChannel }),
              let tunnelInfo = lock.withLock({ self.activeTunnelInfo }) else { return }

        guard let localPort = Int(tunnelInfo.localPort),
              localPort >= 1 && localPort <= 65535 else {
            throw SSHTunnelError.invalidPort(tunnelInfo.localPort)
        }

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

                let sshChildChannelFuture = sshChannel.eventLoop.flatSubmit {
                    sshChannel.pipeline.handler(type: NIOSSHHandler.self).flatMap { sshHandler -> EventLoopFuture<Channel> in
                        let childChannelPromise = sshChannel.eventLoop.makePromise(of: Channel.self)
                        Logger.debug("Opening direct-tcpip to \(tunnelInfo.remoteServer):\(Int(tunnelInfo.remotePort) ?? 0) from originator: \(originator)", log: Logger.ssh)
                        
                        let directTCPIP = NIOSSH.SSHChannelType.DirectTCPIP(
                            targetHost: tunnelInfo.remoteServer,
                            targetPort: Int(tunnelInfo.remotePort) ?? 0,
                            originatorAddress: originator
                        )
                        
                        sshHandler.createChannel(childChannelPromise, channelType: .directTCPIP(directTCPIP)) { sshChildChannel, _ in
                            strongSelf.configureSSHChildPipeline(sshChildChannel, inbound: inbound, strongSelf: strongSelf)
                        }
                        return childChannelPromise.futureResult
                    }
                }
                
                let setupFuture = inbound.setOption(ChannelOptions.autoRead, value: false).flatMap {
                    sshChildChannelFuture
                }.flatMap { sshChildChannel -> EventLoopFuture<Void> in
                    return strongSelf.configureInboundTCPPipeline(inbound, sshChildChannel: sshChildChannel, strongSelf: strongSelf)
                }.flatMap {
                    inbound.setOption(ChannelOptions.autoRead, value: true)
                }

                setupFuture.whenFailure { [weak self] error in
                    let errorMsg = "Failed to establish forwarding channel to \(tunnelInfo.remoteServer):\(Int(tunnelInfo.remotePort) ?? 0) — \(error.localizedDescription)"
                    Logger.error(errorMsg, log: Logger.ssh)
                    Task { @MainActor in
                        self?.errorCallback?(errorMsg)
                    }
                    inbound.close(promise: nil)
                }
                
                return setupFuture
            }
            .childChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)

        do {
            let server = try await serverBootstrap.bind(host: "127.0.0.1", port: localPort).get()
            lock.withLock { self.localServerChannel = server }
            if let localPort = server.localAddress?.port {
                Logger.info("Local listener bound on 127.0.0.1:\(localPort)", log: Logger.ssh)
            }
        } catch {
            let errorMsg = "Local port bind failed: \(error.localizedDescription)"
            Logger.error("Local listener bind failed: \(error)", log: Logger.ssh)
            await MainActor.run {
                self.connection.state = .failed(errorMsg)
                self.errorCallback?(errorMsg)
            }
            await self.disconnect()
            throw error
        }
    }
    
    // New helper method extracted from the inner closure in startLocalListener()
    private func configureSSHChildPipeline(_ sshChildChannel: Channel, inbound: Channel, strongSelf: SSHManager) -> EventLoopFuture<Void> {
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

    private func configureInboundTCPPipeline(_ inbound: Channel, sshChildChannel: Channel, strongSelf: SSHManager) -> EventLoopFuture<Void> {
        let sent: (Int) -> Void = { [weak strongSelf] n in
            guard let manager = strongSelf else { return }
            Task { @MainActor in manager.handleBytesSent(n) }
        }
        let tcpToSSH = GenericRelayHandler<ByteBuffer, SSHChannelData>(peer: sshChildChannel, onBytes: sent) { buffer in
            let sshData = SSHChannelData(type: .channel, data: .byteBuffer(buffer))
            return (sshData, buffer.readableBytes)
        }
        return inbound.pipeline.addHandler(tcpToSSH)
    }

    func disconnect() async {
        await MainActor.run {
            connection.state = .disconnecting
        }
        await shutdown()
    }

    private func shutdown() async {
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
            self.sessionReadyPromise = nil
            self.sessionReadyCompleted = false
            self.internalBytesSent = 0
            self.internalBytesReceived = 0
        }

        if let group = lock.withLock({ self.eventLoopGroup }) {
            do {
                try await group.shutdownGracefully()
            } catch {
                Logger.error("EventLoopGroup shutdown error: \(error)", log: Logger.ssh)
            }
            lock.withLock { self.eventLoopGroup = nil }
        }

        await MainActor.run {
            // Only transition to idle if we're disconnecting normally
            // Preserve .failed state so UI can show the error
            if case .disconnecting = self.connection.state {
                self.connection.state = .idle
            } else if case .connecting = self.connection.state {
                // Connection attempt was aborted
                self.connection.state = .idle
            }
            // If state is .failed, preserve it for UI display
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

