// Copyright 2020-2026 Comraich ANS
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

import Testing
import Foundation
import NIO
import os

@testable import SSH_TunnelBuilder

// MARK: - SSHManager connect / shutdown lifecycle
//
// Closes the long-standing "SSHManager connect/disconnect flows" coverage gap.
// These tests drive the real `connect()` and `disconnect()` paths — including the
// state that `OSAllocatedUnfairLock` now guards — without needing an SSH server:
//
//  - failure paths short-circuit before any socket work (missing credentials,
//    unparseable key);
//  - the handshake-timeout path only needs a TCP peer that accepts and then stays
//    silent, which is exactly what `SilentTCPListener` below provides;
//  - `disconnect()` is the public door to the private `shutdown()`.
//
// NOT covered here (needs a real SSH server, so still a gap): successful session
// establishment, `startLocalListener` / port-forwarding, `invalidPort`, and the
// host-key prompt's pause/re-arm of the handshake deadline.
//
// (The old `SSHManagerTests.swift` was dead, commented-out XCTest code that
// couldn't compile because it was wrongly a member of the app target; both it and
// that misconfiguration are gone.)

/// Accepts TCP connections on loopback and then says nothing at all — the peer
/// completes a TCP handshake but never speaks SSH, so `sessionReadyPromise` can
/// only ever be resolved by the handshake timeout. This is the same scenario the
/// 2026-06-16 hang fix was originally validated against by hand.
private final class SilentTCPListener {
    private let channel: Channel

    /// Port the listener is bound to on 127.0.0.1.
    var port: Int { channel.localAddress?.port ?? 0 }

    init() async throws {
        channel = try await ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            // Accept the connection, install nothing, write nothing.
            .childChannelInitializer { $0.eventLoop.makeSucceededVoidFuture() }
            .bind(host: "127.0.0.1", port: 0)
            .get()
    }

    func close() async {
        try? await channel.close().get()
    }
}

/// Thread-safe capture for `SSHManager.errorCallback`, which is `@Sendable` and
/// fires from whichever executor hit the error.
private final class ErrorRecorder: Sendable {
    private let messages = OSAllocatedUnfairLock(initialState: [String]())

    var callback: @Sendable (String) -> Void {
        { [messages] message in messages.withLock { $0.append(message) } }
    }

    var recorded: [String] { messages.withLock { $0 } }
}

/// `.serialized` for a concrete reason: these tests mutate
/// `SSHManager.connectionTimeoutSeconds` / `.handshakeTimeoutSeconds`, which are
/// `nonisolated(unsafe) static var` process-wide knobs. Running them in parallel
/// would race each other's save/restore and produce flakes.
///
/// This is deliberately NOT the `.serialized`-everything workaround that the
/// 2026-06-15 Swift Testing runner bug prompted (that bug is fixed; see Known
/// Issues in CLAUDE.md, and note the other suites remain parallel). It is scoped
/// to this one suite because this one suite touches global mutable config.
@Suite("SSHManager Lifecycle Tests", .serialized)
struct SSHManagerLifecycleTests {

    // MARK: Helpers

    @MainActor
    private func makeConnection(password: String = "",
                                privateKey: String = "",
                                serverAddress: String = "127.0.0.1",
                                portNumber: String = "22") -> Connection {
        let info = ConnectionInfo(name: "Lifecycle Test",
                                  serverAddress: serverAddress,
                                  portNumber: portNumber,
                                  username: "user",
                                  password: password,
                                  privateKey: privateKey,
                                  privateKeyPassphrase: "")
        let tunnel = TunnelInfo(localPort: "0", remoteServer: "remote", remotePort: "80")
        return Connection(id: UUID(), connectionInfo: info, tunnelInfo: tunnel)
    }

    /// Runs `body` and returns whatever it threw, or `nil` if it didn't throw.
    /// `SSHTunnelError` isn't `Equatable` (it carries `Error` payloads), so the
    /// tests pattern-match the result rather than using `#expect(throws:)`.
    private func captureError(_ body: () async throws -> Void) async -> Error? {
        do {
            try await body()
            return nil
        } catch {
            return error
        }
    }

