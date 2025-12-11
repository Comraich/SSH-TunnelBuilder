import Foundation
import NIO
import NIOSSH
import CryptoKit
import Security

private final class SSHSessionReadyHandler: ChannelInboundHandler, RemovableChannelHandler {
    typealias InboundIn = Any

    private let sessionReadyPromise: EventLoopPromise<Void>
    private var promiseFulfilled = false

    init(sessionReadyPromise: EventLoopPromise<Void>) {
        self.sessionReadyPromise = sessionReadyPromise
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        context.fireUserInboundEventTriggered(event)
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        // If an error occurs during handshake (e.g., auth failure), fail the promise.
        if !promiseFulfilled {
            promiseFulfilled = true
            sessionReadyPromise.fail(error)
        }
        context.fireErrorCaught(error)
    }
    
    func channelInactive(context: ChannelHandlerContext) {
        // If the channel closes before authentication succeeds, fail the promise.
        if !promiseFulfilled {
            promiseFulfilled = true
            sessionReadyPromise.fail(ChannelError.ioOnClosedChannel)
        }
        context.fireChannelInactive()
    }
}

private extension TaskGroup where ChildTaskResult == Void {
    // Helper to add a channel-closing task, reducing duplication in shutdown().
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

// A single, generic relay handler to replace the two specific ones.
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
        _ = peer.close(mode: .all)
        context.close(promise: nil)
    }
}

// Accept-all host key validator (development only) matching provided protocol
private struct AcceptAllHostKeysDelegate: NIOSSHClientServerAuthenticationDelegate {
    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        validationCompletePromise.succeed(())
    }
}

// User auth delegate supporting private key (preferred) and password fallback.
final class FlexibleAuthDelegate: NIOSSHClientUserAuthenticationDelegate, Sendable {
    let username: String
    let password: String?
    let privateKey: NIOSSHPrivateKey?
    let privateKeyPassphrase: String?

