// Copyright 2020-2026 Comraich ANS
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

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
                // The connecting spinner lives in ConnectionIndicatorView (the
                // status row), so it is intentionally not duplicated here.
            }
        }
    }
}

