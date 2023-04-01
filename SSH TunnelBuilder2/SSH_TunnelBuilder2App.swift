//
//  SSH_TunnelBuilder2App.swift
//  SSH TunnelBuilder2
//
//  Created by Simon Bruce-Cassidy on 14/03/2022.
//

import SwiftUI

@main
struct SSH_TunnelBuilder2App: App {
    @StateObject private var connectionStore = ConnectionStore()

    var body: some Scene {
        WindowGroup {
            ContentView(connectionStore: connectionStore)
        }
    }
}

