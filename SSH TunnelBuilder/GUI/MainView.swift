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
#if os(macOS)
import AppKit
#endif

// MARK: - Editable Field View

/// A field that renders as plain text in `.view` mode and an editable
/// `TextField`/`SecureField` otherwise.
struct EditableFieldView: View {
    let value: Binding<String>
    let placeholder: String
    let isSecure: Bool

    @Environment(ConnectionStore.self) private var connectionStore

    init(value: Binding<String>, placeholder: String, isSecure: Bool = false) {
        self.value = value
        self.placeholder = placeholder
        self.isSecure = isSecure
    }

    var body: some View {
        if connectionStore.mode == .view {
            if isSecure {
                Text(value.wrappedValue.isEmpty ? "" : "<obfuscated>")
            } else {
                Text(value.wrappedValue)
            }
        } else {
            // Group wraps an if/else (`_ConditionalContent`), so the shared
            // text-field style applies to both branches — not the single-child
            // Group anti-pattern.
            Group {
                if isSecure {
                    SecureField(placeholder, text: value)
                } else {
                    TextField(placeholder, text: value)
                }
            }
            .textFieldStyle(.roundedBorder)
        }
    }
}

// MARK: - Main View

/// Thin dispatcher: picks the section view for the current mode/selection.
/// Each section is its own `View` type so it forms its own invalidation
/// boundary rather than sharing one large body.
struct MainView: View {
    @Environment(ConnectionStore.self) var connectionStore

    @Binding var selectedConnection: Connection?

    var body: some View {
        if connectionStore.mode == .loading {
            LoadingView()
        } else if connectionStore.mode == .view && selectedConnection == nil {
            EmptySelectionView()
        } else {
            ConnectionDetailView(selectedConnection: $selectedConnection)
        }
    }
}

// MARK: - Loading View

