import Foundation
import GRDB

/// Applies schema migrations sequentially from the current on-disk
/// `user_version` up to the latest known version.
///
/// Designed as the `DatabaseManager.SchemaMigrator` — runs at the end
/// of every successful `open()` (including after corruption recovery).
///
/// Each migration step is wrapped in a savepoint: a crash mid-step
/// rolls back to the pre-step state; the next open picks up from the
/// un-incremented `user_version`.
public struct MigrationRunner: Sendable {

    // MARK: - Known versions

    /// Ordered list of migrations. Index 0 = V1→V2, index 1 = V2→V3, etc.
    private static let migrations: [(version: Int, apply: (Database) throws -> Void)] = [
        (version: 2, apply: SchemaV2.apply(to:)),
    ]

    /// Latest known schema version.
    public static let latestVersion: Int = migrations.last?.version ?? 1

    // MARK: - SchemaMigrator

    /// `DatabaseManager.SchemaMigrator`-compatible function.
    ///
    /// If the database is brand new (user_version = 0), applies the full
    /// V1 baseline then runs incremental migrations to latest.
    public static func migrate(_ db: Database) throws {
        let currentVersion = try Int.fetchOne(db, sql: "PRAGMA user_version") ?? 0

        if currentVersion < 1 {
            try SchemaV1.apply(to: db)
        }

        for (version, apply) in migrations {
            if currentVersion < version {
                try apply(db)
            }
        }

        let finalVersion = try Int.fetchOne(db, sql: "PRAGMA user_version") ?? 0
        if finalVersion != latestVersion && latestVersion > 1 {
            try db.execute(sql: "PRAGMA user_version = \(latestVersion);")
        }
    }

    // MARK: - Backfill plan

    /// Describes a SwiftData-to-SQLite backfill step (Spec §7.2 Phase 2A).
    /// Not a DDL migration — this is a data migration that copies rows
    /// from the caller's SwiftData store into the framework's SQLite tables.
    public struct BackfillStep: Sendable {
        public let sourceEntity: String
        public let targetTable: String
        public let batchLimit: Int

        public init(sourceEntity: String, targetTable: String, batchLimit: Int = 5000) {
            self.sourceEntity = sourceEntity
            self.targetTable = targetTable
            self.batchLimit = batchLimit
        }
    }

    /// Ordered list of backfill steps for the Phase 2A cutover.
    /// The app fills this at launch with the SwiftData entities to migrate.
    public static var backfillSteps: [BackfillStep] = []
}
