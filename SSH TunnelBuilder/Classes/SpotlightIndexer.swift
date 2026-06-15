import Foundation
import CoreSpotlight
import UniformTypeIdentifiers

/// Donates SSH connections to Core Spotlight so the user can find them from
/// system-wide search.
///
/// **Opt-in and privacy-conscious by design.** This app is an SSH connection
/// manager, so the connection list is effectively infrastructure inventory:
/// - Nothing is indexed unless the user explicitly turns the feature on in
///   Settings (`isEnabled`, defaulting to `false`).
/// - Only the connection's *name* is indexed — never the hostname, username,
///   port, private key, or any other credential. Secrets live in the Keychain
///   and are never donated to the system-wide Spotlight index.
enum SpotlightIndexer {
    /// Shared domain for every donated connection, so the whole set can be
    /// cleared in a single call when the user opts out.
    static let domainIdentifier = "no.comraich.sshTunnelBuilder.connections"

    /// `UserDefaults` key backing the Settings toggle. Shared with the
    /// `@AppStorage` binding in `SettingsView` so both read the same source.
    static let enabledDefaultsKey = "spotlightIndexingEnabled"

    /// Whether the user has opted in to Spotlight indexing. Defaults to `false`.
    static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: enabledDefaultsKey)
    }

    // MARK: - Indexing

    /// Indexes a single connection (name only). No-op unless the user opted in.
    @MainActor
    static func index(_ connection: Connection) {
        guard isEnabled else { return }
        donate([item(id: connection.id, name: connection.connectionInfo.name)])
    }

    /// Re-indexes the full set of connections. Used when the user first enables
    /// the feature so existing connections become searchable immediately.
    @MainActor
    static func indexAll(_ connections: [Connection]) {
        guard isEnabled else { return }
        let items = connections.map { item(id: $0.id, name: $0.connectionInfo.name) }
        guard !items.isEmpty else { return }
        donate(items)
    }

    // MARK: - De-indexing

    /// Removes a single connection from the index. Runs regardless of the
    /// opt-in state so a deleted connection never lingers in Spotlight.
    static func deindex(id: UUID) {
        CSSearchableIndex.default().deleteSearchableItems(withIdentifiers: [id.uuidString]) { error in
            if let error {
                Logger.error("Spotlight de-index failed: \(error.localizedDescription)", log: Logger.spotlight)
            }
        }
    }

    /// Removes every donated connection. Used when the user disables the feature.
    static func deindexAll() {
        CSSearchableIndex.default().deleteSearchableItems(withDomainIdentifiers: [domainIdentifier]) { error in
            if let error {
                Logger.error("Spotlight clear-all failed: \(error.localizedDescription)", log: Logger.spotlight)
            }
        }
    }

    // MARK: - Private

    /// Builds a searchable item carrying only the connection name. Extracting
    /// `id`/`name` here keeps the (non-`Sendable`) `Connection` out of the
    /// escaping completion handler.
    private static func item(id: UUID, name: String) -> CSSearchableItem {
        let attributes = CSSearchableItemAttributeSet(contentType: .content)
        attributes.title = name
        attributes.displayName = name
        // Intentionally no host / username / port — see the type-level note.
        return CSSearchableItem(uniqueIdentifier: id.uuidString,
                                domainIdentifier: domainIdentifier,
                                attributeSet: attributes)
    }

    private static func donate(_ items: [CSSearchableItem]) {
        CSSearchableIndex.default().indexSearchableItems(items) { error in
            if let error {
                Logger.error("Spotlight index failed: \(error.localizedDescription)", log: Logger.spotlight)
            }
        }
    }
}