    init(username: String, password: String?, privateKeyString: String?, privateKeyPassphrase: String?) {
        self.username = username
        self.password = password?.isEmpty == false ? password : nil

        if let keyString = privateKeyString, !keyString.isEmpty {
            let normalized = keyString
                .replacingOccurrences(of: "\r\n", with: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            
            self.privateKeyPassphrase = (privateKeyPassphrase?.isEmpty == false) ? privateKeyPassphrase : nil
            self.privateKey = FlexibleAuthDelegate.makeNIOSSHPrivateKey(fromPEM: normalized, passphrase: self.privateKeyPassphrase)
            
            if self.privateKey == nil {
                print("FlexibleAuthDelegate: Private key parsing disabled for current NIOSSH version or unsupported key format. Falling back to password if available.")
            }
        } else {
            self.privateKeyPassphrase = nil
            self.privateKey = nil
        }
    }

    private static func extractPEMBody(begin: String, end: String, from text: String) -> Data? {
        guard let beginRange = text.range(of: begin), let endRange = text.range(of: end, range: beginRange.upperBound..<text.endIndex) else { return nil }
        let bodyRange = beginRange.upperBound..<endRange.lowerBound
        let body = text[bodyRange]
            .replacingOccurrences(of: "\n", with: "")
            .replacingOccurrences(of: "\r", with: "")
            .replacingOccurrences(of: "\t", with: "")
            .replacingOccurrences(of: " ", with: "")
        return Data(base64Encoded: body)
    }

    private enum KeyKind { case ecdsaP256, ecdsaP384, ecdsaP521, rsa, unknown }

    // Minimal OID detection inside PKCS#8 DER to decide curve / RSA
    private static func detectKeyKind(in der: Data) -> KeyKind {
        // Very small heuristic: search for curve OIDs or RSA OID bytes
        // P-256: 1.2.840.10045.3.1.7 -> 06 08 2A 86 48 CE 3D 03 01 07
        // P-384: 1.3.132.0.34       -> 06 05 2B 81 04 00 22
        // P-521: 1.3.132.0.35       -> 06 05 2B 81 04 00 23
        // RSA:   1.2.840.113549.1.1.1 -> 06 09 2A 86 48 86 F7 0D 01 01 01
        let p256: [UInt8] = [0x06,0x08,0x2A,0x86,0x48,0xCE,0x3D,0x03,0x01,0x07]
        let p384: [UInt8] = [0x06,0x05,0x2B,0x81,0x04,0x00,0x22]
        let p521: [UInt8] = [0x06,0x05,0x2B,0x81,0x04,0x00,0x23]
        let rsa:  [UInt8] = [0x06,0x09,0x2A,0x86,0x48,0x86,0xF7,0x0D,0x01,0x01,0x01]
        let bytes = [UInt8](der)
        func contains(_ sig: [UInt8]) -> Bool {
            guard sig.count <= bytes.count else { return false }
            let limit = bytes.count - sig.count
            var i = 0
            while i <= limit {
                var j = 0
                while j < sig.count, bytes[i + j] == sig[j] { j += 1 }
                if j == sig.count { return true }
                i += 1
            }
            return false
        }
        if contains(p256) { return .ecdsaP256 }
        if contains(p384) { return .ecdsaP384 }
        if contains(p521) { return .ecdsaP521 }
        if contains(rsa) { return .rsa }
        return .unknown
    }

    // Build SecKey from RSA PKCS#1 or PKCS#8 private key
    private static func makeSecKeyRSA(from der: Data, isPKCS1: Bool) -> SecKey? {
        let attrs: CFDictionary = [
            kSecAttrKeyType: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass: kSecAttrKeyClassPrivate,
        ] as CFDictionary
        // If PKCS#1, wrap into a PKCS#8 structure header for SecKey to accept, else try as-is
        var keyData = der
        if isPKCS1 {
            // Minimal PKCS#8 wrapper for RSA private key: PrivateKeyInfo { version, alg { rsaOID, NULL }, octetString(pkcs1) }
            // Prebuilt header for RSA OID and NULL params; encode lengths dynamically
            let rsaOID: [UInt8] = [0x30,0x0D,0x06,0x09,0x2A,0x86,0x48,0x86,0xF7,0x0D,0x01,0x01,0x01,0x05,0x00]
            let pkcs1Octet = [UInt8]([0x04]) + lengthBytes(for: keyData.count) + [UInt8](keyData)
            let alg = rsaOID
            let version: [UInt8] = [0x02,0x01,0x00]
            let inner = version + alg + pkcs1Octet
            let pkcs8 = [UInt8]([0x30]) + lengthBytes(for: inner.count) + inner
            keyData = Data(pkcs8)
        }
        return SecKeyCreateWithData(keyData as CFData, attrs, nil)
    }

    private static func lengthBytes(for length: Int) -> [UInt8] {
        if length < 0x80 { return [UInt8(length)] }
        var len = length
        var bytes: [UInt8] = []
        while len > 0 { bytes.insert(UInt8(len & 0xFF), at: 0); len >>= 8 }
        return [0x80 | UInt8(bytes.count)] + bytes
    }

    private static func makeNIOSSHPrivateKey(fromPEM pem: String, passphrase: String?) -> NIOSSHPrivateKey? {
        // Normalize PEM
        let pem = pem.replacingOccurrences(of: "\r\n", with: "\n").trimmingCharacters(in: .whitespacesAndNewlines)

        func decodeBase64Body(begin: String, end: String, from text: String) -> Data? {
            guard let b = text.range(of: begin), let e = text.range(of: end, range: b.upperBound..<text.endIndex) else { return nil }
            let body = text[b.upperBound..<e.lowerBound]
                .components(separatedBy: .newlines)
                .joined()
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return Data(base64Encoded: body)
        }

        // 0) OpenSSH Ed25519 private key (unencypted)
        if pem.contains("-----BEGIN OPENSSH PRIVATE KEY-----") {
            // Decode OpenSSH PEM body
            if let blob = decodeBase64Body(begin: "-----BEGIN OPENSSH PRIVATE KEY-----", end: "-----END OPENSSH PRIVATE KEY-----", from: pem) {
                print("NIOSSH: Detected OpenSSH Ed25519 private key; attempting to construct NIOSSHPrivateKey.")
                // Requires fork exposing: NIOSSHPrivateKey(init openSSHEd25519PrivateKeyBlob: [UInt8])
                if let key = try? NIOSSHPrivateKey(openSSHEd25519PrivateKeyBlob: Array(blob)) {
                    return key
                } else {
                    print("NIOSSH: Failed to build Ed25519 key from OpenSSH private key blob. Ensure fork exposes init(openSSHEd25519PrivateKeyBlob:).")
                    return nil
                }
            } else {
                print("NIOSSH: Failed to decode OpenSSH private key PEM body")
                return nil
            }
        }

        // Helper to try building SecKey from PKCS#8 DER for EC or RSA
        func secKeyFromPKCS8DER(_ der: Data) -> SecKey? {
            // Try EC first
            var attrs: CFDictionary = [
                kSecAttrKeyType: kSecAttrKeyTypeECSECPrimeRandom,
                kSecAttrKeyClass: kSecAttrKeyClassPrivate,
            ] as CFDictionary
            if let key = SecKeyCreateWithData(der as CFData, attrs, nil) { return key }
            // Then RSA
            attrs = [
                kSecAttrKeyType: kSecAttrKeyTypeRSA,
                kSecAttrKeyClass: kSecAttrKeyClassPrivate,
            ] as CFDictionary
            if let key = SecKeyCreateWithData(der as CFData, attrs, nil) { return key }
            return nil
        }

        // 1) Encrypted PKCS#8
        if pem.contains("-----BEGIN ENCRYPTED PRIVATE KEY-----") {
            guard let pass = passphrase, !pass.isEmpty else {
                print("NIOSSH: Encrypted PKCS#8 key detected but no passphrase provided.")
                return nil
            }
            do {
                let der = try PEMDecryptor.decryptEncryptedPKCS8PEM(pem, passphrase: pass)
                if secKeyFromPKCS8DER(der) != nil {
                    // Temporarily disabled until fork exposes init(secKey:)
                    print("NIOSSH: init(secKey:) not available in current NIOSSH build; falling back to password.")
                    return nil
                }
                print("NIOSSH: SecKeyCreateWithData failed for decrypted PKCS#8.")
                return nil
            } catch {
                print("NIOSSH: Failed to decrypt PKCS#8: \(error)")
                return nil
            }
        }

        // 2) Unencrypted PKCS#8 PRIVATE KEY
        if pem.contains("-----BEGIN PRIVATE KEY-----") {
            guard let der = decodeBase64Body(begin: "-----BEGIN PRIVATE KEY-----", end: "-----END PRIVATE KEY-----", from: pem) else {
                print("NIOSSH: Failed to decode PKCS#8 PRIVATE KEY PEM body")
                return nil
            }
            if secKeyFromPKCS8DER(der) != nil {
                // Temporarily disabled until fork exposes init(secKey:)
                print("NIOSSH: init(secKey:) not available in current NIOSSH build; falling back to password.")
                return nil
            }
            print("NIOSSH: SecKeyCreateWithData failed for PKCS#8 PRIVATE KEY.")
            return nil
        }

        // 3) Legacy/unsupported PEM blocks: advise conversion
        if pem.contains("-----BEGIN EC PRIVATE KEY-----") {
            print("NIOSSH: EC PRIVATE KEY (traditional) not supported directly; please convert to PKCS#8 (openssl pkcs8 -topk8 -nocrypt -in ec.key -out ec_pkcs8.pem)")
            return nil
        }
        if pem.contains("-----BEGIN RSA PRIVATE KEY-----") {
            print("NIOSSH: RSA PKCS#1 not supported directly; convert to PKCS#8 with `openssl pkcs8 -topk8 -in id_rsa -out id_rsa_pkcs8.pem`.")
            return nil
        }

        print("NIOSSH: Unsupported or encrypted private key format. Supported: PKCS#8 PRIVATE KEY and ENCRYPTED PRIVATE KEY")
        return nil
    }
    
    private func makeAuthOffer(with offerType: NIOSSHUserAuthenticationOffer.Offer) -> NIOSSHUserAuthenticationOffer {
        return NIOSSHUserAuthenticationOffer(
            username: username,
            serviceName: "ssh-connection",
            offer: offerType
        )
    }
    
    private struct AuthStrategy {
        let method: NIOSSHAvailableUserAuthenticationMethods
        let offer: () -> NIOSSHUserAuthenticationOffer.Offer?
    }

    func nextAuthenticationType(
        availableMethods: NIOSSHAvailableUserAuthenticationMethods,
        nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>
    ) {
        let strategies: [AuthStrategy] = [
            AuthStrategy(method: .publicKey) {
                self.privateKey.map { .privateKey(.init(privateKey: $0)) }
            },
            AuthStrategy(method: .password) {
                self.password.map { .password(.init(password: $0)) }
            }
        ]

        for strategy in strategies {
            if availableMethods.contains(strategy.method), let offerType = strategy.offer() {
                let offer = makeAuthOffer(with: offerType)
                nextChallengePromise.succeed(offer)
                return
            }
        }
        
        nextChallengePromise.succeed(nil)
    }
}

final class SSHManager: ObservableObject, @unchecked Sendable {
    let connection: Connection
    private var eventLoopGroup: MultiThreadedEventLoopGroup?
    private var sshClientChannel: Channel?
    private var localServerChannel: Channel?
    private let lock = NSLock()