struct LoadingView: View {
    var body: some View {
        VStack(spacing: 16) {
            ProgressView()
                .scaleEffect(1.5)
            Text("Loading connections...")
                .font(.title2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Empty Selection View

struct EmptySelectionView: View {
    @Environment(ConnectionStore.self) private var connectionStore

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "network")
                .font(.system(size: 60))
                .foregroundStyle(.secondary)

            Text("No Connection Selected")
                .font(.title)
                .fontWeight(.semibold)

            Text("Select a connection from the sidebar or create a new one")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            if connectionStore.connections.isEmpty {
                Button {
                    connectionStore.mode = .create
                } label: {
                    Label("Create Connection", systemImage: "plus.circle.fill")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .padding(.top, 8)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}

// MARK: - Notice Banner

/// A dismissable blue information banner (migration / CloudKit notices).
struct NoticeBanner: View {
    let message: String
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "info.circle")
                .foregroundStyle(.blue)
            Text(message)
                .foregroundStyle(.primary)
            Spacer()
            Button(action: onDismiss) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss notice")
        }
        .padding(8)
        .background(Color.blue.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .padding([.horizontal, .top])
    }
}

// MARK: - Connection Detail View

/// The detail pane for the create / edit / view modes: the name header, any
/// notices, the live status + data counters (view mode), and the field form.
struct ConnectionDetailView: View {
    @Environment(ConnectionStore.self) private var connectionStore

    @Binding var selectedConnection: Connection?

    var body: some View {
        VStack {
            connectionNameRow(label: "Connection Name:", value: connectionNameBinding)
                .padding()

            if let notice = connectionStore.migrationNotice {
                NoticeBanner(message: notice) { connectionStore.migrationNotice = nil }
            }

            if let cloud = connectionStore.cloudNotice {
                NoticeBanner(message: cloud) { connectionStore.cloudNotice = nil }
            }

            HStack(alignment: .firstTextBaseline) {
                if connectionStore.mode == .view, let connection = selectedConnection {
                    Text("Connection Status:")
                        .frame(maxWidth: .infinity, alignment: .leading)
                    ConnectionIndicatorView(connection: connection)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .padding(.trailing)
                } else {
                    // Maintain spacing when no connection is selected
                    Color.clear.frame(maxWidth: .infinity)
                    Color.clear.frame(maxWidth: .infinity)
                }
            }
            .padding(.horizontal)

            if connectionStore.mode == .view {
                if let connection = selectedConnection {
                    DataCounterView(connection: connection)
                        .padding()
                } else {
                    Text("")
                }
                Spacer()
            }

            connectionForm
        }
        .toolbar {
            ToolbarItemGroup {
                if connectionStore.mode == .create || connectionStore.mode == .edit {
                    Button("Cancel") {
                        // Clear the create form before leaving create mode —
                        // checking after setting `.view` would always be false.
                        if connectionStore.mode == .create {
                            connectionStore.clearCreateForm()
                        }
                        connectionStore.mode = .view
                        if selectedConnection == nil {
                            selectedConnection = connectionStore.connections.first
                        }
                    }
                }
            }
        }
    }

    // MARK: - Form

    private var connectionForm: some View {
        VStack(alignment: .leading) {
            Group {
                infoRow(label: "Server Address:", value: serverAddressBinding)
                infoRow(label: "Port Number:", value: portNumberBinding)
                infoRow(label: "User Name:", value: usernameBinding)
                infoRow(label: "Password:", value: passwordBinding, isSecure: true)
                infoRow(label: "Private Key:", value: privateKeyBinding, isSecure: true)
                infoRow(label: "Local Port:", value: localPortBinding)
                infoRow(label: "Remote Server:", value: remoteServerBinding)
                infoRow(label: "Remote Port:", value: remotePortBinding)
            }

            HStack {
                if connectionStore.mode == .view, let connection = selectedConnection {
                    ConnectButtonView(connection: connection)
                        .environment(connectionStore)
                        .padding()
                } else {
                    Button(connectionStore.mode == .create ? "Create" : "Save") {
                        saveForm()
                    }
                    .padding()
                }
            }
            .padding(.bottom)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Commits the create/edit form back to the store.
    private func saveForm() {
        switch connectionStore.mode {
        case .create:
            let connectionInfo = ConnectionInfo(
                name: connectionStore.connectionName,
                serverAddress: connectionStore.serverAddress,
                portNumber: connectionStore.portNumber,
                username: connectionStore.username,
                password: connectionStore.password,
                privateKey: connectionStore.privateKey,
                privateKeyPassphrase: ""
            )
            let tunnelInfo = TunnelInfo(
                localPort: connectionStore.localPort,
                remoteServer: connectionStore.remoteServer,
                remotePort: connectionStore.remotePort
            )
            connectionStore.newConnection(connectionInfo: connectionInfo, tunnelInfo: tunnelInfo)
            connectionStore.clearCreateForm()
            connectionStore.mode = .view
        case .edit:
            if let tempConnection = connectionStore.tempConnection {
                connectionStore.saveConnection(tempConnection, connectionToUpdate: selectedConnection)
                selectedConnection = tempConnection
                connectionStore.mode = .view
            }
        case .view, .loading:
            break
        }
    }

    // MARK: - Binding Helper

    private func formBinding(
        createKeyPath: ReferenceWritableKeyPath<ConnectionStore, String>,
        editConnectionInfoKeyPath: WritableKeyPath<ConnectionInfo, String>? = nil,
        editTunnelInfoKeyPath: WritableKeyPath<TunnelInfo, String>? = nil,
        viewConnectionInfoKeyPath: KeyPath<ConnectionInfo, String>? = nil,
        viewTunnelInfoKeyPath: KeyPath<TunnelInfo, String>? = nil
    ) -> Binding<String> {
        switch connectionStore.mode {
        case .create:
            return Binding(
                get: { connectionStore[keyPath: createKeyPath] },
                set: { connectionStore[keyPath: createKeyPath] = $0 }
            )
        case .edit:
            return Binding(
                get: {
                    if let keyPath = editConnectionInfoKeyPath {
                        return connectionStore.tempConnection?.connectionInfo[keyPath: keyPath] ?? ""
                    }
                    if let keyPath = editTunnelInfoKeyPath {
                        return connectionStore.tempConnection?.tunnelInfo[keyPath: keyPath] ?? ""
                    }
                    return ""
                },
                set: { newValue in
                    if let keyPath = editConnectionInfoKeyPath {
                        connectionStore.tempConnection?.connectionInfo[keyPath: keyPath] = newValue
                    }
                    if let keyPath = editTunnelInfoKeyPath {
                        connectionStore.tempConnection?.tunnelInfo[keyPath: keyPath] = newValue
                    }
                }
            )
        default: // .view, .loading
            let value = {
                if let keyPath = viewConnectionInfoKeyPath {
                    return selectedConnection?.connectionInfo[keyPath: keyPath] ?? ""
                }
                if let keyPath = viewTunnelInfoKeyPath {
                    return selectedConnection?.tunnelInfo[keyPath: keyPath] ?? ""
                }
                return ""
            }()
            return .constant(value)
        }
    }

    // MARK: - Bindings

    private var connectionNameBinding: Binding<String> {
        formBinding(
            createKeyPath: \.connectionName,
            editConnectionInfoKeyPath: \.name,
            viewConnectionInfoKeyPath: \.name
        )
    }

    private var serverAddressBinding: Binding<String> {
        formBinding(
            createKeyPath: \.serverAddress,
            editConnectionInfoKeyPath: \.serverAddress,
            viewConnectionInfoKeyPath: \.serverAddress
        )
    }

    private var portNumberBinding: Binding<String> {
        formBinding(
            createKeyPath: \.portNumber,
            editConnectionInfoKeyPath: \.portNumber,
            viewConnectionInfoKeyPath: \.portNumber
        )
    }

    private var usernameBinding: Binding<String> {
        formBinding(
            createKeyPath: \.username,
            editConnectionInfoKeyPath: \.username,
            viewConnectionInfoKeyPath: \.username
        )
    }

    // Secrets aren't loaded into the model at rest, so in `.view` mode these
    // bindings reflect Keychain *existence* (so the "<obfuscated>" indicator
    // still appears) rather than the model's empty value. Create/edit modes
    // use the real value as before (edit hydrates its temp copy).
    private var passwordBinding: Binding<String> {
        if connectionStore.mode == .view {
            return secretViewBinding(exists: selectedConnection.map { connectionStore.hasStoredPassword($0) } ?? false)
        }
        return formBinding(createKeyPath: \.password, editConnectionInfoKeyPath: \.password)
    }

    private var privateKeyBinding: Binding<String> {
        if connectionStore.mode == .view {
            return secretViewBinding(exists: selectedConnection.map { connectionStore.hasStoredPrivateKey($0) } ?? false)
        }
        return formBinding(createKeyPath: \.privateKey, editConnectionInfoKeyPath: \.privateKey)
    }

    /// A read-only binding whose value is a non-empty sentinel when a secret
    /// exists. `EditableFieldView` shows "<obfuscated>" for any non-empty secure
    /// value, so this drives the indicator without loading the secret itself.
    private func secretViewBinding(exists: Bool) -> Binding<String> {
        .constant(exists ? "********" : "")
    }

    private var localPortBinding: Binding<String> {
        formBinding(
            createKeyPath: \.localPort,
            editTunnelInfoKeyPath: \.localPort,
            viewTunnelInfoKeyPath: \.localPort
        )
    }

    private var remoteServerBinding: Binding<String> {
        formBinding(
            createKeyPath: \.remoteServer,
            editTunnelInfoKeyPath: \.remoteServer,
            viewTunnelInfoKeyPath: \.remoteServer
        )
    }

    private var remotePortBinding: Binding<String> {
        formBinding(
            createKeyPath: \.remotePort,
            editTunnelInfoKeyPath: \.remotePort,
            viewTunnelInfoKeyPath: \.remotePort
        )
    }

    // MARK: - Row Views

    /// Small repeated fragment within this view's body — a `@ViewBuilder`
    /// helper is appropriate here (not a factored-out section).
    @ViewBuilder
    private func infoRow(label: String, value: Binding<String>, isSecure: Bool = false) -> some View {
        HStack {
            Text(label)
            Spacer()
            EditableFieldView(value: value, placeholder: "Enter \(label.lowercased())", isSecure: isSecure)
        }
        .padding(.horizontal)
    }

    private func connectionNameRow(label: String, value: Binding<String>) -> some View {
        HStack {
            Text(label)
                .font(.largeTitle)
            Spacer()
            EditableFieldView(value: value, placeholder: "Enter connection name")
                .font(.largeTitle)
        }
    }
}
