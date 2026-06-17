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
#if os(macOS)
import AppKit
#endif

// MARK: - PEM Key Detection Utilities

/// Represents the different types of PEM-encoded private keys
enum PEMKeyKind {
    case pkcs8        // PKCS#8 format - ECDSA supported (encrypted or unencrypted)
    case ec           // EC PRIVATE KEY - ECDSA supported (unencrypted)
    case rsa          // RSA format - NOT supported
    case openssh      // OpenSSH format - Ed25519/ECDSA supported (unencrypted)
    case dsa          // DSA format - NOT supported
    case unknown      // Unrecognized format
}

/// Returns a human-readable description of the key type
func keyKindDescription(_ kind: PEMKeyKind) -> String {
    switch kind {
    case .pkcs8: return "PKCS#8 PRIVATE KEY"
    case .ec: return "EC PRIVATE KEY (ECDSA)"
    case .rsa: return "RSA PRIVATE KEY"
    case .openssh: return "OPENSSH PRIVATE KEY (Ed25519/ECDSA)"
    case .dsa: return "DSA PRIVATE KEY"
    case .unknown: return "Unknown"
    }
}

/// Detects the type of PEM private key from its text content
func detectPEMKeyKind(_ text: String) -> PEMKeyKind {
    let t = text.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    if t.contains("-----BEGIN ENCRYPTED PRIVATE KEY-----") { return .pkcs8 }
    if t.contains("-----BEGIN PRIVATE KEY-----") { return .pkcs8 }
    if t.contains("-----BEGIN EC PRIVATE KEY-----") { return .ec }
    if t.contains("-----BEGIN RSA PRIVATE KEY-----") { return .rsa }
    if t.contains("-----BEGIN OPENSSH PRIVATE KEY-----") { return .openssh }
    if t.contains("-----BEGIN DSA PRIVATE KEY-----") { return .dsa }
    return .unknown
}

/// Determines whether a PEM private key is encrypted
func isPEMEncrypted(_ text: String) -> Bool {
    let t = text.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    if t.contains("-----BEGIN ENCRYPTED PRIVATE KEY-----") { return true }
    if t.contains("PROC-TYPE: 4,ENCRYPTED") { return true }
    if t.contains("DEK-INFO:") { return true }
    return false
}

// MARK: - Clipboard

/// Copies text to the system clipboard (macOS only)
func copyToClipboard(_ text: String) {
    #if os(macOS)
    let pb = NSPasteboard.general
    pb.clearContents()
    pb.setString(text, forType: .string)
    #endif
}
