import SwiftUI

struct ContentView: View {
    @StateObject var connectionStore: ConnectionStore
    @State private var selectedConnection: Connection?
    @State private var showingErrorSheet = false
    @State private var errorMessage = ""

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
        .onChange(of: connectionStore.errorAlert) { _, newValue in
            if let error = newValue {
                errorMessage = error.message
                showingErrorSheet = true
                // Clear the error after capturing it
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(100))
                    connectionStore.errorAlert = nil
                }
            }
        }
        .sheet(isPresented: $showingErrorSheet) {
            ErrorSheetView(message: errorMessage, isPresented: $showingErrorSheet)
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

// MARK: - Error Sheet View

struct ErrorSheetView: View {
    let message: String
    @Binding var isPresented: Bool

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 50))
                .foregroundColor(.red)

            Text("Error")
                .font(.title)
                .fontWeight(.bold)

            Text(message)
                .font(.body)
                .multilineTextAlignment(.center)
                .padding()

            Button("OK") {
                isPresented = false
            }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.borderedProminent)
        }
        .padding(30)
        .frame(minWidth: 400, minHeight: 250)
    }
}

// Moved to ConnectionStore.swift as it's used there primarily

#Preview("Empty State") {
    ContentView(connectionStore: ConnectionStore(mode: .view, connections: []))
}

#Preview("With Connections") {
    ContentView(connectionStore: ConnectionStore(mode: .view, connections: SampleData.connections))
}

