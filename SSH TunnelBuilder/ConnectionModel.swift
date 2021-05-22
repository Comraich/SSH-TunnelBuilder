//
//  ConnectionModel.swift
//  SSH TunnelBuilder
//
//  Created by Simon Bruce-Cassidy on 08/05/2021.
//

import Foundation

struct Connection: Codable {
    
    var connectionId: Int?
    var connectionName: String?
    var sshHost: String?
    var sshHostPort: Int?
    var localPort: Int?
    var remoteServer: String?
    var remotePort: Int?
    var userName: String?
    var password: String?
    var publicKey: String?
    
}

struct TableViewConnectionRecords {
    
    var connection: Connection?
    var sshClient: SSHClient?
    
    init(connection: Connection, sshClient: SSHClient) {
        
        self.connection = connection
        self.sshClient = sshClient
        
    }
}
