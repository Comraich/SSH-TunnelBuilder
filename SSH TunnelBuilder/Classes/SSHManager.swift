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
private final class FlexibleAuthDelegate: NIOSSHClientUserAuthenticationDelegate, Sendable {
    let username: String
    let password: String?
    let privateKey: NIOSSHPrivateKey?

    init(username: String, password: String?, privateKeyString: String?) {
        self.username = username
        self.password = password?.isEmpty == false ? password : nil

        if let keyString = privateKeyString, !keyString.isEmpty {
            let normalized = keyString
                .replacingOccurrences(of: "\r\n", with: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            
            self.privateKey = FlexibleAuthDelegate.makeNIOSSHPrivateKey(fromPEM: normalized)
            
            if self.privateKey == nil {
                print("FlexibleAuthDelegate: Failed to parse private key. Supported here: ECDSA P-256/P-384/P-521 (PEM/PKCS#8). OpenSSH Ed25519 keys are not parsed; convert to PEM/PKCS#8 or upgrade dependencies.")
            }
        } else {
            self.privateKey = nil
        }
    }

    private static func makeNIOSSHPrivateKey(fromPEM pem: String) -> NIOSSHPrivateKey? {
        let keyParsers: [() -> NIOSSHPrivateKey?] = [
            { try? CryptoKit.P256.Signing.PrivateKey(pemRepresentation: pem).map(NIOSSHPrivateKey.init) },
            { try? CryptoKit.P384.Signing.PrivateKey(pemRepresentation: pem).map(NIOSSHPrivateKey.init) },
            { try? CryptoKit.P521.Signing.PrivateKey(pemRepresentation: pem).map(NIOSSHPrivateKey.init) }
        ]

        for parser in keyParsers {
            if let key = parser() {
                return key
            }
        }
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
                        
                        // Transform SSH data to a raw buffer for the TCP peer
                        let sshToTCP = GenericRelayHandler<SSHChannelData, ByteBuffer>(peer: inbound, onBytes: received) { sshData in
                            guard case .byteBuffer(let buffer) = sshData.data else { return (nil, 0) }
                            return (buffer, buffer.readableBytes)
                        }
                        
                        // Transform a raw buffer from TCP to SSH data for the SSH peer
                        let tcpToSSH = GenericRelayHandler<ByteBuffer, SSHChannelData>(peer: child, onBytes: sent) { buffer in
                            let sshData = SSHChannelData(type: .channel, data: .byteBuffer(buffer))
                            return (sshData, buffer.readableBytes)
                        }

                        return child.pipeline.addHandler(sshToTCP).flatMap {
                            inbound.pipeline.addHandler(tcpToSSH)
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
