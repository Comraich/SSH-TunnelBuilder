import SwiftUI
#if os(macOS)
import AppKit
#endif

// MARK: - PEM Key Detection Utilities

/// Represents the different types of PEM-encoded private keys
enum PEMKeyKind {
    case pkcs8        // PKCS#8 format - ECDSA supported (encrypted or unencrypted)
    case ec           // EC PRIVATE KEY - ECDSA supported (unencrypted)
    case rsa          // RSA format - NOT supported
    case openssh      // OpenSSH format - Ed25519/ECDSA supported (unencrypted only)
    case dsa          // DSA format - NOT supported
    case unknown      // Unrecognized format
}

/// Returns a human-readable description of the key type
func keyKindDescription(_ kind: PEMKeyKind) -> String {
    switch kind {
    case .pkcs8: return "PKCS#8 PRIVATE KEY"
    case .ec: return "EC PRIVATE KEY (ECDSA)"
    case .rsa: return "RSA PRIVATE KEY"
    case .openssh: return "OPENSSH PRIVATE KEY (Ed25519/ECDSA)"
    case .dsa: return "DSA PRIVATE KEY"
    case .unknown: return "Unknown"
    }
}

/// Detects the type of PEM private key from its text content
func detectPEMKeyKind(_ text: String) -> PEMKeyKind {
    let t = text.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    if t.contains("-----BEGIN ENCRYPTED PRIVATE KEY-----") { return .pkcs8 }
    if t.contains("-----BEGIN PRIVATE KEY-----") { return .pkcs8 }
    if t.contains("-----BEGIN EC PRIVATE KEY-----") { return .ec }
    if t.contains("-----BEGIN RSA PRIVATE KEY-----") { return .rsa }
    if t.contains("-----BEGIN OPENSSH PRIVATE KEY-----") { return .openssh }
    if t.contains("-----BEGIN DSA PRIVATE KEY-----") { return .dsa }
    return .unknown
}

/// Determines whether a PEM private key is encrypted
func isPEMEncrypted(_ text: String) -> Bool {
    let t = text.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    if t.contains("-----BEGIN ENCRYPTED PRIVATE KEY-----") { return true }
    if t.contains("PROC-TYPE: 4,ENCRYPTED") { return true }
    if t.contains("DEK-INFO:") { return true }
    return false
}

// MARK: - Key Validation

/// Describes an issue detected during early key validation inside the credentials sheet
enum KeyValidationIssue {
    /// No issue — key is usable
    case none
    /// Encrypted PKCS#8 key contains RSA — must generate a new key
    case encryptedPKCS8ContainsRSA
    /// Encrypted OpenSSH key using a cipher we don't support — can convert
    case encryptedOpenSSHKey
    /// Encrypted key provided without a passphrase
    case passphraseRequired
    /// Decryption failed (wrong passphrase or corrupt key)
    case decryptionFailed
}

/// Validates a private key *before* attempting connection.
/// Returns a `KeyValidationIssue` describing any problem found.
func validatePrivateKey(pemString: String, passphrase: String) -> KeyValidationIssue {
    let trimmed = pemString.trimmingCharacters(in: .whitespacesAndNewlines)
    let kind = detectPEMKeyKind(trimmed)

    switch kind {
    case .openssh:
        // Encrypted OpenSSH keys are now decrypted in-app (bcrypt + AES-CTR/CBC/GCM).
        // Surface the actionable cases; let anything else fall through to connect.
        do {
            let data = try OpenSSHKeyParser.extractOpenSSHData(from: trimmed)
            _ = try OpenSSHKeyParser.parseOpenSSHPrivateKey(data, passphrase: passphrase.isEmpty ? nil : passphrase)
            return .none
        } catch let error as OpenSSHCipherError {
            switch error {
            case .encryptedKeyNeedsPassphrase: return .passphraseRequired
            case .incorrectPassphrase: return .decryptionFailed
            case .unsupportedCipher, .unsupportedKDF: return .encryptedOpenSSHKey
            case .malformedKDFOptions, .cipherFailure: return .none
            }
        } catch {
            return .none  // Other parse errors — let the connection flow handle them
        }

    case .pkcs8 where isPEMEncrypted(trimmed):
        // Encrypted PKCS#8 — try to decrypt and inspect contents
        guard !passphrase.isEmpty else { return .passphraseRequired }
        do {
            let der = try PEMDecryptor.decryptEncryptedPKCS8PEM(trimmed, passphrase: passphrase)
            let key = try PEMDecryptor.parsePKCS8PrivateKey(der)
            if case .rsa = key {
                return .encryptedPKCS8ContainsRSA
            }
            return .none  // EC key inside — all good
        } catch {
            return .decryptionFailed
        }

    default:
        return .none
    }
}

