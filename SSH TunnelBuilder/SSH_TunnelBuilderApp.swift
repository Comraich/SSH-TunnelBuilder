import SwiftUI

@main
struct SSH_TunnelBuilderApp: App {
    @State private var connectionStore: ConnectionStore
    @State private var trafficMonitor: MenuBarTrafficMonitor

    init() {
        let store = ConnectionStore()
        let monitor = MenuBarTrafficMonitor(store: store)
        monitor.start()
        _connectionStore = State(initialValue: store)
        _trafficMonitor = State(initialValue: monitor)
    }

    var body: some Scene {
        WindowGroup {
            ContentView(connectionStore: connectionStore)
        }
        .commands {
            AppCommands(store: connectionStore)
        }

        Settings {
            SettingsView()
                .environment(connectionStore)
        }

        // Menu bar traffic indicator. Only inserted while a tunnel is connected.
        // `hasActiveConnection` must be read here, directly in the scene body, so
        // Observation registers the dependency and re-evaluates the scene when it
        // flips — reading it inside the binding's deferred get closure would never
        // establish that dependency, so the item would never appear. `.constant`
        // is fine because visibility is driven by the monitor, not user action.
        MenuBarExtra(isInserted: .constant(trafficMonitor.hasActiveConnection)) {
            MenuBarTrafficContent(store: connectionStore)
        } label: {
            MenuBarTrafficLabel(monitor: trafficMonitor)
        }
    }
}
