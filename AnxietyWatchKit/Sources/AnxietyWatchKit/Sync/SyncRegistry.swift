import Foundation

/// Collects all @Syncable types at `SyncCoordinator.bootstrap()` time. Each
/// generated `registerForSync(_:)` calls `register(_:)`; the coordinator then
/// reads `registered` to apply trigger DDL and wire encoders/decoders.
public actor SyncRegistry {
    private var entries: [(name: String, direction: SyncDirection, ddl: String)] = []

    public init() {}

    public func register<T: Syncable>(_ type: T.Type) {
        // Idempotent per table: re-registering the same table replaces the entry
        // (bootstrap may run more than once, e.g. after corruption recovery).
        entries.removeAll { $0.name == type.syncTableName }
        entries.append((name: type.syncTableName, direction: type.syncDirection, ddl: type.syncTriggerDDL))
    }

    public var registered: [(name: String, direction: SyncDirection, ddl: String)] {
        entries
    }
}
