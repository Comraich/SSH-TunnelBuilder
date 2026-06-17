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

import Foundation
import NIO
@preconcurrency import NIOSSH

// NIO channel handlers and delegates used by `SSHManager`. Kept separate so the
// manager itself reads as connection lifecycle, not pipeline plumbing.

// MARK: - Host Key Delegate

/// Bridges NIOSSH's host-key validation to a closure supplied by `SSHManager`.
final class InteractiveHostKeyDelegate: NIOSSHClientServerAuthenticationDelegate, Sendable {
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

// MARK: - Session Ready Handler

/// Fulfils `sessionReadyPromise` once user auth succeeds, or fails it if the
/// channel errors or goes inactive first.
final class SSHSessionReadyHandler: ChannelInboundHandler, RemovableChannelHandler {
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

// MARK: - TaskGroup Helper

extension TaskGroup where ChildTaskResult == Void {
    /// Adds a child task that closes `channel`, logging any error under `name`.
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

// MARK: - Generic Relay Handler

// `@unchecked Sendable`: a `ChannelHandler` is confined to its channel's event
// loop, and every stored property here is immutable. NIO's pipeline APIs require
// `Sendable` handlers under Swift 6, so we vouch for the confinement explicitly.
// `OutboundType: Sendable` lets the transformed value cross into the peer's
// event-loop closure without warning (the concrete types are `ByteBuffer` and
// `SSHChannelData`, both `Sendable`).
final class GenericRelayHandler<InboundType, OutboundType: Sendable>: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = InboundType

    private let peer: Channel
    private let onBytes: @Sendable (Int) -> Void
    private let transform: @Sendable (InboundType) -> (OutboundType?, Int)

    init(peer: Channel, onBytes: @escaping @Sendable (Int) -> Void, transform: @escaping @Sendable (InboundType) -> (OutboundType?, Int)) {
        self.peer = peer
        self.onBytes = onBytes
        self.transform = transform
    }

    func channelRead(context _: ChannelHandlerContext, data: NIOAny) {
        let inboundData = self.unwrapInboundIn(data)
        let (outboundData, count) = transform(inboundData)

        if count > 0 {
            self.onBytes(count)
            if let outboundData {
                // Ensure write happens on the peer's event loop for thread safety.
                // Capture `peer` (Sendable) rather than `self`.
                let peer = self.peer
                peer.eventLoop.execute {
                    peer.writeAndFlush(outboundData, promise: nil)
                }
            }
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        // Ensure close happens on the peer's event loop for thread safety.
        let peer = self.peer
        peer.eventLoop.execute {
            peer.close(mode: .all, promise: nil)
        }
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        Logger.error("GenericRelayHandler error: \(error)", log: Logger.ssh)
        // Ensure close happens on the peer's event loop for thread safety.
        let peer = self.peer
        peer.eventLoop.execute {
            peer.close(mode: .all, promise: nil)
        }
        context.close(promise: nil)
    }
}
