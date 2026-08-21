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
import CryptoKit
import CommonCrypto
import SwiftASN1

// MARK: - Object identifiers
//
// Typed `ASN1ObjectIdentifier` constants rather than dotted strings: comparison
// is a value compare instead of depending on `description`'s format, which
// SwiftASN1 makes no stability promise about.
private enum OID {
    static let pbes2: ASN1ObjectIdentifier = [1, 2, 840, 113549, 1, 5, 13]
    static let pbkdf2: ASN1ObjectIdentifier = [1, 2, 840, 113549, 1, 5, 12]
    static let hmacWithSHA256: ASN1ObjectIdentifier = [1, 2, 840, 113549, 2, 9]
    static let aes256CBC: ASN1ObjectIdentifier = [2, 16, 840, 1, 101, 3, 4, 1, 42]
    static let rsaEncryption: ASN1ObjectIdentifier = [1, 2, 840, 113549, 1, 1, 1]
    static let idEcPublicKey: ASN1ObjectIdentifier = [1, 2, 840, 10045, 2, 1]
    static let idEd25519: ASN1ObjectIdentifier = [1, 3, 101, 112]
}

// MARK: - DER helpers

/// Reads the next node of a SEQUENCE, failing with a `PEMDecryptorError` rather
/// than returning `nil`, so required-field absence reads as a parse error.
private func nextNode(_ nodes: inout ASN1NodeCollection.Iterator,
                      _ field: String) throws -> ASN1Node {
    guard let node = nodes.next() else {
        throw PEMDecryptorError.asn1ParseError("Missing required field: \(field)")
    }
    return node
}

/// Consumes and discards any remaining nodes.
///
/// `DER.sequence` throws `Unconsumed sequence nodes` if a builder leaves anything
/// behind, which is normally a useful strictness check — it replaces the old
/// parser's explicit `isAtEnd` guards. But in a few places the old parser
/// deliberately *ignored* trailing OPTIONAL fields it had no use for (a curve OID
/// in an EC `AlgorithmIdentifier`, PKCS#8 `[0] attributes`, SEC1 `[0] parameters`
/// / `[1] publicKey`). This keeps that tolerance explicit and local, so behaviour
/// is unchanged rather than newly strict.
private func drainRemaining(_ nodes: inout ASN1NodeCollection.Iterator) {
    while nodes.next() != nil {}
}

/// Runs `body`, converting SwiftASN1's errors into `PEMDecryptorError` so the
/// error surface callers see is unchanged.
private func mappingASN1Errors<T>(_ body: () throws -> T) throws -> T {
    do {
        return try body()
    } catch let error as PEMDecryptorError {
        throw error
    } catch {
        throw PEMDecryptorError.asn1ParseError(String(describing: error))
    }
}

enum PEMKey {
    case rsa
    case ec(curveOID: String, privateScalar: Data)
    case ed25519(seed: Data)
}

enum PEMDecryptorError: Error {
    case unsupportedFormat
    case invalidPEM
    case asn1ParseError(String)
    case kdfError
    case decryptionFailed
}

/// Decoded PBES2 encryption parameters plus the ciphertext they apply to.
private struct EncryptedPKCS8Params {
    var scheme: PBES2Scheme
    var ciphertext: Data
}

/// PBES2 parameters: the PBKDF2 inputs and the AES-CBC IV.
private struct PBES2Scheme {
    var salt: Data
    var iterations: Int
    /// Absent in most real files; RFC 8018 leaves it OPTIONAL.
    var keyLength: Int?
    var prf: ASN1ObjectIdentifier
    var iv: Data
}

/// AlgorithmIdentifier ::= SEQUENCE { algorithm OBJECT IDENTIFIER,
///                                    parameters ANY DEFINED BY algorithm OPTIONAL }
///
/// For PBES2 the parameters are
/// PBES2-params ::= SEQUENCE { keyDerivationFunc AlgorithmIdentifier,
///                            encryptionScheme AlgorithmIdentifier }
private func parsePBES2AlgorithmIdentifier(_ node: ASN1Node) throws -> PBES2Scheme {
    try DER.sequence(node, identifier: .sequence) { alg in
        guard try ASN1ObjectIdentifier(derEncoded: &alg) == OID.pbes2 else {
            throw PEMDecryptorError.unsupportedFormat
        }
        let paramsNode = try nextNode(&alg, "PBES2-params")
        return try DER.sequence(paramsNode, identifier: .sequence) { params in
            let kdf = try parsePBKDF2AlgorithmIdentifier(try nextNode(&params, "keyDerivationFunc"))
            let iv = try parseAESCBCScheme(try nextNode(&params, "encryptionScheme"))
            return PBES2Scheme(salt: kdf.salt, iterations: kdf.iterations,
                               keyLength: kdf.keyLength, prf: kdf.prf, iv: iv)
        }
    }
}

