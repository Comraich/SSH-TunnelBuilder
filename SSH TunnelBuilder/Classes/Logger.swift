import Foundation
import os

/// Centralized logging for SSH TunnelBuilder using os.Logger
/// Logs are visible in Console.app and can be filtered by subsystem/category
enum Logger {
    private static let subsystem = Bundle.main.bundleIdentifier ?? "com.comraich.ssh-tunnelbuilder"

    struct Category {
        fileprivate let logger: os.Logger
    }

    // MARK: - Log Categories
    static let ssh = Category(logger: os.Logger(subsystem: subsystem, category: "SSH"))
    static let keychain = Category(logger: os.Logger(subsystem: subsystem, category: "Keychain"))
    static let cloudKit = Category(logger: os.Logger(subsystem: subsystem, category: "CloudKit"))
    static let crypto = Category(logger: os.Logger(subsystem: subsystem, category: "Crypto"))

    // MARK: - Convenience Methods

    static func debug(_ message: String, log: Category) {
        log.logger.debug("\(message, privacy: .public)")
    }

    static func info(_ message: String, log: Category) {
        log.logger.info("\(message, privacy: .public)")
    }

    static func error(_ message: String, log: Category) {
        log.logger.error("\(message, privacy: .public)")
    }
}
