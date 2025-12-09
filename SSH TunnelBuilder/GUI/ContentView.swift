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
