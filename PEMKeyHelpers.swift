import Foundation
#if os(macOS)
import AppKit
#endif

// MARK: - PEM Key Detection and Validation

/// Represents the different types of PEM-encoded private keys
enum PEMKeyKind {
    case pkcs8        // Standard PKCS#8 format (most compatible)
    case ec           // Elliptic Curve key (supported)
    case rsa          // Legacy RSA format (may need conversion)
    case openssh      // OpenSSH format (not directly supported by NIOSSH)
    case dsa          // DSA format (deprecated, not recommended)
    case ed25519      // ED25519 format (not yet supported)
    case unknown      // Unrecognized format
}

/// Returns a human-readable description of the key type
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

/// Detects the type of PEM private key from its text content
/// - Parameter text: The PEM-encoded key text
/// - Returns: The detected key type
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

/// Determines whether a PEM private key is encrypted
/// - Parameter text: The PEM-encoded key text
/// - Returns: `true` if the key is encrypted and requires a passphrase
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
