//
//  ConnectionRow.swift
//  SSH TunnelBuilder2
//
//  Created by Simon Bruce-Cassidy on 31/03/2023.
//

import SwiftUI

struct ConnectionRow: View {
    let connection: Connection
    let isSelected: Bool
    
    var body: some View {
        Text(connection.name)
            .background(isSelected ? Color.blue.opacity(0.3) : Color.clear)
            .cornerRadius(5)
    }
}
