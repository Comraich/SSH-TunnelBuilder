import SwiftUI

@main
struct SSH_TunnelBuilderApp: App {
    @State private var connectionStore = ConnectionStore()

    var body: some Scene {
        WindowGroup {
            ContentView(connectionStore: connectionStore)
        }

        Settings {
            SettingsView()
                .environment(connectionStore)
        }
    }
}
