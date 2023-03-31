//
//  Connection.swift
//  SSH TunnelBuilder2
//
//  Created by Simon Bruce-Cassidy on 28/03/2023.
//

import Foundation
import CloudKit

struct Connection: Identifiable, Equatable, Hashable {
    let id: UUID
    let recordID: CKRecord.ID?
    let name: String
    let serverAddress: String
    let portNumber: String
    let username: String
    let password: String
    let privateKey: String
    let localPort: String
    let remoteServer: String
    let remotePort: String
    
    init(id: UUID = UUID(),
         recordID: CKRecord.ID? = nil,
         name: String,
         serverAddress: String,
         portNumber: String,
         username: String,
         password: String,
         privateKey: String,
         localPort: String,
         remoteServer: String,
         remotePort: String) {
        
        self.id = id
        self.recordID = recordID
        self.name = name
        self.serverAddress = serverAddress
        self.portNumber = portNumber
        self.username = username
        self.password = password
        self.privateKey = privateKey
        self.localPort = localPort
        self.remoteServer = remoteServer
        self.remotePort = remotePort
    }
}