    private var sessionReadyPromise: EventLoopPromise<Void>?
    private var sessionReadyCompleted: Bool = false

    @Published private(set) var isActive: Bool = false
    @Published private(set) var bytesSent: Int64 = 0
    @Published private(set) var bytesReceived: Int64 = 0

    init(connection: Connection) { self.connection = connection }

    func connect() async throws {
        guard !connection.isActive else { return }
        let hasPassword = !connection.connectionInfo.password.isEmpty
        let hasKey = !connection.connectionInfo.privateKey.isEmpty
        guard hasPassword || hasKey else {
            print("SSHManager.connect: Missing credentials (provide a password or a private key)")
            await MainActor.run {
                connection.isConnecting = false
                connection.isActive = false
                isActive = false
            }
            return
        }

        await MainActor.run { connection.isConnecting = true }
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        lock.withLock { self.eventLoopGroup = group }

        let authDelegate = FlexibleAuthDelegate(
            username: connection.connectionInfo.username,
            password: hasPassword ? connection.connectionInfo.password : nil,
            privateKeyString: hasKey ? connection.connectionInfo.privateKey : nil,
            privateKeyPassphrase: connection.connectionInfo.privateKeyPassphrase
        )
        let serverDelegate = AcceptAllHostKeysDelegate()

        let host = connection.connectionInfo.serverAddress
        let port = Int(connection.connectionInfo.portNumber) ?? 22

        // Create a promise that will be fulfilled when SSH auth completes.
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
            // This connects the TCP socket.
            let channel = try await bootstrap.connect(host: host, port: port).get()
            
            // This waits for the SSH handshake and authentication to complete.
            if let sessionReadyPromise = self.sessionReadyPromise {
                try await sessionReadyPromise.futureResult.get()
            }
            
            // NOW the connection is fully up and ready.
            lock.withLock { self.sshClientChannel = channel }
            await MainActor.run {
                self.connection.isActive = true
                self.isActive = true
                self.connection.isConnecting = false
            }
            try await startLocalListener()
        } catch {
            print("SSH connect failed: \(error)")
            // Ensure any pending sessionReadyPromise is failed to avoid leaking promises.
            if let p = self.sessionReadyPromise, self.sessionReadyCompleted == false {
                self.sessionReadyCompleted = true
                p.fail(error)
            }
            self.sessionReadyPromise = nil

            await MainActor.run { self.connection.isConnecting = false }
            await shutdown()
            throw error // Re-throw the error for the caller to handle
        }
    }

