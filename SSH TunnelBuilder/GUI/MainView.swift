import SwiftUI
#if os(macOS)
import AppKit
#endif

// A reusable view for displaying a shell command with a copy button.
struct CommandHelpRow: View {
    let title: String
    let command: String

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.subheadline)
                Text(command)
                    .font(.body.monospaced())
            }
            Spacer(minLength: 8)
            Button("Copy") { copyToClipboard(command) }
        }
    }
    
    private func copyToClipboard(_ text: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #endif
    }
}

// A view that switches between a Text label and a TextField/SecureField
// based on the current MainViewMode.
struct EditableFieldView: View {
    let value: Binding<String>
    let placeholder: String
    let isSecure: Bool
    
    @EnvironmentObject private var connectionStore: ConnectionStore

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

// A self-contained view for showing PEM private key status and warnings.
struct PEMKeyInfoView: View {
    enum KeyKind { case pkcs8, ec, rsa, openssh, dsa, ed25519, unknown }

    @Binding var keyText: String
    
    private var trimmedKey: String { keyText.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var kind: KeyKind { detectKeyKind(trimmedKey) }
    private var isEncrypted: Bool { isPEMEncrypted(trimmedKey) }
    private var isSupported: Bool { kind == .pkcs8 || kind == .ec }
    
    var body: some View {
        if !trimmedKey.isEmpty {
            keyStatusView
            
            if !isEncrypted {
                unencryptedKeyWarning
            }
            
            if kind == .openssh || kind == .ed25519 {
                unsupportedKeyHelp
            }
        }
    }

    @ViewBuilder
    private var keyStatusView: some View {
        HStack(spacing: 6) {
            Image(systemName: isSupported ? "checkmark.circle" : "exclamationmark.triangle")
                .foregroundColor(isSupported ? .green : .orange)
            Text("Detected key: \(keyKindDescription(kind))")
                .foregroundColor(isSupported ? .green : .orange)
                .font(.footnote)
        }
    }
    
    @ViewBuilder
    private var unencryptedKeyWarning: some View {
        HStack(spacing: 6) {
            Image(systemName: "lock.open")
                .foregroundColor(.orange)
            Text("Warning: Key appears unencrypted. Prefer an encrypted PEM (PKCS#8) with a passphrase.")
                .foregroundColor(.orange)
                .font(.footnote)
        }
    }
    
    @ViewBuilder
    private var unsupportedKeyHelp: some View {
        VStack(alignment: .leading) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "lightbulb")
                    .foregroundColor(.yellow)
                Text("Detected OpenSSH/Ed25519 key. For this release, generate an ECDSA key:")
                    .font(.footnote)
                Spacer(minLength: 8)
            }
            HStack(alignment: .firstTextBaseline) {
                let genCmd = "ssh-keygen -t ecdsa -b 256 -m PEM -f ~/.ssh/id_ecdsa"
                Text(genCmd)
                    .font(.body.monospaced())
                Spacer(minLength: 8)
                Button("Copy") { copyToClipboard(genCmd) }
            }
        }
    }
    
    private func keyKindDescription(_ kind: KeyKind) -> String {
        switch kind {
        case .pkcs8: return "PKCS#8 PRIVATE KEY"
        case .ec: return "EC PRIVATE KEY (ECDSA)"
        case .rsa: return "RSA PRIVATE KEY"
        case .openssh: return "OPENSSH PRIVATE KEY"
        case .dsa: return "DSA PRIVATE KEY"
        case .ed25519: return "ED25519 PRIVATE KEY"
        case .unknown: return "Unknown"
        }
    }

    private func detectKeyKind(_ text: String) -> KeyKind {
        let t = text.uppercased()
        if t.contains("-----BEGIN ENCRYPTED PRIVATE KEY-----") { return .pkcs8 }
        if t.contains("-----BEGIN PRIVATE KEY-----") { return .pkcs8 }
        if t.contains("-----BEGIN EC PRIVATE KEY-----") { return .ec }
        if t.contains("-----BEGIN RSA PRIVATE KEY-----") { return .rsa }
        if t.contains("-----BEGIN OPENSSH PRIVATE KEY-----") { return .openssh }
        if t.contains("-----BEGIN DSA PRIVATE KEY-----") { return .dsa }
        if t.contains("ED25519 PRIVATE KEY") { return .ed25519 }
        return .unknown
    }

    private func isPEMEncrypted(_ text: String) -> Bool {
        let t = text.uppercased()
        if t.contains("-----BEGIN ENCRYPTED PRIVATE KEY-----") { return true }
        if t.contains("PROC-TYPE: 4,ENCRYPTED") { return true }
        if t.contains("DEK-INFO:") { return true }
        return false
    }
    
    private func copyToClipboard(_ text: String) {
        #if os(macOS)
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        #endif
    }
}

