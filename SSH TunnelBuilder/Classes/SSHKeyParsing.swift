import Foundation
import NIO
import NIOFoundationCompat
@preconcurrency import NIOSSH
import CryptoKit

// Private-key parsing for SSH authentication. Turns PEM/OpenSSH key text into a
// `NIOSSHPrivateKey` (Ed25519 / ECDSA only — see CLAUDE.md for why RSA/DSA can't
// be supported). `SSHManager` consumes `FlexibleAuthDelegate`; the public app
// surface (e.g. key validation) goes through the `OpenSSHKeyParser` facade.

// MARK: - OpenSSH Parser Facade

internal enum OpenSSHKeyParser {
    enum OpenSSHParsingError: LocalizedError, Equatable {
        case insufficientData
        case invalidPEMFormat
        case invalidKeyFormat(reason: String)
        case unsupportedKeyType(String)
        case unsupportedCurve(String)
        case invalidStringData

        var errorDescription: String? {
            switch self {
            case .insufficientData:
                return "Insufficient data while parsing the key."
            case .invalidPEMFormat:
                return "Invalid PEM format."
            case .invalidKeyFormat(let reason):
                return "Invalid key format: \(reason)"
            case .unsupportedKeyType(let type):
                return "Unsupported key type: '\(type)'."
            case .unsupportedCurve(let curve):
                return "Unsupported elliptic curve: '\(curve)'. Supported curves are nistp256, nistp384, and nistp521."
            case .invalidStringData:
                return "Invalid string data in key."
            }
        }
    }

    static func extractOpenSSHData(from pem: String) throws -> Data { return try FlexibleAuthDelegate.extractOpenSSHData(from: pem) }
    static func parseOpenSSHPrivateKey(_ data: Data, passphrase: String? = nil) throws -> NIOSSHPrivateKey { return try FlexibleAuthDelegate.parseOpenSSHPrivateKey(data, passphrase: passphrase) }
    static func readSSHBytes(from buffer: inout ByteBuffer) throws -> [UInt8] { return try FlexibleAuthDelegate.readSSHBytes(from: &buffer) }
}

// MARK: - Authentication Delegate

final class FlexibleAuthDelegate: NIOSSHClientUserAuthenticationDelegate, Sendable {
    let username: String
    let password: String?
    let privateKey: NIOSSHPrivateKey?
    let initializationError: String? // Captured synchronously for immediate reporting
    let reportError: (@Sendable (String) -> Void)?

    init(username: String, password: String?, privateKeyString: String?, privateKeyPassphrase: String?, reportError: (@Sendable (String) -> Void)? = nil) {
        self.reportError = reportError
        self.username = username
        self.password = password?.isEmpty == false ? password : nil

        var parsedKey: NIOSSHPrivateKey? = nil
        var initError: String? = nil

        if let keyString = privateKeyString, !keyString.isEmpty {
            do {
                parsedKey = try FlexibleAuthDelegate.parsePrivateKey(pemString: keyString, passphrase: privateKeyPassphrase)
                Logger.info("Private key parsed successfully", log: Logger.ssh)
            } catch {
                let errorMsg = "Failed to parse private key: \(error.localizedDescription)"
                initError = error.localizedDescription
                reportError?(errorMsg)
                Logger.error(errorMsg, log: Logger.ssh)
            }
        }
        self.privateKey = parsedKey
        self.initializationError = initError
    }

    private func makeAuthOffer(with offerType: NIOSSHUserAuthenticationOffer.Offer) -> NIOSSHUserAuthenticationOffer {
        return NIOSSHUserAuthenticationOffer(
            username: username,
            serviceName: "ssh-connection",
            offer: offerType
        )
    }

