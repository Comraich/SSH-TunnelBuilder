//
//  ViewModel.swift
//  SSH TunnelBuilder
//
//  Created by Simon Bruce-Cassidy.
//

import Foundation
import CloudKit

class ViewModel: NSObject {
    
    let container: CKContainer
    let privateDB: CKDatabase
    private(set) var connections: [Connection] = []
    
    override init() {
        
        container = CKContainer.default()
        privateDB = container.privateCloudDatabase
        
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
            
            DispatchQueue.main.async {
                completion(nil)
                
            }
        }
    }
}
