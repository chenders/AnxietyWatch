import Foundation
import GRDB

/// Schema version 2 — incremental changes from V1 → V2.
///
/// Applied by `MigrationRunner` when `PRAGMA user_version` < 2.
/// Each statement uses `IF NOT EXISTS` so it is idempotent.
public enum SchemaV2 {
    public static let version: Int = 2

    /// V2 DDL statements. Currently empty — V2 reserves the version
    /// number to signal the migration infrastructure is active. Future
    /// columns, tables, or indexes are appended here.
    public static let statements: [String] = []

    /// Applies V2 migrations within a savepoint.
    public static func apply(to db: Database) throws {
        try db.inSavepoint {
            for sql in statements {
                try db.execute(sql: sql)
            }
            try db.execute(sql: "PRAGMA user_version = \(version);")
            return .commit
        }
    }
}
