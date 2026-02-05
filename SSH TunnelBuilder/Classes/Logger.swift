import Foundation
import os.log

/// Centralized logging for SSH TunnelBuilder using os.log
/// Logs are visible in Console.app and can be filtered by subsystem/category
enum Logger {
    private static let subsystem = Bundle.main.bundleIdentifier ?? "com.comraich.ssh-tunnelbuilder"

    // MARK: - Log Categories
    static let ssh = OSLog(subsystem: subsystem, category: "SSH")
    static let keychain = OSLog(subsystem: subsystem, category: "Keychain")
    static let cloudKit = OSLog(subsystem: subsystem, category: "CloudKit")
    static let crypto = OSLog(subsystem: subsystem, category: "Crypto")

    // MARK: - Convenience Methods

    /// Log debug information (not persisted by default)
    static func debug(_ message: String, log: OSLog = .default) {
        os_log(.debug, log: log, "%{public}@", message)
    }

    /// Log general information
    static func info(_ message: String, log: OSLog = .default) {
        os_log(.info, log: log, "%{public}@", message)
    }

    /// Log errors
    static func error(_ message: String, log: OSLog = .default) {
        os_log(.error, log: log, "%{public}@", message)
    }

    /// Log faults (serious errors)
    static func fault(_ message: String, log: OSLog = .default) {
        os_log(.fault, log: log, "%{public}@", message)
    }
}