    func nextAuthenticationType(
        availableMethods: NIOSSHAvailableUserAuthenticationMethods,
        nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>
    ) {
        if availableMethods.contains(.publicKey), let key = self.privateKey {
             // Correctly construct the private key offer wrapper
             let offer = makeAuthOffer(with: .privateKey(.init(privateKey: key)))
             nextChallengePromise.succeed(offer)
             return
        }

        if availableMethods.contains(.password), let password = self.password {
            let offer = makeAuthOffer(with: .password(.init(password: password)))
            nextChallengePromise.succeed(offer)
            return
        }

        nextChallengePromise.succeed(nil)
    }
}

// MARK: - Key Parsing

private extension FlexibleAuthDelegate {
    static func parsePrivateKey(pemString: String, passphrase: String?) throws -> NIOSSHPrivateKey {
        let trimmed = pemString.trimmingCharacters(in: .whitespacesAndNewlines)

        let kind = detectPEMKeyKind(trimmed)

        // Handle OpenSSH keys (Ed25519, ECDSA), encrypted or not
        if kind == .openssh {
            let data = try extractOpenSSHData(from: trimmed)
            return try parseOpenSSHPrivateKey(data, passphrase: passphrase)
        }

        guard kind == .pkcs8 || kind == .ec else {
            throw SSHTunnelError.unsupportedKeyType(keyKindDescription(kind))
        }

        let isEncrypted = isPEMEncrypted(trimmed)
        let derData: Data

        if isEncrypted {
            guard let passphrase = passphrase, !passphrase.isEmpty else {
                throw SSHTunnelError.encryptedKeyNoPassphrase
            }
            derData = try PEMDecryptor.decryptEncryptedPKCS8PEM(trimmed, passphrase: passphrase)
        } else if trimmed.contains("-----BEGIN PRIVATE KEY-----") || trimmed.contains("-----BEGIN EC PRIVATE KEY-----") {
            derData = try decodeUnencryptedPEM(trimmed)
        } else {
            throw PEMDecryptorError.invalidPEM
        }

        // A `.ec` kind here is a top-level SEC1 `EC PRIVATE KEY` (unencrypted);
        // its DER is a bare SEC1 ECPrivateKey, not a PKCS#8 PrivateKeyInfo, so
        // it needs the SEC1 parser. Everything else (`BEGIN PRIVATE KEY` and any
        // decrypted PKCS#8 blob) is PKCS#8.
        let parsedKey = (kind == .ec)
            ? try PEMDecryptor.parseSEC1ECPrivateKey(derData)
            : try PEMDecryptor.parsePKCS8PrivateKey(derData)

        switch parsedKey {
        case .ec(_, let privateScalar):
            switch privateScalar.count {
            case 32:
                let key = try P256.Signing.PrivateKey(rawRepresentation: privateScalar)
                return NIOSSHPrivateKey(p256Key: key)
            case 48:
                let key = try P384.Signing.PrivateKey(rawRepresentation: privateScalar)
                return NIOSSHPrivateKey(p384Key: key)
            case 66:
                let key = try P521.Signing.PrivateKey(rawRepresentation: privateScalar)
                return NIOSSHPrivateKey(p521Key: key)
            default:
                throw SSHTunnelError.unsupportedCurveLength
            }
        case .ed25519(let seed):
            let key = try Curve25519.Signing.PrivateKey(rawRepresentation: seed)
            return NIOSSHPrivateKey(ed25519Key: key)
        case .rsa:
            throw SSHTunnelError.rsaNotSupported
        }
    }

    // MARK: - OpenSSH Parsing Helpers

    static func extractOpenSSHData(from pem: String) throws -> Data {
        let lines = pem.components(separatedBy: .newlines)
        var base64String = ""
        var insideBlock = false

        for line in lines {
            if line.contains("-----BEGIN OPENSSH PRIVATE KEY-----") {
                insideBlock = true
                continue
            }
            if line.contains("-----END OPENSSH PRIVATE KEY-----") {
                insideBlock = false
                break
            }
            if insideBlock {
                base64String += line.trimmingCharacters(in: .whitespaces)
            }
        }

        guard !base64String.isEmpty, let data = Data(base64Encoded: base64String) else {
            throw OpenSSHKeyParser.OpenSSHParsingError.invalidPEMFormat
        }
        return data
    }

