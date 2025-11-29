import Foundation
import NIO
import NIOSSH
import Crypto

// Relay from SSH child channel (SSHChannelData) to a TCP Channel (ByteBuffer)
private final class SSHToTCPRelay: ChannelInboundHandler {
    typealias InboundIn = SSHChannelData

    private let peer: Channel
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

    func channelInactive(context: ChannelHandlerContext) {
        _ = peer.close(mode: .all)
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        _ = peer.close(mode: .all)
        context.close(promise: nil)
    }
}

// Relay from TCP Channel (ByteBuffer) to SSH child channel (SSHChannelData)
private final class TCPToSSHRelay: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer

    private let peer: Channel
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

// User auth delegate supporting private key (preferred) and password authentication.
private final class FlexibleAuthDelegate: NIOSSHClientUserAuthenticationDelegate {
    let username: String
    let password: String?
    let privateKey: NIOSSHPrivateKey?

    init(username: String, password: String?, privateKeyString: String?) {
        self.username = username
        self.password = password
        
        if let keyString = privateKeyString, !keyString.isEmpty {
            // We need to determine the key type from the PEM string.
            // We'll try common types like RSA and P256.
            if let rsaKey = try? RSA.PrivateKey(pemRepresentation: keyString) {
                self.privateKey = NIOSSHPrivateKey(rsaKey)
            } else if let p256Key = try? P256.Signing.PrivateKey(pemRepresentation: keyString) {
                self.privateKey = NIOSSHPrivateKey(p256Key)
            } else {
                print("Failed to parse private key PEM: Unsupported key type or invalid format.")
                self.privateKey = nil
            }
        } else {
            self.privateKey = nil
        }
    }

    func nextAuthenticationType(
        availableMethods: NIOSSHAvailableUserAuthenticationMethods,
        nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>
    ) {
        // Prefer public key auth if available and we have a key
        if let key = self.privateKey, availableMethods.contains(.publicKey) {
            let offer = NIOSSHUserAuthenticationOffer(
                username: username,
                serviceName: "ssh-connection",
                offer: .privateKey(.init(privateKey: key))
            )
            nextChallengePromise.succeed(offer)
            return
        }

        // Fall back to password if available
        if let password = self.password, !password.isEmpty, availableMethods.contains(.password) {
            let offer = NIOSSHUserAuthenticationOffer(
                username: username,
                serviceName: "ssh-connection",
                offer: .password(.init(password: password))
            )
            nextChallengePromise.succeed(offer)
            return
        }
        
        // Signal that we have no more credentials to offer.
        nextChallengePromise.succeed(nil)
    }
}

@MainActor
final class SSHManager: ObservableObject {
    let connection: Connection
    private var eventLoopGroup: MultiThreadedEventLoopGroup?
    private var sshClientChannel: Channel?
    private var localServerChannel: Channel?

    @Published private(set) var isActive: Bool = false
    @Published private(set) var bytesSent: Int64 = 0
    @Published private(set) var bytesReceived: Int64 = 0

    init(connection: Connection) { self.connection = connection }

    func connect() async {
        guard !connection.isActive else { return }
        let hasPassword = !connection.connectionInfo.password.isEmpty
        let hasKey = !connection.connectionInfo.privateKey.isEmpty
        guard hasPassword || hasKey else {
            print("SSHManager.connect: Missing credentials (no password or private key)")
            connection.isConnecting = false
            connection.isActive = false
            isActive = false
            return
        }

        connection.isConnecting = true
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
                let sshHandler = NIOSSHHandler(
                    role: .client(.init(userAuthDelegate: authDelegate, serverAuthDelegate: serverDelegate)),
                    allocator: channel.allocator,
                    inboundChildChannelInitializer: nil
                )
                return channel.pipeline.addHandler(sshHandler)
            }

        do {
            let channel = try await bootstrap.connect(host: host, port: port).get()
            self.sshClientChannel = channel
            self.connection.isActive = true
            self.isActive = true
            self.connection.isConnecting = false
            try await startLocalListener()
        } catch {
            print("SSH connect failed: \(error)")
            await shutdown()
        }
    }

    private func startLocalListener() async throws {
        guard let group = self.eventLoopGroup, let sshChannel = self.sshClientChannel else { return }

        let localPort = Int(connection.tunnelInfo.localPort) ?? 0
        let remoteHost = connection.tunnelInfo.remoteServer
        let remotePort = Int(connection.tunnelInfo.remotePort) ?? 0

        let serverBootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.backlog, value: 8)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { [weak self] inbound in
                guard let self else {
                    return inbound.eventLoop.makeFailedFuture(IOError(errnoCode: ECANCELED, reason: "SSHManager deallocated"))
                }
                return sshChannel.pipeline.handler(type: NIOSSHHandler.self).flatMap { ssh in
                    guard let originator = inbound.remoteAddress else {
                        let error = IOError(errnoCode: EADDRNOTAVAIL, reason: "Inbound channel has no remote address")
                        return inbound.eventLoop.makeFailedFuture(error)
                    }
                    
                    let direct = SSHChannelType.DirectTCPIP(
                        targetHost: remoteHost,
                        targetPort: remotePort,
                        originatorAddress: originator
                    )

                    let childPromise = inbound.eventLoop.makePromise(of: Channel.self)
                    ssh.createChannel(childPromise, channelType: .directTCPIP(direct)) { child, _ in
                        let sent: (Int) -> Void = { [weak self] n in
                            Task { @MainActor in self?.handleBytesSent(n) }
                        }
                        let received: (Int) -> Void = { [weak self] n in
                            Task { @MainActor in self?.handleBytesReceived(n) }
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
            await self.disconnect()
            throw error // rethrow to signal connection failure
        }
    }

    func disconnect() async {
        await shutdown()
    }

    private func shutdown() async {
        connection.isConnecting = false
        
        await withTaskGroup(of: Void.self) { group in
            if let sshClientChannel {
                group.addTask {
                    do {
                        try await sshClientChannel.close(mode: .all).get()
                    } catch {
                        print("Error closing SSH client channel: \(error)")
                    }
                }
            }
            
            if let localServerChannel {
                group.addTask {
                    do {
                        try await localServerChannel.close(mode: .all).get()
                    } catch {
                        print("Error closing local server channel: \(error)")
                    }
                }
            }
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
        self.connection.isActive = false
        self.isActive = false
        self.bytesSent = 0
        self.bytesReceived = 0
        self.connection.bytesSent = 0
        self.connection.bytesReceived = 0
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
