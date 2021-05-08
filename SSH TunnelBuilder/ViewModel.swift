//
//  ViewModel.swift
//  TableDemo
//
//  Created by Gabriel Theodoropoulos.
//  Copyright © 2019 Appcoda. All rights reserved.
//

import Foundation

class ViewModel: NSObject {
    
    // MARK: - Properties
    
    var connections = [Connections]()
    
    // MARK: - Init
    
    override init() {
        super.init()
        
        //  Load dummy data.
        loadDummyData()
    }
    
    // MARK: - Private Methods
    
    private func loadDummyData() {
        guard let dummyDataURL = Bundle.main.url(forResource: "MOCK_DATA", withExtension: "json"),
            let dummyData = try? Data(contentsOf: dummyDataURL)
            else { return }
        
        let decoder = JSONDecoder()
        do {
            connections = try decoder.decode([Connections].self, from: dummyData)
        } catch {
            print(error.localizedDescription)
        }
        
    }
    
    // MARK: - Public Methods

    func removeConnection(atIndex index: Int) {
        connections.remove(at: index)
    }
}
