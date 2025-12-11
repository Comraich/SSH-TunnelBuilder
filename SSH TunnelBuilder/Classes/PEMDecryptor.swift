import Foundation
import CryptoKit
import CommonCrypto

enum PEMKey {
    case rsa(n: Data, e: Data, d: Data, p: Data, q: Data, dP: Data, dQ: Data, qInv: Data)
    case ec(curveOID: String, privateScalar: Data)
}

enum PEMDecryptorError: Error {
    case unsupportedFormat
    case invalidPEM
    case asn1ParseError(String)
    case kdfError
    case decryptionFailed
}

struct PEMDecryptor {
    /// Decrypts an ENCRYPTED PKCS#8 PRIVATE KEY PEM using the provided passphrase.
    /// Supports PBES2 + PBKDF2 (HMAC-SHA1 or HMAC-SHA256) with AES-256-CBC.
    static func decryptEncryptedPKCS8PEM(_ pem: String, passphrase: String) throws -> Data {
        let base64 = try extractEncryptedPrivateKeyBase64(from: pem)
        let der = Data(base64Encoded: base64) ?? Data()
        guard !der.isEmpty else { throw PEMDecryptorError.invalidPEM }
        
        var asn1 = try ASN1Parser(data: der)
        var sequence = try asn1.readSequence()
        
        // EncryptedPrivateKeyInfo ::= SEQUENCE { encryptionAlgorithm AlgorithmIdentifier, encryptedData OCTET STRING }
        var encryptionAlgorithm = try sequence.readSequence()
        let encryptedData = try sequence.readOctetString()
        if !sequence.isAtEnd { throw PEMDecryptorError.asn1ParseError("Extra data after EncryptedPrivateKeyInfo fields") }
        
        // encryptionAlgorithm: AlgorithmIdentifier ::= SEQUENCE { algorithm OBJECT IDENTIFIER, parameters ANY DEFINED BY algorithm OPTIONAL }
        let algOID = try encryptionAlgorithm.readOID()
        guard algOID == "1.2.840.113549.1.5.13" else { // PBES2 OID
            throw PEMDecryptorError.unsupportedFormat
        }
        var pbes2params = try encryptionAlgorithm.readSequence()
        
        // PBES2-params ::= SEQUENCE { keyDerivationFunc AlgorithmIdentifier, encryptionScheme AlgorithmIdentifier }
        var kdfAlg = try pbes2params.readSequence()
        let kdfOID = try kdfAlg.readOID()
        guard kdfOID == "1.2.840.113549.1.5.12" else { // PBKDF2 OID
            throw PEMDecryptorError.unsupportedFormat
        }
        var pbkdf2params = try kdfAlg.readSequence()
        // PBKDF2-params ::= SEQUENCE { salt OCTET STRING, iterationCount INTEGER, keyLength INTEGER OPTIONAL, prf AlgorithmIdentifier DEFAULT hmacWithSHA1 }
        let salt = try pbkdf2params.readOctetString()
        let iterationCount = try pbkdf2params.readInteger()
        var keyLength: Int? = nil
        if let nextTag = try pbkdf2params.peekTag(), nextTag == 0x02 {
            keyLength = try pbkdf2params.readInteger()
        }
        var prfOID = "1.2.840.113549.2.7" // default hmacWithSHA1
        if let nextTag = try pbkdf2params.peekTag(), nextTag == 0x30 {
            // prf AlgorithmIdentifier ::= SEQUENCE { algorithm OBJECT IDENTIFIER, parameters ANY DEFINED BY algorithm OPTIONAL }
            var prfAlg = try pbkdf2params.readSequence()
            prfOID = try prfAlg.readOID()
            // parameters ignored (usually NULL)
            if !prfAlg.isAtEnd { _ = try? prfAlg.readAny() } // ignore
            if !pbkdf2params.isAtEnd { } // continue
        }
        if !pbkdf2params.isAtEnd { throw PEMDecryptorError.asn1ParseError("Extra data after PBKDF2 params") }
        
        var encSchemeAlg = try pbes2params.readSequence()
        let encSchemeOID = try encSchemeAlg.readOID()
        guard encSchemeOID == "2.16.840.1.101.3.4.1.42" else { // aes256-CBC OID
            throw PEMDecryptorError.unsupportedFormat
        }
        let iv = try encSchemeAlg.readOctetString()
        if !pbes2params.isAtEnd { throw PEMDecryptorError.asn1ParseError("Extra data after PBES2 params") }
        
        // Derive key with PBKDF2-HMAC (SHA1 or SHA256)
        let keyLen = keyLength ?? 32
        guard keyLen == 32 else { throw PEMDecryptorError.unsupportedFormat }
        let key: Data
        switch prfOID {
        case "1.2.840.113549.2.7": // HMAC-SHA1
            key = try pbkdf2(password: Data(passphrase.utf8),
                             salt: salt,
                             iterations: iterationCount,
                             keyLength: keyLen,
                             variant: .sha1)
        case "1.2.840.113549.2.9": // HMAC-SHA256
            key = try pbkdf2(password: Data(passphrase.utf8),
                             salt: salt,
                             iterations: iterationCount,
                             keyLength: keyLen,
                             variant: .sha256)
        default:
            throw PEMDecryptorError.unsupportedFormat
        }
        
        guard key.count == 32 else { throw PEMDecryptorError.decryptionFailed }
        guard iv.count == 16 else { throw PEMDecryptorError.decryptionFailed }
        guard encryptedData.count % 16 == 0 else { throw PEMDecryptorError.decryptionFailed }
        
        let plaintext = try AESCBC.decrypt(ciphertext: encryptedData, key: key, iv: iv)
        return plaintext
    }
    
