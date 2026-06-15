//
//  DataCounterView.swift
//  SSH TunnelBuilder
//
//  Created by Simon Bruce-Cassidy on 10/04/2023.
//

import Foundation
import SwiftUI

struct DataCounterView: View {
    var connection: Connection

    var body: some View {
        VStack {
            HStack {
                VStack(alignment: .leading) {
                    Text("Data Sent: \(connection.bytesSent.formatted(.byteCount(style: .file)))")
                    Text("Data Received: \(connection.bytesReceived.formatted(.byteCount(style: .file)))")
                }
                Spacer()
                VStack {
                    if connection.isConnecting {
                        ProgressView()
                    }
                }
            }
        }
    }
}