/// PBKDF2-params ::= SEQUENCE { salt OCTET STRING, iterationCount INTEGER,
///                              keyLength INTEGER OPTIONAL,
///                              prf AlgorithmIdentifier DEFAULT hmacWithSHA1 }
///
/// `keyLength` and `prf` are both OPTIONAL/DEFAULT and carry *universal* tags
/// (INTEGER, SEQUENCE) rather than context tags, so they're matched by tag number
/// — the structural equivalent of the previous parser's `peekTag()` lookahead.
private func parsePBKDF2AlgorithmIdentifier(
    _ node: ASN1Node
) throws -> (salt: Data, iterations: Int, keyLength: Int?, prf: ASN1ObjectIdentifier) {
    try DER.sequence(node, identifier: .sequence) { kdf in
        guard try ASN1ObjectIdentifier(derEncoded: &kdf) == OID.pbkdf2 else {
            throw PEMDecryptorError.unsupportedFormat
        }
        let paramsNode = try nextNode(&kdf, "PBKDF2-params")
        return try DER.sequence(paramsNode, identifier: .sequence) { params in
            let salt = Data(try ASN1OctetString(derEncoded: &params).bytes)
            let iterations = try Int(derEncoded: &params)
            let keyLength = try DER.optionalImplicitlyTagged(
                &params, tagNumber: 2, tagClass: .universal
            ) { try Int(derEncoded: $0) }

            // RFC 8018's DEFAULT is hmacWithSHA1. Keeping that as the fallback
            // means an omitted prf is rejected by the SHA-256 policy check rather
            // than silently treated as SHA-256.
            var prf: ASN1ObjectIdentifier = [1, 2, 840, 113549, 2, 7]
            if let prfNode = DER.optionalImplicitlyTagged(
                &params, tagNumber: 16, tagClass: .universal, { $0 }
            ) {
                prf = try DER.sequence(prfNode, identifier: .sequence) { prfAlg in
                    let oid = try ASN1ObjectIdentifier(derEncoded: &prfAlg)
                    // parameters ANY OPTIONAL — in practice NULL. Must be consumed.
                    drainRemaining(&prfAlg)
                    return oid
                }
            }
            return (salt, iterations, keyLength, prf)
        }
    }
}

/// The encryptionScheme AlgorithmIdentifier, restricted to aes256-CBC, whose
/// parameters are the 16-byte IV as an OCTET STRING.
private func parseAESCBCScheme(_ node: ASN1Node) throws -> Data {
    try DER.sequence(node, identifier: .sequence) { scheme in
        guard try ASN1ObjectIdentifier(derEncoded: &scheme) == OID.aes256CBC else {
            throw PEMDecryptorError.unsupportedFormat
        }
        return Data(try ASN1OctetString(derEncoded: &scheme).bytes)
    }
}

struct PEMDecryptor {
    /// Decrypts an ENCRYPTED PKCS#8 PRIVATE KEY PEM using the provided passphrase.
    /// Supports PBES2 + PBKDF2 (HMAC-SHA1 or HMAC-SHA256) with AES-256-CBC.
    static func decryptEncryptedPKCS8PEM(_ pem: String, passphrase: String) throws -> Data {
        let base64 = try extractEncryptedPrivateKeyBase64(from: pem)
        let der = Data(base64Encoded: base64) ?? Data()
        guard !der.isEmpty else { throw PEMDecryptorError.invalidPEM }
        
        // EncryptedPrivateKeyInfo ::= SEQUENCE { encryptionAlgorithm AlgorithmIdentifier,
        //                                        encryptedData OCTET STRING }
        //
        // `DER.sequence` rejects any node a builder leaves unconsumed, so the
        // "extra data after …" checks the previous parser made by hand are now
        // enforced structurally at every level below.
        let params = try mappingASN1Errors { () -> EncryptedPKCS8Params in
            let root = try DER.parse(Array(der))
            return try DER.sequence(root, identifier: .sequence) { top in
                let algNode = try nextNode(&top, "encryptionAlgorithm")
                let scheme = try parsePBES2AlgorithmIdentifier(algNode)
                let ciphertext = Data(try ASN1OctetString(derEncoded: &top).bytes)
                return EncryptedPKCS8Params(scheme: scheme, ciphertext: ciphertext)
            }
        }

        let salt = params.scheme.salt
        let iterationCount = params.scheme.iterations
        let iv = params.scheme.iv
        let encryptedData = params.ciphertext

        // Security policy, unchanged: AES-256 key length only, and reject any
        // PBKDF2 PRF other than HMAC-SHA256 (notably SHA-1).
        let keyLen = params.scheme.keyLength ?? 32
        guard keyLen == 32 else { throw PEMDecryptorError.unsupportedFormat }
        guard params.scheme.prf == OID.hmacWithSHA256 else {
            throw PEMDecryptorError.unsupportedFormat
        }
        let key = try pbkdf2(password: Data(passphrase.utf8),
                             salt: salt,
                             iterations: iterationCount,
                             keyLength: keyLen)
        
        guard key.count == 32 else { throw PEMDecryptorError.decryptionFailed }
        guard iv.count == 16 else { throw PEMDecryptorError.decryptionFailed }
        guard encryptedData.count % 16 == 0 else { throw PEMDecryptorError.decryptionFailed }
        
        let plaintext = try AESCBC.decrypt(ciphertext: encryptedData, key: key, iv: iv)
        return plaintext
    }
    
