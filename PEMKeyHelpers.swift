import Foundation
#if os(macOS)
import AppKit
#endif

// MARK: - PEM Key Detection and Validation

enum PEMKeyKind {
    case pkcs8
    case ec
    case rsa
    case openssh
    case dsa
    case ed25519
    case unknown
}

func keyKindDescription(_ kind: PEMKeyKind) -> String {
    switch kind {
    case .pkcs8: return "PKCS#8 PRIVATE KEY"
    case .ec: return "EC PRIVATE KEY (ECDSA)"
    case .rsa: return "RSA PRIVATE KEY"
    case .openssh: return "OPENSSH PRIVATE KEY"
    case .dsa: return "DSA PRIVATE KEY"
    case .ed25519: return "ED25519 PRIVATE KEY"
    case .unknown: return "Unknown"
    }
}

func detectPEMKeyKind(_ text: String) -> PEMKeyKind {
    let t = text.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    if t.contains("-----BEGIN ENCRYPTED PRIVATE KEY-----") { return .pkcs8 }
    if t.contains("-----BEGIN PRIVATE KEY-----") { return .pkcs8 }
    if t.contains("-----BEGIN EC PRIVATE KEY-----") { return .ec }
    if t.contains("-----BEGIN RSA PRIVATE KEY-----") { return .rsa }
    if t.contains("-----BEGIN OPENSSH PRIVATE KEY-----") { return .openssh }
    if t.contains("-----BEGIN DSA PRIVATE KEY-----") { return .dsa }
    if t.contains("ED25519 PRIVATE KEY") { return .ed25519 }
    return .unknown
}

func isPEMEncrypted(_ text: String) -> Bool {
    let t = text.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    if t.contains("-----BEGIN ENCRYPTED PRIVATE KEY-----") { return true }
    if t.contains("PROC-TYPE: 4,ENCRYPTED") { return true }
    if t.contains("DEK-INFO:") { return true }
    return false
}

// MARK: - Clipboard Helper

func copyToClipboard(_ text: String) {
    #if os(macOS)
    let pb = NSPasteboard.general
    pb.clearContents()
    pb.setString(text, forType: .string)
    #endif
}
