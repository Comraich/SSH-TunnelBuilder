import SwiftUI

/// App preferences (opened with ⌘,). Currently hosts the opt-in Spotlight
/// indexing control.
struct SettingsView: View {
    @Environment(ConnectionStore.self) private var connectionStore
    @AppStorage(SpotlightIndexer.enabledDefaultsKey) private var spotlightEnabled = false

    var body: some View {
        Form {
            Section {
                Toggle("Show connections in Spotlight", isOn: $spotlightEnabled)
                Text("When enabled, your connection **names** become searchable from system-wide Spotlight so you can jump straight to a connection. Only the name is indexed — never the hostname, username, port, or any credential.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } header: {
                Text("Spotlight")
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .onChange(of: spotlightEnabled) { _, isOn in
            // Bring the index in line with the new preference immediately:
            // donate the current set when turning on, clear it all when off.
            if isOn {
                SpotlightIndexer.indexAll(connectionStore.connections)
            } else {
                SpotlightIndexer.deindexAll()
            }
        }
    }
}

#Preview {
    SettingsView()
        .environment(ConnectionStore(mode: .view, connections: SampleData.connections))
}
