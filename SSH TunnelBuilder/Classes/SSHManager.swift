import Foundation
import NIO
import NIOSSH
import Combine

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
                DispatchQueue.main.async { self.onBytes(count) }
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
            DispatchQueue.main.async { self.onBytes(count) }
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

// Simple error to indicate no more auth methods are available
private enum SSHAuthError: Error { case noMoreMethods }

// Password-first user auth delegate matching the provided protocol
private final class PasswordAuthDelegate: NIOSSHClientUserAuthenticationDelegate {
    let username: String
    let password: String?

    init(username: String, password: String?) {
        self.username = username
        self.password = password
    }

    func nextAuthenticationType(
        availableMethods: NIOSSHAvailableUserAuthenticationMethods,
        nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>
    ) {
        if let password = password, availableMethods.contains(.password) {
            let offer = NIOSSHUserAuthenticationOffer(
                username: username,
                serviceName: "ssh-connection",
                offer: .password(.init(password: password))
            )
            nextChallengePromise.succeed(offer)
        } else {
            nextChallengePromise.fail(SSHAuthError.noMoreMethods)
        }
    }
}

final class SSHManager: ObservableObject {
    let connection: Connection
    private var eventLoopGroup: MultiThreadedEventLoopGroup?
    private var sshClientChannel: Channel?
    private var trafficTimer: AnyCancellable?
    private var localServerChannel: Channel?

    @Published private(set) var isActive: Bool = false
    @Published private(set) var bytesSent: Int64 = 0
    @Published private(set) var bytesReceived: Int64 = 0

    init(connection: Connection) { self.connection = connection }

    func connect() {
        guard !connection.isActive else { return }
        let hasPassword = !connection.connectionInfo.password.isEmpty
        let hasKey = !connection.connectionInfo.privateKey.isEmpty
        guard hasPassword || hasKey else {
            print("SSHManager.connect: Missing credentials (no password or private key)")
            DispatchQueue.main.async {
                self.connection.isConnecting = false
                self.connection.isActive = false
                self.isActive = false
            }
            return
        }

        DispatchQueue.main.async { self.connection.isConnecting = true }
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        self.eventLoopGroup = group

        let username = connection.connectionInfo.username
        let password = hasPassword ? connection.connectionInfo.password : nil

        let authDelegate = PasswordAuthDelegate(username: username, password: password)
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
                return channel.pipeline.addHandlers([sshHandler])
            }

        bootstrap.connect(host: host, port: port).whenComplete { [weak self] (result: Result<Channel, Error>) in
            guard let self = self else { return }
            switch result {
            case .failure(let error):
                print("SSH connect failed: \(error)")
                self.cleanup()
                DispatchQueue.main.async {
                    self.connection.isConnecting = false
                    self.connection.isActive = false
                    self.isActive = false
                }
            case .success(let channel):
                self.sshClientChannel = channel
                DispatchQueue.main.async {
                    self.connection.isActive = true
                    self.isActive = true
                    self.connection.isConnecting = false
                }
                self.startLocalListener()
            }
        }
    }

    private func startLocalListener() {
        guard let group = self.eventLoopGroup, let sshChannel = self.sshClientChannel else { return }

        let localPort = Int(connection.tunnelInfo.localPort) ?? 0
        let remoteHost = connection.tunnelInfo.remoteServer
        let remotePort = Int(connection.tunnelInfo.remotePort) ?? 0

        let serverBootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.backlog, value: 8)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { [weak self] inbound in
                guard let self = self else { return inbound.close() }
                // Obtain the SSH handler from the client channel pipeline
                return sshChannel.pipeline.handler(type: NIOSSHHandler.self).flatMap { ssh in
                    // Build originator address (localhost:localPort)
                    let originator: SocketAddress
                    do {
                        originator = try SocketAddress(ipAddress: "127.0.0.1", port: localPort)
                    } catch {
                        print("Failed to create originator SocketAddress: \(error)")
                        return inbound.close()
                    }

                    // Prepare DirectTCPIP parameters
                    let direct = SSHChannelType.DirectTCPIP(
                        targetHost: remoteHost,
                        targetPort: remotePort,
                        originatorAddress: originator
                    )

                    // Create the SSH child channel and set up relays
                    let childPromise = inbound.eventLoop.makePromise(of: Channel.self)
                    childPromise.futureResult.whenComplete { result in
                        if case .failure(let error) = result {
                            print("Failed to create DirectTCPIP child channel: \(error)")
                            _ = inbound.close(mode: .all)
                        }
                    }

                    ssh.createChannel(childPromise, channelType: .directTCPIP(direct)) { child, _ in
                        let sent: (Int) -> Void = { [weak self] n in
                            guard let self = self else { return }
                            DispatchQueue.main.async { self.connection.bytesSent += Int64(n) }
                        }
                        let received: (Int) -> Void = { [weak self] n in
                            guard let self = self else { return }
                            DispatchQueue.main.async { self.connection.bytesReceived += Int64(n) }
                        }
                        return child.pipeline.addHandlers([
                            SSHToTCPRelay(peer: inbound, onBytes: received)
                        ]).flatMap {
                            inbound.pipeline.addHandlers([
                                TCPToSSHRelay(peer: child, onBytes: sent)
                            ])
                        }
                    }

                    // Complete inbound initializer immediately; relays attach when child becomes active
                    return inbound.eventLoop.makeSucceededFuture(())
                }
            }
            .childChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)

        serverBootstrap.bind(host: "127.0.0.1", port: localPort).whenComplete { [weak self] (result: Result<Channel, Error>) in
            guard let self = self else { return }
            switch result {
            case .failure(let error):
                print("Local listener bind failed: \(error)")
                self.disconnect()
            case .success(let server):
                self.localServerChannel = server
                print("Local listener bound on 127.0.0.1:\(localPort)")
            }
        }
    }

    func disconnect() {
        DispatchQueue.main.async { self.connection.isConnecting = false }
        if let ssh = sshClientChannel { _ = ssh.close(mode: .all); sshClientChannel = nil }
        if let server = localServerChannel { _ = server.close(mode: .all); localServerChannel = nil }
        if let group = eventLoopGroup {
            group.shutdownGracefully(queue: .global()) { error in
                if let error = error { print("EventLoopGroup shutdown error: \(error)") }
            }
            eventLoopGroup = nil
        }
        trafficTimer?.cancel(); trafficTimer = nil
        DispatchQueue.main.async {
            self.connection.isActive = false
            self.isActive = false
        }
    }

    private func cleanup() {
        if let ssh = sshClientChannel { _ = ssh.close(mode: .all); sshClientChannel = nil }
        if let server = localServerChannel { _ = server.close(mode: .all); localServerChannel = nil }
        if let group = eventLoopGroup {
            group.shutdownGracefully(queue: .global()) { error in
                if let error = error { print("EventLoopGroup shutdown error: \(error)") }
            }
            eventLoopGroup = nil
        }
        trafficTimer?.cancel(); trafficTimer = nil
    }
}