    static func parsePKCS8PrivateKey(_ der: Data) throws -> PEMKey {
        var asn1 = try ASN1Parser(data: der)
        var seq = try asn1.readSequence()
        // PrivateKeyInfo ::= SEQUENCE { version INTEGER, privateKeyAlgorithm AlgorithmIdentifier, privateKey OCTET STRING }
        _ = try seq.readInteger() // version
        var alg = try seq.readSequence()
        let algOID = try alg.readOID()
        var curveOID: String? = nil
        if !alg.isAtEnd {
            // parameters could be NULL, OID (for EC), or a sequence
            if let tag = try alg.peekTag(), tag == 0x06 {
                curveOID = try alg.readOID()
            } else {
                _ = try? alg.readAny()
            }
        }
        let pkOctets = try seq.readOctetString()
        if !seq.isAtEnd { _ = try? seq.readAny() }

        if algOID == "1.2.840.113549.1.1.1" { // rsaEncryption
            // RSAPrivateKey (PKCS#1) inside the OCTET STRING
            var inner = try ASN1Parser(data: pkOctets)
            var rsaseq = try inner.readSequence()
            _ = try rsaseq.readInteger() // version
            let n = try rsaseq.readIntegerBytes()
            let e = try rsaseq.readIntegerBytes()
            let d = try rsaseq.readIntegerBytes()
            let p = try rsaseq.readIntegerBytes()
            let q = try rsaseq.readIntegerBytes()
            let dP = try rsaseq.readIntegerBytes()
            let dQ = try rsaseq.readIntegerBytes()
            let qInv = try rsaseq.readIntegerBytes()
            return .rsa(n: n, e: e, d: d, p: p, q: q, dP: dP, dQ: dQ, qInv: qInv)
        } else if algOID == "1.2.840.10045.2.1" { // id-ecPublicKey
            // ECPrivateKey inside the OCTET STRING: SEQUENCE { version, privateKey OCTET STRING, [0] params OPTIONAL, [1] publicKey OPTIONAL }
            var inner = try ASN1Parser(data: pkOctets)
            var ecseq = try inner.readSequence()
            _ = try ecseq.readInteger() // version
            let priv = try ecseq.readOctetString()
            // params may be present as [0] EXPLICIT OID, but we already captured curveOID from AlgorithmIdentifier
            return .ec(curveOID: curveOID ?? "", privateScalar: priv)
        } else {
            throw PEMDecryptorError.unsupportedFormat
        }
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
    
    private enum HashVariant {
        case sha1, sha256
    }
    
    private static func pbkdf2(password: Data, salt: Data, iterations: Int, keyLength: Int, variant: HashVariant) throws -> Data {
        guard iterations > 0 && keyLength > 0 else { throw PEMDecryptorError.kdfError }
        
        let hLen: Int
        switch variant {
        case .sha1: hLen = 20
        case .sha256: hLen = 32
        }
        
        func hmac(_ key: Data, _ data: Data) -> Data {
            let keySym = SymmetricKey(data: key)
            switch variant {
            case .sha1:
                let mac = HMAC<Insecure.SHA1>.authenticationCode(for: data, using: keySym)
                return Data(mac)
            case .sha256:
                let mac = HMAC<SHA256>.authenticationCode(for: data, using: keySym)
                return Data(mac)
            }
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
    
    private static func aes256cbcDecrypt(ciphertext: Data, key: Data, iv: Data) throws -> Data {
        return try AESCBC.decrypt(ciphertext: ciphertext, key: key, iv: iv)
    }
    
    private static func pkcs7Unpad(_ data: Data) throws -> Data {
        guard let last = data.last else { throw PEMDecryptorError.decryptionFailed }
        let paddingLen = Int(last)
        guard paddingLen > 0 && paddingLen <= 16 else { throw PEMDecryptorError.decryptionFailed }
        let paddingStart = data.count - paddingLen
        guard paddingStart >= 0 else { throw PEMDecryptorError.decryptionFailed }
        let padding = data[paddingStart..<data.count]
        guard padding.allSatisfy({ $0 == last }) else { throw PEMDecryptorError.decryptionFailed }
        return data.prefix(paddingStart)
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
        let status = outData.withUnsafeMutableBytes { outBuf in
            ciphertext.withUnsafeBytes { ctBuf in
                key.withUnsafeBytes { keyBuf in
                    iv.withUnsafeBytes { ivBuf in
                        CCCrypt(CCOperation(kCCDecrypt),
                                CCAlgorithm(kCCAlgorithmAES),
                                CCOptions(kCCOptionPKCS7Padding),
                                keyBuf.baseAddress, key.count,
                                ivBuf.baseAddress,
                                ctBuf.baseAddress, ctBuf.count,
                                outBuf.baseAddress, outBuf.count,
                                &outLength)
                    }
                }
            }
        }
        guard status == kCCSuccess else { throw PEMDecryptorError.decryptionFailed }
        outData.removeSubrange(outLength..<outData.count)
        return outData
    }
}

// MARK: - ASN.1 Minimal Parser

private struct ASN1Parser {
    private let data: Data
    private var offset: Int = 0
    
    init(data: Data) throws {
        self.data = data
    }
    
    var isAtEnd: Bool {
        return offset >= data.count
    }
    
    mutating func readByte() throws -> UInt8 {
        guard offset < data.count else {
            throw PEMDecryptorError.asn1ParseError("Unexpected end of data")
        }
        let b = data[offset]
        offset += 1
        return b
    }
    
    mutating func peekByte() throws -> UInt8 {
        guard offset < data.count else {
            throw PEMDecryptorError.asn1ParseError("Unexpected end of data")
        }
        return data[offset]
    }
    
    mutating func peekTag() throws -> UInt8? {
        guard offset < data.count else { return nil }
        return data[offset]
    }
    
    mutating func readLength() throws -> Int {
        let first = try readByte()
        if first & 0x80 == 0 {
            return Int(first & 0x7F)
        }
        let count = Int(first & 0x7F)
        guard count > 0 && count <= 4 else {
            throw PEMDecryptorError.asn1ParseError("Invalid length byte count")
        }
        var length = 0
        for _ in 0..<count {
            length <<= 8
            length |= Int(try readByte())
        }
        return length
    }
    
    mutating func readSequence() throws -> ASN1Parser {
        let tag = try readByte()
        guard tag == 0x30 else {
            throw PEMDecryptorError.asn1ParseError("Expected SEQUENCE (tag 0x30), got \(String(format:"0x%02X",tag))")
        }
        let length = try readLength()
        guard offset + length <= data.count else {
            throw PEMDecryptorError.asn1ParseError("Sequence length exceeds data")
        }
        let seqData = data[offset..<offset+length]
        offset += length
        return try ASN1Parser(data: seqData)
    }
    
    mutating func readOctetString() throws -> Data {
        let tag = try readByte()
        guard tag == 0x04 else {
            throw PEMDecryptorError.asn1ParseError("Expected OCTET STRING (tag 0x04), got \(String(format:"0x%02X",tag))")
        }
        let length = try readLength()
        guard offset + length <= data.count else {
            throw PEMDecryptorError.asn1ParseError("OCTET STRING length exceeds data")
        }
        let value = data[offset..<offset+length]
        offset += length
        return value
    }
    
    mutating func readOID() throws -> String {
        let tag = try readByte()
        guard tag == 0x06 else {
            throw PEMDecryptorError.asn1ParseError("Expected OBJECT IDENTIFIER (tag 0x06), got \(String(format:"0x%02X",tag))")
        }
        let length = try readLength()
        guard offset + length <= data.count else {
            throw PEMDecryptorError.asn1ParseError("OID length exceeds data")
        }
        let oidData = data[offset..<offset+length]
        offset += length
        return try parseOID(oidData)
    }
    
    mutating func readInteger() throws -> Int {
        let tag = try readByte()
        guard tag == 0x02 else {
            throw PEMDecryptorError.asn1ParseError("Expected INTEGER (tag 0x02), got \(String(format:"0x%02X",tag))")
        }
        let length = try readLength()
        guard offset + length <= data.count else {
            throw PEMDecryptorError.asn1ParseError("INTEGER length exceeds data")
        }
        let intData = data[offset..<offset+length]
        offset += length
        return try parseInteger(intData)
    }
    
    mutating func readAny() throws -> ASN1Parser {
        _ = try readByte()
        let length = try readLength()
        guard offset + length <= data.count else {
            throw PEMDecryptorError.asn1ParseError("ANY length exceeds data")
        }
        let anyData = data[(offset-2-length)..<(offset+length)]
        offset += length
        return try ASN1Parser(data: anyData)
    }
    
    mutating func readIntegerBytes() throws -> Data {
        let tag = try readByte()
        guard tag == 0x02 else {
            throw PEMDecryptorError.asn1ParseError("Expected INTEGER (tag 0x02), got \(String(format:"0x%02X",tag))")
        }
        let length = try readLength()
        guard offset + length <= data.count else {
            throw PEMDecryptorError.asn1ParseError("INTEGER length exceeds data")
        }
        let intData = data[offset..<offset+length]
        offset += length
        return intData
    }
    
    private func parseInteger(_ data: Data) throws -> Int {
        guard !data.isEmpty else { throw PEMDecryptorError.asn1ParseError("Invalid INTEGER encoding") }
        // Support positive integers only
        var value = 0
        for byte in data {
            value = (value << 8) | Int(byte)
        }
        return value
    }
    
    private func parseOID(_ data: Data) throws -> String {
        guard data.count >= 1 else { throw PEMDecryptorError.asn1ParseError("Invalid OID encoding") }
        var oidComponents = [Int]()
        let firstByte = data[data.startIndex]
        oidComponents.append(Int(firstByte / 40))
        oidComponents.append(Int(firstByte % 40))
        
        var value = 0
        var cursor = data.index(after: data.startIndex)
        while cursor < data.endIndex {
            let byte = data[cursor]
            value = (value << 7) | Int(byte & 0x7F)
            if (byte & 0x80) == 0 {
                oidComponents.append(value)
                value = 0
            }
            cursor = data.index(after: cursor)
        }
        if (data.last! & 0x80) != 0 {
            throw PEMDecryptorError.asn1ParseError("OID encoding incomplete")
        }
        return oidComponents.map(String.init).joined(separator: ".")
    }
}

