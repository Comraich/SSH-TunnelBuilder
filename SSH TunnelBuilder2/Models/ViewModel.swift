//
//  ViewModel.swift
//  SSH TunnelBuilder
//
//  Created by Simon Bruce-Cassidy.
//

import Foundation
import CloudKit

class ViewModel: NSObject {
    
    let privateDB: CKDatabase
    private(set) var connections: [Connection] = []
    static var highestConnectionId: Int = 0
    
    override init() {
        
        privateDB = CKContainer.default().privateCloudDatabase
        
    }
    
    @objc func refresh(_ completion: @escaping (Error?) -> Void) {
        
      let predicate = NSPredicate(value: true)
      let query = CKQuery(recordType: "connection", predicate: predicate)
        connections(forQuery: query, completion)
        
    }
    
    private func connections(forQuery query: CKQuery,
                             _ completion: @escaping (Error?) -> Void) {
        
        privateDB.perform(query,
                          inZoneWith: CKRecordZone.default().zoneID) { [weak self] results, error in
            guard let self = self else { return }
            
            if let error = error {
                DispatchQueue.main.async {
                    completion(error)
                }
                return
            }
            
            guard let results = results else { return }
            self.connections = results.compactMap {
                Connection(record: $0, database: self.privateDB)
            }
            
            for connection in self.connections {
                
                if connection.connectionId > ViewModel.highestConnectionId {
                    ViewModel.highestConnectionId = connection.connectionId
                
                }
            }
            DispatchQueue.main.async {
                completion(nil)
                
            }
        }
    }
    
    func getConnection(connectionId: Int) -> Connection? {
        
        for connection in connections {
            
            if connection.connectionId == connectionId {
                return connection
            }
        }
        
        return nil
        
    }
    
    func exportConnectionsToJSON() -> Data? {
        
        var codableConnection = CodableConnection()
        let jsonEncoder = JSONEncoder()
        var connectionArray = [CodableConnection]()
        
        for connection in connections {
            
            codableConnection.connectionId = connection.connectionId
            codableConnection.connectionName = connection.connectionName
            codableConnection.sshHost = connection.sshHost
            codableConnection.sshHostPort = connection.sshHostPort
            codableConnection.localPort = connection.localPort
            codableConnection.remoteServer = connection.remoteServer
            codableConnection.remotePort = connection.remotePort
            codableConnection.username = connection.username
            codableConnection.password = connection.password
            // codableConnection.privateKey = connection.privateKey
            
            connectionArray.append(codableConnection)
        }
        
        do {
            
            let jsonData = try jsonEncoder.encode(connectionArray)
            return jsonData

        } catch {
            
            NSLog("Unable to save.")
            return nil
            
        }
    }
}