    static func parseOpenSSHPrivateKey(_ data: Data, passphrase: String? = nil) throws -> NIOSSHPrivateKey {
        var buffer = ByteBuffer(data: data)

        // 1. Magic "openssh-key-v1\0" (15 bytes)
        guard let magic = buffer.readBytes(length: 15),
              String(bytes: magic, encoding: .utf8) == "openssh-key-v1\0" else {
            throw OpenSSHKeyParser.OpenSSHParsingError.invalidKeyFormat(reason: "Invalid OpenSSH magic header")
        }

        // 2-4. Cipher, KDF name, KDF options
        let cipherName = try readSSHString(from: &buffer)
        let kdfName = try readSSHString(from: &buffer)
        let kdfOptions = try readSSHBytes(from: &buffer)
        let isEncrypted = !(cipherName == "none" && kdfName == "none")

        // 5. Num Keys
        guard let numKeys = buffer.readInteger(as: UInt32.self) else {
             throw OpenSSHKeyParser.OpenSSHParsingError.invalidKeyFormat(reason: "Could not read number of keys from private key blob")
        }

        guard numKeys >= 1 else {
             throw OpenSSHKeyParser.OpenSSHParsingError.invalidKeyFormat(reason: "No keys found in private key data")
        }

        // 6. Public Key Blob (Binary data)
        let _ = try readSSHBytes(from: &buffer) // pubKeyBlob

        // 7. Private Key section — encrypted unless cipher/KDF are both "none".
        // When encrypted, OpenSSH derives the cipher key+IV from the passphrase
        // with bcrypt_pbkdf; decrypt back to the same plaintext layout. For AEAD
        // ciphers the 16-byte authentication tag follows the encrypted section
        // as trailing bytes, so capture whatever remains in the buffer.
        let privateSection = try readSSHBytes(from: &buffer)
        let authTag = buffer.readableBytes > 0
            ? (buffer.readBytes(length: buffer.readableBytes) ?? [])
            : []
        let privateBlobBytes: [UInt8]
        if isEncrypted {
            privateBlobBytes = try OpenSSHKeyDecryptor.decryptPrivateSection(
                cipherName: cipherName,
                kdfName: kdfName,
                kdfOptions: kdfOptions,
                ciphertext: privateSection,
                authTag: authTag,
                passphrase: passphrase
            )
        } else {
            privateBlobBytes = privateSection
        }
        var privateBuffer = ByteBuffer(bytes: privateBlobBytes)

        // Check Ints — for an encrypted key this is also the proof that the
        // passphrase was correct (a wrong passphrase yields garbage plaintext).
        guard let check1 = privateBuffer.readInteger(as: UInt32.self),
              let check2 = privateBuffer.readInteger(as: UInt32.self),
              check1 == check2 else {
            if isEncrypted {
                throw OpenSSHCipherError.incorrectPassphrase
            }
            throw OpenSSHKeyParser.OpenSSHParsingError.invalidKeyFormat(reason: "Private key blob integrity check failed")
        }

        // Key Type
        let keyType = try readSSHString(from: &privateBuffer)

        if keyType == "ssh-ed25519" {
            // Pub key
            let _ = try readSSHBytes(from: &privateBuffer)
            // Priv key — OpenSSH stores 64 bytes: seed (32) || public key (32).
            // Curve25519.Signing.PrivateKey takes the 32-byte seed as rawRepresentation.
            let keyBytes = try readSSHBytes(from: &privateBuffer)
            guard keyBytes.count >= 32 else {
                throw OpenSSHKeyParser.OpenSSHParsingError.invalidKeyFormat(reason: "Ed25519 private key blob too short (\(keyBytes.count) bytes)")
            }
            let seed = Data(keyBytes.prefix(32))
            let ed25519Key = try Curve25519.Signing.PrivateKey(rawRepresentation: seed)
            return NIOSSHPrivateKey(ed25519Key: ed25519Key)
        } else if keyType.hasPrefix("ecdsa-sha2-") {
            let curveName = try readSSHString(from: &privateBuffer)
            let _ = try readSSHBytes(from: &privateBuffer) // Public Key
            let privateScalarBytes = try readSSHBytes(from: &privateBuffer) // Private Key Scalar

            let normalized: Data
            switch curveName {
            case "nistp256":
                normalized = try normalizeScalar(privateScalarBytes, targetSize: 32)
                let key = try P256.Signing.PrivateKey(rawRepresentation: normalized)
                return NIOSSHPrivateKey(p256Key: key)
            case "nistp384":
                normalized = try normalizeScalar(privateScalarBytes, targetSize: 48)
                let key = try P384.Signing.PrivateKey(rawRepresentation: normalized)
                return NIOSSHPrivateKey(p384Key: key)
            case "nistp521":
                normalized = try normalizeScalar(privateScalarBytes, targetSize: 66)
                let key = try P521.Signing.PrivateKey(rawRepresentation: normalized)
                return NIOSSHPrivateKey(p521Key: key)
            default:
                throw OpenSSHKeyParser.OpenSSHParsingError.unsupportedCurve(curveName)
            }
        } else {
            throw OpenSSHKeyParser.OpenSSHParsingError.unsupportedKeyType(keyType)
        }
    }

