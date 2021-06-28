//
//  Connection.swift
//  SSH TunnelBuilder
//
//  Created by Simon Bruce-Cassidy on 08/05/2021.
//

import Foundation
import CloudKit

struct CodableConnection : Codable {
    
    var connectionId: Int?
    var connectionName: String?
    var sshHost: String?
    var sshHostPort: Int?
    var localPort: Int?
    var remoteServer: String?
    var remotePort: Int?
    var username: String?
    var password: String?
    var privateKey: String?

    enum CodingKeys: String, CodingKey {
        case connectionId
        case connectionName
        case sshHost
        case sshHostPort
        case localPort
        case remoteServer
        case remotePort
        case username
        case password
        case privateKey
    }
}

class Connection {
    
    static let recordType = "Connection"
    var id: CKRecord.ID?
    var connectionId: Int
    var connectionName: String
    var sshHost: String
    var sshHostPort: Int
    var localPort: Int
    var remoteServer: String
    var remotePort: Int
    var username: String
    var password: String?
    var privateKey: String?
    
    init?(record: CKRecord, database: CKDatabase) {
        guard
            let connectionId = record["connectionId"] as? Int,
            let connectionName = record["connectionName"] as? String,
            let sshHost = record["sshHost"] as? String,
            let sshHostPort = record["sshHostPort"] as? Int,
            let localPort = record["localPort"] as? Int,
            let remoteServer = record["remoteServer"] as? String,
            let remotePort = record["remotePort"] as? Int,
            let username = record["username"] as? String
        else { return nil }
        self.id = record.recordID
        self.connectionId = connectionId
        self.connectionName = connectionName
        self.sshHost = sshHost
        self.sshHostPort = sshHostPort
        self.localPort = localPort
        self.remoteServer = remoteServer
        self.remotePort = remotePort
        self.username = username
        self.password = record["password"] as? String
        self.privateKey = record["privateKey"] as? String

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