/// Copies text to the system clipboard (macOS only)
func copyToClipboard(_ text: String) {
    #if os(macOS)
    let pb = NSPasteboard.general
    pb.clearContents()
    pb.setString(text, forType: .string)
    #endif
}

// MARK: - Command Help Row View

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
}

// MARK: - Editable Field View

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

// A self-contained view for showing PEM private key status and warnings.
struct PEMKeyInfoView: View {
    @Binding var keyText: String

    private var trimmedKey: String { keyText.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var kind: PEMKeyKind { detectPEMKeyKind(trimmedKey) }
    private var isEncrypted: Bool { isPEMEncrypted(trimmedKey) }

    /// Supported: PKCS#8, EC, OpenSSH (unencrypted Ed25519/ECDSA)
    private var isSupported: Bool {
        switch kind {
        case .pkcs8, .ec: return true
        case .openssh: return true  // Ed25519/ECDSA supported (unencrypted)
        case .rsa, .dsa, .unknown: return false
        }
    }

    var body: some View {
        if !trimmedKey.isEmpty {
            keyStatusView

            // OpenSSH keys: warn that encrypted ones won't work
            if kind == .openssh {
                opensshKeyNote
            }

            // PKCS#8/EC unencrypted warning
            if (kind == .pkcs8 || kind == .ec) && !isEncrypted {
                unencryptedKeyWarning
            }

            // RSA/DSA: show help to convert
            if kind == .rsa || kind == .dsa {
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
    private var opensshKeyNote: some View {
        HStack(spacing: 6) {
            Image(systemName: "info.circle")
                .foregroundColor(.blue)
            Text("OpenSSH Ed25519/ECDSA keys are supported, including passphrase-protected keys (aes-ctr, aes-cbc, aes-gcm). Enter the passphrase below if the key is encrypted.")
                .foregroundColor(.secondary)
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
                Image(systemName: "exclamationmark.triangle")
                    .foregroundColor(.orange)
                Text("\(keyKindDescription(kind)) is not supported. Convert to ECDSA or Ed25519:")
                    .font(.footnote)
                Spacer(minLength: 8)
            }
            HStack(alignment: .firstTextBaseline) {
                let genCmd = "ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519"
                Text(genCmd)
                    .font(.body.monospaced())
                Spacer(minLength: 8)
                Button("Copy") { copyToClipboard(genCmd) }
            }
        }
    }
}

// MARK: - Key Validation Alert

/// Identifiable wrapper so `.sheet(item:)` can present a `KeyValidationIssue`
struct KeyIssuePresentation: Identifiable {
    let id = UUID()
    let issue: KeyValidationIssue
}

/// Rich dialog shown when early key validation detects an actionable problem
struct KeyValidationAlertView: View {
    let issue: KeyValidationIssue
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            Divider()
            explanation
            Divider()
            commands
            HStack {
                Spacer()
                Button("OK") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(minWidth: 480, maxWidth: 560)
    }

    @ViewBuilder
    private var header: some View {
        switch issue {
        case .encryptedPKCS8ContainsRSA:
            Label("RSA Key Detected", systemImage: "shield.lefthalf.filled")
                .font(.title2.bold())
                .foregroundColor(.red)
        case .encryptedOpenSSHKey:
            Label("Encrypted OpenSSH Key", systemImage: "lock.fill")
                .font(.title2.bold())
                .foregroundColor(.orange)
        default:
            EmptyView()
        }
    }

    @ViewBuilder
    private var explanation: some View {
        switch issue {
        case .encryptedPKCS8ContainsRSA:
            Text("Your encrypted key contains an RSA private key. RSA is not supported and cannot be converted to another algorithm. You need to generate a new Ed25519 or ECDSA key pair.")
                .font(.body)
        case .encryptedOpenSSHKey:
            Text("This OpenSSH key is encrypted with a cipher this app doesn't support (only AES ctr/cbc/gcm; not chacha20-poly1305 or 3des-cbc). Re-encrypt it with `ssh-keygen -p -Z aes256-ctr`, remove the passphrase, or convert it to PKCS#8.")
                .font(.body)
        default:
            EmptyView()
        }
    }

    @ViewBuilder
    private var commands: some View {
        switch issue {
        case .encryptedPKCS8ContainsRSA:
            VStack(alignment: .leading, spacing: 12) {
                Text("Generate a new key:")
                    .font(.subheadline.bold())
                CommandHelpRow(
                    title: "Ed25519 (recommended):",
                    command: "ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519"
                )
                CommandHelpRow(
                    title: "ECDSA (P-256):",
                    command: "ssh-keygen -t ecdsa -b 256 -f ~/.ssh/id_ecdsa"
                )
                Divider()
                CommandHelpRow(
                    title: "Copy the new public key to your server:",
                    command: "ssh-copy-id -i ~/.ssh/id_ed25519.pub user@host"
                )
            }

        case .encryptedOpenSSHKey:
            VStack(alignment: .leading, spacing: 12) {
                Text("Convert your key:")
                    .font(.subheadline.bold())
                CommandHelpRow(
                    title: "Remove encryption (keep OpenSSH format):",
                    command: "ssh-keygen -p -N \"\" -f ~/.ssh/id_ed25519"
                )
                CommandHelpRow(
                    title: "Convert to PKCS#8 (keeps encryption with passphrase):",
                    command: "openssl pkey -in ~/.ssh/id_ed25519 -out key.pem"
                )
                CommandHelpRow(
                    title: "Or convert to encrypted PKCS#8:",
                    command: "openssl pkcs8 -topk8 -v2 aes-256-cbc -in key.pem -out key_encrypted.pem"
                )
            }

        default:
            EmptyView()
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
                            Button(action: {
                                if connectionStore.mode == .create {
                                    let connectionInfo = ConnectionInfo(name: connectionStore.connectionName, serverAddress: connectionStore.serverAddress, portNumber: connectionStore.portNumber, username: connectionStore.username, password: connectionStore.password, privateKey: connectionStore.privateKey, privateKeyPassphrase: "")
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

struct ConnectionIndicatorView: View {
    var connection: Connection

    private var statusColor: Color {
        switch connection.state {
        case .idle: return .gray
        case .connecting, .disconnecting: return .orange
        case .connected: return .green
        case .failed: return .red
        }
    }

    private var statusText: String {
        switch connection.state {
        case .idle: return "Disconnected"
        case .connecting: return "Connecting..."
        case .connected: return "Connected"
        case .disconnecting: return "Disconnecting..."
        case .failed(let message): return "Failed: \(message)"
        }
    }

    var body: some View {
        HStack(spacing: 4) {
            if connection.state.isConnecting || connection.state.isDisconnecting {
                ProgressView()
                    .scaleEffect(0.6)
                    .frame(width: 10, height: 10)
            } else {
                Circle()
                    .fill(statusColor)
                    .frame(width: 10, height: 10)
            }
            Text(statusText)
                .lineLimit(1)
                .truncationMode(.tail)
                .multilineTextAlignment(.trailing)
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }
}

struct ConnectButtonView: View {
    var connection: Connection
    @Environment(ConnectionStore.self) var connectionStore
    @State private var showCredentialsSheet: Bool = false
    @State private var tempPassword: String = ""
    @State private var tempPrivateKey: String = ""
    @State private var tempPassphrase: String = ""
    @State private var saveCredentials: Bool = false
    @State private var pemError: String? = nil
    @State private var showKeyInfo: Bool = false
    @State private var keyIssuePresentation: KeyIssuePresentation? = nil
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
            if let presentation = keyIssuePresentation {
                // Show the key validation alert inside the same sheet
                KeyValidationAlertView(issue: presentation.issue) {
                    keyIssuePresentation = nil
                }
            } else {
                credentialsSheetContent
            }
        }
    }

    @ViewBuilder
    private var credentialsSheetContent: some View {
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
                                Text("• Ed25519 (OpenSSH format)")
                                    .font(.footnote)
                                Text("• ECDSA P-256/P-384/P-521 (OpenSSH, EC PRIVATE KEY, or PKCS#8)")
                                    .font(.footnote)
                                Text("• Encrypted OpenSSH keys (aes-ctr/cbc/gcm, with passphrase)")
                                    .font(.footnote)
                                Text("• PKCS#8 encrypted keys (with passphrase)")
                                    .font(.footnote)

                                Text("Not supported:")
                                    .font(.subheadline)
                                Text("• RSA, DSA keys")
                                    .font(.footnote)

                                Divider()
                                CommandHelpRow(
                                    title: "Generate an Ed25519 key:",
                                    command: "ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519"
                                )

                                Divider()
                                CommandHelpRow(
                                    title: "Encrypt an existing key with a passphrase (PKCS#8):",
                                    command: "openssl pkcs8 -topk8 -v2 aes-256-cbc -in key.pem -out key_encrypted.pem"
                                )

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

                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 6) {
                        Text("Passphrase (optional)")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                        if isPEMEncrypted(tempPrivateKey) {
                            Image(systemName: "lock")
                                .foregroundColor(.secondary)
                                .help("This key appears to be encrypted; enter the passphrase.")
                        }
                    }
                    SecureField("Enter passphrase", text: $tempPassphrase)
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                }

                if let pemError = pemError {
                    Text(pemError)
                        .foregroundColor(.red)
                        .font(.footnote)
                }

                Toggle("Save credentials to this connection", isOn: $saveCredentials)

                Text("Provide either a password or a private key (PEM). If you choose not to save, the credentials will be used for this session only. Note: Passphrases are never saved and must be re-entered each time.")
                    .font(.footnote)
                    .foregroundColor(.secondary)

                HStack {
                    Spacer()
                    Button("Cancel") { showCredentialsSheet = false }
                    Button("Connect") {
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

    private func handleConnect() {
        let providedPassword = !tempPassword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let providedKey = !tempPrivateKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        guard providedPassword || providedKey else { return }

        pemError = nil

        if providedKey {
            let keyKind = detectPEMKeyKind(tempPrivateKey)

            guard keyKind != .unknown else {
                pemError = "Invalid private key format."
                return
            }

            // Supported: PKCS#8, EC, OpenSSH (Ed25519/ECDSA unencrypted)
            // Not supported: RSA, DSA, public keys, PuTTY format
            if keyKind == .rsa || keyKind == .dsa {
                pemError = "Unsupported key type (\(keyKindDescription(keyKind))). Use Ed25519 or ECDSA instead."
                return
            }

            // Early key validation — detect issues before attempting connection
            let issue = validatePrivateKey(pemString: tempPrivateKey, passphrase: tempPassphrase)
            switch issue {
            case .none:
                break
            case .passphraseRequired:
                pemError = "This key is encrypted. Please enter the passphrase."
                return
            case .decryptionFailed:
                pemError = "Could not decrypt the key. Check your passphrase and try again."
                return
            case .encryptedPKCS8ContainsRSA, .encryptedOpenSSHKey:
                // Swap the sheet content to show the rich validation dialog
                keyIssuePresentation = KeyIssuePresentation(issue: issue)
                return
            }
        }

        // At this point, validation passed. Store credentials temporarily/permanently.

        // If password field was filled, use it.
        if providedPassword { connection.connectionInfo.password = tempPassword }

        // If key field was filled, use it.
        if providedKey {
            connection.connectionInfo.privateKey = tempPrivateKey
            connection.connectionInfo.privateKeyPassphrase = tempPassphrase
        } else {
             connection.connectionInfo.privateKeyPassphrase = ""
        }

        // Ensure we clear the opposing field if only one was provided in the modal
        if providedPassword && !providedKey { connection.connectionInfo.privateKey = "" }
        if providedKey && !providedPassword { connection.connectionInfo.password = "" }

        if saveCredentials {
            // This implicitly updates the Keychain via ConnectionStore's save logic.
            connectionStore.saveConnection(connection, connectionToUpdate: connection)
        }

        connectionStore.connect(connection)
        showCredentialsSheet = false
        tempPassword = ""
        tempPrivateKey = ""
        tempPassphrase = ""
        saveCredentials = false
    }
}
