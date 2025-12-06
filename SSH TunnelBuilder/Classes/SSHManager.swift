import Foundation
import NIO
import NIOSSH
import CryptoKit

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

// Protocol to handle common channel closing logic for relay handlers
private protocol PeerClosingHandler: ChannelInboundHandler {
    var peer: Channel { get }
}

extension PeerClosingHandler {
    func channelInactive(context: ChannelHandlerContext) {
        _ = peer.close(mode: .all)
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        _ = peer.close(mode: .all)
        context.close(promise: nil)
    }
}

// Relay from SSH child channel (SSHChannelData) to a TCP Channel (ByteBuffer)
private final class SSHToTCPRelay: PeerClosingHandler {
    typealias InboundIn = SSHChannelData

    let peer: Channel
    private let onBytes: (Int) -> Void

    init(peer: Channel, onBytes: @escaping (Int) -> Void) {
        self.peer = peer
        self.onBytes = onBytes
    }
    
    func channelActive(context: ChannelHandlerContext) {
        print("SSHToTCPRelay active: SSH child -> TCP peer")
        context.fireChannelActive()
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let sshData = self.unwrapInboundIn(data)
        switch sshData.data {
        case .byteBuffer(let buffer):
            let count = buffer.readableBytes
            if count > 0 {
                self.onBytes(count)
                _ = peer.writeAndFlush(buffer)
            }
        case .fileRegion(_):
            // Not expected for our forwarding path; ignore or handle as needed.
            break
        }
    }
}

// Relay from TCP Channel (ByteBuffer) to SSH child channel (SSHChannelData)
private final class TCPToSSHRelay: PeerClosingHandler {
    typealias InboundIn = ByteBuffer

    let peer: Channel
    private let onBytes: (Int) -> Void

    init(peer: Channel, onBytes: @escaping (Int) -> Void) {
        self.peer = peer
        self.onBytes = onBytes
    }
    
    func channelActive(context: ChannelHandlerContext) {
        print("TCPToSSHRelay active: TCP inbound -> SSH child")
        context.fireChannelActive()
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let buffer = self.unwrapInboundIn(data)
        let count = buffer.readableBytes
        if count > 0 {
            self.onBytes(count)
            let sshData = SSHChannelData(type: .channel, data: .byteBuffer(buffer))
            _ = peer.writeAndFlush(sshData)
        }
    }
}

// Accept-all host key validator (development only) matching provided protocol
private struct AcceptAllHostKeysDelegate: NIOSSHClientServerAuthenticationDelegate {
    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        validationCompletePromise.succeed(())
    }
}

// User auth delegate supporting private key (preferred) and password fallback.
private final class FlexibleAuthDelegate: NIOSSHClientUserAuthenticationDelegate, Sendable {
    let username: String
    let password: String?
    let privateKey: NIOSSHPrivateKey?

    init(username: String, password: String?, privateKeyString: String?) {
        self.username = username
        self.password = password?.isEmpty == false ? password : nil

        if let keyString = privateKeyString, !keyString.isEmpty {
            // Normalize and trim
            let normalized = keyString
                .replacingOccurrences(of: "\r\n", with: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)

            // Try to parse PEM/PKCS#8 using CryptoKit (ECDSA P-256/P-384/P-521)
            if let key = FlexibleAuthDelegate.makeNIOSSHPrivateKey(fromPEM: normalized) {
                self.privateKey = key
            } else {
                self.privateKey = nil
                print("FlexibleAuthDelegate: Failed to parse private key. Supported here: ECDSA P-256/P-384/P-521 (PEM/PKCS#8). OpenSSH Ed25519 keys are not parsed; convert to PEM/PKCS#8 or upgrade dependencies.")
            }
        } else {
            self.privateKey = nil
        }
    }

    private static func makeNIOSSHPrivateKey(fromPEM pem: String) -> NIOSSHPrivateKey? {
        // Try ECDSA P-256 / P-384 / P-521 (PKCS#8 or SEC1 EC)
        if let p256 = try? CryptoKit.P256.Signing.PrivateKey(pemRepresentation: pem) {
            return NIOSSHPrivateKey(p256Key: p256)
        }
        if let p384 = try? CryptoKit.P384.Signing.PrivateKey(pemRepresentation: pem) {
            return NIOSSHPrivateKey(p384Key: p384)
        }
        if let p521 = try? CryptoKit.P521.Signing.PrivateKey(pemRepresentation: pem) {
            return NIOSSHPrivateKey(p521Key: p521)
        }
        // Ed25519 OpenSSH keys are not parsed via PEM here; conversion required.
        return nil
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
        // Prefer public key when we have one and server allows it
        if let key = self.privateKey, availableMethods.contains(.publicKey) {
            let offer = makeAuthOffer(with: .privateKey(.init(privateKey: key)))
            nextChallengePromise.succeed(offer)
            return
        }

        // Fall back to password if available and allowed
        if let password = self.password, availableMethods.contains(.password) {
            let offer = makeAuthOffer(with: .password(.init(password: password)))
            nextChallengePromise.succeed(offer)
            return
        }

        // No more credentials to offer
        nextChallengePromise.succeed(nil)
    }
}

