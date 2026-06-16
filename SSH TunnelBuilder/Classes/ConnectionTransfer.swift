import Foundation
import CryptoKit
import CommonCrypto

// MARK: - Transfer DTOs

/// A single connection as written to / read from an export file. Carries the
/// full secret set because an export is a complete, passphrase-encrypted backup.
///
/// There is deliberately no `id` / `recordID`: importing mints fresh identifiers
/// so restored connections become *new* records rather than colliding with — or
/// silently overwriting — existing ones. `privateKeyPassphrase` is included for
/// completeness but is normally empty, since the app never persists it.
struct ExportedConnection: Codable, Equatable {
    var name: String
    var serverAddress: String
    var portNumber: String
    var username: String
    var password: String
    var privateKey: String
    var privateKeyPassphrase: String
    var knownHostKey: String
    var localPort: String
    var remoteServer: String
    var remotePort: String
}

/// The decrypted body of an export file.
struct ExportPayload: Codable, Equatable {
    var connections: [ExportedConnection]
}

// MARK: - Errors

enum ConnectionTransferError: LocalizedError {
    case emptyPassphrase
    case wrongPassphraseOrCorruptFile
    case unrecognizedFormat
    case unsupportedVersion(Int)
    case malformed(String)
    case randomGenerationFailed
    case keyDerivationFailed

    var errorDescription: String? {
        switch self {
        case .emptyPassphrase:
            return "Enter a passphrase to encrypt or open the export file."
        case .wrongPassphraseOrCorruptFile:
            return "Couldn’t decrypt the file. The passphrase may be wrong, or the file may be damaged."
        case .unrecognizedFormat:
            return "This doesn’t look like an SSH TunnelBuilder export file."
        case .unsupportedVersion(let version):
            return "This export file uses a newer format (version \(version)) than this app understands. Update the app and try again."
        case .malformed(let detail):
            return "The export file is malformed: \(detail)"
        case .randomGenerationFailed:
            return "Couldn’t generate secure random data for encryption."
        case .keyDerivationFailed:
            return "Couldn’t derive an encryption key from the passphrase."
        }
    }
}

// MARK: - On-disk envelope

/// The plaintext header stored alongside the ciphertext. It describes how to
/// derive the key and which cipher was used, but holds no secret material — the
/// connection data lives only inside `data`.
private struct ExportEnvelope: Codable {
    let format: String
    let version: Int
    let kdf: String
    let iterations: Int
    let salt: String   // base64
    let cipher: String
    let data: String   // base64 of AES-GCM combined box (nonce + ciphertext + tag)

    static let expectedFormat = "ssh-tunnelbuilder-export"
    static let currentVersion = 1
    static let kdfName = "pbkdf2-hmac-sha256"
    static let cipherName = "aes-256-gcm"
}

// MARK: - Encrypt / Decrypt

/// Stateless codec that turns an `ExportPayload` into an encrypted file blob and
/// back. Pure and `nonisolated`, so the slow key-derivation step can run off the
/// main actor.
enum ConnectionTransfer {
    /// PBKDF2 iteration count. OWASP's recommended floor for PBKDF2-HMAC-SHA256.
    static let pbkdf2Iterations = 600_000
    private static let saltByteCount = 16
    private static let keyByteCount = 32 // AES-256

    /// Encrypts `payload` under `passphrase`, returning the bytes to write to disk.
    static func encrypt(_ payload: ExportPayload, passphrase: String) throws -> Data {
        guard !passphrase.isEmpty else { throw ConnectionTransferError.emptyPassphrase }

        let plaintext = try JSONEncoder().encode(payload)
        let salt = try randomBytes(count: saltByteCount)
        let key = try deriveKey(passphrase: passphrase, salt: salt, iterations: pbkdf2Iterations)

        let sealed = try AES.GCM.seal(plaintext, using: key)
        guard let combined = sealed.combined else {
            // Only nil for a custom nonce; the default seal always produces one.
            throw ConnectionTransferError.malformed("missing sealed box")
        }

        let envelope = ExportEnvelope(
            format: ExportEnvelope.expectedFormat,
            version: ExportEnvelope.currentVersion,
            kdf: ExportEnvelope.kdfName,
            iterations: pbkdf2Iterations,
            salt: salt.base64EncodedString(),
            cipher: ExportEnvelope.cipherName,
            data: combined.base64EncodedString()
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(envelope)
    }

    /// Decrypts file `data` with `passphrase`, returning the connection payload.
    static func decrypt(_ data: Data, passphrase: String) throws -> ExportPayload {
        guard !passphrase.isEmpty else { throw ConnectionTransferError.emptyPassphrase }

        let envelope: ExportEnvelope
        do {
            envelope = try JSONDecoder().decode(ExportEnvelope.self, from: data)
        } catch {
            throw ConnectionTransferError.unrecognizedFormat
        }

        guard envelope.format == ExportEnvelope.expectedFormat else {
            throw ConnectionTransferError.unrecognizedFormat
        }
        guard envelope.version <= ExportEnvelope.currentVersion else {
            throw ConnectionTransferError.unsupportedVersion(envelope.version)
        }
        guard envelope.kdf == ExportEnvelope.kdfName, envelope.cipher == ExportEnvelope.cipherName else {
            throw ConnectionTransferError.malformed("unsupported kdf/cipher")
        }
        guard
            let salt = Data(base64Encoded: envelope.salt),
            let combined = Data(base64Encoded: envelope.data)
        else {
            throw ConnectionTransferError.malformed("invalid base64")
        }

        let key = try deriveKey(passphrase: passphrase, salt: salt, iterations: envelope.iterations)

        let plaintext: Data
        do {
            let box = try AES.GCM.SealedBox(combined: combined)
            plaintext = try AES.GCM.open(box, using: key)
        } catch {
            // Tag mismatch (wrong passphrase) or truncated ciphertext both land here.
            throw ConnectionTransferError.wrongPassphraseOrCorruptFile
        }

        do {
            return try JSONDecoder().decode(ExportPayload.self, from: plaintext)
        } catch {
            throw ConnectionTransferError.malformed("decoded payload was not valid")
        }
    }

    // MARK: - Crypto helpers

    private static func randomBytes(count: Int) throws -> Data {
        var bytes = Data(count: count)
        let status = bytes.withUnsafeMutableBytes { buffer in
            SecRandomCopyBytes(kSecRandomDefault, count, buffer.baseAddress!)
        }
        guard status == errSecSuccess else { throw ConnectionTransferError.randomGenerationFailed }
        return bytes
    }

    /// Derives a 256-bit key from `passphrase` + `salt` via PBKDF2-HMAC-SHA256.
    private static func deriveKey(passphrase: String, salt: Data, iterations: Int) throws -> SymmetricKey {
        let passwordBytes = Array(passphrase.utf8) // guaranteed non-empty by callers
        var derived = [UInt8](repeating: 0, count: keyByteCount)

        let status: Int32 = passwordBytes.withUnsafeBufferPointer { pw in
            pw.baseAddress!.withMemoryRebound(to: CChar.self, capacity: pw.count) { passwordPtr in
                salt.withUnsafeBytes { saltBuffer in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        passwordPtr,
                        pw.count,
                        saltBuffer.bindMemory(to: UInt8.self).baseAddress!,
                        salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                        UInt32(iterations),
                        &derived,
                        derived.count
                    )
                }
            }
        }
        guard status == kCCSuccess else { throw ConnectionTransferError.keyDerivationFailed }
        defer { for index in derived.indices { derived[index] = 0 } }
        return SymmetricKey(data: Data(derived))
    }
}
