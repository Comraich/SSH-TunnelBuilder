import Foundation
import NIO
import NIOFoundationCompat
@preconcurrency import NIOSSH
import CryptoKit

// SSH connection lifecycle: authenticate, bring up the session, and run a local
// listener that forwards each accepted TCP connection over a direct-tcpip SSH
// channel. The NIO handlers it installs live in `SSHChannelHandlers.swift`, and
// private-key parsing lives in `SSHKeyParsing.swift`.

final class SSHManager: @unchecked Sendable {
    /// TCP connect timeout in seconds. Increase for high-latency networks.
    /// `nonisolated(unsafe)` because this is a simple configuration knob set
    /// at most once before connecting; it is not mutated concurrently.
    nonisolated(unsafe) static var connectionTimeoutSeconds: Int64 = 10

    /// Deadline (seconds) for the SSH handshake + authentication phase, measured
    /// from the start of the connection but *paused* while the user is deciding at
    /// the host-key trust prompt. `connectionTimeoutSeconds` only bounds the TCP
    /// connect; without this, a server that accepts the socket but never completes
    /// auth (wrong credentials that hang, a stalled handshake) would leave the
    /// connection stuck in `.connecting` forever.
    /// `nonisolated(unsafe)` for the same reason as `connectionTimeoutSeconds`.
    nonisolated(unsafe) static var handshakeTimeoutSeconds: Int64 = 15

    let connection: Connection
    private var eventLoopGroup: MultiThreadedEventLoopGroup?
    private var sshClientChannel: Channel?
    private var localServerChannel: Channel?
    private let lock = NSLock()

    // Store active config safely for background threads
    private var activeTunnelInfo: TunnelInfo?

    private var sessionReadyPromise: EventLoopPromise<Void>?
    private var sessionReadyCompleted = false

    /// Scheduled task that fails `sessionReadyPromise` if the handshake/auth phase
    /// runs past `handshakeTimeoutSeconds`. Guarded by `lock`.
    private var handshakeTimeoutTask: Scheduled<Void>?

    // Async handler: (hostname, fingerprint, keyType, keyData, isMismatch) -> user's trust decision.
    // `isMismatch` is true when a previously pinned key exists but no longer matches — the UI should
    // present a stronger warning so the user can replace the pinned key knowingly.
    var hostKeyValidationHandler: (@Sendable (String, String, String, Data, Bool) async -> Bool)?

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

        // Use NIO's process-wide singleton event loop group. It is shared across
        // all connections and must never be shut down (see shutdown()).
        let group = MultiThreadedEventLoopGroup.singleton
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

        // Bound the handshake + auth phase (see handshakeTimeoutSeconds). Armed
        // before connecting so it is always in place before NIOSSH starts the
        // handshake; the host-key prompt pauses it (see handleHostKeyValidation).
        armHandshakeTimeout()

        let bootstrap = ClientBootstrap(group: group)
            .channelOption(ChannelOptions.connectTimeout, value: .seconds(Self.connectionTimeoutSeconds))
            .channelInitializer { channel in
                // The initializer runs on the channel's event loop, so add the
                // handlers synchronously. This keeps the (non-Sendable) NIO
                // handlers out of an escaping @Sendable closure, which the
                // previous `addHandler(...).flatMap { addHandler(...) }` chain
                // required under Swift 6.
                channel.eventLoop.makeCompletedFuture {
                    let clientConfig = SSHClientConfiguration(userAuthDelegate: authDelegate,
                                                              serverAuthDelegate: serverDelegate)
                    let sshHandler = NIOSSHHandler(
                        role: .client(clientConfig),
                        allocator: channel.allocator,
                        inboundChildChannelInitializer: nil
                    )
                    guard let sessionReadyPromise = self.sessionReadyPromise else {
                        throw SSHTunnelError.internalError("Missing sessionReadyPromise")
                    }
                    let sessionReadyHandler = SSHSessionReadyHandler(sessionReadyPromise: sessionReadyPromise)
                    try channel.pipeline.syncOperations.addHandlers([sshHandler, sessionReadyHandler])
                }
            }

