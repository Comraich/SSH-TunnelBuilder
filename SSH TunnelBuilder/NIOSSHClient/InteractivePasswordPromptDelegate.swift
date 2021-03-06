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

import Dispatch
import Foundation
import NIO
import NIOSSH

/// A client user auth delegate that provides an interactive prompt for password-based user auth.
final class InteractivePasswordPromptDelegate: NIOSSHClientUserAuthenticationDelegate {
    private let queue: DispatchQueue

    private var username: String?

    private var password: String?
    
    private var privateKey: String?

    init(username: String?, password: String?) {
        self.queue = DispatchQueue(label: "io.swiftnio.ssh.InteractivePasswordPromptDelegate")
        self.username = username
        self.password = password
        self.privateKey = ""
    }

    func nextAuthenticationType(availableMethods: NIOSSHAvailableUserAuthenticationMethods, nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>) {
        // guard availableMethods.contains(.password) || availableMethods.contains(.publicKey) else {
        guard availableMethods.contains(.password) else {
            print("Error: password auth not supported")
            nextChallengePromise.fail(SSHClientError.passwordAuthenticationNotSupported)
            return
        }

        self.queue.async {
            if self.privateKey == "" {

            nextChallengePromise.succeed(NIOSSHUserAuthenticationOffer(username: self.username!, serviceName: "", offer: .password(.init(password: self.password!))))
                
           }
//                else {
//
//                nextChallengePromise.succeed(NIOSSHUserAuthenticationOffer(username: self.username!, serviceName: "", offer: .privateKey(.init(privateKey: self.privateKey))))
//            }
        }
    }
}
