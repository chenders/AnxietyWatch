import Foundation

/// Sync direction for a @Syncable type (Spec §2.4).
public enum SyncDirection: String, Sendable, Codable {
    /// Full round-trip: uploaded to the server AND restorable from it.
    /// Requires BOTH `encodeForSync()` and `init(fromSync:)` — enforced at
    /// compile time by the @Syncable macro (EMAY-loss regression guard).
    case bidirectional
    /// Upload-only (legacy telemetry).
    case upOnly
    /// Download-only (e.g. server-owned lookup tables).
    case downOnly
}

/// Conformance produced by the @Syncable macro. `SyncCoordinator.bootstrap()`
/// walks all registered types via `SyncRegistry`.
///
/// PRIMARY-KEY LIMITATION: the macro's `primaryKey` parameter supports a
/// SINGLE column (default "id"), rendered as `CAST(NEW.<pk> AS TEXT)` in the
/// generated triggers. Tables with composite primary keys must pass
/// `primaryKeyExpression:` with a NEW.-based SQL expression producing a
/// stable TEXT key (e.g. `NEW.source || '-' || NEW.type || '-' ||
/// CAST(NEW.timestamp AS TEXT)`); the DELETE trigger rewrites NEW. → OLD.
/// automatically.
public protocol Syncable {
    static var syncDirection: SyncDirection { get }
    static var syncTableName: String { get }
    /// SQLite trigger DDL applied by DatabaseManager on migrate. ALWAYS uses
    /// the mandatory `FROM (SELECT hlc_now_json() AS h)` scalar-subquery
    /// pattern (see `HLC.registerUDFs(on:)` for the contract).
    static var syncTriggerDDL: String { get }
    static func registerForSync(_ registry: SyncRegistry) async
}

/// Attached member macro. Expansion produces on the annotated struct/class:
/// - `public static let syncDirection: SyncDirection`
/// - `public static let syncTableName: String` (defaults to the type name in
///   lowercased_snake form when `tableName` is nil)
/// - `public static let syncTriggerDDL: String` (INSERT/UPDATE/DELETE triggers
///   into `_sync_log` using the mandatory hlc_now_json() subquery pattern)
/// - `public static func registerForSync(_ registry: SyncRegistry) async`
///
/// Compile-time enforcement: `.bidirectional` (the default) requires the type
/// to implement BOTH `encodeForSync()` and `init(fromSync:)`; missing either
/// produces a macro diagnostic. This is the EMAY-loss regression guard.
@attached(member, names: named(syncDirection), named(syncTableName), named(syncTriggerDDL), named(registerForSync))
public macro Syncable(
    direction: SyncDirection = .bidirectional,
    tableName: String? = nil,
    primaryKey: String = "id",
    primaryKeyExpression: String? = nil
) = #externalMacro(module: "AnxietyWatchKitMacros", type: "SyncableMacro")