    /// Saves the process-wide timeout knobs, applies overrides, runs `body`, and
    /// restores them even if the body throws.
    private func withTimeouts(connect: Int64? = nil,
                              handshake: Int64? = nil,
                              _ body: () async throws -> Void) async rethrows {
        let savedConnect = SSHManager.connectionTimeoutSeconds
        let savedHandshake = SSHManager.handshakeTimeoutSeconds
        defer {
            SSHManager.connectionTimeoutSeconds = savedConnect
            SSHManager.handshakeTimeoutSeconds = savedHandshake
        }
        if let connect { SSHManager.connectionTimeoutSeconds = connect }
        if let handshake { SSHManager.handshakeTimeoutSeconds = handshake }
        try await body()
    }

    /// A loopback port with nothing listening: bind to an ephemeral port, read it
    /// back, then close. Connecting there yields an immediate ECONNREFUSED.
    private func closedPort() async throws -> Int {
        let listener = try await SilentTCPListener()
        let port = listener.port
        await listener.close()
        return port
    }

    // MARK: Credential / key failure paths (no sockets involved)

    @Test("connect() with neither password nor key fails with missingCredentials")
    @MainActor func connectWithoutCredentialsFails() async {
        let connection = makeConnection(password: "", privateKey: "")
        let manager = SSHManager(connection: connection)
        let recorder = ErrorRecorder()
        manager.errorCallback = recorder.callback

        let error = await captureError { try await manager.connect() }

        guard let tunnelError = error as? SSHTunnelError else {
            Issue.record("expected an SSHTunnelError, got \(String(describing: error))")
            return
        }
        guard case .missingCredentials = tunnelError else {
            Issue.record("expected .missingCredentials, got \(tunnelError)")
            return
        }
        // The connection must not be left spinning in `.connecting`.
        guard case .failed(let message) = connection.state else {
            Issue.record("expected .failed, got \(connection.state)")
            return
        }
        #expect(message.isEmpty == false)
        #expect(recorder.recorded.isEmpty == false, "the UI must be told why it failed")
    }

    @Test("connect() with an unparseable private key fails with keyParsingFailed")
    @MainActor func connectWithBadKeyFails() async {
        // Password is empty, so the key is the only credential and its failure is
        // fatal. This also drives the `@concurrent makeAuthDelegate` hop.
        let connection = makeConnection(password: "", privateKey: "not a key at all")
        let manager = SSHManager(connection: connection)
        let recorder = ErrorRecorder()
        manager.errorCallback = recorder.callback

        let error = await captureError { try await manager.connect() }

        guard let tunnelError = error as? SSHTunnelError else {
            Issue.record("expected an SSHTunnelError, got \(String(describing: error))")
            return
        }
        guard case .keyParsingFailed = tunnelError else {
            Issue.record("expected .keyParsingFailed, got \(tunnelError)")
            return
        }
        // `shutdown()` runs on this path; it must preserve `.failed` rather than
        // resetting to `.idle`, so the UI can still show the reason.
        guard case .failed = connection.state else {
            Issue.record("expected .failed to survive shutdown(), got \(connection.state)")
            return
        }
        #expect(recorder.recorded.isEmpty == false)
    }

    // MARK: Handshake timeout — the path the lock refactor touches

    @Test("A peer that accepts TCP but never speaks SSH fails with connectionTimeout")
    @MainActor func silentPeerTimesOutHandshake() async throws {
        let listener = try await SilentTCPListener()
        let connection = makeConnection(password: "pw", portNumber: String(listener.port))
        let manager = SSHManager(connection: connection)
        let recorder = ErrorRecorder()
        manager.errorCallback = recorder.callback

        // 1s handshake deadline keeps the test fast; the TCP connect itself is
        // instant on loopback so the default connect timeout is irrelevant here.
        await withTimeouts(handshake: 1) {
            let error = await captureError { try await manager.connect() }

            guard let tunnelError = error as? SSHTunnelError else {
                Issue.record("expected an SSHTunnelError, got \(String(describing: error))")
                return
            }
            guard case .connectionTimeout = tunnelError else {
                Issue.record("expected .connectionTimeout, got \(tunnelError)")
                return
            }
        }
        await listener.close()

        // The regression this guards: the connection used to sit in `.connecting`
        // forever, spinning both indicators with no way out but Disconnect.
        #expect(connection.state.isConnecting == false)
        guard case .failed = connection.state else {
            Issue.record("expected .failed, got \(connection.state)")
            return
        }
        #expect(recorder.recorded.isEmpty == false)
    }

