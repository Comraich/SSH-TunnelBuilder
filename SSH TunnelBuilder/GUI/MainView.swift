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
            Group {
                if isSecure {
                    SecureField(placeholder, text: value)
                } else {
                    TextField(placeholder, text: value)
                }
            }
            .textFieldStyle(RoundedBorderTextFieldStyle())
        }
    }
}

// MARK: - Main View

struct MainView: View {
    @Environment(ConnectionStore.self) var connectionStore

    @Binding var selectedConnection: Connection?

    var body: some View {
        if connectionStore.mode == .loading {
            loadingView
        } else if connectionStore.mode == .view && selectedConnection == nil {
            emptySelectionView
        } else {
            VStack {
                connectionNameRow(label: "Connection Name:", value: connectionNameBinding)
                    .padding()

                if let notice = connectionStore.migrationNotice {
                    noticeBanner(notice) { connectionStore.migrationNotice = nil }
                }

                if let cloud = connectionStore.cloudNotice {
                    noticeBanner(cloud) { connectionStore.cloudNotice = nil }
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

    private var passwordBinding: Binding<String> {
        formBinding(
            createKeyPath: \.password,
            editConnectionInfoKeyPath: \.password,
            viewConnectionInfoKeyPath: \.password
        )
    }

    private var privateKeyBinding: Binding<String> {
        formBinding(
            createKeyPath: \.privateKey,
            editConnectionInfoKeyPath: \.privateKey,
            viewConnectionInfoKeyPath: \.privateKey
        )
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

    /// A dismissable blue information banner (migration / CloudKit notices).
    private func noticeBanner(_ message: String, onDismiss: @escaping () -> Void) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "info.circle")
                .foregroundColor(.blue)
            Text(message)
                .foregroundColor(.primary)
            Spacer()
            Button(action: onDismiss) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(8)
        .background(Color.blue.opacity(0.1))
        .cornerRadius(8)
        .padding([.horizontal, .top])
    }

    // MARK: - Helper Views

    private var loadingView: some View {
        VStack(spacing: 16) {
            ProgressView()
                .scaleEffect(1.5)
            Text("Loading connections...")
                .font(.title2)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptySelectionView: some View {
        VStack(spacing: 20) {
            Image(systemName: "network")
                .font(.system(size: 60))
                .foregroundColor(.secondary)

            Text("No Connection Selected")
                .font(.title)
                .fontWeight(.semibold)

            Text("Select a connection from the sidebar or create a new one")
                .font(.body)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)

            if connectionStore.connections.isEmpty {
                Button(action: {
                    connectionStore.mode = .create
                }) {
                    Label("Create Connection", systemImage: "plus.circle.fill")
                        .font(.headline)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 10)
                        .background(Color.accentColor)
                        .foregroundColor(.white)
                        .cornerRadius(8)
                }
                .buttonStyle(.plain)
                .padding(.top, 8)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}
