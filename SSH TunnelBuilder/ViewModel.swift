//
//  ViewModel.swift
//  SSH TunnelBuilder
//
//  Created by Simon Bruce-Cassidy.
//

import Foundation

class ViewModel: NSObject {
    
    var connections = [Connections]()
    
    override init() {
        super.init()
        
        loadJSonData()
        
    }
    
    private func loadJSonData() {
        
        guard let jsonDataURL = Bundle.main.url(forResource: "MOCK_DATA", withExtension: "json"),
            let jsonData = try? Data(contentsOf: jsonDataURL)
        
            else { return }
        
        let decoder = JSONDecoder()
        
        do {
            connections = try decoder.decode([Connections].self, from: jsonData)
        } catch {
            print(error.localizedDescription)
        }
    }

    func removeConnection(atIndex index: Int) {
        
        connections.remove(at: index)
        
    }
}
