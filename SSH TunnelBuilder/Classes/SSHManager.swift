import Foundation
import NIO
import NIOSSH
import Combine

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
            self.connection.isConnecting = false
            self.connection.isActive = false
            self.isActive = false
            return
        }

        self.connection.isConnecting = true
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

        bootstrap.connect(host: host, port: port).whenComplete { [weak self] result in
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
            }
        }
    }

    func disconnect() {
        self.connection.isConnecting = false
        if let ssh = sshClientChannel { _ = ssh.close(mode: .all); sshClientChannel = nil }
        if let group = eventLoopGroup {
            do { try group.syncShutdownGracefully() } catch { print("EventLoopGroup shutdown error: \(error)") }
            eventLoopGroup = nil
        }
        trafficTimer?.cancel(); trafficTimer = nil
        self.connection.isActive = false
        self.isActive = false
    }

    private func cleanup() {
        if let ssh = sshClientChannel { _ = ssh.close(mode: .all); sshClientChannel = nil }
        if let group = eventLoopGroup { do { try group.syncShutdownGracefully() } catch { print("EventLoopGroup shutdown error: \(error)") }; eventLoopGroup = nil }
        trafficTimer?.cancel(); trafficTimer = nil
    }
}

