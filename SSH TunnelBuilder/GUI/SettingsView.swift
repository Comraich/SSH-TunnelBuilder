import SwiftUI

/// App preferences (opened with ⌘,). Hosts the opt-in Spotlight indexing
/// control and the optional Touch ID / password protection for credentials.
struct SettingsView: View {
    @Environment(ConnectionStore.self) private var connectionStore
    @AppStorage(SpotlightIndexer.enabledDefaultsKey) private var spotlightEnabled = false
    @AppStorage(KeychainService.protectionEnabledKey) private var requireAuthForCredentials = false
    @AppStorage(ConnectionStore.credentialGraceSecondsKey) private var credentialGraceSeconds = 300.0

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

            Section {
                Toggle("Require Touch ID or password to use saved credentials", isOn: $requireAuthForCredentials)
                Text("When enabled, your saved passwords and private keys are stored so that connecting (or editing a connection) requires Touch ID or your login password. This adds a layer of protection if someone gains access to your unlocked Mac, at the cost of an authentication prompt each time you connect.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if requireAuthForCredentials {
                    Picker("Remember authentication", selection: $credentialGraceSeconds) {
                        Text("Ask every time").tag(0.0)
                        Text("For 5 minutes").tag(300.0)
                        Text("For 15 minutes").tag(900.0)
                        Text("For 30 minutes").tag(1800.0)
                        Text("For 1 hour").tag(3600.0)
                    }
                    Text("How long a single authentication is remembered. Within this window, reconnecting won't ask again.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } header: {
                Text("Security")
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
        .onChange(of: requireAuthForCredentials) { _, isOn in
            // The preference (read by KeychainService when saving) is already
            // updated by @AppStorage; re-key the existing stored credentials so
            // the new protection applies to them too. Disabling prompts once to
            // read the currently protected items.
            connectionStore.reprotectStoredCredentials(enabled: isOn)
        }
    }
}

#Preview {
    SettingsView()
        .environment(ConnectionStore(mode: .view, connections: SampleData.connections))
}