    static func parsePKCS8PrivateKey(_ der: Data) throws -> PEMKey {
        // PrivateKeyInfo ::= SEQUENCE { version INTEGER,
        //                               privateKeyAlgorithm AlgorithmIdentifier,
        //                               privateKey OCTET STRING,
        //                               [0] attributes OPTIONAL }
        let (algOID, pkOctets) = try mappingASN1Errors { () -> (ASN1ObjectIdentifier, Data) in
            let root = try DER.parse(Array(der))
            return try DER.sequence(root, identifier: .sequence) { seq in
                _ = try Int(derEncoded: &seq) // version
                let algNode = try nextNode(&seq, "privateKeyAlgorithm")
                let oid = try DER.sequence(algNode, identifier: .sequence) { alg in
                    let oid = try ASN1ObjectIdentifier(derEncoded: &alg)
                    // parameters ANY OPTIONAL — the EC curve OID, or NULL for RSA.
                    // Not needed: the curve is inferred from the scalar length.
                    drainRemaining(&alg)
                    return oid
                }
                let octets = Data(try ASN1OctetString(derEncoded: &seq).bytes)
                drainRemaining(&seq) // [0] attributes
                return (oid, octets)
            }
        }

        switch algOID {
        case OID.rsaEncryption:
            // RSA is detected only so callers can reject it; the key material
            // is never used, so we don't parse the RSAPrivateKey contents.
            return .rsa
        case OID.idEcPublicKey:
            // The privateKey OCTET STRING wraps a SEC1 ECPrivateKey structure.
            return try parseSEC1ECPrivateKey(pkOctets)
        case OID.idEd25519:
            // The privateKey OCTET STRING wraps a CurvePrivateKey, which is
            // itself an OCTET STRING holding the 32-byte seed (04 20 || seed).
            let seed = try mappingASN1Errors {
                Data(try ASN1OctetString(derEncoded: Array(pkOctets)).bytes)
            }
            guard seed.count == 32 else {
                throw PEMDecryptorError.asn1ParseError("Ed25519 seed must be 32 bytes, got \(seed.count)")
            }
            return .ed25519(seed: seed)
        default:
            throw PEMDecryptorError.unsupportedFormat
        }
    }

    /// Parses a SEC1 `ECPrivateKey` (RFC 5915) and returns its private scalar.
    /// Used both for top-level `EC PRIVATE KEY` PEMs and for the inner key blob
    /// of a PKCS#8 EC `PrivateKeyInfo` (which is itself a SEC1 ECPrivateKey).
    ///
    /// ECPrivateKey ::= SEQUENCE { version INTEGER, privateKey OCTET STRING,
    ///                             [0] parameters OPTIONAL, [1] publicKey OPTIONAL }
    ///
    /// The curve is identified by the caller from the scalar length, so the
    /// optional namedCurve parameters are not read here.
    static func parseSEC1ECPrivateKey(_ der: Data) throws -> PEMKey {
        let scalar = try mappingASN1Errors { () -> Data in
            let root = try DER.parse(Array(der))
            return try DER.sequence(root, identifier: .sequence) { seq in
                _ = try Int(derEncoded: &seq) // version (1)
                let scalar = Data(try ASN1OctetString(derEncoded: &seq).bytes)
                drainRemaining(&seq) // [0] parameters, [1] publicKey
                return scalar
            }
        }
        return .ec(curveOID: "", privateScalar: scalar)
    }
    
