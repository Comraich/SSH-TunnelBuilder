//
//  DataCounterView.swift
//  SSH TunnelBuilder
//
//  Created by Simon Bruce-Cassidy on 10/04/2023.
//

import Foundation
import SwiftUI

struct DataCounterView: View {
    @ObservedObject var connection: Connection

    var body: some View {
        VStack {
            HStack {
                VStack(alignment: .leading) {
                    Text("Data Sent: \(byteCountFormatter.string(fromByteCount: connection.bytesSent))")
                    Text("Data Received: \(byteCountFormatter.string(fromByteCount: connection.bytesReceived))")
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

    private var byteCountFormatter: ByteCountFormatter {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter
    }
}