    static func normalizeScalar(_ bytes: [UInt8], targetSize: Int) throws -> Data {
        var result = bytes
        // Strip leading zeros if longer (OpenSSH MPINT format)
        while result.count > targetSize && result.first == 0 {
            result.removeFirst()
        }

        if result.count > targetSize {
            throw OpenSSHKeyParser.OpenSSHParsingError.invalidKeyFormat(reason: "Private key scalar is too large for the curve")
        }

        // Pad with leading zeros if shorter
        while result.count < targetSize {
            result.insert(0, at: 0)
        }

        return Data(result)
    }

    static func readSSHString(from buffer: inout ByteBuffer) throws -> String {
        let bytes = try readSSHBytes(from: &buffer)
        guard let string = String(bytes: bytes, encoding: .utf8) else {
             throw OpenSSHKeyParser.OpenSSHParsingError.invalidStringData
        }
        return string
    }

    static func readSSHBytes(from buffer: inout ByteBuffer) throws -> [UInt8] {
        guard let length = buffer.readInteger(as: UInt32.self) else {
            throw OpenSSHKeyParser.OpenSSHParsingError.insufficientData
        }
        guard let bytes = buffer.readBytes(length: Int(length)) else {
             throw OpenSSHKeyParser.OpenSSHParsingError.insufficientData
        }
        return bytes
    }

    static func decodeUnencryptedPEM(_ pem: String) throws -> Data {
        let normalized = pem
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")

        let startMarkers = ["-----BEGIN PRIVATE KEY-----", "-----BEGIN EC PRIVATE KEY-----"]
        let endMarkers = ["-----END PRIVATE KEY-----", "-----END EC PRIVATE KEY-----"]

        var base64Content = ""

        for (start, end) in zip(startMarkers, endMarkers) {
            if let startRange = normalized.range(of: start),
               let endRange = normalized.range(of: end) {
                let base64Start = startRange.upperBound
                let base64End = endRange.lowerBound
                base64Content = normalized[base64Start..<base64End]
                    .components(separatedBy: .newlines)
                    .joined()
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                break
            }
        }

        guard !base64Content.isEmpty, let data = Data(base64Encoded: base64Content) else {
            throw PEMDecryptorError.invalidPEM
        }
        return data
    }
}
