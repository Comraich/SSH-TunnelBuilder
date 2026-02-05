import SwiftUI

// MARK: - Reusable Error Alert Modifier

extension View {
    func errorAlert(_ errorAlert: Binding<ErrorAlert?>) -> some View {
        self.alert(item: errorAlert) { error in
            Alert(
                title: Text("Error"),
                message: Text(error.message),
                dismissButton: .default(Text("OK"))
            )
        }
    }
}

struct ContentView: View {
    @StateObject var connectionStore: ConnectionStore
    @State private var selectedConnection: Connection?
    
    init(connectionStore: ConnectionStore) {
        _connectionStore = StateObject(wrappedValue: connectionStore)
    }
    
    var body: some View {
        NavigationSplitView {
            NavigationList(
                connectionStore: connectionStore,
                selectedConnection: $selectedConnection,
                mode: $connectionStore.mode
            )
            .environmentObject(connectionStore)
            .accessibilityIdentifier("NavigationList")
        } detail: {
            MainView(selectedConnection: $selectedConnection)
                .environmentObject(connectionStore)
                .accessibilityIdentifier("MainView")
        }
        .errorAlert($connectionStore.errorAlert)
        .alert(item: $connectionStore.hostKeyRequest) { request in
            Alert(
                title: Text("Unknown Host"),
                message: Text("The host '\(request.hostname)' is unknown.\n\nFingerprint:\n\(request.fingerprint)\n\nDo you want to trust this host?"),
                primaryButton: .default(Text("Trust")) {
                    request.completion(true)
                },
                secondaryButton: .cancel(Text("Cancel")) {
                    request.completion(false)
                }
            )
        }
    }
}

// Moved to ConnectionStore.swift as it's used there primarily

#Preview("Empty State") {
    ContentView(connectionStore: ConnectionStore())
}
#Preview("With Connections") {
    ContentView(connectionStore: ConnectionStore.mockWithSampleData())
}

