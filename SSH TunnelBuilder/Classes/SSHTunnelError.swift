import Foundation

/// Unified error type for SSH TunnelBuilder
/// Consolidates errors from various subsystems into a single hierarchy
enum SSHTunnelError: LocalizedError {
    // MARK: - Authentication Errors
    case missingCredentials
    case authenticationFailed
    case unsupportedKeyType(String)
    case keyParsingFailed(String)
    case encryptedKeyNoPassphrase
    case unsupportedCurveLength
    case rsaNotSupported
    case invalidPEM

    // MARK: - Connection Errors
    case connectionTimeout
    case networkError(Error)
    case tunnelSetupFailed(Error)
    case invalidPort(String)

    // MARK: - Host Key Errors
    case hostKeyMismatch
    case hostKeyValidationMissing
    case hostKeyRejected

    // MARK: - Internal Errors
    case internalError(String)

    var errorDescription: String? {
        switch self {
        // Authentication
        case .missingCredentials:
            return "Missing password or private key. Please provide authentication credentials."
        case .authenticationFailed:
            return "Authentication failed. Please check your username and credentials."
        case .unsupportedKeyType(let type):
            return "Unsupported key type: \(type)"
        case .keyParsingFailed(let detail):
            return "Failed to parse private key: \(detail). Ensure it's in PEM format (PKCS#8, Ed25519, or EC)."
        case .encryptedKeyNoPassphrase:
            return "Key is encrypted but no passphrase provided."
        case .unsupportedCurveLength:
            return "Unsupported ECDSA curve length."
        case .rsaNotSupported:
            return "RSA keys are not currently supported. Convert your key to Ed25519 or ECDSA (nistp256/384/521)."
        case .invalidPEM:
            return "Invalid PEM format."

        // Connection
        case .connectionTimeout:
            return "Connection timed out. Please check the server address and network connectivity."
        case .networkError(let error):
            return "Network error: \(error.localizedDescription)"
        case .tunnelSetupFailed(let error):
            return "Failed to set up tunnel: \(error.localizedDescription)"
        case .invalidPort(let port):
            return "Invalid port: '\(port)'. Must be between 1 and 65535."

        // Host Key
        case .hostKeyMismatch:
            return "SECURITY WARNING: Host key mismatch! The server key has changed. This could be a Man-in-the-Middle attack."
        case .hostKeyValidationMissing:
            return "Unknown host key and no validation callback configured."
        case .hostKeyRejected:
            return "Connection cancelled: Host key was not trusted."

        // Internal
        case .internalError(let detail):
            return "Internal error: \(detail)"
        }
    }
}
