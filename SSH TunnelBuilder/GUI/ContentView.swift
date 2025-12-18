import SwiftUI

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
        .alert(item: $connectionStore.errorAlert) { errorAlert in
            Alert(
                title: Text("Error"),
                message: Text(errorAlert.message),
                dismissButton: .default(Text("OK"))
            )
        }
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

enum ConnectionState {
    case connected
    case disconnected
    case connecting
}

enum MainViewMode {
    case create
    case edit
    case view
    case loading
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView(connectionStore: ConnectionStore())
    }
}
