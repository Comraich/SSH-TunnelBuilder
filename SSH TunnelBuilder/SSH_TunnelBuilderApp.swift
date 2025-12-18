import SwiftUI

@main
struct SSH_TunnelBuilderApp: App {
    @StateObject private var connectionStore = ConnectionStore()

    var body: some Scene {
        WindowGroup {
            ContentView(connectionStore: connectionStore)
        }
    }
}