        do {
            let channel = try await bootstrap.connect(host: host, port: port).get()

            if let sessionReadyPromise = self.sessionReadyPromise {
                try await sessionReadyPromise.futureResult.get()
                self.sessionReadyCompleted = true
            }
            cancelHandshakeTimeout()

            lock.withLock { self.sshClientChannel = channel }
            await MainActor.run {
                self.connection.state = .connected
            }

            try await startLocalListener()
        } catch {
            Logger.error("SSH connect failed: \(error)", log: Logger.ssh)
            cancelHandshakeTimeout()
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

    // MARK: - Host Key Validation

    private func handleHostKeyValidation(host: String, port _: Int, key: NIOSSHPublicKey, promise: EventLoopPromise<Void>, knownHostKey: String) {
        let keyData = serialize(key: key)
        let fingerprint: String
        if let keyData = keyData {
            // OpenSSH-style fingerprint: SHA256 of the wire-format key blob,
            // base64 without padding (matches `ssh-keygen -l` output).
            let digest = SHA256.hash(data: keyData)
            let base64 = Data(digest).base64EncodedString().replacingOccurrences(of: "=", with: "")
            fingerprint = "SHA256:" + base64
        } else {
            // Fallback: we cannot serialize the key with this NIOSSH version; present a legacy marker.
            fingerprint = "SHA256:UNAVAILABLE"
        }

        var isMismatch = false
        if !knownHostKey.isEmpty {
            // Only consider a stored pin authoritative when we actually have wire
            // bytes for the presented key. If `serialize(key:)` returned nil, the
            // fingerprint is the non-host-specific "SHA256:UNAVAILABLE" sentinel;
            // matching against it would silently trust any host that triggers the
            // nil-serialize path, so we force the user to re-confirm instead.
            if let keyData = keyData {
                if let knownData = Data(base64Encoded: knownHostKey), knownData == keyData {
                    promise.succeed(())
                    return
                }
                if knownHostKey == fingerprint {
                    promise.succeed(())
                    return
                }
            }
            // A previously pinned key is on file but doesn't match what the server
            // just presented (or we can't verify it). Don't auto-fail — surface the
            // change to the user so they can re-trust the new key (e.g. after a
            // legitimate server rekey) or reject it (possible MITM).
            isMismatch = true
        }

        guard let handler = self.hostKeyValidationHandler else {
            promise.fail(isMismatch ? SSHTunnelError.hostKeyMismatch : SSHTunnelError.hostKeyValidationMissing)
            return
        }

        let keyType = keyData == nil ? "Unknown (Legacy Lib)" : "Unknown"
        let resolvedKeyData = keyData ?? Data()

        // Bridge the async UI decision back onto the NIO promise. NIOSSH's
        // validateHostKey is not async, so we keep its promise and fulfil it from
        // the awaited result. EventLoopPromise is Sendable and hops to its own
        // event loop when completed, so resolving it from this Task is safe.
        Task {
            // The user is deciding at the host-key prompt — don't count that
            // against the handshake deadline. Re-arm once they trust so the
            // remaining auth phase stays bounded.
            self.cancelHandshakeTimeout()
            let allowed = await handler(host, fingerprint, keyType, resolvedKeyData, isMismatch)
            if allowed {
                self.armHandshakeTimeout()
                promise.succeed(())
            } else {
                promise.fail(isMismatch ? SSHTunnelError.hostKeyMismatch : SSHTunnelError.hostKeyRejected)
            }
        }
    }

    /// Schedules a task that fails `sessionReadyPromise` with `.connectionTimeout`
    /// after `handshakeTimeoutSeconds`, so a stalled handshake/auth can't leave the
    /// connection wedged in `.connecting`. Completing an already-resolved promise is
    /// a no-op in NIO, so this is safe even if the session becomes ready first.
    private func armHandshakeTimeout() {
        guard let group = lock.withLock({ self.eventLoopGroup }) else { return }
        let scheduled = group.next().scheduleTask(in: .seconds(Self.handshakeTimeoutSeconds)) { [weak self] in
            guard let self else { return }
            self.lock.withLock {
                guard let promise = self.sessionReadyPromise, self.sessionReadyCompleted == false else { return }
                self.sessionReadyCompleted = true
                Logger.error("SSH handshake/auth timed out after \(Self.handshakeTimeoutSeconds)s", log: Logger.ssh)
                promise.fail(SSHTunnelError.connectionTimeout)
            }
        }
        lock.withLock { self.handshakeTimeoutTask = scheduled }
    }

    /// Cancels a pending handshake-timeout task, if any.
    private func cancelHandshakeTimeout() {
        let task = lock.withLock { () -> Scheduled<Void>? in
            let existing = self.handshakeTimeoutTask
            self.handshakeTimeoutTask = nil
            return existing
        }
        task?.cancel()
    }

    private func serialize(key: NIOSSHPublicKey) -> Data? {
        // NIOSSH exposes the canonical OpenSSH public-key string
        // ("<algorithm-id> <base64-wire-bytes>") via `String(openSSHPublicKey:)`.
        // The base64 component decodes to the SSH wire-format key blob — the same
        // bytes OpenSSH hashes for its SHA256 fingerprint, and a stable, host-unique
        // value we can pin for trust-on-first-use and compare on later connections.
        let openSSHString = String(openSSHPublicKey: key)
        let components = openSSHString.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
        guard components.count >= 2, let blob = Data(base64Encoded: String(components[1])) else {
            return nil
        }
        return blob
    }

    // MARK: - Local Listener / Forwarding

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

    /// Relays bytes arriving on the SSH child channel out to the local TCP peer.
    private func configureSSHChildPipeline(_ sshChildChannel: Channel, inbound: Channel, strongSelf: SSHManager) -> EventLoopFuture<Void> {
        let received: @Sendable (Int) -> Void = { [weak strongSelf] n in
            guard let manager = strongSelf else { return }
            Task { @MainActor in manager.handleBytesReceived(n) }
        }
        let sshToTCP = GenericRelayHandler<SSHChannelData, ByteBuffer>(peer: inbound, onBytes: received) { sshData in
            guard case .byteBuffer(let buffer) = sshData.data else { return (nil, 0) }
            return (buffer, buffer.readableBytes)
        }
        return sshChildChannel.pipeline.addHandler(sshToTCP)
    }

    /// Relays bytes arriving on the local TCP peer into the SSH child channel.
    private func configureInboundTCPPipeline(_ inbound: Channel, sshChildChannel: Channel, strongSelf: SSHManager) -> EventLoopFuture<Void> {
        let sent: @Sendable (Int) -> Void = { [weak strongSelf] n in
            guard let manager = strongSelf else { return }
            Task { @MainActor in manager.handleBytesSent(n) }
        }
        let tcpToSSH = GenericRelayHandler<ByteBuffer, SSHChannelData>(peer: sshChildChannel, onBytes: sent) { buffer in
            let sshData = SSHChannelData(type: .channel, data: .byteBuffer(buffer))
            return (sshData, buffer.readableBytes)
        }
        return inbound.pipeline.addHandler(tcpToSSH)
    }

    // MARK: - Disconnect / Shutdown

    func disconnect() async {
        await MainActor.run {
            connection.state = .disconnecting
        }
        await shutdown()
    }

    private func shutdown() async {
        cancelHandshakeTimeout()
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
        }

        // The event loop group is NIO's process-wide singleton, which is perpetual
        // and must not be shut down. Just drop our reference to it; the channels
        // were already closed above.
        lock.withLock { self.eventLoopGroup = nil }

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
        }
    }

    // MARK: - Main Actor State Updates

    private func handleBytesSent(_ count: Int) {
        let n = Int64(count)
        Task { @MainActor in
            self.connection.bytesSent += n
        }
    }

    private func handleBytesReceived(_ count: Int) {
        let n = Int64(count)
        Task { @MainActor in
            self.connection.bytesReceived += n
        }
    }
}
