import SwiftUI

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

// MARK: - PEM Key Info View

/// A self-contained view for showing PEM private key status and warnings.
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
