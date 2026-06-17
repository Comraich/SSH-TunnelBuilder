// Copyright 2020-2026 Comraich ANS
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

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
                Text("When enabled, using a saved password or private key requires a single Touch ID / login-password prompt per session — connecting, editing, and exporting are all covered by the same authentication for the duration of the grace window below. Your secrets stay on this Mac and never leave the Keychain.")
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
            // The toggle now governs *only* the app-side `evaluatePolicy` gate
            // — Keychain items are no longer stamped with `.userPresence`. We
            // still run a one-pass migration so any pre-existing protected
            // items from older app versions are re-saved without the flag, so
            // future connects honour the single-prompt-per-grace-window model.
            connectionStore.reprotectStoredCredentials(enabled: isOn)
        }
    }
}

#Preview {
    SettingsView()
        .environment(ConnectionStore(mode: .view, connections: SampleData.connections))
}
