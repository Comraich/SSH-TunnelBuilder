import Foundation
import NIO
import NIOSSH
// Connection.swift must be imported or available in scope for the Connection type.

// MARK: - NIOSSH Handlers

private final class SSHSessionReadyHandler: ChannelInboundHandler, RemovableChannelHandler {
    typealias InboundIn = Any

    private let sessionReadyPromise: EventLoopPromise<Void>
    private var promiseFulfilled = false

    init(sessionReadyPromise: EventLoopPromise<Void>) {
        self.sessionReadyPromise = sessionReadyPromise
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        // NIOSSH sends specific events upon successful negotiation/auth.
        if event is UserAuthSuccessEvent, !promiseFulfilled {
            promiseFulfilled = true
            sessionReadyPromise.succeed(())
        }
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

// Accept-all host key validator (development only)
private struct AcceptAllHostKeysDelegate: NIOSSHClientServerAuthenticationDelegate {
    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        // WARNING: This accepts ANY host key. Implement proper host key validation in production.
        validationCompletePromise.succeed(())
    }
}

// User auth delegate supporting only password authentication.
private final class FlexibleAuthDelegate: NIOSSHClientUserAuthenticationDelegate, Sendable {
    let username: String
    let password: String?
    let reportError: (@Sendable (String) -> Void)? // <-- Changed to @Sendable closure

    // We keep the initializer matching the original signature for consistency, 
    // but private key parameters are ignored.
    init(username: String, password: String?, privateKeyString: String?, privateKeyPassphrase: String?, reportError: (@Sendable (String) -> Void)? = nil) {
        self.reportError = reportError
        self.username = username
        self.password = password?.isEmpty == false ? password : nil
        
        if (privateKeyString?.isEmpty == false) {
             reportError?("Private key provided but only password authentication is enabled in this implementation.")
        }
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
        // Only attempt password authentication
        guard availableMethods.contains(.password), let password = self.password else {
            nextChallengePromise.succeed(nil)
            return
        }

        let offerType: NIOSSHUserAuthenticationOffer.Offer = .password(.init(password: password))
        let offer = makeAuthOffer(with: offerType)
        
        nextChallengePromise.succeed(offer)
    }
}

// MARK: - SSHManager

final class SSHManager: ObservableObject, @unchecked Sendable {
    // Uses the global Connection type defined in Connection.swift
    let connection: Connection 
    private var eventLoopGroup: MultiThreadedEventLoopGroup?
    private var sshClientChannel: Channel?
    private var localServerChannel: Channel?
    private let lock = NSLock()

    private var sessionReadyPromise: EventLoopPromise<Void>?
    private var sessionReadyCompleted: Bool = false

    // Removed duplicated @Published state, relying on Connection object's state
    @Published var lastErrorMessage: String? = nil
    
    // We only need internal counters now, as the connection object handles the @Published state
    private var internalBytesSent: Int64 = 0
    private var internalBytesReceived: Int64 = 0

    init(connection: Connection) { self.connection = connection }

    func connect() async throws {
        // Use connection.isActive which is defined in Connection.swift
        guard !connection.isActive else { return }
        
        let hasPassword = !connection.connectionInfo.password.isEmpty
        let hasKey = !connection.connectionInfo.privateKey.isEmpty
        
        guard hasPassword else {
            print("SSHManager.connect: Missing password for authentication.")
            await MainActor.run {
                connection.isConnecting = false
                connection.isActive = false
            }
            throw NSError(domain: "SSHManager", code: 1, userInfo: [NSLocalizedDescriptionKey: "Missing password"])
        }

        await MainActor.run { connection.isConnecting = true }
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        lock.withLock { self.eventLoopGroup = group }

        let authDelegate = FlexibleAuthDelegate(
            username: connection.connectionInfo.username,
            password: hasPassword ? connection.connectionInfo.password : nil,
            privateKeyString: hasKey ? connection.connectionInfo.privateKey : nil, // Passed for consistent API, but ignored
            privateKeyPassphrase: connection.connectionInfo.privateKeyPassphrase,  // Passed for consistent API, but ignored
            reportError: { [weak self] message in
                Task { @MainActor in
                    self?.lastErrorMessage = message
                }
            }
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
            // 1. Connect the TCP socket.
            let channel = try await bootstrap.connect(host: host, port: port).get()
            
            // 2. Wait for the SSH handshake and password authentication to complete.
            if let sessionReadyPromise = self.sessionReadyPromise {
                try await sessionReadyPromise.futureResult.get()
            }
            
            // 3. Connection is fully up and ready.
            lock.withLock { self.sshClientChannel = channel }
            await MainActor.run {
                self.connection.isActive = true
                self.lastErrorMessage = nil
                self.connection.isConnecting = false
            }
            
            // 4. Start listening locally for tunneling requests.
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
                        // SSH -> TCP (forward data received from remote server to local client)
                        let sshToTCP = GenericRelayHandler<SSHChannelData, ByteBuffer>(peer: inbound, onBytes: received) { sshData in
                            guard case .byteBuffer(let buffer) = sshData.data else { return (nil, 0) }
                            return (buffer, buffer.readableBytes)
                        }
                        return sshChildChannel.pipeline.addHandler(sshToTCP)
                    }
                    return childChannelPromise.futureResult
                }.flatMap { sshChildChannel -> EventLoopFuture<Void> in
                    // 4. The SSH child channel is ready; configure the local client's pipeline to forward to it.
                    let sent: (Int) -> Void = { [weak strongSelf] n in
                        guard let manager = strongSelf else { return }
                        Task { @MainActor in manager.handleBytesSent(n) }
                    }
                    // TCP -> SSH (forward data received from local client to remote server via SSH)
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
            // Reset internal counters
            self.internalBytesSent = 0
            self.internalBytesReceived = 0
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
        
        // Reset state on connection object
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
            // Update the published property on the Connection object
            self.connection.bytesSent += n
        }
    }
    
    private func handleBytesReceived(_ count: Int) {
        let n = Int64(count)
        self.internalBytesReceived += n
        Task { @MainActor in
            // Update the published property on the Connection object
            self.connection.bytesReceived += n
        }
    }
}
