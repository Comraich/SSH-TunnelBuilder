import SwiftUI
import AppKit

@main
struct SSH_TunnelBuilderApp: App {
    // Keeps the app (and any active tunnels) alive after the window is closed,
    // and reopens the window on a dock click. Without this, closing the window
    // terminates the app and tears down every connection — see `AppDelegate`.
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

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
        // Single-instance `Window` (not `WindowGroup`) so SwiftUI auto-adds it
        // to the Window menu — closing the window leaves the entry there, and
        // the user can reopen it from the menu (or the menu bar item, or the
        // dock icon).
        Window("SSH Tunnel Builder", id: "main") {
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

/// Keeps the app running after the user closes the main window so active
/// tunnels survive, and brings the window back on a dock click.
///
/// SwiftUI's `Window` scene treats the close button as "quit the app" by
/// default (unlike `WindowGroup`), which would tear down every tunnel.
/// Returning `false` from `applicationShouldTerminateAfterLastWindowClosed`
/// suppresses that, leaving the dock icon and any active `MenuBarExtra` in
/// place; `applicationShouldHandleReopen` then lets the system perform its
/// standard re-show of the main window when the dock icon is clicked.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        true
    }
}