final class SSHManager: ObservableObject {
    let connection: Connection
    private var eventLoopGroup: MultiThreadedEventLoopGroup?
    private var sshClientChannel: Channel?
    private var localServerChannel: Channel?

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
        self.eventLoopGroup = group

        let authDelegate = FlexibleAuthDelegate(
            username: connection.connectionInfo.username,
            password: hasPassword ? connection.connectionInfo.password : nil,
            privateKeyString: hasKey ? connection.connectionInfo.privateKey : nil
        )
        let serverDelegate = AcceptAllHostKeysDelegate()

        let host = connection.connectionInfo.serverAddress
        let port = Int(connection.connectionInfo.portNumber) ?? 22

        let bootstrap = ClientBootstrap(group: group)
            .channelInitializer { channel in
                let clientConfig = SSHClientConfiguration(userAuthDelegate: authDelegate,
                                                          serverAuthDelegate: serverDelegate)
                let sshHandler = NIOSSHHandler(
                    role: .client(clientConfig),
                    allocator: channel.allocator,
                    inboundChildChannelInitializer: nil
                )
                return channel.pipeline.addHandler(sshHandler)
            }

        do {
            let channel = try await bootstrap.connect(host: host, port: port).get()
            self.sshClientChannel = channel
            await MainActor.run {
                self.connection.isActive = true
                self.isActive = true
                self.connection.isConnecting = false
            }
            try await startLocalListener()
        } catch {
            print("SSH connect failed: \(error)")
            await MainActor.run { self.connection.isConnecting = false }
            await shutdown()
            throw error // Re-throw the error for the caller to handle
        }
    }

    private func startLocalListener() async throws {
        guard let group = self.eventLoopGroup, let sshChannel = self.sshClientChannel else { return }

        let localPort = Int(connection.tunnelInfo.localPort) ?? 0

        let serverBootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.backlog, value: 8)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { [weak self] inbound in
                guard let strongSelf = self, let sshChannel = strongSelf.sshClientChannel else {
                    return inbound.eventLoop.makeFailedFuture(IOError(errnoCode: ECANCELED, function: "SSHManager deallocated"))
                }
                let targetHost = strongSelf.connection.tunnelInfo.remoteServer
                let targetPort = Int(strongSelf.connection.tunnelInfo.remotePort) ?? 0

                guard let originator = inbound.remoteAddress else {
                    let error = IOError(errnoCode: EADDRNOTAVAIL, function: "Inbound channel has no remote address")
                    return inbound.eventLoop.makeFailedFuture(error)
                }
                
                let childPromise = inbound.eventLoop.makePromise(of: Channel.self)
                return sshChannel.pipeline.handler(type: NIOSSHHandler.self).flatMap { ssh in
                    let direct = SSHChannelType.DirectTCPIP(
                        targetHost: targetHost,
                        targetPort: targetPort,
                        originatorAddress: originator
                    )

                    ssh.createChannel(childPromise, channelType: .directTCPIP(direct)) { child, _ in
                        let sent: (Int) -> Void = { [weak strongSelf] n in
                            guard let manager = strongSelf else { return }
                            Task { @MainActor in manager.handleBytesSent(n) }
                        }
                        let received: (Int) -> Void = { [weak strongSelf] n in
                            guard let manager = strongSelf else { return }
                            Task { @MainActor in manager.handleBytesReceived(n) }
                        }
                        return child.pipeline.addHandlers([
                            SSHToTCPRelay(peer: inbound, onBytes: received)
                        ]).flatMap {
                            inbound.pipeline.addHandlers([
                                TCPToSSHRelay(peer: child, onBytes: sent)
                            ])
                        }
                    }
                    
                    childPromise.futureResult.whenFailure { error in
                        print("Failed to create DirectTCPIP child channel: \(error)")
                        _ = inbound.close(mode: .all)
                    }

                    return inbound.eventLoop.makeSucceededFuture(())
                }
            }
            .childChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)

        do {
            let server = try await serverBootstrap.bind(host: "127.0.0.1", port: localPort).get()
            self.localServerChannel = server
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
            mutableGroup.closeChannel(sshClientChannel, name: "SSH client")
            mutableGroup.closeChannel(localServerChannel, name: "local server")
        }
        
        sshClientChannel = nil
        localServerChannel = nil

        // Shutdown event loop group
        if let group = eventLoopGroup {
            do {
                try await group.shutdownGracefully()
            } catch {
                print("EventLoopGroup shutdown error: \(error)")
            }
            self.eventLoopGroup = nil
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
