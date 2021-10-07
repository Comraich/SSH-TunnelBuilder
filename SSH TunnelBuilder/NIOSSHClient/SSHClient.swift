//
//  SSHClient.swift
//  SSH TunnelBuilder
//
//  Created by Simon Bruce-Cassidy on 18/05/2021.
//

import Foundation
import Dispatch
import NIO
import NIOSSH

// This file contains an example NIO SSH client. As NIO SSH is currently under active
// development this file doesn't currently do all that much, but it does provide a binary you
// can kick off to get a feel for how NIO SSH drives the connection live. As the feature set of
// NIO SSH increases we'll be adding to this client to try to make it a better example of what you
// can do with NIO SSH.
final class ErrorHandler: ChannelInboundHandler {
    typealias InboundIn = Any

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        print("Error in pipeline: \(error)")
        context.close(promise: nil)
    }
}

final class AcceptAllHostKeysDelegate: NIOSSHClientServerAuthenticationDelegate {
    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        // Do not replicate this in your own code: validate host keys! This is a
        // choice made for expedience, not for any other reason.
        validationCompletePromise.succeed(())
    }
}

enum SSHClientError: Swift.Error {
    case passwordAuthenticationNotSupported
    case commandExecFailed
    case invalidChannelType
    case invalidData
}

class SSHClient
{
    
    public var server: PortForwardingServer?
    
    func Connect(connection: Connection, password: String? = nil) throws
    {
        let parser = ConnectionParser()
        let parseResult = parser.parse(connection: connection)
        
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer {
            try! group.syncShutdownGracefully()
        }
        
        var connectionPassword: String? = connection.password
        
        if password != nil {
            connectionPassword = password
        }
        
        let bootstrap = ClientBootstrap(group: group)
                        .channelInitializer { channel in
                            channel.pipeline.addHandlers([NIOSSHHandler(role: .client(.init(userAuthDelegate: InteractivePasswordPromptDelegate(username: connection.username, password: connectionPassword), serverAuthDelegate: AcceptAllHostKeysDelegate())), allocator: channel.allocator, inboundChildChannelInitializer: nil), ErrorHandler()])
                        }
                        .channelOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR), value: 1)
                        .channelOption(ChannelOptions.socket(SocketOptionLevel(IPPROTO_TCP), TCP_NODELAY), value: 1)
        

        let channel = try bootstrap.connect(host: parseResult.host, port: parseResult.port).wait()

        if let portForward = parseResult.portForward {
            // We've been asked to port forward.
            self.server = PortForwardingServer(group: group,
                                              bindHost: portForward.bindHost ?? "localhost",
                                              bindPort: portForward.bindPort) { inboundChannel in
                // This block executes whenever a new inbound channel is received. We want to forward it to the peer.
                // To do that, we have to begin by creating a new SSH channel of the appropriate type.
                channel.pipeline.handler(type: NIOSSHHandler.self).flatMap { sshHandler in
                    let promise = inboundChannel.eventLoop.makePromise(of: Channel.self)
                    let directTCPIP = SSHChannelType.DirectTCPIP(targetHost: String(portForward.targetHost),
                                                                 targetPort: portForward.targetPort,
                                                                 originatorAddress: inboundChannel.remoteAddress!)
                    sshHandler.createChannel(promise,
                                             channelType: .directTCPIP(directTCPIP)) { childChannel, channelType in
                        guard case .directTCPIP = channelType else {
                            return channel.eventLoop.makeFailedFuture(SSHClientError.invalidChannelType)
                        }

                        // Attach a pair of glue handlers, one in the inbound channel and one in the outbound one.
                        // We also add an error handler to both channels, and a wrapper handler to the SSH child channel to
                        // encapsulate the data in SSH messages.
                        // When the glue handlers are in, we can create both channels.
                        let (ours, theirs) = GlueHandler.matchedPair()
                        return childChannel.pipeline.addHandlers([SSHWrapperHandler(), ours, ErrorHandler()]).flatMap {
                            inboundChannel.pipeline.addHandlers([theirs, ErrorHandler()])
                        }
                    }

                    // We need to erase the channel here: we just want success or failure info.
                    return promise.futureResult.map { _ in }
                }
            }

            // Run the server until complete
            try! self.server!.run().wait()

        }
    }
    
    func disconnect() {
        
        _ = self.server?.close()
        
    }
}

