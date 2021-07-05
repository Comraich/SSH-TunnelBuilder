//
//  Connection.swift
//  SSH TunnelBuilder
//
//  Created by Simon Bruce-Cassidy on 08/05/2021.
//

import Foundation
import CloudKit

class Connection {
    
    static let recordType = "Connection"
    private let id: CKRecord.ID
    let connectionId: Int
    let connectionName: String
    let sshHost: String
    let sshHostPort: Int
    let localPort: Int
    let remoteServer: String
    let remotePort: Int
    let userName: String
    var password: String?
    var publicKey: String?
    
    init?(record: CKRecord, database: CKDatabase) {
        guard
            let connectionId = record["connectionId"] as? Int,
            let connectionName = record["connectionName"] as? String,
            let sshHost = record["sshHost"] as? String,
            let sshHostPort = record["sshHostPort"] as? Int,
            let localPort = record["localPort"] as? Int,
            let remoteServer = record["remoteServer"] as? String,
            let remotePort = record["remotePort"] as? Int,
            let userName = record["userName"] as? String
        else { return nil }
        self.id = record.recordID
        self.connectionId = connectionId
        self.connectionName = connectionName
        self.sshHost = sshHost
        self.sshHostPort = sshHostPort
        self.localPort = localPort
        self.remoteServer = remoteServer
        self.remotePort = remotePort
        self.userName = userName
        self.password = record["password"] as? String
        self.publicKey = record["publicKey"] as? String

    }
}

extension Connection: Hashable {
    static func == (lhs: Connection, rhs: Connection) -> Bool {
    return lhs.id == rhs.id
    }
    
    func hash(into hasher: inout Hasher) {
    hasher.combine(id)
    }
}

struct TableViewConnectionRecords {
    
    var connection: Connection?
    var sshClient: SSHClient?
    
    init(connection: Connection, sshClient: SSHClient) {
        
        self.connection = connection
        self.sshClient = sshClient
        
    }
}
