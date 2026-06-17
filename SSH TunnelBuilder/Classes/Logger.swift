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
    static let spotlight = Category(logger: os.Logger(subsystem: subsystem, category: "Spotlight"))

    // MARK: - Convenience Methods

    // The os.log default privacy level (`.private`) shows full values to a
    // developer attached via Xcode but redacts them to `<private>` in archived
    // logs (sysdiagnose, Console.app on another user account, support bundles).
    // Most call sites interpolate hostnames, tunnel targets, or connection
    // nicknames — operational metadata that shouldn't ship verbatim in
    // diagnostics. Keep that default; let individual call sites opt into
    // `privacy: .public` where they explicitly want a public correlator.

    static func debug(_ message: String, log: Category) {
        log.logger.debug("\(message)")
    }

    static func info(_ message: String, log: Category) {
        log.logger.info("\(message)")
    }

    static func error(_ message: String, log: Category) {
        log.logger.error("\(message)")
    }
}
