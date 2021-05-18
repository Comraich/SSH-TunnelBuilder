//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2020 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//
import Foundation

/// A very simple connection definition parser.
struct ConnectionParser {
    func parse(connection: Connection) -> Result {
        
        let sshHost = URL(string: "ssh://" + connection.sshHost! + ":" + String(connection.sshHostPort!))!
        let portForward = PortForward(portForwardString: String(connection.localPort!) + ":" + connection.remoteServer! + ":" + String(connection.remotePort!))

        return Result(sshHost: sshHost, portForward:portForward)
        
    }
}

extension ConnectionParser {
    struct Result {

        var host: String

        var port: Int

        var user: String?

        var password: String?

        var portForward: PortForward?

        fileprivate init(sshHost: URL, portForward: PortForward?) {
            self.host = sshHost.host ?? "::1"
            self.port = sshHost.port ?? 22
            self.user = sshHost.user
            self.password = sshHost.password
            self.portForward = portForward
        }
    }
}

extension ConnectionParser {
    // A structure representing a parsed listen string: [bind_address:]port:host:hostport
    struct PortForward {
        var bindHost: Substring?
        var bindPort: Int
        var targetHost: Substring
        var targetPort: Int

        init?(portForwardString: String) {
            var components = portForwardString.split(separator: ":")

            switch components.count {
            case 4:
                self.bindHost = components.removeFirst()
                fallthrough
            case 3:
                guard let bindPort = Int(components.removeFirst()) else {
                    return nil
                }
                self.bindPort = bindPort
                self.targetHost = components.removeFirst()
                guard let targetPort = Int(components.removeFirst()) else {
                    return nil
                }
                self.targetPort = targetPort
            default:
                return nil
            }
        }
    }
}