    private func startLocalListener() async throws {
        let group = lock.withLock { self.eventLoopGroup }
        guard let group, let sshChannel = lock.withLock({ self.sshClientChannel }) else { return }

        let localPort = Int(connection.tunnelInfo.localPort) ?? 0

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

                // 1. Pause reading from the client channel.
                let setupFuture = inbound.setOption(ChannelOptions.autoRead, value: false).flatMap {
                    // 2. Get the main NIOSSH handler.
                    sshChannel.pipeline.handler(type: NIOSSHHandler.self)
                }.flatMap { (ssh: NIOSSHHandler) -> EventLoopFuture<Channel> in
                    // 3. Create the forwarding channel using an explicit promise for clarity.
                    let childChannelPromise = sshChannel.eventLoop.makePromise(of: Channel.self)
                    print("Opening direct-tcpip to \(strongSelf.connection.tunnelInfo.remoteServer):\(Int(strongSelf.connection.tunnelInfo.remotePort) ?? 0) from originator: \(originator)")
                    let directTCPIP = NIOSSH.SSHChannelType.DirectTCPIP(
                        targetHost: strongSelf.connection.tunnelInfo.remoteServer,
                        targetPort: Int(strongSelf.connection.tunnelInfo.remotePort) ?? 0,
                        originatorAddress: originator
                    )
                    ssh.createChannel(childChannelPromise, channelType: .directTCPIP(directTCPIP)) { sshChildChannel, _ in
                        let received: (Int) -> Void = { [weak strongSelf] n in
                            guard let manager = strongSelf else { return }
                            Task { @MainActor in manager.handleBytesReceived(n) }
                        }
                        let sshToTCP = GenericRelayHandler<SSHChannelData, ByteBuffer>(peer: inbound, onBytes: received) { sshData in
                            guard case .byteBuffer(let buffer) = sshData.data else { return (nil, 0) }
                            return (buffer, buffer.readableBytes)
                        }
                        let f = sshChildChannel.pipeline.addHandler(sshToTCP)
                        f.whenSuccess { _ in
                            if let promise = self?.sessionReadyPromise, self?.sessionReadyCompleted == false {
                                self?.sessionReadyCompleted = true
                                promise.succeed(())
                            }
                        }
                        return f
                    }
                    return childChannelPromise.futureResult
                }.flatMap { sshChildChannel -> EventLoopFuture<Void> in
                    // 4. The SSH child channel is ready; configure the local client's pipeline to forward to it.
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
                    // 5. With both pipelines configured, resume reading from the local client.
                    inbound.setOption(ChannelOptions.autoRead, value: true)
                }

                setupFuture.whenFailure { error in
                    print("Failed to establish forwarding channel to \(strongSelf.connection.tunnelInfo.remoteServer):\(Int(strongSelf.connection.tunnelInfo.remotePort) ?? 0) — error: \(error)")
                    // Correctly close the channel, satisfying the compiler.
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
            throw error // rethrow to signal connection failure
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

            // Fail any pending sessionReadyPromise to avoid leaks during shutdown.
            if let p = self.sessionReadyPromise, self.sessionReadyCompleted == false {
                self.sessionReadyCompleted = true
                p.fail(ChannelError.ioOnClosedChannel)
            }
        }
        
        self.sessionReadyPromise = nil
        self.sessionReadyCompleted = false

        // Shutdown event loop group
        if let group = lock.withLock({ self.eventLoopGroup }) {
            do {
                try await group.shutdownGracefully()
            } catch {
                print("EventLoopGroup shutdown error: \(error)")
            }
            lock.withLock { self.eventLoopGroup = nil }
        }
        
        // Reset state
        await MainActor.run {
            self.connection.isActive = false
            self.isActive = false
            self.bytesSent = 0
            self.bytesReceived = 0
            self.connection.bytesSent = 0
            self.connection.bytesReceived = 0
        }
    }
    
    // MARK: - Main Actor State Updates
    
    private func handleBytesSent(_ count: Int) {
        let n = Int64(count)
        self.bytesSent += n
        self.connection.bytesSent += n
    }
    
    private func handleBytesReceived(_ count: Int) {
        let n = Int64(count)
        self.bytesReceived += n
        self.connection.bytesReceived += n
    }
}

