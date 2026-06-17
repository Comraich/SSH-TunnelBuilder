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

import Foundation
import CommonCrypto
import CryptoKit

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
/// `bcrypt_pbkdf` (see ``BcryptPBKDF``) and encrypts with one of the AES-CTR,
/// AES-CBC, or AES-GCM ciphers.
///
/// The `chacha20-poly1305@openssh.com` AEAD (a non-standard ChaCha20/Poly1305
/// construction) and the legacy `3des-cbc` cipher are reported as unsupported;
/// convert such keys with `ssh-keygen -p -Z aes256-ctr` or to PKCS#8.
enum OpenSSHKeyDecryptor {
    private struct CipherSpec {
        enum Mode { case ctr, cbc, gcm }
        let keyLength: Int
        let ivLength: Int
        let blockSize: Int
        let mode: Mode

        /// Length of the trailing authentication tag (AEAD ciphers only).
        var authLength: Int { mode == .gcm ? 16 : 0 }
    }

    private static func spec(for cipherName: String) -> CipherSpec? {
        switch cipherName {
        case "aes256-ctr": return CipherSpec(keyLength: 32, ivLength: 16, blockSize: 16, mode: .ctr)
        case "aes192-ctr": return CipherSpec(keyLength: 24, ivLength: 16, blockSize: 16, mode: .ctr)
        case "aes128-ctr": return CipherSpec(keyLength: 16, ivLength: 16, blockSize: 16, mode: .ctr)
        case "aes256-cbc": return CipherSpec(keyLength: 32, ivLength: 16, blockSize: 16, mode: .cbc)
        case "aes192-cbc": return CipherSpec(keyLength: 24, ivLength: 16, blockSize: 16, mode: .cbc)
        case "aes128-cbc": return CipherSpec(keyLength: 16, ivLength: 16, blockSize: 16, mode: .cbc)
        case "aes256-gcm@openssh.com": return CipherSpec(keyLength: 32, ivLength: 12, blockSize: 16, mode: .gcm)
        case "aes128-gcm@openssh.com": return CipherSpec(keyLength: 16, ivLength: 12, blockSize: 16, mode: .gcm)
        default: return nil
        }
    }

    /// Decrypts `ciphertext` (the OpenSSH private section) into plaintext bytes.
    /// `authTag` is the trailing authentication tag for AEAD ciphers and is empty
    /// otherwise. For CTR/CBC the caller still verifies `check1 == check2`, which
    /// is what proves the passphrase was correct; AEAD ciphers fail here directly.
    static func decryptPrivateSection(
        cipherName: String,
        kdfName: String,
        kdfOptions: [UInt8],
        ciphertext: [UInt8],
        authTag: [UInt8] = [],
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
        guard authTag.count == spec.authLength else {
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

        switch spec.mode {
        case .ctr:
            // CTR is symmetric: decrypt == encrypt over the keystream.
            return try aesStreamDecrypt(mode: CCMode(kCCModeCTR),
                                        modeOptions: CCModeOptions(kCCModeOptionCTR_BE),
                                        operation: CCOperation(kCCEncrypt),
                                        key: key, iv: iv, input: ciphertext)
        case .cbc:
            return try aesStreamDecrypt(mode: CCMode(kCCModeCBC),
                                        modeOptions: 0,
                                        operation: CCOperation(kCCDecrypt),
                                        key: key, iv: iv, input: ciphertext)
        case .gcm:
            return try aesGCM(key: key, iv: iv, ciphertext: ciphertext, tag: authTag)
        }
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

    // MARK: - AES

    /// Decrypts block-aligned input with an unpadded AES streaming cipher
    /// (CTR or CBC) via CommonCrypto. Splitting key/IV setup from the data pass
    /// keeps each closure nesting shallow.
    ///
    /// CBC offers no built-in integrity, but that is inherent to the OpenSSH key
    /// format for this cipher: the passphrase is verified afterwards via the
    /// `check1 == check2` words, and the cipher is dictated by the *user-supplied*
    /// key file, not chosen by this app. (Static analysers flag CBC generically.)
    private static func aesStreamDecrypt(
        mode: CCMode,
        modeOptions: CCModeOptions,
        operation: CCOperation,
        key: [UInt8],
        iv: [UInt8],
        input: [UInt8]
    ) throws -> [UInt8] {
        var cryptorRef: CCCryptorRef?
        let createStatus = key.withUnsafeBytes { keyPtr in
            iv.withUnsafeBytes { ivPtr in
                CCCryptorCreateWithMode(
                    operation,
                    mode,
                    CCAlgorithm(kCCAlgorithmAES),
                    CCPadding(ccNoPadding),
                    ivPtr.baseAddress,
                    keyPtr.baseAddress, key.count,
                    nil, 0, 0,
                    modeOptions,
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

    /// AES-GCM (`aes{128,256}-gcm@openssh.com`). Standard GCM with a 12-byte IV
    /// and a trailing 16-byte tag, decrypted via CryptoKit. A failed tag check is
    /// reported as an incorrect passphrase (the most likely cause).
    private static func aesGCM(key: [UInt8], iv: [UInt8], ciphertext: [UInt8], tag: [UInt8]) throws -> [UInt8] {
        do {
            let box = try AES.GCM.SealedBox(
                nonce: try AES.GCM.Nonce(data: iv),
                ciphertext: ciphertext,
                tag: tag
            )
            let plaintext = try AES.GCM.open(box, using: SymmetricKey(data: key))
            return [UInt8](plaintext)
        } catch {
            throw OpenSSHCipherError.incorrectPassphrase
        }
    }
}
