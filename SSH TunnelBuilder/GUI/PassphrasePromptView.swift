import SwiftUI

/// Collects a passphrase for encrypting an export or decrypting an import.
///
/// In `.encrypt` mode it asks for the passphrase twice and requires the two to
/// match before enabling the action; in `.decrypt` mode it asks once.
struct PassphrasePromptView: View {
    enum Purpose {
        case encrypt(connectionCount: Int)
        case decrypt
    }

    let purpose: Purpose
    let onSubmit: (String) -> Void
    let onCancel: () -> Void

    @State private var passphrase = ""
    @State private var confirmation = ""

    private var isEncrypting: Bool {
        if case .encrypt = purpose { return true }
        return false
    }

    private var passphrasesMismatch: Bool {
        isEncrypting && !confirmation.isEmpty && passphrase != confirmation
    }

    private var canSubmit: Bool {
        guard !passphrase.isEmpty else { return false }
        return isEncrypting ? passphrase == confirmation : true
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label(title, systemImage: "lock.fill")
                .font(.headline)

            Text(explanation)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            SecureField("Passphrase", text: $passphrase)
                .textFieldStyle(.roundedBorder)

            if isEncrypting {
                SecureField("Confirm passphrase", text: $confirmation)
                    .textFieldStyle(.roundedBorder)

                if passphrasesMismatch {
                    Text("Passphrases don’t match.")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button(isEncrypting ? "Export" : "Import") {
                    onSubmit(passphrase)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canSubmit)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(width: 380)
    }

    private var title: String {
        isEncrypting ? "Encrypt Export" : "Open Export"
    }

    private var explanation: String {
        switch purpose {
        case .encrypt(let count):
            let noun = count == 1 ? "connection" : "connections"
            return "Choose a passphrase to encrypt \(count) \(noun). You’ll need it to import the file later — it can’t be recovered if lost."
        case .decrypt:
            return "Enter the passphrase this file was encrypted with."
        }
    }
}

#Preview("Encrypt") {
    PassphrasePromptView(purpose: .encrypt(connectionCount: 3), onSubmit: { _ in }, onCancel: {})
}

#Preview("Decrypt") {
    PassphrasePromptView(purpose: .decrypt, onSubmit: { _ in }, onCancel: {})
}