struct MainView: View {
    @EnvironmentObject var connectionStore: ConnectionStore
    
    @Binding var selectedConnection: Connection?
        
    var body: some View {
        if connectionStore.mode == .loading {
            Text("Loading connections...")
                .font(.largeTitle)
                .padding()
        } else {
            VStack {
                connectionNameRow(label: "Connection Name:", value: connectionNameBinding)
                    .padding()
                
                if let notice = connectionStore.migrationNotice {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "info.circle")
                            .foregroundColor(.blue)
                        Text(notice)
                            .foregroundColor(.primary)
                        Spacer()
                        Button(action: { connectionStore.migrationNotice = nil }) {
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
                
                if let cloud = connectionStore.cloudNotice {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "info.circle")
                            .foregroundColor(.blue)
                        Text(cloud)
                            .foregroundColor(.primary)
                        Spacer()
                        Button(action: { connectionStore.cloudNotice = nil }) {
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
                
                HStack {
                    if connectionStore.mode == .view, let connection = selectedConnection {
                        Text("Connection Status:")
                        Spacer()
                        ConnectionIndicatorView(connection: connection)
                            .padding(.trailing)
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
                                .environmentObject(connectionStore)
                                .padding()
                        } else {
                            Button(action: {
                                if connectionStore.mode == .create {
                                    let connectionInfo = ConnectionInfo(name: connectionStore.connectionName, serverAddress: connectionStore.serverAddress, portNumber: connectionStore.portNumber, username: connectionStore.username, password: connectionStore.password, privateKey: connectionStore.privateKey)
                                    let tunnelInfo = TunnelInfo(localPort: connectionStore.localPort, remoteServer: connectionStore.remoteServer, remotePort: connectionStore.remotePort)
                                    connectionStore.newConnection(connectionInfo: connectionInfo, tunnelInfo: tunnelInfo)
                                    connectionStore.clearCreateForm()
                                    connectionStore.mode = .view
                                } else if connectionStore.mode == .edit {
                                    if let tempConnection = connectionStore.tempConnection {
                                        connectionStore.saveConnection(tempConnection, connectionToUpdate: selectedConnection)
                                        selectedConnection = tempConnection
                                        connectionStore.mode = .view
                                    }
                                }
                            }) {
                                Text(connectionStore.mode == .create ? "Create" : "Save")
                            }
                            .padding()
                        }
                    }
                    .padding(.bottom)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .toolbar {
                ToolbarItemGroup {
                    if connectionStore.mode == .create || connectionStore.mode == .edit {
                        Button(action: {
                            connectionStore.mode = .view
                            if connectionStore.mode == .create {
                                connectionStore.clearCreateForm()
                            }
                            if selectedConnection == nil {
                                selectedConnection = connectionStore.connections.first
                            }
                        }) {
                            Text("Cancel")
                        }
                    }
                }
            }
        }
    }
    
    // MARK: - Binding Helper

    private func formBinding(
        createKeyPath: WritableKeyPath<ConnectionStore, String>,
        editConnectionInfoKeyPath: WritableKeyPath<ConnectionInfo, String>? = nil,
        editTunnelInfoKeyPath: WritableKeyPath<TunnelInfo, String>? = nil,
        viewConnectionInfoKeyPath: KeyPath<ConnectionInfo, String>? = nil,
        viewTunnelInfoKeyPath: KeyPath<TunnelInfo, String>? = nil
    ) -> Binding<String> {
        switch connectionStore.mode {
        case .create:
            return $connectionStore[dynamicMember: createKeyPath]
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
    
    // MARK: - Views

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

    func changeMode(to newMode: MainViewMode) {
        connectionStore.mode = newMode
    } 
}

struct ConnectionIndicatorView: View {
    @ObservedObject var connection: Connection

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(connection.isActive ? Color.green : Color.red)
                .frame(width: 10, height: 10)
            Text(connection.isActive ? "Connected" : "Disconnected")
        }
    }
}

struct ConnectButtonView: View {
    @ObservedObject var connection: Connection
    @EnvironmentObject var connectionStore: ConnectionStore
    @State private var showCredentialsSheet: Bool = false
    @State private var tempPassword: String = ""
    @State private var tempPrivateKey: String = ""
    @State private var saveCredentials: Bool = false
    @State private var pemError: String? = nil
    @State private var showKeyInfo: Bool = false
    @AppStorage("KeyInfoPopoverDismissed") private var keyInfoPopoverDismissed: Bool = false

    var body: some View {
        Button(action: {
            if connection.isActive {
                connectionStore.disconnect(connection)
            } else {
                let hasPassword = !connection.connectionInfo.password.isEmpty
                let hasKey = !connection.connectionInfo.privateKey.isEmpty
                if !(hasPassword || hasKey) {
                    showCredentialsSheet = true
                    return
                }
                connectionStore.connect(connection)
            }
        }) {
            Text(connection.isActive ? "Disconnect" : "Connect")
        }
        .sheet(isPresented: $showCredentialsSheet) {
            HStack {
                Spacer()
                VStack(alignment: .leading, spacing: 16) {
                    Text("Enter Credentials")
                        .font(.title2).bold()

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Password")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                        SecureField("Enter password", text: $tempPassword)
                            .textFieldStyle(RoundedBorderTextFieldStyle())
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 6) {
                            Text("Private Key (PEM)")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                            Button(action: { if !keyInfoPopoverDismissed { showKeyInfo.toggle() } }) {
                                Image(systemName: "info.circle")
                            }
                            .buttonStyle(.plain)
                            .help("Key format help")
                            .popover(isPresented: $showKeyInfo) {
                                VStack(alignment: .leading, spacing: 10) {
                                    Text("Key format help")
                                        .font(.headline)

                                    Text("Supported:")
                                        .font(.subheadline)
                                    Text("• ECDSA P-256/P-384/P-521 in PEM (EC PRIVATE KEY) or PKCS#8 (PRIVATE KEY)")
                                        .font(.footnote)

                                    Text("Not supported in this build:")
                                        .font(.subheadline)
                                    Text("• OpenSSH Ed25519, RSA, DSA")
                                        .font(.footnote)

                                    Divider()
                                    CommandHelpRow(
                                        title: "Generate an ECDSA key (recommended):",
                                        command: "ssh-keygen -t ecdsa -b 256 -m PEM -f ~/.ssh/id_ecdsa"
                                    )

                                    Divider()
                                    CommandHelpRow(
                                        title: "Encrypt an existing PEM key with a passphrase (PKCS#8):",
                                        command: "openssl pkcs8 -topk8 -v2 aes-256-cbc -in id_ecdsa -out id_ecdsa_encrypted.pem"
                                    )

                                    Divider()
                                    Text("If you currently have an OpenSSH Ed25519 key, generate an ECDSA key for this release.")
                                        .font(.footnote)
                                        .foregroundColor(.secondary)

                                    Toggle("Don't show again", isOn: $keyInfoPopoverDismissed)
                                        .toggleStyle(.checkbox)
                                }
                                .padding(14)
                                .frame(minWidth: 480)
                            }
                        }
                        TextEditor(text: $tempPrivateKey)
                            .frame(minHeight: 140)
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(Color.secondary.opacity(0.2))
                            )
                            .font(.body.monospaced())
                            .accessibilityLabel("Private Key (PEM)")
                    }
                    
                    PEMKeyInfoView(keyText: $tempPrivateKey)
                    
                    if let pemError = pemError {
                        Text(pemError)
                            .foregroundColor(.red)
                            .font(.footnote)
                    }

                    Toggle("Save credentials to this connection", isOn: $saveCredentials)

                    Text("Provide either a password or a private key (PEM). If you choose not to save, the credentials will be used for this session only.")
                        .font(.footnote)
                        .foregroundColor(.secondary)

                    HStack {
                        Spacer()
                        Button("Cancel") { showCredentialsSheet = false }
                        Button("Connect") {
                            // Logic to validate and connect...
                            handleConnect()
                        }
                        .keyboardShortcut(.defaultAction)
                    }
                }
                .padding(20)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color(.windowBackgroundColor))
                )
                .shadow(radius: 12)
                .frame(maxWidth: 560)
                Spacer()
            }
            .frame(minWidth: 480, minHeight: 420)
#if os(macOS)
            .presentationSizing(.fitted)
#endif
        }
    }
    
    private func handleConnect() {
        let providedPassword = !tempPassword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let providedKey = !tempPrivateKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        guard providedPassword || providedKey else { return }

        pemError = nil
        
        if providedKey {
            if !isValidPEMPrivateKey(tempPrivateKey) {
                pemError = "Invalid private key format. Supported: OPENSSH, RSA, EC, DSA, or PKCS#8 PRIVATE KEY."
                return
            }
            let keyKind = detectKeyKind(tempPrivateKey)
            if !(keyKind == .pkcs8 || keyKind == .ec) {
                pemError = "Unsupported private key type (\(keyKindDescription(keyKind))). Supported: ECDSA (EC PRIVATE KEY) or PKCS#8 PRIVATE KEY."
                return
            }
        }
        
        if providedPassword { connection.connectionInfo.password = tempPassword }
        if providedKey { connection.connectionInfo.privateKey = tempPrivateKey }

        if providedPassword && !providedKey { connection.connectionInfo.privateKey = "" }
        if providedKey && !providedPassword { connection.connectionInfo.password = "" }

        if saveCredentials {
            connectionStore.saveConnection(connection, connectionToUpdate: connection)
        }

        connectionStore.connect(connection)
        showCredentialsSheet = false
        tempPassword = ""
        tempPrivateKey = ""
        saveCredentials = false
    }

    private func isValidPEMPrivateKey(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let tokens = ["OPENSSH PRIVATE KEY", "RSA PRIVATE KEY", "EC PRIVATE KEY", "DSA PRIVATE KEY", "ED25519 PRIVATE KEY", "PRIVATE KEY"]
        return tokens.contains { trimmed.contains("-----BEGIN \($0)-----") && trimmed.contains("-----END \($0)-----") }
    }
    
    // Minimal detectors needed for validation logic in handleConnect
    private enum KeyKind { case pkcs8, ec, other }
    private func detectKeyKind(_ text: String) -> KeyKind {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if t.contains("PRIVATE KEY") { return .pkcs8 } // Catches PKCS#8 and ENCRYPTED PKCS#8
        if t.contains("EC PRIVATE KEY") { return .ec }
        return .other
    }
    private func keyKindDescription(_ kind: PEMKeyInfoView.KeyKind) -> String {
        switch kind {
        case .pkcs8: return "PKCS#8"
        case .ec: return "EC"
        default: return "Unsupported"
        }
    }
}

struct ConnectionEnvironmentKey: EnvironmentKey {
    static var defaultValue: Connection?
}

extension EnvironmentValues {
    var connection: Connection? {
        get { self[ConnectionEnvironmentKey.self] }
        set { self[ConnectionEnvironmentKey.self] = newValue }
    }
}