    private static func extractEncryptedPrivateKeyBase64(from pem: String) throws -> String {
        let normalized = pem.replacingOccurrences(of: "\r\n", with: "\n")
                            .replacingOccurrences(of: "\r", with: "\n")
        guard let startRange = normalized.range(of: "-----BEGIN ENCRYPTED PRIVATE KEY-----"),
              let endRange = normalized.range(of: "-----END ENCRYPTED PRIVATE KEY-----") else {
            throw PEMDecryptorError.invalidPEM
        }
        let base64Start = startRange.upperBound
        let base64End = endRange.lowerBound
        
        let base64Content = normalized[base64Start..<base64End]
            .components(separatedBy: .newlines)
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if base64Content.isEmpty { throw PEMDecryptorError.invalidPEM }
        return base64Content
    }
    
    /// PBKDF2-HMAC-SHA256. The encrypted-PKCS#8 path rejects any other PRF, so
    /// only SHA-256 is supported here.
    private static func pbkdf2(password: Data, salt: Data, iterations: Int, keyLength: Int) throws -> Data {
        guard iterations > 0 && keyLength > 0 else { throw PEMDecryptorError.kdfError }

        let hLen = 32 // HMAC-SHA256 output size

        func hmac(_ key: Data, _ data: Data) -> Data {
            let mac = HMAC<SHA256>.authenticationCode(for: data, using: SymmetricKey(data: key))
            return Data(mac)
        }

        var derivedKey = Data()
        let blockCount = UInt32((keyLength + hLen - 1) / hLen)
        for i in 1...blockCount {
            var u = hmac(password, salt + withUnsafeBytes(of: i.bigEndian, Array.init))
            var t = u
            for _ in 1..<iterations {
                u = hmac(password, u)
                t = xor(t, u)
            }
            derivedKey.append(t)
        }
        return derivedKey.prefix(keyLength)
    }
    
    private static func xor(_ a: Data, _ b: Data) -> Data {
        var res = Data(count: min(a.count, b.count))
        for i in 0..<res.count {
            res[i] = a[i] ^ b[i]
        }
        return res
    }
    
}

// AES-256-CBC with PKCS#7 padding (no ECB, no raw/NoPadding).
private enum AESCBC {
    static func decrypt(ciphertext: Data, key: Data, iv: Data) throws -> Data {
        guard key.count == kCCKeySizeAES256 else { throw PEMDecryptorError.decryptionFailed }
        guard iv.count == kCCBlockSizeAES128 else { throw PEMDecryptorError.decryptionFailed }
        
        // Defensive checks: CBC requires an IV and ciphertext at least one block; reject all-zero IV to avoid trivial patterns
        guard ciphertext.count >= kCCBlockSizeAES128 else { throw PEMDecryptorError.decryptionFailed }
        if iv.allSatisfy({ $0 == 0 }) { throw PEMDecryptorError.decryptionFailed }
        
        var outLength: size_t = 0
        var outData = Data(count: ciphertext.count + kCCBlockSizeAES128)
        let status = performCCCryptDecrypt(
            ciphertext: ciphertext,
            key: key,
            iv: iv,
            outData: &outData,
            outLength: &outLength
        )
        guard status == kCCSuccess else { throw PEMDecryptorError.decryptionFailed }
        outData.removeSubrange(outLength..<outData.count)
        return outData
    }
    
    private static func performCCCryptDecrypt(
        ciphertext: Data,
        key: Data,
        iv: Data,
        outData: inout Data,
        outLength: inout size_t
    ) -> CCCryptorStatus {
        return outData.withUnsafeMutableBytes { outBuf in
            let outBase = outBuf.baseAddress
            let outCount = outBuf.count
            return ciphertext.withUnsafeBytes { ctBuf in
                let ctBase = ctBuf.baseAddress
                let ctCount = ctBuf.count
                return key.withUnsafeBytes { keyBuf in
                    let keyBase = keyBuf.baseAddress
                    return iv.withUnsafeBytes { ivBuf in
                        let ivBase = ivBuf.baseAddress
                        return CCCrypt(
                            CCOperation(kCCDecrypt),
                            CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(kCCOptionPKCS7Padding),
                            keyBase, key.count,
                            ivBase,
                            ctBase, ctCount,
                            outBase, outCount,
                            &outLength
                        )
                    }
                }
            }
        }
    }
}