    @Test("A refused TCP connection fails and leaves the connection in .failed")
    @MainActor func refusedConnectionFails() async throws {
        let deadPort = try await closedPort()
        let connection = makeConnection(password: "pw", portNumber: String(deadPort))
        let manager = SSHManager(connection: connection)

        // Not an SSHTunnelError — NIO surfaces ECONNREFUSED from the bootstrap —
        // so this asserts the state machine's reaction, not the error's type.
        await withTimeouts(connect: 2, handshake: 2) {
            let error = await captureError { try await manager.connect() }
            #expect(error != nil, "connecting to a closed port must fail")
        }

        #expect(connection.state.isConnecting == false)
        guard case .failed = connection.state else {
            Issue.record("expected .failed, got \(connection.state)")
            return
        }
    }

    // MARK: shutdown() via disconnect()

    @Test("disconnect() on a manager that never connected is safe and idempotent")
    @MainActor func disconnectWithoutConnectIsSafe() async {
        let connection = makeConnection(password: "pw")
        let manager = SSHManager(connection: connection)

        // Exercises shutdown()'s claim-and-clear with a nil promise and nil
        // channels — the shape most likely to trip over the lock refactor.
        await manager.disconnect()
        await manager.disconnect()

        #expect(connection.state == .idle)
    }

    @Test("disconnect() after a failed connect resets to idle and zeroes counters")
    @MainActor func disconnectAfterFailureResetsState() async {
        let connection = makeConnection(password: "", privateKey: "")
        let manager = SSHManager(connection: connection)

        _ = await captureError { try await manager.connect() }
        guard case .failed(let reason) = connection.state else {
            Issue.record("expected .failed after a failed connect, got \(connection.state)")
            return
        }
        #expect(reason.isEmpty == false)

        connection.bytesSent = 4096
        connection.bytesReceived = 8192
        await manager.disconnect()

        // `disconnect()` moves through `.disconnecting`, so unlike the in-connect
        // shutdown the terminal state here is `.idle` — and the counters reset.
        #expect(connection.state == .idle)
        #expect(connection.bytesSent == 0)
        #expect(connection.bytesReceived == 0)
    }

    // MARK: Guard against re-entrant connect

    @Test("connect() is a no-op when the connection is already connected")
    @MainActor func connectWhileConnectedIsNoOp() async {
        let connection = makeConnection(password: "pw")
        let manager = SSHManager(connection: connection)
        connection.state = .connected

        // Must return without throwing and without disturbing the live state —
        // the early-out reads `connection.state` on the main actor before any
        // socket work begins.
        let error = await captureError { try await manager.connect() }

        #expect(error == nil)
        #expect(connection.state == .connected)
    }

    // MARK: Concurrency stress on the refactored lock

    @Test("Concurrent connect and disconnect never deadlock or crash")
    @MainActor func concurrentConnectAndDisconnectIsSafe() async throws {
        let listener = try await SilentTCPListener()

        // Races `connect()`'s promise setup and the handshake timeout against
        // `shutdown()`'s claim-and-clear. Before the fields moved inside the lock,
        // `sessionReadyPromise`/`sessionReadyCompleted` were touched unguarded on
        // exactly these two paths. A double-resolve or torn read shows up here as
        // a crash or a hang rather than a failed expectation.
        await withTimeouts(handshake: 1) {
            for _ in 0..<5 {
                let connection = makeConnection(password: "pw",
                                                portNumber: String(listener.port))
                let manager = SSHManager(connection: connection)

                async let connectAttempt: Error? = captureError {
                    try await manager.connect()
                }
                async let disconnectAttempt: Void = {
                    // Land mid-handshake, while the promise is live.
                    try? await Task.sleep(for: .milliseconds(50))
                    await manager.disconnect()
                }()

                _ = await connectAttempt
                await disconnectAttempt

                // Whatever the interleaving, the connection must settle out of
                // `.connecting` — never wedged mid-flight.
                #expect(connection.state.isConnecting == false,
                        "left in .connecting after concurrent connect/disconnect")
            }
        }
        await listener.close()
    }
}
