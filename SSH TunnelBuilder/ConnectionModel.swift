//
//  ConnectionModel.swift
//  SSH TunnelBuilder
//
//  Created by Simon Bruce-Cassidy on 08/05/2021.
//

import Foundation

struct Connections {
    var connectionId: Int?
    var connectionName: String?
    var localPort: Int?
    var remoteServer: String?
    var remotePort: Int?
    var userName: String?
    var password: String?
    var publicKey: String?
}
