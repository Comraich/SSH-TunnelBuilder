import SwiftUI

/// The Connect/Disconnect button. When a connection has no stored credentials,
/// it presents a credentials sheet (password and/or PEM private key) before
/// connecting, validating the key up front.
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
                            keyFormatHelpPopover
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

    @ViewBuilder
    private var keyFormatHelpPopover: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Key format help")
                .font(.headline)

            Text("Supported:")
                .font(.subheadline)
            Text("• Ed25519 (OpenSSH or PKCS#8 format)")
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
