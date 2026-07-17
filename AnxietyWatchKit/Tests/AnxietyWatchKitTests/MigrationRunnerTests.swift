import XCTest
import GRDB
@testable import AnxietyWatchKit

final class MigrationRunnerTests: XCTestCase {

    // MARK: - V1 baseline

    func testV1BaselineAppliedOnNewDB() throws {
        let db = try makeNewDB()
        try db.write { db in
            try MigrationRunner.migrate(db)

            let tables = try String.fetchAll(db, sql: """
                SELECT name FROM sqlite_master WHERE type='table' ORDER BY name
                """)
            XCTAssertTrue(tables.contains("samples"))
            XCTAssertTrue(tables.contains("samples_1min"))
            XCTAssertTrue(tables.contains("sample_tombstones"))
            XCTAssertTrue(tables.contains("_sync_log"))
            XCTAssertTrue(tables.contains("_backfill_progress"))
            XCTAssertTrue(tables.contains("_sync_quarantine"))

            let version = try Int.fetchOne(db, sql: "PRAGMA user_version")
            XCTAssertEqual(version, MigrationRunner.latestVersion)
        }
    }

    func testMigrationIdempotent() throws {
        let db = try makeNewDB()
        try db.write { db in try MigrationRunner.migrate(db) }
        try db.write { db in
            try MigrationRunner.migrate(db)
            let version = try Int.fetchOne(db, sql: "PRAGMA user_version")
            XCTAssertEqual(version, MigrationRunner.latestVersion)
            let count = try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM sqlite_master WHERE type='table'
                """)
            try MigrationRunner.migrate(db)
            let countAfter = try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM sqlite_master WHERE type='table'
                """)
            XCTAssertEqual(count, countAfter)
        }
    }

    func testUpgradeV1ToV2() throws {
        let db = try makeNewDB()
        try db.write { db in try SchemaV1.apply(to: db) }
        try db.read { db in
            let v = try Int.fetchOne(db, sql: "PRAGMA user_version")
            XCTAssertEqual(v, 1)
        }
        try db.write { db in try MigrationRunner.migrate(db) }
        try db.read { db in
            let v = try Int.fetchOne(db, sql: "PRAGMA user_version")
            XCTAssertEqual(v, MigrationRunner.latestVersion)
        }
    }

    func testV2EmptyMigrationDoesNotAlterData() throws {
        let db = try makeNewDB()
        try db.write { db in
            try SchemaV1.apply(to: db)
            try db.execute(sql: """
                INSERT INTO samples (source, type, timestamp, value,
                    hlc_physical, hlc_logical, node_id)
                VALUES (2, 1, 1.0, 72.0, 1000, 0,
                    x'000102030405060708090a0b0c0d0e0f')
                """)
        }
        try db.write { db in try MigrationRunner.migrate(db) }
        try db.read { db in
            let count = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM samples")
            XCTAssertEqual(count, 1)
            let value = try Double.fetchOne(db, sql: "SELECT value FROM samples WHERE timestamp = 1.0")
            XCTAssertEqual(value, 72.0)
        }
    }

    func testSavepointRollbackOnFaultyMigration() throws {
        let db = try makeNewDB()
        try db.write { db in
            try SchemaV1.apply(to: db)
            let preVersion = try Int.fetchOne(db, sql: "PRAGMA user_version")
            XCTAssertEqual(preVersion, 1)
            do {
                try db.inSavepoint {
                    try db.execute(sql: "CREATE TABLE IF NOT EXISTS migration_test (id INTEGER PRIMARY KEY)")
                    throw DatabaseError(message: "simulated failure")
                }
            } catch { /* expected */ }
            let exists = try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='migration_test'
                """)
            XCTAssertEqual(exists, 0)
            let postVersion = try Int.fetchOne(db, sql: "PRAGMA user_version")
            XCTAssertEqual(postVersion, 1)
        }
    }

    func testLatestVersionMatchesSchemaV2() {
        XCTAssertEqual(MigrationRunner.latestVersion, SchemaV2.version)
        XCTAssertEqual(SchemaV1.version, 1)
        XCTAssertEqual(SchemaV2.version, 2)
    }

    // MARK: - Helpers

    private func makeNewDB() throws -> DatabaseQueue {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("migration_test_\(UUID().uuidString).sqlite")
        return try DatabaseQueue(path: tempURL.path)
    }
}
