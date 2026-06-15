import Foundation
import CommonCrypto

/// Errors raised while decrypting a passphrase-protected OpenSSH private key.
enum OpenSSHCipherError: LocalizedError, Equatable {
    case encryptedKeyNeedsPassphrase
    case incorrectPassphrase
    case unsupportedCipher(String)
    case unsupportedKDF(String)
    case malformedKDFOptions
    case cipherFailure

    var errorDescription: String? {
        switch self {
        case .encryptedKeyNeedsPassphrase:
            return "This OpenSSH key is encrypted. Please enter its passphrase."
        case .incorrectPassphrase:
            return "Incorrect passphrase for the OpenSSH key."
        case .unsupportedCipher(let name):
            return "Unsupported OpenSSH key cipher '\(name)'. Re-encrypt the key with aes256-ctr, or convert it to PKCS#8."
        case .unsupportedKDF(let name):
            return "Unsupported OpenSSH key KDF '\(name)'. Only bcrypt is supported."
        case .malformedKDFOptions:
            return "Malformed OpenSSH key KDF options."
        case .cipherFailure:
            return "Failed to decrypt the OpenSSH key."
        }
    }
}

/// Decrypts the encrypted private section of an OpenSSH (`openssh-key-v1`)
/// private key. OpenSSH derives the cipher key + IV from the passphrase with
/// `bcrypt_pbkdf` (see ``BcryptPBKDF``) and encrypts with an AES-CTR cipher.
///
/// Only the AES-CTR ciphers are handled — those are what modern `ssh-keygen`
/// produces. The legacy AES-CBC ciphers and the AEAD ciphers
/// (chacha20-poly1305, aes-gcm) are reported as unsupported; convert such keys
/// with `ssh-keygen -p -Z aes256-ctr` or to PKCS#8.
enum OpenSSHKeyDecryptor {
    private struct CipherSpec {
        let keyLength: Int
        let ivLength: Int
        let blockSize: Int
    }

    private static func spec(for cipherName: String) -> CipherSpec? {
        switch cipherName {
        case "aes256-ctr": return CipherSpec(keyLength: 32, ivLength: 16, blockSize: 16)
        case "aes192-ctr": return CipherSpec(keyLength: 24, ivLength: 16, blockSize: 16)
        case "aes128-ctr": return CipherSpec(keyLength: 16, ivLength: 16, blockSize: 16)
        default: return nil
        }
    }

    /// Decrypts `ciphertext` (the OpenSSH private section) into plaintext bytes.
    /// The caller is responsible for the subsequent `check1 == check2` integrity
    /// check, which is what actually proves the passphrase was correct.
    static func decryptPrivateSection(
        cipherName: String,
        kdfName: String,
        kdfOptions: [UInt8],
        ciphertext: [UInt8],
        passphrase: String?
    ) throws -> [UInt8] {
        guard let passphrase, !passphrase.isEmpty else {
            throw OpenSSHCipherError.encryptedKeyNeedsPassphrase
        }
        guard kdfName == "bcrypt" else {
            throw OpenSSHCipherError.unsupportedKDF(kdfName)
        }
        guard let spec = spec(for: cipherName) else {
            throw OpenSSHCipherError.unsupportedCipher(cipherName)
        }
        guard !ciphertext.isEmpty, ciphertext.count % spec.blockSize == 0 else {
            throw OpenSSHCipherError.cipherFailure
        }

        let (salt, rounds) = try parseBcryptOptions(kdfOptions)
        let keyiv = BcryptPBKDF.derive(
            passphrase: Array(passphrase.utf8),
            salt: salt,
            rounds: rounds,
            keyLength: spec.keyLength + spec.ivLength
        )
        guard keyiv.count == spec.keyLength + spec.ivLength else {
            throw OpenSSHCipherError.cipherFailure
        }
        let key = Array(keyiv[0..<spec.keyLength])
        let iv = Array(keyiv[spec.keyLength..<(spec.keyLength + spec.ivLength)])

        return try aesCTR(key: key, iv: iv, input: ciphertext)
    }

    /// `bcrypt` kdfoptions are `string salt || uint32 rounds`.
    private static func parseBcryptOptions(_ bytes: [UInt8]) throws -> (salt: [UInt8], rounds: Int) {
        guard bytes.count >= 4 else { throw OpenSSHCipherError.malformedKDFOptions }
        let saltLength = beUInt32(bytes, 0)
        let roundsOffset = 4 + saltLength
        guard saltLength > 0, bytes.count >= roundsOffset + 4 else {
            throw OpenSSHCipherError.malformedKDFOptions
        }
        let salt = Array(bytes[4..<roundsOffset])
        let rounds = beUInt32(bytes, roundsOffset)
        guard rounds > 0 else { throw OpenSSHCipherError.malformedKDFOptions }
        return (salt, rounds)
    }

    private static func beUInt32(_ bytes: [UInt8], _ offset: Int) -> Int {
        (Int(bytes[offset]) << 24) | (Int(bytes[offset + 1]) << 16)
            | (Int(bytes[offset + 2]) << 8) | Int(bytes[offset + 3])
    }

    // MARK: - AES via CommonCrypto

    /// AES-CTR. Counter mode is symmetric, so a decrypt is an encrypt over the
    /// keystream; CommonCrypto exposes CTR only through the streaming API.
    private static func aesCTR(key: [UInt8], iv: [UInt8], input: [UInt8]) throws -> [UInt8] {
        var cryptorRef: CCCryptorRef?
        let createStatus = key.withUnsafeBytes { keyPtr in
            iv.withUnsafeBytes { ivPtr in
                CCCryptorCreateWithMode(
                    CCOperation(kCCEncrypt),
                    CCMode(kCCModeCTR),
                    CCAlgorithm(kCCAlgorithmAES),
                    CCPadding(ccNoPadding),
                    ivPtr.baseAddress,
                    keyPtr.baseAddress, key.count,
                    nil, 0, 0,
                    CCModeOptions(kCCModeOptionCTR_BE),
                    &cryptorRef
                )
            }
        }
        guard createStatus == kCCSuccess, let cryptor = cryptorRef else {
            throw OpenSSHCipherError.cipherFailure
        }
        defer { CCCryptorRelease(cryptor) }

        var output = [UInt8](repeating: 0, count: input.count)
        var moved = 0
        let updateStatus = input.withUnsafeBytes { inPtr in
            output.withUnsafeMutableBytes { outPtr in
                CCCryptorUpdate(cryptor, inPtr.baseAddress, input.count,
                                outPtr.baseAddress, outPtr.count, &moved)
            }
        }
        guard updateStatus == kCCSuccess, moved == input.count else {
            throw OpenSSHCipherError.cipherFailure
        }
        return output
    }
}
